// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Stands in for Relay's destination executor on Monad
///         (`0xb92fe925dc43a0ecde6c8b1a2709c170ec4fff4f`, verified a 4,720-byte contract
///         on chain 143).
///
/// This exists because the pre-existing `creditArrival` tests used `vm.prank(forwarder)`,
/// which makes an EOA impersonate the forwarder. That proves the authorisation guard but
/// NOT the thing that actually happens in production: a **contract** receives the bridged
/// tokens and then performs an ordered batch of calls inside a single transaction. Those
/// are different situations — `msg.sender` is a contract, the token balance arrives at the
/// executor rather than at the vault, and call ordering inside one transaction decides
/// whether the vault's balance check passes.
///
/// The shape mirrors what Relay returns in `output.calls`: a list of
/// `(to, value, data)` executed in order. Deliberately minimal and deliberately NOT
/// access-controlled, because the point of the mock is to exercise StreamVault's own
/// guards, not to model Relay's order authentication.
contract MockRelayExecutor {
    struct Call {
        address to;
        uint256 value;
        bytes data;
    }

    event Executed(address indexed to, uint256 value, bytes data, bytes result);
    event Received(address indexed from, uint256 amount);

    /// @notice Execute an ordered batch of calls in one transaction, as Relay's executor
    ///         does when it lands a cross-chain transfer and then runs the destination
    ///         calls attached to it.
    /// @dev Reverts propagate: if any call fails the whole batch fails, which is the
    ///      property that makes the arrival-and-open atomic rather than two chances to
    ///      half-succeed.
    function execute(Call[] calldata calls) external payable returns (bytes[] memory results) {
        results = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = calls[i].to.call{value: calls[i].value}(calls[i].data);
            if (!ok) {
                // Bubble up the revert reason so a failure is diagnosable rather than
                // surfacing as a bare "execution reverted".
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
            results[i] = ret;
            emit Executed(calls[i].to, calls[i].value, calls[i].data, ret);
        }
    }

    /// Relay delivers the bridged tokens to the executor first; `output.payments[].recipient`
    /// is the executor, not the destination protocol.
    receive() external payable {}

    /// @notice Allow the test to place ERC20 tokens here the way a bridge fill would.
    function onTokensReceived(address from, uint256 amount) external {
        emit Received(from, amount);
    }
}
