// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice Stand-in for Agora's AUSD in unit tests.
///
/// Mirrors the properties verified live on Monad mainnet for the real token at
/// 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a:
///   - symbol "AUSD", 6 decimals
///   - EIP-2612 permit (real token exposes DOMAIN_SEPARATOR and nonces)
///
/// Permit is the load-bearing part: it is what makes the gasless path work, because a
/// payment becomes a signature and the payer never needs MON or sends a transaction.
/// The real AUSD also supports EIP-3009 transferWithAuthorization; that is not modelled
/// here because Moname's relayer uses the EIP-2612 + transferFrom route.
///
/// `mint` is open so tests can fund anyone. The real AUSD is a permissioned-mint
/// EIP-1967 proxy and cannot be funded this way on a fork — see test/Fork.t.sol.
contract MockAUSD is ERC20, ERC20Permit {
    constructor() ERC20("AUSD", "AUSD") ERC20Permit("AUSD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
