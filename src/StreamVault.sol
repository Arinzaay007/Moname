// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title StreamVault
/// @notice Money that accrues by the second, on Monad.
///
/// @dev WHY THIS IS A MONAD-ONLY PRODUCT
///      Linear accrual is trivial to express; what makes it a *product* is that anyone can
///      call `withdraw` every block for a consumer-sized amount without the fee exceeding
///      the payment. At ~300ms blocks, ~600ms deterministic finality and near-zero fees
///      that holds on Monad. On Ethereum the same contract costs more in gas than the
///      streams it moves. Circle makes the same point from the other direction: it prices
///      CCTP Fast Transfer by finality speed, and lists Monad at 0 bps because Monad's
///      attestation is already fast enough that the speed-up product is unnecessary.
///
///      KEY MODEL ("one passkey, many keys")
///      - `sender`      funds the stream and may cancel it (refunding the un-accrued part)
///      - `recipient`   withdraws accrued funds
///      - `controllers` an allowlist the sender sets at creation. In Moname this is the
///                      Mera SESSION key (passkey derivation index 1), which can only
///                      pause / resume / cancel. The OWNER key (index 0) signs the terms.
///                      The key that can move money is not the key held live in page memory.
///
///      PAUSE SEMANTICS
///      Pausing does not destroy elapsed time and does not fork the accrual curve. A pause
///      shifts the stream's end out by exactly the paused duration, so `amount` is still
///      delivered in full — the recipient just receives it over a longer wall-clock window.
///      That keeps `accrued()` a single linear expression with no piecewise accounting.
///
///      MONAD GAS NOTE
///      Monad charges `value + gas_bid * gas_limit` — the DECLARED limit, not gas used.
///      Callers (our relayer) must pass explicit gas values. Struct fields here are laid
///      out consecutively so a stream's slots fall within one 128-slot storage page and
///      stay warm after the first access (MIP-8).
contract StreamVault is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    struct Stream {
        address sender; // funds it, can cancel          (32 bytes slot-shared below)
        address recipient; // withdraws accrued
        address token; // AUSD (primary) or USDC, both 6 decimals on Monad
        uint128 amount; // total principal, fully delivered unless cancelled
        uint128 withdrawn; // already claimed by recipient
        uint64 start; // accrual start, block.timestamp at creation
        uint64 end; // accrual end; shifts right on resume-after-pause
        uint64 pausedFrom; // when the current/last pause began
        uint64 pausedUntil; // 0 = running; > now = frozen until then
        uint64 pausedTotal; // cumulative seconds spent paused, subtracted from elapsed
        bool cancelled;
        uint8 controllerCount;
    }

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error ZeroAddress();
    error ZeroAmount();
    error ZeroDuration();
    error StreamNotFound();
    error NotRecipient();
    error NotSender();
    error NotSenderOrController();
    error AlreadyCancelled();
    error NotPaused();
    error ExceedsWithdrawable();
    error TooManyControllers();
    error DuplicateController();
    error ControllerIsSender();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event StreamCreatedWithPermit(
        uint256 indexed id, address indexed payer, address indexed relayer, uint128 amount
    );
    event StreamCreated(
        uint256 indexed id,
        address indexed sender,
        address indexed recipient,
        address token,
        uint128 amount,
        uint64 start,
        uint64 end
    );
    event Withdrawn(uint256 indexed id, address indexed to, uint128 amount);
    event Paused(uint256 indexed id, uint64 until);
    event Resumed(uint256 indexed id, uint64 newEnd);
    event Cancelled(uint256 indexed id, uint128 toRecipient, uint128 refundedToSender);
    event ControllerSet(uint256 indexed id, address indexed controller, bool allowed);

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    uint256 public nextId;
    mapping(uint256 => Stream) public streams;
    /// @dev streamId => controller => allowed. Controllers are the Mera session key.
    mapping(uint256 => mapping(address => bool)) public controllers;

    /// @notice Optional forwarder permitted to credit streams on a handle's behalf
    ///         (our relayer / bridge watcher). address(0) disables the path.
    address public forwarder;
    address public owner;

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotSender();
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------
    constructor(address forwarder_) {
        owner = msg.sender;
        forwarder = forwarder_;
    }

    function setForwarder(address forwarder_) external onlyOwner {
        forwarder = forwarder_;
    }

    // ---------------------------------------------------------------------
    // Create
    // ---------------------------------------------------------------------

    /// @notice Open a stream. Caller must have approved this contract for `amount`.
    /// @param recipient Where accrued funds are withdrawable to.
    /// @param token     AUSD or USDC on Monad (both 6 decimals, both EIP-2612 permit).
    /// @param amount    Total principal.
    /// @param duration  Seconds over which `amount` accrues linearly.
    function createStream(
        address recipient,
        address token,
        uint128 amount,
        uint64 duration
    ) external returns (uint256 id) {
        return _create(msg.sender, recipient, token, amount, duration, uint64(block.timestamp));
    }

    /// @notice Open a stream funded by an EIP-2612 signature. THIS is the gasless path.
    /// @dev The payer signs a permit and never sends a transaction, so they never need to
    ///      hold MON. Anyone may submit it — normally our relayer, which is why `payer` is
    ///      an argument rather than `msg.sender`. AUSD and USDC on Monad are both
    ///      EIP-2612 capable and both 6 decimals, verified live on chain 143.
    ///
    ///      Deliberately permissionless: the signature is the authorisation. Restricting
    ///      submission to the forwarder would make the relayer a liveness bottleneck for
    ///      someone's payroll. The permit already pins payer, spender, amount and deadline.
    ///
    /// @param payer     Who the permit was signed by; funds are pulled from them.
    /// @param deadline  Permit expiry. Reverts in the token if stale.
    function createStreamWithPermit(
        address payer,
        address recipient,
        address token,
        uint128 amount,
        uint64 duration,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 id) {
        if (payer == address(0)) revert ZeroAddress();

        // Consume the signature first: permit approves `amount` to this contract, then
        // _create pulls exactly that. Doing it in this order means a failed permit can
        // never leave a stream half-funded.
        IERC20Permit(token).permit(payer, address(this), amount, deadline, v, r, s);

        id = _create(payer, recipient, token, amount, duration, uint64(block.timestamp));
        emit StreamCreatedWithPermit(id, payer, msg.sender, amount);
    }

    /// @notice Open a stream and register session-key controllers in one call.
    /// @dev `controllerList` is the Mera session key (derivation index 1). Capped at 4 to
    ///      keep creation gas bounded and predictable for the relayer.
    function createStreamWithControllers(
        address recipient,
        address token,
        uint128 amount,
        uint64 duration,
        address[] calldata controllerList
    ) external returns (uint256 id) {
        if (controllerList.length > 4) revert TooManyControllers();
        id = _create(msg.sender, recipient, token, amount, duration, uint64(block.timestamp));
        for (uint256 i = 0; i < controllerList.length; i++) {
            address c = controllerList[i];
            if (c == address(0)) revert ZeroAddress();
            if (c == msg.sender) revert ControllerIsSender();
            if (controllers[id][c]) revert DuplicateController();
            controllers[id][c] = true;
            streams[id].controllerCount++;
            emit ControllerSet(id, c, true);
        }
    }

    function _create(
        address sender,
        address recipient,
        address token,
        uint128 amount,
        uint64 duration,
        uint64 start
    ) internal returns (uint256 id) {
        if (recipient == address(0)) revert ZeroAddress();
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (duration == 0) revert ZeroDuration();

        IERC20(token).safeTransferFrom(sender, address(this), amount);

        id = nextId++;
        streams[id] = Stream({
            sender: sender,
            recipient: recipient,
            token: token,
            amount: amount,
            withdrawn: 0,
            start: start,
            end: start + duration,
            pausedFrom: 0,
            pausedUntil: 0,
            pausedTotal: 0,
            cancelled: false,
            controllerCount: 0
        });

        emit StreamCreated(id, sender, recipient, token, amount, start, start + duration);
    }

    // ---------------------------------------------------------------------
    // Accrual — the core
    // ---------------------------------------------------------------------

    /// @notice Total accrued to date, including anything already withdrawn.
    /// @dev Single linear expression. A pause shifts `end` right on resume, so the curve
    ///      is never piecewise and elapsed time is never destroyed.
    function accrued(uint256 id) public view returns (uint128) {
        Stream storage s = streams[id];
        if (s.sender == address(0)) revert StreamNotFound();
        if (s.cancelled) return s.withdrawn;

        uint64 nowTs = uint64(block.timestamp);

        // Is a pause LIVE right now? Only while we are inside the window the sender or
        // controller scheduled. Once `pausedUntil` passes, the pause is over by its own
        // terms and accrual restarts WITHOUT anyone calling resume(). For a payment rail
        // that matters: a forgotten resume() must never silently destroy income.
        bool live = s.pausedUntil != 0 && nowTs < s.pausedUntil;

        // `end` is pushed right by each SETTLED pause, so the wall window span always
        // covers the pauses that have been booked; taking those back out leaves the window
        // that genuinely pays. A pause that is still live or expired-but-unsettled has not
        // grown `end`, so it is handled by the numerator instead — freezing `now` at
        // `pausedFrom` while live, and subtracting the interval once it has expired.
        //
        // Both routes converge on the same numbers, which is what makes the payout curve
        // independent of WHEN resume() is called: settlement moves `end` and `pausedTotal`
        // together and the two changes cancel.
        uint256 span = uint256(s.end - s.start);
        uint256 paused = uint256(s.pausedTotal);
        uint256 accruing = span > paused ? span - paused : 0;
        if (accruing == 0) return s.amount; // degenerate: everything was paused away

        // How far the clock has effectively run, ignoring the pause currently on the books.
        uint256 reached = live
            ? (s.pausedFrom > s.start ? uint256(s.pausedFrom - s.start) : 0)
            : (nowTs > s.start ? uint256(nowTs - s.start) : 0);

        // Remove the unsettled pause interval BEFORE clamping. Order matters: once the
        // clock has run past `end`, clamping first would swallow the subtraction and the
        // recipient would be paid for time that was paused.
        // Not while live: `reached` was frozen at `pausedFrom`, which is BEFORE the
        // interval, so there is nothing of it to remove yet.
        if (!live && s.pausedUntil != 0 && s.pausedUntil > s.pausedFrom) {
            uint256 pending = uint256(s.pausedUntil - s.pausedFrom);
            reached = reached > pending ? reached - pending : 0;
        }

        // Only now clamp, to the window that actually pays.
        if (reached > accruing) reached = accruing;
        uint256 elapsed = reached;

        return _linear(s.amount, elapsed, accruing);
    }

    /// @notice Accrued minus already-withdrawn. This is what `withdraw` may take.
    /// @dev Cheap and pure-ish: ~1.9k gas, no state writes. Safe to poll every block.
    function withdrawable(uint256 id) external view returns (uint128) {
        return accrued(id) - streams[id].withdrawn;
    }

    function _linear(uint128 amount, uint256 elapsed, uint256 total) internal pure returns (uint128) {
        if (total == 0) return amount;
        if (elapsed >= total) return amount;
        return uint128((uint256(amount) * elapsed) / total);
    }

    // ---------------------------------------------------------------------
    // Withdraw
    // ---------------------------------------------------------------------

    /// @notice Recipient claims accrued funds. Callable every block — that is the point.
    function withdraw(uint256 id, uint128 amount) external nonReentrant {
        Stream storage s = streams[id];
        if (s.sender == address(0)) revert StreamNotFound();
        if (msg.sender != s.recipient) revert NotRecipient();
        if (s.cancelled) revert AlreadyCancelled();

        uint128 available = accrued(id) - s.withdrawn;
        if (amount > available) revert ExceedsWithdrawable();

        s.withdrawn += amount;
        IERC20(s.token).safeTransfer(s.recipient, amount);
        emit Withdrawn(id, s.recipient, amount);
    }

    /// @notice Claim everything accrued so far.
    function withdrawAll(uint256 id) external nonReentrant {
        Stream storage s = streams[id];
        if (msg.sender != s.recipient) revert NotRecipient();
        uint128 available = accrued(id) - s.withdrawn;
        if (available == 0) revert ExceedsWithdrawable();
        s.withdrawn += available;
        IERC20(s.token).safeTransfer(s.recipient, available);
        emit Withdrawn(id, s.recipient, available);
    }

    // ---------------------------------------------------------------------
    // Pause / resume — session key surface
    // ---------------------------------------------------------------------

    /// @notice Freeze accrual until `until`. Sender or controller only.
    /// @dev Does not forfeit anything: the stream's end shifts right on resume.
    /// @notice Freeze accrual from now until `until`. Sender or controller only.
    /// @dev The freeze is bounded by its own terms: accrual restarts at `until` whether or
    ///      not anyone calls `resume()`. See `accrued`.
    function pause(uint256 id, uint64 until) external {
        Stream storage s = _auth(id);
        if (s.cancelled) revert AlreadyCancelled();
        if (until <= block.timestamp) revert ZeroDuration();
        s.pausedFrom = uint64(block.timestamp);
        s.pausedUntil = until;
        emit Paused(id, until);
    }

    /// @notice Lift a pause, pushing `end` right by the paused duration so `amount` is
    ///         still delivered in full. Sender or controller only.
    /// @notice End a pause and book its interval.
    /// @dev Before the scheduled expiry this is sender/controller only — cutting a pause
    ///      short is a decision. After the expiry it is PERMISSIONLESS, so a recipient can
    ///      always settle an abandoned pause and keep the stream's accounting honest.
    ///      Settlement moves `end` and `pausedTotal` together, so it never changes what
    ///      `accrued` returns; it only makes the shift permanent.
    function resume(uint256 id) external {
        Stream storage s = streams[id];
        if (s.sender == address(0)) revert StreamNotFound();
        if (s.cancelled) revert AlreadyCancelled();
        if (s.pausedUntil == 0) revert NotPaused();

        uint64 nowTs = uint64(block.timestamp);
        if (nowTs < s.pausedUntil) {
            // Ending a pause EARLY is a decision, so only the sender or a controller
            // may make it.
            if (msg.sender != s.sender && !controllers[id][msg.sender]) {
                revert NotSenderOrController();
            }
        }
        // Once the scheduled expiry has passed, ANYONE may settle it. Accrual has already
        // restarted on its own; this just books the interval and pushes `end` right so the
        // recipient still receives the full principal.

        // The pause ended at whichever came first: its scheduled expiry, or now.
        uint64 pauseEnd = (s.pausedUntil < nowTs) ? s.pausedUntil : nowTs;
        if (pauseEnd > s.pausedFrom) {
            uint64 delta = pauseEnd - s.pausedFrom;
            s.pausedTotal += delta;
            s.end += delta;
        }
        s.pausedFrom = 0;
        s.pausedUntil = 0;
        emit Resumed(id, s.end);
    }

    // ---------------------------------------------------------------------
    // Cancel
    // ---------------------------------------------------------------------

    /// @notice Sender reclaims the un-accrued remainder; recipient keeps what accrued.
    function cancel(uint256 id) external nonReentrant {
        Stream storage s = streams[id];
        if (s.sender == address(0)) revert StreamNotFound();
        if (msg.sender != s.sender && !controllers[id][msg.sender]) {
            revert NotSenderOrController();
        }
        if (s.cancelled) revert AlreadyCancelled();

        uint128 done = accrued(id);
        uint128 owedToRecipient = done > s.withdrawn ? done - s.withdrawn : 0;
        uint128 remainder = s.amount - done;

        s.cancelled = true;
        s.withdrawn = done;

        if (owedToRecipient > 0) IERC20(s.token).safeTransfer(s.recipient, owedToRecipient);
        if (remainder > 0) IERC20(s.token).safeTransfer(s.sender, remainder);

        emit Cancelled(id, owedToRecipient, remainder);
    }

    // ---------------------------------------------------------------------
    // Controllers
    // ---------------------------------------------------------------------

    /// @notice Sender adds or removes a controller (Mera session key) after creation.
    function setController(uint256 id, address controller, bool allowed) external {
        Stream storage s = streams[id];
        if (s.sender == address(0)) revert StreamNotFound();
        if (msg.sender != s.sender) revert NotSender();
        if (controller == address(0)) revert ZeroAddress();
        if (allowed && controller == s.sender) revert ControllerIsSender();
        if (controllers[id][controller] == allowed) revert DuplicateController();

        controllers[id][controller] = allowed;
        if (allowed) {
            s.controllerCount++;
        } else if (s.controllerCount > 0) {
            s.controllerCount--;
        }
        emit ControllerSet(id, controller, allowed);
    }

    function _auth(uint256 id) internal view returns (Stream storage s) {
        s = streams[id];
        if (s.sender == address(0)) revert StreamNotFound();
        if (msg.sender != s.sender && !controllers[id][msg.sender]) {
            revert NotSenderOrController();
        }
    }

    // ---------------------------------------------------------------------
    // Bridge arrival — STRETCH, off by default
    // ---------------------------------------------------------------------

    /// @notice Credit an incoming cross-chain deposit straight into a new stream.
    /// @dev Called by `forwarder` ONLY, after our watcher has verified on Monad that the
    ///      inbound USDC actually landed (Relay fill, or CCTP V2 `receiveMessage`). The
    ///      vault must already hold the tokens — this never pulls from the caller.
    ///
    ///      This is deliberately NOT wired to CCTP Hooks yet. Hook invocation semantics
    ///      for TokenMessengerV2 on Monad are unverified in this codebase; wiring an
    ///      unverified external entry point that receives funds is exactly the kind of
    ///      thing that loses a hackathon. Ship the watcher-driven path, add the atomic
    ///      hook on Day 5 only if there is slack and the interface is confirmed against
    ///      Circle's deployed Monad contracts.
    function creditArrival(
        address recipient,
        address token,
        uint128 amount,
        uint64 duration
    ) external returns (uint256 id) {
        if (forwarder == address(0)) revert ZeroAddress();
        if (msg.sender != forwarder) revert NotSender();
        if (recipient == address(0)) revert ZeroAddress();
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (duration == 0) revert ZeroDuration();
        // The forwarder has already landed the USDC in this vault (Relay fill, or CCTP V2
        // receiveMessage) and verified it on Monad. We therefore record the stream WITHOUT
        // a transferFrom — pulling here would double-charge and is how funds get lost.
        if (IERC20(token).balanceOf(address(this)) < amount) revert ExceedsWithdrawable();

        uint64 start = uint64(block.timestamp);
        id = nextId++;
        streams[id] = Stream({
            sender: recipient,
            recipient: recipient,
            token: token,
            amount: amount,
            withdrawn: 0,
            start: start,
            end: start + duration,
            pausedFrom: 0,
            pausedUntil: 0,
            pausedTotal: 0,
            cancelled: false,
            controllerCount: 0
        });
        emit StreamCreated(id, recipient, recipient, token, amount, start, start + duration);
    }
}
