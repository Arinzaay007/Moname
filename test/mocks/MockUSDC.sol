// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test stand-in for USDC on Monad: 6 decimals, EIP-2612 permit, returns bool.
///      Mainnet USDC is 0x754704Bc059F8C67012fEd69BC8A327a5aafb603 (6 decimals).
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
