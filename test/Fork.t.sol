// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StreamVault} from "../src/StreamVault.sol";
import {HandleRegistry} from "../src/HandleRegistry.sol";

/// @notice Fork tests against REAL Monad mainnet (chain 143) and REAL tokens.
///
/// Mock tokens in StreamVault.t.sol prove our arithmetic. They do not prove the arithmetic
/// holds against a real 6-decimal stablecoin with real EIP-2612 permit semantics on real
/// mainnet state. This file does, and costs nothing to run.
///
///   forge test --match-contract ForkMainnetTest -vv
///
/// Token coverage, and an honest note on its limits:
///
///   - USDC  0x754704Bc059F8C67012fEd69BC8A327a5aafb603 — Circle native, standard ERC-20
///     storage layout, so we can fund a fork account and run the whole streaming flow
///     against it end to end.
///
///   - AUSD  0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a — Agora's dollar stablecoin, and
///     the token the Agora cross-border bounty names. Its identity, decimals, supply and
///     EIP-712 permit domain are all asserted here against live mainnet. What is NOT done
///     here is funding an account with it: AUSD is an EIP-1967 proxy (implementation
///     0xc1e3C7D486d6A92fBE920232E439EeC2cEb112dA) whose balance mapping is not at a
///     discoverable low slot, so neither forge-std's `deal` nor a 1024-slot scan can write
///     one. AUSD-funded flows are therefore covered on testnet, where Agora's AUSD is the
///     identical bytecode (codesize 5937 on both networks, verified).
///
/// Both tokens are 6 decimals on Monad, which is why StreamVault needs no adaptation layer
/// to serve either — see test_bothStablecoinsShareOurAssumptions.
contract ForkMainnetTest is Test {
    address constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;

    StreamVault vault;
    HandleRegistry handles;

    address sender = makeAddr("sender");
    address recipient = makeAddr("recipient");
    address forwarder = makeAddr("forwarder");
    address session = vm.addr(0xa11ce);

    uint128 constant AMOUNT = 1_000_000_000; // 1,000.00 at 6 decimals
    uint64 constant DURATION = 3600; // one hour

    function setUp() public {
        vm.createSelectFork("monad");
        assertEq(block.chainid, 143, "must be Monad mainnet");

        vault = new StreamVault(forwarder);
        handles = new HandleRegistry();

        _fund(USDC, sender, uint256(AMOUNT) * 10);
        vm.prank(sender);
        IERC20(USDC).approve(address(vault), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // Real AUSD on real mainnet — view-level, needs no funding
    // ------------------------------------------------------------------

    function test_realAUSD_identity() public view {
        assertEq(IERC20MetaProbe(AUSD).symbol(), "AUSD");
        assertEq(IERC20MetaProbe(AUSD).decimals(), 6, "same decimals as USDC");
        uint256 supply = IERC20MetaProbe(AUSD).totalSupply();
        assertTrue(supply > 0, "AUSD is live on mainnet");
        console2.log("AUSD total supply (whole units):", supply / 1e6);
    }

    /// AUSD being EIP-2612 permit-capable is what makes the gasless inbound path work:
    /// the payer signs, never holds MON, never sends a transaction.
    function test_realAUSD_supportsPermit() public view {
        assertTrue(
            IERC20PermitProbe(AUSD).DOMAIN_SEPARATOR() != bytes32(0),
            "AUSD exposes a real EIP-712 domain"
        );
        assertEq(IERC20PermitProbe(AUSD).nonces(sender), 0, "fresh account has nonce 0");
    }

    /// Both stablecoins satisfy every assumption StreamVault makes, so one deployment
    /// serves either and the token choice is configuration, not code.
    function test_bothStablecoinsShareOurAssumptions() public view {
        assertEq(IERC20MetaProbe(USDC).decimals(), 6);
        assertEq(IERC20MetaProbe(AUSD).decimals(), 6);
        assertTrue(IERC20PermitProbe(USDC).DOMAIN_SEPARATOR() != bytes32(0), "USDC permit");
        assertTrue(IERC20PermitProbe(AUSD).DOMAIN_SEPARATOR() != bytes32(0), "AUSD permit");
    }

    // ------------------------------------------------------------------
    // Full streaming flow against a real mainnet stablecoin
    // ------------------------------------------------------------------

    function test_streamRealUSDC_endToEnd() public {
        vm.prank(recipient);
        handles.register("arinza");
        assertEq(handles.resolve("arinza"), recipient, "payable by handle, not hex");

        address[] memory controllers = new address[](1);
        controllers[0] = session;
        vm.prank(sender);
        uint256 id = vault.createStreamWithControllers(
            recipient, USDC, AMOUNT, DURATION, controllers
        );

        assertEq(IERC20(USDC).balanceOf(address(vault)), AMOUNT, "principal escrowed");
        assertEq(IERC20(USDC).balanceOf(sender), uint256(AMOUNT) * 9, "sender debited once");

        vm.warp(block.timestamp + 1800);
        uint128 half = vault.accrued(id);
        assertEq(half, AMOUNT / 2, "exactly half at the halfway point");

        vm.prank(recipient);
        vault.withdrawAll(id);
        assertEq(IERC20(USDC).balanceOf(recipient), half, "recipient holds real USDC");

        // Session key may pause; a stranger may not.
        vm.warp(block.timestamp + 600);
        vm.prank(session);
        vault.pause(id, uint64(block.timestamp + 300));
        uint128 frozen = vault.accrued(id);

        vm.warp(block.timestamp + 100);
        assertEq(vault.accrued(id), frozen, "frozen while paused");

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(StreamVault.NotSenderOrController.selector);
        vault.pause(id, uint64(block.timestamp + 9999));

        // Expiry passes with nobody calling resume(): accrual restarts on its own.
        vm.warp(block.timestamp + 400);
        assertGt(vault.accrued(id), frozen, "auto-unfroze at the scheduled expiry");

        vm.warp(block.timestamp + DURATION * 2);
        assertEq(vault.accrued(id), AMOUNT, "fully accrued");
        vm.prank(recipient);
        vault.withdrawAll(id);

        assertEq(IERC20(USDC).balanceOf(recipient), AMOUNT, "every cent, no more");
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0, "vault drained exactly");
        assertEq(vault.withdrawable(id), 0, "nothing left to claim");
    }

    /// Gasless inbound: the forwarder credits tokens that already landed, with no
    /// transferFrom, so the payer is never charged twice.
    function test_creditArrival_withRealUSDC() public {
        _fund(USDC, address(vault), 500_000_000); // a bridged transfer landed

        uint256 next = vault.nextId();
        vm.prank(forwarder);
        vault.creditArrival(recipient, USDC, 500_000_000, 1800);

        assertEq(IERC20(USDC).balanceOf(address(vault)), 500_000_000, "no double charge");
        vm.warp(block.timestamp + 1800);
        vm.prank(recipient);
        vault.withdrawAll(next);
        assertEq(IERC20(USDC).balanceOf(recipient), 500_000_000);
    }

    function test_creditArrival_rejectsNonForwarder() public {
        _fund(USDC, address(vault), 500_000_000);
        vm.prank(recipient);
        vm.expectRevert(StreamVault.NotSender.selector);
        vault.creditArrival(recipient, USDC, 500_000_000, 1800);
    }

    // ------------------------------------------------------------------
    // Fork funding helper
    // ------------------------------------------------------------------

    /// Locate an ERC-20 `balances` mapping base slot by writing a sentinel at
    /// keccak256(probe, p) and seeing which p `balanceOf` reflects. No `vm.load` in the
    /// loop: on a fork every unknown-slot read is an RPC round trip.
    function _findBalanceSlot(address token) internal returns (uint256) {
        address probe = makeAddr("slot-probe");
        uint256 sentinel = 123456789;
        for (uint256 p = 0; p < 64; p++) {
            bytes32 loc = keccak256(abi.encode(probe, p));
            vm.store(token, loc, bytes32(sentinel));
            uint256 got = IERC20(token).balanceOf(probe);
            vm.store(token, loc, bytes32(0));
            if (got == sentinel) return p;
        }
        revert("could not locate balances mapping");
    }

    function _fund(address token, address to, uint256 amount) internal {
        uint256 p = _findBalanceSlot(token);
        bytes32 loc = keccak256(abi.encode(to, p));
        uint256 cur = uint256(vm.load(token, loc));
        vm.store(token, loc, bytes32(cur + amount));
        assertEq(IERC20(token).balanceOf(to), cur + amount, "funding took effect");
    }
}

interface IERC20PermitProbe {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function nonces(address) external view returns (uint256);
}

/// OZ's IERC20 deliberately omits the optional metadata + permit methods, so probe them.
interface IERC20MetaProbe {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
}
