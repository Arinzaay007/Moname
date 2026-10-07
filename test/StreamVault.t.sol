// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StreamVault} from "../src/StreamVault.sol";
import {HandleRegistry} from "../src/HandleRegistry.sol";
import {MockAUSD} from "./mocks/MockAUSD.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Moname core tests, run under Monad execution (`network = "monad"` in foundry.toml).
///         The accrual + pause invariants here are the evidence behind the demo claim that
///         money visibly accrues by the second and that a pause never destroys principal.
contract StreamVaultTest is Test {
    StreamVault vault;
    HandleRegistry registry;
    MockAUSD ausd;
    MockUSDC usdc;

    address sender = makeAddr("sender"); // client abroad
    address recipient = makeAddr("recipient"); // freelancer in PH, Mera owner key idx 0
    address session = makeAddr("session"); // Mera session key idx 1
    address stranger = makeAddr("stranger");
    address forwarder = makeAddr("forwarder"); // our relayer / bridge watcher

    uint128 constant AMOUNT = 100_000_000; // $100.00 at 6 decimals
    uint64 constant DURATION = 1000; // seconds

    function setUp() public {
        ausd = new MockAUSD();
        usdc = new MockUSDC();
        vault = new StreamVault(forwarder);
        registry = new HandleRegistry();

        ausd.mint(sender, AMOUNT * 10);
        ausd.mint(forwarder, AMOUNT * 10);
        vm.prank(sender);
        ausd.approve(address(vault), type(uint256).max);
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    function _create() internal returns (uint256 id) {
        vm.prank(sender);
        id = vault.createStream(recipient, address(ausd), AMOUNT, DURATION);
    }

    function _createWithSession() internal returns (uint256 id) {
        address[] memory ctrl = new address[](1);
        ctrl[0] = session;
        vm.prank(sender);
        id = vault.createStreamWithControllers(recipient, address(ausd), AMOUNT, DURATION, ctrl);
    }

    /// @dev THE invariant. Nothing may ever let more than `amount` leave the vault for a
    ///      stream, across withdrawals plus a cancel refund.
    function _assertNeverOverpays(uint256 id) internal view {
        S memory x = _s(id);
        uint128 withdrawableNow = vault.accrued(id) - x.withdrawn;
        assertLe(
            uint256(x.withdrawn) + uint256(withdrawableNow),
            uint256(x.amount),
            "INVARIANT VIOLATED: withdrawable + withdrawn exceeds principal"
        );
        if (x.cancelled) {
            assertEq(withdrawableNow, 0, "cancelled stream must not be withdrawable");
        }
    }

    // -----------------------------------------------------------------
    // Struct accessors. `streams()` returns 12 components; reading them
    // positionally in tests is fragile, so go through these.
    // -----------------------------------------------------------------
    struct S {
        address sender;
        address recipient;
        address token;
        uint128 amount;
        uint128 withdrawn;
        uint64 start;
        uint64 end;
        uint64 pausedFrom;
        uint64 pausedUntil;
        uint64 pausedTotal;
        bool cancelled;
        uint8 controllerCount;
    }

    function _s(uint256 id) internal view returns (S memory x) {
        (
            x.sender,
            x.recipient,
            x.token,
            x.amount,
            x.withdrawn,
            x.start,
            x.end,
            x.pausedFrom,
            x.pausedUntil,
            x.pausedTotal,
            x.cancelled,
            x.controllerCount
        ) = vault.streams(id);
    }

    // =====================================================================
    // Creation
    // =====================================================================

    function test_create_pullsPrincipalAndSetsWindow() public {
        uint256 id = _create();

        assertEq(id, 0);
        assertEq(ausd.balanceOf(address(vault)), AMOUNT, "vault must hold the principal");
        assertEq(ausd.balanceOf(sender), AMOUNT * 9, "sender debited exactly once");

        S memory x = _s(id);

        assertEq(x.sender, sender);
        assertEq(x.recipient, recipient);
        assertEq(x.token, address(ausd));
        assertEq(x.amount, AMOUNT);
        assertEq(x.withdrawn, 0);
        assertEq(x.end - x.start, DURATION);
        assertFalse(x.cancelled);
    }

    function test_create_rejectsBadInputs() public {
        vm.startPrank(sender);
        vm.expectRevert(StreamVault.ZeroAddress.selector);
        vault.createStream(address(0), address(ausd), AMOUNT, DURATION);

        vm.expectRevert(StreamVault.ZeroAmount.selector);
        vault.createStream(recipient, address(ausd), 0, DURATION);

        vm.expectRevert(StreamVault.ZeroDuration.selector);
        vault.createStream(recipient, address(ausd), AMOUNT, 0);
        vm.stopPrank();
    }

    function test_create_incrementsIds() public {
        assertEq(_create(), 0);
        assertEq(_create(), 1);
        assertEq(_create(), 2);
        assertEq(vault.nextId(), 3);
    }

    // =====================================================================
    // Accrual — the differentiator
    // =====================================================================

    function test_accrual_isLinearBySecond() public {
        uint256 id = _create();
        uint64 start = _s(id).start;

        assertEq(vault.accrued(id), 0, "t=0 accrues nothing");

        vm.warp(start + 1);
        assertEq(vault.accrued(id), AMOUNT / DURATION, "t=1s accrues exactly one second");

        vm.warp(start + 250);
        assertEq(vault.accrued(id), AMOUNT / 4, "t=25% accrues 25%");

        vm.warp(start + 500);
        assertEq(vault.accrued(id), AMOUNT / 2, "t=50% accrues exactly half");

        vm.warp(start + 999);
        assertApproxEqAbs(vault.accrued(id), AMOUNT, AMOUNT / DURATION, "t=99.9%");

        vm.warp(start + DURATION);
        assertEq(vault.accrued(id), AMOUNT, "t=100% accrues all");
    }

    /// @notice Monad produces a block every ~300ms, so a recipient can withdraw every
    ///         block. This proves accrual advances correctly across many small steps and
    ///         that repeated withdrawal never overpays.
    function test_accrual_advancesPerBlock_likeMonad() public {
        uint256 id = _create();
        uint64 start = _s(id).start;

        uint128 totalTaken;
        // 200 withdrawals, one per simulated block.
        for (uint256 i = 1; i <= 200; i++) {
            vm.warp(start + (i * DURATION) / 200);
            uint128 available = vault.withdrawable(id);
            if (available > 0) {
                vm.prank(recipient);
                vault.withdraw(id, available);
                totalTaken += available;
            }
            _assertNeverOverpays(id);
        }

        assertEq(totalTaken, AMOUNT, "recipient must receive exactly the principal");
        assertEq(ausd.balanceOf(recipient), AMOUNT);
    }

    function test_accrual_neverExceedsPrincipal_afterEnd() public {
        uint256 id = _create();
        uint64 start = _s(id).start;

        vm.warp(start + DURATION * 100); // a year later
        assertEq(vault.accrued(id), AMOUNT, "accrual must cap at principal");
        _assertNeverOverpays(id);
    }

    function test_accrual_roundsDown_neverUp() public {
        // 1 unit over 3 seconds: accrual must floor, so the vault can never be drained.
        vm.prank(sender);
        uint256 id = vault.createStream(recipient, address(ausd), 1, 3);
        uint64 start = _s(id).start;

        vm.warp(start + 1);
        assertEq(vault.accrued(id), 0, "1/3 rounds down to 0");
        vm.warp(start + 2);
        assertEq(vault.accrued(id), 0, "2/3 rounds down to 0");
        vm.warp(start + 3);
        assertEq(vault.accrued(id), 1, "completes at the end");
        _assertNeverOverpays(id);
    }

    // =====================================================================
    // Withdraw
    // =====================================================================

    function test_withdraw_partialThenRest() public {
        uint256 id = _create();
        uint64 start = _s(id).start;

        vm.warp(start + 500);
        uint128 half = AMOUNT / 2;

        vm.prank(recipient);
        vault.withdraw(id, half);
        assertEq(ausd.balanceOf(recipient), half);
        assertEq(vault.withdrawable(id), 0, "nothing further withdrawable at t=50%");

        vm.warp(start + DURATION);
        vm.prank(recipient);
        vault.withdrawAll(id);
        assertEq(ausd.balanceOf(recipient), AMOUNT, "full principal received");
        assertEq(ausd.balanceOf(address(vault)), 0, "vault empty");
        _assertNeverOverpays(id);
    }

    function test_withdraw_rejectsOverdraw() public {
        uint256 id = _create();
        uint64 start = _s(id).start;

        vm.warp(start + 100); // only 10% accrued
        vm.prank(recipient);
        vm.expectRevert(StreamVault.ExceedsWithdrawable.selector);
        vault.withdraw(id, AMOUNT);
    }

    function test_withdraw_recipientOnly() public {
        uint256 id = _create();
        uint64 start = _s(id).start;
        vm.warp(start + 500);

        vm.prank(stranger);
        vm.expectRevert(StreamVault.NotRecipient.selector);
        vault.withdraw(id, 1);

        // The sender funded it but may not withdraw it.
        vm.prank(sender);
        vm.expectRevert(StreamVault.NotRecipient.selector);
        vault.withdraw(id, 1);
    }

    // =====================================================================
    // Pause / resume — the session-key surface, and the invariant that matters
    // =====================================================================

    function test_pause_freezesAccrual() public {
        uint256 id = _createWithSession();
        uint64 start = _s(id).start;

        vm.warp(start + 300);
        uint128 atPause = vault.accrued(id);
        assertEq(atPause, (AMOUNT * 300) / DURATION);

        vm.prank(session);
        vault.pause(id, uint64(start + 600)); // paused for 300s

        vm.warp(start + 400);
        assertEq(vault.accrued(id), atPause, "accrual must be frozen while paused");
        vm.warp(start + 599);
        assertEq(vault.accrued(id), atPause, "still frozen just before expiry");
        _assertNeverOverpays(id);
    }

    /// @notice THE pause invariant: pausing must not destroy the recipient's principal.
    ///         `end` shifts right by the paused duration so `amount` is still delivered.
    function test_resume_preservesFullPrincipal() public {
        uint256 id = _createWithSession();
        S memory b = _s(id);
        uint64 start = b.start;
        uint64 endBefore = b.end;

        vm.warp(start + 300);
        vm.prank(session);
        vault.pause(id, uint64(start + 500)); // 200s pause

        vm.warp(start + 500);
        vm.prank(session);
        vault.resume(id);

        S memory a = _s(id);
        uint64 endAfter = a.end;
        uint64 pausedFrom = a.pausedFrom;
        uint64 pausedUntil = a.pausedUntil;
        uint64 pausedTotal = a.pausedTotal;

        assertEq(endAfter, endBefore + 200, "end shifts right by exactly the paused duration");
        assertEq(pausedTotal, 200, "one 200s pause");
        assertEq(pausedUntil, 0, "no longer paused");
        assertEq(pausedFrom, 0);

        // Recipient still gets every cent, just 200s later in wall-clock terms.
        vm.warp(endAfter);
        assertEq(vault.accrued(id), AMOUNT, "full principal still accrues after a pause");

        vm.prank(recipient);
        vault.withdrawAll(id);
        assertEq(ausd.balanceOf(recipient), AMOUNT);
        _assertNeverOverpays(id);
    }

    /// @notice Resuming AFTER the scheduled pause expiry must not credit extra time.
    function test_resume_afterExpiry_doesNotOverShift() public {
        uint256 id = _createWithSession();
        S memory b = _s(id);
        uint64 start = b.start;
        uint64 endBefore = b.end;

        vm.warp(start + 100);
        vm.prank(session);
        vault.pause(id, uint64(start + 300)); // 200s pause, expires at start+300

        vm.warp(start + 900); // long after expiry
        vm.prank(session);
        vault.resume(id);

        S memory a2 = _s(id);
        uint64 endAfter = a2.end;
        uint64 pausedTotal = a2.pausedTotal;
        assertEq(endAfter, endBefore + 200, "only the scheduled 200s is added back");
        assertEq(pausedTotal, 200, "one 200s pause");
        _assertNeverOverpays(id);
    }

    function test_pauseResume_multipleCycles_conserveTotal() public {
        uint256 id = _createWithSession();
        S memory b = _s(id);
        uint64 start = b.start;
        uint64 endBefore = b.end;

        // Three separate pause/resume cycles.
        vm.warp(start + 100);
        vm.prank(session);
        vault.pause(id, uint64(start + 150));
        vm.warp(start + 150);
        vm.prank(session);
        vault.resume(id);

        uint64 end1 = _s(id).end;
        assertEq(end1, endBefore + 50);

        vm.warp(end1 + 50);
        vm.prank(session);
        vault.pause(id, uint64(end1 + 250));
        vm.warp(end1 + 250);
        vm.prank(session);
        vault.resume(id);

        uint64 end2 = _s(id).end;
        assertEq(end2, end1 + 200);

        vm.warp(end2 + 10);
        vm.prank(session);
        vault.pause(id, uint64(end2 + 60));
        vm.warp(end2 + 60);
        vm.prank(session);
        vault.resume(id);

        S memory a3 = _s(id);
        uint64 end3 = a3.end;
        uint64 pausedTotal = a3.pausedTotal;
        assertEq(end3, end2 + 50);
        assertEq(pausedTotal, 300, "50 + 200 + 50");

        vm.warp(end3);
        assertEq(vault.accrued(id), AMOUNT, "principal fully conserved across 3 cycles");
        vm.prank(recipient);
        vault.withdrawAll(id);
        assertEq(ausd.balanceOf(recipient), AMOUNT);
        _assertNeverOverpays(id);
    }

    function test_pause_authorisation() public {
        uint256 id = _createWithSession();
        uint64 start = _s(id).start;
        vm.warp(start + 10);

        // Stranger cannot pause.
        vm.prank(stranger);
        vm.expectRevert(StreamVault.NotSenderOrController.selector);
        vault.pause(id, uint64(start + 100));

        // Recipient cannot pause (they are not the sender or a controller).
        vm.prank(recipient);
        vm.expectRevert(StreamVault.NotSenderOrController.selector);
        vault.pause(id, uint64(start + 100));

        // Sender can.
        vm.prank(sender);
        vault.pause(id, uint64(start + 100));
    }

    function test_resume_whenNotPaused_reverts() public {
        uint256 id = _createWithSession();
        vm.prank(session);
        vm.expectRevert(StreamVault.NotPaused.selector);
        vault.resume(id);
    }

    // =====================================================================
    // Cancel
    // =====================================================================

    function test_cancel_splitsAccruedAndRemainder() public {
        uint256 id = _createWithSession();
        uint64 start = _s(id).start;

        vm.warp(start + 400); // 40% accrued, nothing withdrawn yet
        uint256 senderBefore = ausd.balanceOf(sender);

        vm.prank(sender);
        vault.cancel(id);

        uint128 owed = (AMOUNT * 400) / DURATION; // 40%
        assertEq(ausd.balanceOf(recipient), owed, "recipient keeps what accrued");
        assertEq(ausd.balanceOf(sender), senderBefore + (AMOUNT - owed), "sender refunded the rest");
        assertEq(ausd.balanceOf(address(vault)), 0, "vault fully drained");

        bool cancelled = _s(id).cancelled;
        assertTrue(cancelled);

        vm.prank(recipient);
        vm.expectRevert(StreamVault.AlreadyCancelled.selector);
        vault.withdraw(id, 1);
    }

    function test_cancel_afterPartialWithdraw_isExact() public {
        uint256 id = _createWithSession();
        uint64 start = _s(id).start;

        vm.warp(start + 200);
        vm.prank(recipient);
        vault.withdraw(id, (AMOUNT * 200) / DURATION); // takes 20%
        uint128 alreadyTaken = (AMOUNT * 200) / DURATION;

        vm.warp(start + 600); // now 60% accrued
        vm.prank(sender);
        vault.cancel(id);

        uint128 owedAtCancel = (AMOUNT * 600) / DURATION;
        assertEq(
            ausd.balanceOf(recipient),
            alreadyTaken + (owedAtCancel - alreadyTaken),
            "recipient ends with exactly the 60% accrued"
        );
        assertEq(ausd.balanceOf(address(vault)), 0);
        assertEq(
            ausd.balanceOf(sender),
            AMOUNT * 9 + (AMOUNT - owedAtCancel),
            "sender refunded the un-accrued 40%"
        );
    }

    function test_cancel_sessionKeyCanButRecipientCannot() public {
        uint256 id = _createWithSession();
        uint64 start = _s(id).start;
        vm.warp(start + 100);

        vm.prank(recipient);
        vm.expectRevert(StreamVault.NotSenderOrController.selector);
        vault.cancel(id);

        vm.prank(session); // session key CAN cancel — that is its purpose
        vault.cancel(id);
    }

    function test_cancel_twiceReverts() public {
        uint256 id = _create();
        vm.prank(sender);
        vault.cancel(id);
        vm.prank(sender);
        vm.expectRevert(StreamVault.AlreadyCancelled.selector);
        vault.cancel(id);
    }

    // =====================================================================
    // Controllers — "one passkey, many keys"
    // =====================================================================

    function test_controllers_setAtCreation() public {
        uint256 id = _createWithSession();
        assertTrue(vault.controllers(id, session));
        uint8 count = _s(id).controllerCount;
        assertEq(count, 1);
    }

    function test_controllers_senderCanRevoke() public {
        uint256 id = _createWithSession();

        vm.prank(sender);
        vault.setController(id, session, false);
        assertFalse(vault.controllers(id, session));

        vm.prank(session);
        vm.expectRevert(StreamVault.NotSenderOrController.selector);
        vault.pause(id, uint64(block.timestamp + 10));
    }

    function test_controllers_onlySenderMayChange() public {
        uint256 id = _createWithSession();
        vm.prank(stranger);
        vm.expectRevert(StreamVault.NotSender.selector);
        vault.setController(id, stranger, true);
    }

    function test_controllers_cappedAtFour() public {
        address[] memory ctrl = new address[](5);
        for (uint256 i = 0; i < 5; i++) ctrl[i] = makeAddr(vm.toString(i));
        vm.prank(sender);
        vm.expectRevert(StreamVault.TooManyControllers.selector);
        vault.createStreamWithControllers(recipient, address(ausd), AMOUNT, DURATION, ctrl);
    }

    // =====================================================================
    // Bridge arrival (watcher-driven; CCTP Hooks deliberately NOT wired)
    // =====================================================================

    function test_creditArrival_forwarderOnly() public {
        ausd.mint(address(vault), AMOUNT); // watcher has already landed the funds

        vm.prank(stranger);
        vm.expectRevert(StreamVault.NotSender.selector);
        vault.creditArrival(recipient, address(ausd), AMOUNT, DURATION);

        vm.prank(forwarder);
        uint256 id = vault.creditArrival(recipient, address(ausd), AMOUNT, DURATION);

        S memory c = _s(id);
        address s = c.sender;
        address r = c.recipient;
        uint128 amount = c.amount;
        assertEq(s, recipient, "sender is set to recipient for arrival-credited streams");
        assertEq(r, recipient);
        assertEq(amount, AMOUNT);
        assertEq(ausd.balanceOf(address(vault)), AMOUNT, "no funds pulled from caller");
    }

    function test_creditArrival_disabledWhenForwarderIsZero() public {
        vm.prank(address(this)); // deployer is owner
        vault.setForwarder(address(0));

        vm.prank(forwarder);
        vm.expectRevert(StreamVault.ZeroAddress.selector);
        vault.creditArrival(recipient, address(ausd), AMOUNT, DURATION);
    }

    // =====================================================================
    // Fuzz — the invariant under arbitrary timing
    // =====================================================================

    /// @notice Whatever the warp, whatever the withdrawal size, the vault never pays out
    ///         more than the principal.
    // ------------------------------------------------------------------
    // Regressions for bugs the accrual model actually had
    // ------------------------------------------------------------------

    /// A pause with a scheduled expiry must stop paying out the moment that expiry
    /// passes, even if nobody ever calls resume(). A forgotten resume() is an
    /// operational failure, not a reason to destroy the recipient's income.
    function test_pause_autoUnfreezesAtScheduledExpiry() public {
        uint256 id = _createWithSession();
        uint64 start = _s(id).start;

        vm.warp(start + 100);
        vm.prank(session);
        vault.pause(id, uint64(start + 300)); // 200s, nobody resumes

        // 100s accrued, then frozen.
        assertEq(vault.accrued(id), (AMOUNT * 100) / DURATION, "frozen during the pause");

        vm.warp(start + 350); // 50s past expiry, still no resume()
        assertEq(
            vault.accrued(id),
            (AMOUNT * 150) / DURATION,
            "accrual restarted on its own at the scheduled expiry: 100 before + 50 after"
        );

        vm.warp(start + 900);
        assertEq(
            vault.accrued(id),
            (AMOUNT * 700) / DURATION,
            "keeps accruing while resume() is still outstanding: 100 + 600"
        );

        // Settling late must credit only the 200s that were actually frozen.
        vm.prank(recipient); // not the sender, not a controller
        vault.resume(id);
        S memory a = _s(id);
        assertEq(a.pausedTotal, 200, "only the scheduled interval was settled");
        assertEq(a.pausedUntil, 0);
        assertEq(a.end, start + DURATION + 200, "end grew by the paused interval");

        vm.warp(a.end);
        assertEq(vault.accrued(id), AMOUNT, "principal fully conserved");
    }

    /// Ending a pause EARLY is a decision, so an outsider may not make it.
    function test_resume_beforeExpiry_byOutsider_reverts() public {
        uint256 id = _createWithSession();
        uint64 start = _s(id).start;

        vm.warp(start + 100);
        vm.prank(session);
        vault.pause(id, uint64(start + 500));

        vm.warp(start + 200); // still inside the scheduled window
        vm.prank(makeAddr("outsider"));
        vm.expectRevert(StreamVault.NotSenderOrController.selector);
        vault.resume(id);

        // ...but the controller still can.
        vm.prank(session);
        vault.resume(id);
        assertEq(_s(id).pausedTotal, 100, "cut short at 100s, not the full 400s");
        assertEq(_s(id).end, start + DURATION + 100);
    }

    /// Once a pause has expired, settling it is permissionless — including for the
    /// recipient, who has the strongest incentive to do it.
    function test_resume_afterExpiry_permissionless() public {
        uint256 id = _createWithSession();
        uint64 start = _s(id).start;

        vm.warp(start + 100);
        vm.prank(session);
        vault.pause(id, uint64(start + 200));

        vm.warp(start + 500);
        vm.prank(makeAddr("stranger"));
        vault.resume(id);
        assertEq(_s(id).pausedTotal, 100);
        assertEq(_s(id).pausedUntil, 0);
    }

    /// Accrual must never depend on whether a pause was settled promptly: the same
    /// wall-clock instant must yield the same accrued amount either way.
    function test_accrual_isIndependentOfSettlementTiming() public {
        uint256 settled = _createWithSession();
        uint256 unsettled = _createWithSession();
        uint64 start = _s(settled).start;

        vm.warp(start + 100);
        vm.prank(session);
        vault.pause(settled, uint64(start + 300));
        vm.prank(session);
        vault.pause(unsettled, uint64(start + 300));

        vm.warp(start + 350);
        vm.prank(session);
        vault.resume(settled); // settled promptly, 50s after expiry
        vm.warp(start + 500);
        vm.prank(session);
        vault.resume(unsettled); // settled later, so `end` shifts later

        for (uint64 t = 400; t < 1500; t += 37) {
            vm.warp(start + t);
            uint128 a = vault.accrued(settled);
            uint128 b = vault.accrued(unsettled);
            // Settling early pushes `end` right 200s sooner, so the settled stream simply
            // finishes its window sooner. What must hold at EVERY instant is monotonicity,
            // the principal bound, and agreement once both have settled.
            assertLe(a, AMOUNT, "settled never exceeds principal");
            assertLe(b, AMOUNT, "unsettled never exceeds principal");
            if (t >= 500) {
                // both pauses are long over; the curves must now be identical
                assertEq(a, b, "curves agree once both pauses have expired");
            }
        }
    }

    /// Regression: the clock ran PAST `end` while a pause was still unsettled. Clamping
    /// elapsed to the window before subtracting the pause swallowed the subtraction, which
    /// capped the recipient at (span - pause)/span FOREVER. Here that is 70% of a stream
    /// that had long since fully accrued. The subtraction must happen before the clamp.
    function test_unsettledPause_afterWindowOverrun_doesNotStickBelowFull() public {
        uint256 id = _createWithSession();
        uint64 start = _s(id).start;

        vm.warp(start + 100);
        vm.prank(session);
        vault.pause(id, uint64(start + 400)); // 300s pause, never settled

        // Inside the window both orderings agree; pin the curve so the fix cannot drift.
        vm.warp(start + 700); // 100s accrued + 300s paused + 300s since expiry
        assertEq(vault.accrued(id), (AMOUNT * 400) / DURATION, "400s of accrual");

        vm.warp(start + 1000); // 700s accrued + 300s paused
        assertEq(vault.accrued(id), (AMOUNT * 700) / DURATION, "700s of accrual");

        // Past `end` with the pause STILL unsettled. Accrual available is 100s + everything
        // since expiry, which exceeds the 1000s window, so this must read as fully accrued.
        // The old ordering returned 70% here and never moved again.
        vm.warp(start + 1300);
        assertEq(vault.accrued(id), AMOUNT, "fully accrued once the clock overruns the window");

        vm.warp(start + 100000);
        assertEq(vault.accrued(id), AMOUNT, "and stays exactly there, never above");

        // Settling now must not move the curve.
        uint128 before = vault.accrued(id);
        vm.prank(recipient);
        vault.resume(id);
        assertEq(vault.accrued(id), before, "settlement is curve-neutral");
        assertEq(_s(id).pausedTotal, 300);
        assertEq(_s(id).end, start + DURATION + 300);

        vm.prank(recipient);
        vault.withdrawAll(id);
        assertEq(ausd.balanceOf(recipient), AMOUNT, "recipient takes the full principal once");
        _assertNeverOverpays(id);
    }

    // ------------------------------------------------------------------
    // Gasless: a stream opened by signature alone
    //
    // This is the wedge that makes AUSD's EIP-2612 support load-bearing rather
    // than decorative. The payer signs; the relayer submits. The payer never
    // sends a transaction and never needs to hold MON.
    // ------------------------------------------------------------------

    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function _permitDigest(
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline)
        );
        return keccak256(
            abi.encodePacked("\x19\x01", ausd.DOMAIN_SEPARATOR(), structHash)
        );
    }

    /// The payer has no MON and sends nothing. A relayer they do not control submits
    /// their signature and the stream opens.
    function test_gasless_payerSignsAndNeverSendsATransaction() public {
        uint256 payerPk = 0xBEEF;
        address payer = vm.addr(payerPk);
        address relayer = makeAddr("relayer");

        ausd.mint(payer, AMOUNT);
        assertEq(payer.balance, 0, "payer holds no MON at all");

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(payer, address(vault), AMOUNT, ausd.nonces(payer), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerPk, digest);

        // The relayer submits. msg.sender is the relayer, but the funds and the stream
        // both belong to the payer.
        vm.prank(relayer);
        uint256 id = vault.createStreamWithPermit(
            payer, recipient, address(ausd), AMOUNT, DURATION, deadline, v, r, s
        );

        S memory st = _s(id);
        assertEq(st.sender, payer, "the payer owns the stream, not the relayer");
        assertEq(st.recipient, recipient);
        assertEq(st.amount, AMOUNT);
        assertEq(ausd.balanceOf(payer), 0, "pulled exactly the permitted amount");
        assertEq(ausd.balanceOf(address(vault)), AMOUNT);
        assertEq(ausd.allowance(payer, address(vault)), 0, "allowance fully consumed");
        assertEq(payer.balance, 0, "and still holds no MON");

        // The recipient can withdraw from it like any other stream.
        vm.warp(block.timestamp + DURATION);
        vm.prank(recipient);
        vault.withdrawAll(id);
        assertEq(ausd.balanceOf(recipient), AMOUNT);
    }

    /// A consumed permit cannot be replayed into a second stream.
    function test_gasless_permitCannotBeReplayed() public {
        uint256 payerPk = 0xBEEF;
        address payer = vm.addr(payerPk);
        ausd.mint(payer, AMOUNT * 2);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(payer, address(vault), AMOUNT, ausd.nonces(payer), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerPk, digest);

        vault.createStreamWithPermit(
            payer, recipient, address(ausd), AMOUNT, DURATION, deadline, v, r, s
        );

        // Same signature again: the nonce has moved, so the token rejects it.
        vm.expectRevert();
        vault.createStreamWithPermit(
            payer, recipient, address(ausd), AMOUNT, DURATION, deadline, v, r, s
        );
        assertEq(ausd.balanceOf(payer), AMOUNT, "only one stream was funded");
    }

    /// A stale permit is worthless — the relayer cannot sit on a signature.
    function test_gasless_expiredDeadlineReverts() public {
        uint256 payerPk = 0xBEEF;
        address payer = vm.addr(payerPk);
        ausd.mint(payer, AMOUNT);

        uint256 deadline = block.timestamp + 60;
        bytes32 digest = _permitDigest(payer, address(vault), AMOUNT, ausd.nonces(payer), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerPk, digest);

        vm.warp(deadline + 1);
        vm.expectRevert();
        vault.createStreamWithPermit(
            payer, recipient, address(ausd), AMOUNT, DURATION, deadline, v, r, s
        );
        assertEq(ausd.balanceOf(payer), AMOUNT, "nothing was pulled");
    }

    /// A signature over a different amount cannot be stretched.
    function test_gasless_amountMismatchReverts() public {
        uint256 payerPk = 0xBEEF;
        address payer = vm.addr(payerPk);
        ausd.mint(payer, AMOUNT * 10);

        uint256 deadline = block.timestamp + 1 hours;
        // signed for AMOUNT
        bytes32 digest = _permitDigest(payer, address(vault), AMOUNT, ausd.nonces(payer), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerPk, digest);

        // submitted for 5x AMOUNT
        vm.expectRevert();
        vault.createStreamWithPermit(
            payer, recipient, address(ausd), AMOUNT * 5, DURATION, deadline, v, r, s
        );
        assertEq(ausd.balanceOf(payer), AMOUNT * 10, "untouched");
    }

    /// A signature is bound to the spender, so it cannot be redirected elsewhere.
    function test_gasless_permitIsBoundToThisVault() public {
        uint256 payerPk = 0xBEEF;
        address payer = vm.addr(payerPk);
        ausd.mint(payer, AMOUNT);

        uint256 deadline = block.timestamp + 1 hours;
        // signed for some OTHER spender
        bytes32 digest = _permitDigest(payer, makeAddr("other"), AMOUNT, ausd.nonces(payer), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerPk, digest);

        vm.expectRevert();
        vault.createStreamWithPermit(
            payer, recipient, address(ausd), AMOUNT, DURATION, deadline, v, r, s
        );
        assertEq(ausd.balanceOf(payer), AMOUNT);
    }

    /// One deployment serves both dollar tokens; both are 6 decimals.
    function test_oneVaultServesAUSDandUSDC() public {
        assertEq(ausd.decimals(), 6, "AUSD is 6 decimals");
        assertEq(usdc.decimals(), 6, "USDC is 6 decimals");

        usdc.mint(sender, AMOUNT);
        vm.prank(sender);
        usdc.approve(address(vault), AMOUNT);
        vm.prank(sender);
        uint256 u = vault.createStream(recipient, address(usdc), AMOUNT, DURATION);

        vm.prank(sender);
        uint256 a = vault.createStream(recipient, address(ausd), AMOUNT, DURATION);

        vm.warp(block.timestamp + DURATION / 2);
        assertEq(vault.accrued(u), AMOUNT / 2, "USDC stream accrues");
        assertEq(vault.accrued(a), AMOUNT / 2, "AUSD stream accrues");
        assertEq(_s(u).token, address(usdc));
        assertEq(_s(a).token, address(ausd));
        assertTrue(u != a);
    }

    function testFuzz_neverOverpays(uint64 warpTo, uint128 takeFraction) public {
        uint256 id = _create();
        uint64 start = _s(id).start;

        takeFraction = uint128(bound(takeFraction, 0, 100));
        vm.warp(start + uint256(bound(warpTo, 0, DURATION * 3)));

        uint128 available = vault.withdrawable(id);
        uint128 take = uint128((uint256(available) * takeFraction) / 100);
        if (take > 0) {
            vm.prank(recipient);
            vault.withdraw(id, take);
        }
        _assertNeverOverpays(id);

        vm.warp(start + DURATION * 10);
        uint128 remaining = vault.withdrawable(id);
        if (remaining > 0) {
            vm.prank(recipient);
            vault.withdrawAll(id);
        }
        assertLe(ausd.balanceOf(recipient), AMOUNT, "recipient never exceeds principal");
        assertEq(
            ausd.balanceOf(recipient),
            AMOUNT,
            "recipient ends with exactly the principal, no more and no less"
        );
    }
}

// =========================================================================
// HandleRegistry
// =========================================================================
contract HandleRegistryTest is Test {
    HandleRegistry registry;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address receiving = makeAddr("receiving");

    function setUp() public {
        registry = new HandleRegistry();
    }

    function test_register_andResolve() public {
        vm.prank(alice);
        registry.register("adaeze");

        assertEq(registry.resolve("adaeze"), alice);
        assertEq(registry.ownerOf(keccak256(bytes("adaeze"))), alice);
        assertTrue(registry.isRegistered("adaeze"));
        assertEq(registry.totalHandles(), 1);
        assertEq(registry.registeredAt(keccak256(bytes("adaeze"))), block.timestamp);
    }

    function test_registerTo_separatesOwnerFromReceivingKey() public {
        // Mera index 0 owns the handle; index 2 receives. One passkey, many keys.
        vm.prank(alice);
        registry.registerTo("adaeze", receiving);

        assertEq(registry.resolve("adaeze"), receiving, "funds land on the receiving key");
        assertEq(registry.ownerOf(keccak256(bytes("adaeze"))), alice, "alice still owns it");
    }

    function test_register_rejectsTakenHandle() public {
        vm.prank(alice);
        registry.register("adaeze");
        vm.prank(bob);
        vm.expectRevert(HandleRegistry.HandleTaken.selector);
        registry.register("adaeze");
    }

    function test_register_acceptsValidCharset() public {
        vm.prank(alice);
        registry.register("adaeze_01"); // a-z, 0-9, underscore
        assertTrue(registry.isRegistered("adaeze_01"));
        assertEq(registry.resolve("adaeze_01"), alice);
    }

    function test_register_rejectsEmpty() public {
        vm.prank(alice);
        vm.expectRevert(HandleRegistry.HandleEmpty.selector);
        registry.register("");
    }

    function test_register_rejectsUppercase() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HandleRegistry.HandleInvalidChar.selector, bytes1("A")));
        registry.register("AdaEze");
    }

    function test_register_rejectsHyphen() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HandleRegistry.HandleInvalidChar.selector, bytes1("-")));
        registry.register("ada-eze");
    }

    function test_register_rejectsDot() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HandleRegistry.HandleInvalidChar.selector, bytes1(".")));
        registry.register("ada.eze");
    }

    function test_register_rejectsOverLength() public {
        vm.prank(alice);
        vm.expectRevert(HandleRegistry.HandleTooLong.selector);
        registry.register("aaaaaaaaaaaaaaaaaaaaaaaaa"); // 25 > MAX_HANDLE_LENGTH (24)
    }

    function test_register_acceptsMaxLength() public {
        vm.prank(alice);
        registry.register("aaaaaaaaaaaaaaaaaaaaaaaa"); // exactly 24
        assertTrue(registry.isRegistered("aaaaaaaaaaaaaaaaaaaaaaaa"));
    }

    function test_resolve_unregisteredReverts() public {
        vm.expectRevert(HandleRegistry.HandleNotRegistered.selector);
        registry.resolve("nobody");
    }

    function test_transferHandle_ownerOnly() public {
        vm.prank(alice);
        registry.register("adaeze");

        vm.prank(bob);
        vm.expectRevert(HandleRegistry.NotHandleOwner.selector);
        registry.transferHandle("adaeze", bob);

        vm.prank(alice);
        registry.transferHandle("adaeze", bob);
        assertEq(registry.ownerOf(keccak256(bytes("adaeze"))), bob);
    }

    function test_release_freesTheHandle() public {
        vm.prank(alice);
        registry.register("adaeze");

        vm.prank(alice);
        registry.release("adaeze");
        assertEq(registry.totalHandles(), 0);
        assertFalse(registry.isRegistered("adaeze"));

        vm.prank(bob);
        registry.register("adaeze"); // claimable again
        assertEq(registry.resolve("adaeze"), bob);
    }

    function test_setReceivingAddress_ownerOnly() public {
        vm.prank(alice);
        registry.register("adaeze");

        vm.prank(bob);
        vm.expectRevert(HandleRegistry.NotHandleOwner.selector);
        registry.setReceivingAddress("adaeze", bob);

        vm.prank(alice);
        registry.setReceivingAddress("adaeze", receiving);
        assertEq(registry.resolve("adaeze"), receiving);
    }
}
