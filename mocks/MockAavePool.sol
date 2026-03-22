// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../src/mocks/MockEURe.sol";

/// @title MockAToken
/// @notice Simulates AAVE's aEURe rebasing token for testing.
///         Minted 1:1 on supply, burned on withdraw, rebased via simulateYield.
///         Holds the underlying EURe directly — mirrors real AAVE v3 architecture
///         where `IERC20(asset).balanceOf(aToken)` equals available liquidity.
contract MockAToken is ERC20 {
    using SafeERC20 for IERC20;

    address public immutable underlying;

    constructor(
        address underlying_
    ) ERC20("Mock aEURe", "aEURe") {
        underlying = underlying_;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function burn(
        address from,
        uint256 amount
    ) external {
        _burn(from, amount);
    }

    /// @dev Called by the pool during withdraw to send underlying to recipient.
    function transferUnderlying(
        address to,
        uint256 amount
    ) external {
        IERC20(underlying).safeTransfer(to, amount);
    }
}

/// @title MockAavePool
/// @notice Simulates AAVE v3 Pool for testing PaktolVault.
///
///         supply()        → transfers EURe to aToken, mints aEURe to onBehalfOf
///         withdraw()      → burns aEURe from caller, sends EURe from aToken to `to`
///         simulateYield() → mints extra aEURe to simulate interest accrual
///                           call MockEURe.mint(address(pool.aToken()), amount) FIRST
///                           to fund the aToken's backing EURe.
///         simulateLoss()  → burns EURe from aToken + aEURe from account
contract MockAavePool {
    using SafeERC20 for IERC20;

    MockAToken public immutable aToken;
    address public immutable underlying;

    constructor(
        address underlying_
    ) {
        underlying = underlying_;
        aToken = new MockAToken(underlying_);
    }

    function supply(
        address,
        uint256 amount,
        address onBehalfOf,
        uint16
    ) external {
        IERC20(underlying).safeTransferFrom(msg.sender, address(aToken), amount);
        aToken.mint(onBehalfOf, amount);
    }

    /// @dev Burns aEURe from msg.sender (the vault), sends EURe from aToken to `to`.
    ///      Supports harvest path (to = TREASURY) and user withdrawal (to = vault).
    function withdraw(
        address,
        uint256 amount,
        address to
    ) external returns (uint256) {
        aToken.burn(msg.sender, amount);
        aToken.transferUnderlying(to, amount);
        return amount;
    }

    /// @notice Simulates interest accrual. Call eure.mint(address(pool.aToken()), amount) first.
    function simulateYield(
        address account,
        uint256 amount
    ) external {
        aToken.mint(account, amount);
    }

    /// @notice Simulates a loss (bad debt / exploit). Burns EURe from aToken + aEURe from account.
    function simulateLoss(
        address account,
        uint256 amount
    ) external {
        MockEURe(underlying).burn(address(aToken), amount);
        aToken.burn(account, amount);
    }
}
