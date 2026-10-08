// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {StreamVault} from "../src/StreamVault.sol";
import {HandleRegistry} from "../src/HandleRegistry.sol";

/// @notice Verified token and network constants.
///
/// Every value here was read off the chain with `cast` on 2026-10-07, not copied from a
/// README. Re-verify before trusting a deployment:
///
///   cast chain-id --rpc-url https://rpc.monad.xyz                # 143
///   cast call 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a 'symbol()(string)'  --rpc-url ...
library MonameConfig {
    // ---- networks -------------------------------------------------------
    uint256 internal constant MAINNET_CHAIN_ID = 143;
    uint256 internal constant TESTNET_CHAIN_ID = 10143;

    // ---- Agora AUSD: the primary token ----------------------------------
    // 6 decimals, EIP-2612 permit (DOMAIN_SEPARATOR present), EIP-3009
    // transferWithAuthorization (selector 0xe3ee160e in bytecode).
    // EIP-1967 proxy; implementation 0xc1e3C7D486d6A92fBE920232E439EeC2cEb112dA.
    // Mainnet supply at verification: 144,570,251 AUSD.
    // Codesize is 5937 on BOTH networks — identical bytecode.
    address internal constant AUSD_MAINNET = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address internal constant AUSD_TESTNET = 0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC;

    // ---- Circle USDC: secondary, mainnet only ---------------------------
    // 6 decimals, permit-capable. NOT deployed on testnet (verified: codesize 0).
    // Bridgeable in via CCTP V2, where Circle charges Monad 0 bps.
    address internal constant USDC_MAINNET = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;

    // ---- Relay destination executor: the inbound forwarder ----------------
    // This is the address Relay delivers bridged tokens to, and therefore the
    // msg.sender that will call creditArrival. Found in a live /quote/v2
    // response at output.payments[].recipient and verified on chain 143 with
    // `cast codesize` = 4720 bytes on 2026-10-08.
    //
    // Setting it as the forwarder is a TRUST DECISION, not a formality: whoever
    // holds `forwarder` can direct existing vault balance to any recipient,
    // because creditArrival pulls nothing and only checks the vault's balance.
    // test_creditArrival_trustBoundary_forwarderCanDirectExistingVaultBalance
    // asserts that this succeeds, so the assumption is explicit rather than
    // folklore. Relay's executor and solver network are better-trusted than a
    // single key we hold, but the README must say so and not claim trustlessness.
    address internal constant RELAY_EXECUTOR_MONAD = 0xb92fe925DC43a0ECdE6c8b1a2709c170Ec4fFf4f;

    /// @notice The dollar token for whichever chain we are on. AUSD first: it is the token
    /// the Agora cross-border bounty names, and it is the only dollar stablecoin that
    /// exists on both networks.
    function primaryToken() internal view returns (address) {
        if (block.chainid == MAINNET_CHAIN_ID) return AUSD_MAINNET;
        if (block.chainid == TESTNET_CHAIN_ID) return AUSD_TESTNET;
        return address(0); // a local anvil has no real dollar token; use test/mocks
    }
}

/// @notice Deploys the Moname contracts.
///
///   # mainnet (chain 143) — the submission target
///   forge script script/Deploy.s.sol:Deploy --rpc-url monad --broadcast \
///     --private-key $MONAD_PRIVATE_KEY --verify
///
///   # testnet (chain 10143)
///   forge script script/Deploy.s.sol:Deploy --rpc-url monad_testnet --broadcast \
///     --private-key $MONAD_PRIVATE_KEY
///
/// Set FORWARDER_ADDRESS to whoever may call `creditArrival`. On mainnet that is Relay's
/// destination executor, `MonameConfig.RELAY_EXECUTOR_MONAD`
/// (0xb92fe925dc43a0ecde6c8b1a2709c170ec4fff4f), which is what makes cross-chain arrivals
/// open a stream atomically. Left unset it deploys as address(0), which makes creditArrival
/// revert ZeroAddress — no inbound path rather than an open one. Read the trust note on that
/// constant before setting it.
///
/// ⚠️ Monad charges gas on the DECLARED limit, not gas used, so an over-estimate is real
/// money. Pass --gas-limit and --gas-price explicitly on mainnet.
contract Deploy is Script {
    function run() external {
        address forwarder = vm.envOr("FORWARDER_ADDRESS", address(0));

        vm.startBroadcast();

        HandleRegistry handles = new HandleRegistry();
        StreamVault vault = new StreamVault(forwarder);

        vm.stopBroadcast();

        address token = MonameConfig.primaryToken();

        console2.log("");
        console2.log("=== Moname deployment ===");
        console2.log("chain id:        ", block.chainid);
        console2.log("StreamVault:     ", address(vault));
        console2.log("HandleRegistry:  ", address(handles));
        console2.log("forwarder:       ", forwarder);
        console2.log("primary token:   ", token);
        if (token == address(0)) {
            console2.log("  ^ no real dollar token on this chain id; use test/mocks locally");
        }
        if (forwarder == address(0)) {
            console2.log("  ^ creditArrival is DISABLED (fails closed). Set FORWARDER_ADDRESS.");
        }
        console2.log("");
        console2.log("Paste the four values above into README.md > Deployment.");
        console2.log("Section 9.2 accepts contract addresses OR tx hashes; record both.");
    }
}
