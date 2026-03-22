// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title MockEURe
 * @author P.LECROSNIER
 * @notice Mock ERC20 token to simulate Monerium EURe for testing
 * @dev This is ONLY for testing purposes, not for production
 */
contract MockEURe is ERC20, ERC20Permit {
    /// @notice Deploy the mock token with initial supply
    constructor() ERC20("Mock EURe", "EURe") ERC20Permit("Mock EURe") {
        // Mint 1 million EURe to deployer for testing
        _mint(msg.sender, 1_000_000 * 10 ** 18);
    }

    /// @notice Mint tokens to any address (for testing)
    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    /// @notice Burn tokens from any address (for testing losses/slashing)
    function burn(
        address from,
        uint256 amount
    ) external {
        _burn(from, amount);
    }
}
