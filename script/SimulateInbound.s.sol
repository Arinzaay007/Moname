// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StreamVault} from "../src/StreamVault.sol";
import {HandleRegistry} from "../src/HandleRegistry.sol";
import {MockAUSD} from "../test/mocks/MockAUSD.sol";
import {MockRelayExecutor} from "../test/mocks/MockRelayExecutor.sol";

/// @notice Proves the cross-border INBOUND leg against a live local deployment.
///
/// `tools/test-relay.sh` proves the gasless permit path. This proves the other half:
/// money arriving from another chain and opening a stream atomically, with no watcher
/// and no second transaction.
///
/// It reproduces what Relay actually does, measured from a live `/quote/v2` response
/// rather than assumed. Relay delivers bridged tokens to its OWN executor contract
/// (`output.payments[].recipient`), then runs the destination calls from `output.calls`
/// in order inside one transaction. For Moname that batch is:
///
///     [0] AUSD.transfer(StreamVault, amount)
///     [1] StreamVault.creditArrival(recipient, AUSD, amount, duration)
///
/// `creditArrival` performs no `transferFrom` on purpose -- the tokens have already
/// landed, and pulling again is how funds get double-charged. That is why the order is
/// load-bearing and why this cannot be collapsed into one call.
///
/// On mainnet the forwarder must be Relay's real executor,
/// `MonameConfig.RELAY_EXECUTOR_MONAD` = 0xb92fe925dc43a0ecde6c8b1a2709c170ec4fff4f.
/// Here we deploy a mock so the whole path is exercisable without a bridge.
///
///   # after tools/local-dev.sh
///   forge script script/SimulateInbound.s.sol:SimulateInbound \
///     --rpc-url http://127.0.0.1:8545 --broadcast \
///     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
contract SimulateInbound is Script {
    function run() external {
        StreamVault vault = StreamVault(vm.envAddress("NEXT_PUBLIC_STREAM_VAULT"));
        HandleRegistry registry = HandleRegistry(vm.envAddress("NEXT_PUBLIC_HANDLE_REGISTRY"));
        MockAUSD token = MockAUSD(vm.envAddress("NEXT_PUBLIC_AUSD_ADDRESS"));

        string memory handle = vm.envOr("INBOUND_HANDLE", string("arinza"));
        uint128 amount = uint128(vm.envOr("INBOUND_AMOUNT", uint256(100_000_000))); // $100.00
        uint64 duration = uint64(vm.envOr("INBOUND_DURATION", uint256(3600))); // 1 hour

        address recipient = registry.resolve(handle);
        console2.log("");
        console2.log("== Moname inbound arrival simulation ==");
        console2.log("  handle       @%s", handle);
        console2.log("  recipient    %s", recipient);
        console2.log("  token        %s", address(token));
        console2.log("  amount       %s units", amount);
        console2.log("  duration     %s s", duration);

        vm.startBroadcast();

        // 1. Stand in for Relay's destination executor and make it the forwarder.
        MockRelayExecutor exec = new MockRelayExecutor();
        console2.log("  executor     %s (mock; mainnet uses 0xb92fe925...)", address(exec));
        vault.setForwarder(address(exec));
        require(vault.forwarder() == address(exec), "forwarder not set");

        // 2. Relay's solver fills: tokens land at the EXECUTOR, not at the vault.
        token.mint(address(exec), amount);
        require(token.balanceOf(address(exec)) == amount, "fill did not land");
        console2.log("  filled       executor holds %s", token.balanceOf(address(exec)));

        uint256 expectedId = vault.nextId();
        uint256 vaultBefore = token.balanceOf(address(vault));

        // 3. One transaction, two calls, in the order Relay returned them.
        MockRelayExecutor.Call[] memory calls = new MockRelayExecutor.Call[](2);
        calls[0] = MockRelayExecutor.Call({
            to: address(token),
            value: 0,
            data: abi.encodeCall(IERC20.transfer, (address(vault), uint256(amount)))
        });
        calls[1] = MockRelayExecutor.Call({
            to: address(vault),
            value: 0,
            data: abi.encodeCall(StreamVault.creditArrival, (recipient, address(token), amount, duration))
        });
        exec.execute(calls);

        vm.stopBroadcast();

        // ---- verify from chain state, not from the transaction's return value ----
        // A public mapping to a struct generates a getter returning a TUPLE of its
        // fields, not the struct itself, so this destructures all twelve.
        (
            address sSender,
            address sRecipient,
            address sToken,
            uint128 sAmount,
            uint128 sWithdrawn,
            uint64 sStart,
            uint64 sEnd,
            uint64 sPausedFrom,
            uint64 sPausedUntil,
            uint64 sPausedTotal,
            bool sCancelled,
            uint8 sControllerCount
        ) = vault.streams(expectedId);
        sToken; sWithdrawn; sPausedFrom; sPausedUntil; sPausedTotal; sControllerCount;

        console2.log("");
        console2.log("== stream #%s opened by the arrival ==", expectedId);
        console2.log("  sender       %s", sSender);
        console2.log("  recipient    %s", sRecipient);
        console2.log("  amount       %s", sAmount);
        console2.log("  start        %s", sStart);
        console2.log("  end          %s", sEnd);
        console2.log("  cancelled    %s", sCancelled ? "true" : "false");

        require(sRecipient == recipient, "wrong recipient");
        require(sSender == recipient, "arrival streams set sender to the recipient");
        require(sAmount == amount, "wrong amount");
        require(sEnd - sStart == duration, "wrong duration");
        require(!sCancelled, "born cancelled");
        require(vault.nextId() == expectedId + 1, "id did not advance by exactly one");
        require(token.balanceOf(address(exec)) == 0, "executor left holding funds");
        require(token.balanceOf(address(vault)) == vaultBefore + amount, "vault did not receive the fill");

        console2.log("");
        console2.log("  vault balance  %s -> %s", vaultBefore, token.balanceOf(address(vault)));
        console2.log("  executor left  %s", token.balanceOf(address(exec)));
        console2.log("  accrued now    %s", vault.accrued(expectedId));
        console2.log("  withdrawable   %s", vault.withdrawable(expectedId));

        console2.log("");
        console2.log("PASS  a cross-chain arrival opened stream #%s atomically:", expectedId);
        console2.log("      tokens landed at the executor, moved to the vault, and the");
        console2.log("      stream opened -- all in ONE transaction, with no watcher and");
        console2.log("      nothing pulled from anyone twice.");
        console2.log("");
        console2.log("      Watch it accrue:  /h/@%s", handle);
    }
}
