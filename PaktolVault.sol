// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/IAavePool.sol";

/// @title PaktolVault
/// @author P.LECROSNIER
/// @notice ERC-4626 vault routing EURe deposits into AAVE v3 on Gnosis Chain.
///
///         Standard (FEE_BPS = 50, CAP_BPS = 350):
///           - 0.5% annual AUM fee on total capital, pro-rated per harvest.
///           - Fee floor at 2% APY: below that, fee scales down with yield.
///           - User net yield capped at 3.5% per year.
///           - AUM fee + surplus above cap → treasury.
///
///         Paktol subscription (FEE_BPS = 0, CAP_BPS = 500):
///           - No fee.
///           - User net yield capped at 5% per year.
///           - Surplus above cap → treasury.
///
///         Harvest formula (unified, covers both plans):
///           maxAumFee  = lastTotalAssets × FEE_BPS × elapsed / (BPS_DENOMINATOR × SECONDS_PER_YEAR)
///           flooredFee = grossYield × FEE_BPS / FLOOR_BPS  [pro-rated when APY < 2%]
///           aumFee     = min(maxAumFee, flooredFee)         [smaller of the two]
///           remaining  = grossYield − aumFee
///           toUsers    = min(remaining, maxNetYield)        [pro-rated annual cap]
///           toTreasury = grossYield − toUsers               [aumFee + surplus above cap]
///
contract PaktolVault is ERC4626, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ─────────────────────────── CONSTANTS ─────────────────────────── */

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice APY floor below which the AUM fee is pro-rated down.
    ///         200 = 2%. When AAVE APY < 2%, aumFee = grossYield × FEE_BPS / FLOOR_BPS
    ///         instead of the full capital-based fee — protecting users in low-yield periods.
    uint256 public constant FLOOR_BPS = 200;

    /// @notice Minimum deposit. EURe has 18 decimals: 1e9 = 0.000000001 EURe.
    ///         Negligible for users, but makes inflation attacks economically infeasible
    ///         combined with _decimalsOffset() = 3 (virtual shares).
    uint256 public constant MIN_DEPOSIT = 1e9;

    /* ─────────────────────────── IMMUTABLES ────────────────────────── */

    /// @notice Annual net yield cap in basis points (350 = 3.5% / 500 = 5%).
    uint256 public immutable CAP_BPS;

    /// @notice Annual AUM fee in basis points on total capital, pro-rated per harvest.
    ///         50 = Standard (0.5%/year). 0 = Paktol subscription (no fee).
    uint256 public immutable FEE_BPS;

    /// @notice Receives fee + yield surplus above cap.
    address public immutable TREASURY;

    /// @notice AAVE v3 Pool on Gnosis Chain.
    address public immutable AAVE_POOL;

    /// @notice AAVE aEURe token. Rebasing 1:1 with EURe + accrued interest.
    address public immutable ATOKEN;

    /// @notice Maximum total assets the vault will accept. 0 = uncapped.
    uint256 public immutable MAX_TVL;

    /* ───────────────────────────── STORAGE ─────────────────────────── */

    /// @notice totalAssets() snapshot — updated after every deposit, withdraw, and harvest.
    uint256 public lastTotalAssets;

    /// @notice Timestamp of the last harvest.
    uint256 public lastHarvestTimestamp;

    /// @notice Emergency pause address. Cannot move funds.
    address public guardian;

    /// @notice Address allowed to call harvest() in addition to owner.
    address public harvester;

    /* ───────────────────────────── EVENTS ──────────────────────────── */

    /// @param grossYield  Raw yield generated since last harvest (in asset decimals).
    /// @param toTreasury  Amount sent to treasury (fee + surplus above cap).
    /// @param toUsers     Amount left in vault for users (net yield ≤ cap).
    /// @param timestamp   Block timestamp of the harvest.
    event Harvested(uint256 grossYield, uint256 toTreasury, uint256 toUsers, uint256 timestamp);
    event GuardianChanged(address indexed oldGuardian, address indexed newGuardian);
    event HarvesterChanged(address indexed oldHarvester, address indexed newHarvester);
    /// @param amount     Total aEURe pulled back to the vault (now idle).
    /// @param timestamp  Block timestamp of the emergency exit.
    event EmergencyExitAave(uint256 amount, uint256 timestamp);

    /* ───────────────────────────── ERRORS ──────────────────────────── */

    error ZeroAddress();
    error CapOutOfRange(uint256 provided);
    error FeeOutOfRange(uint256 provided);
    error NotGuardian();
    error NotHarvester();
    error DepositTooSmall(uint256 assets, uint256 minimum);
    error TvlCapExceeded(uint256 current, uint256 cap);
    error InsufficientAllowance();

    /* ─────────────────────────── CONSTRUCTOR ───────────────────────── */

    /// @param asset_      EURe token address (Monerium, Gnosis Chain).
    /// @param name_       Share token name.
    /// @param symbol_     Share token symbol.
    /// @param owner_      Initial owner — multisig in production.
    /// @param treasury_   Receives fee + yield surplus. Cannot be address(0).
    /// @param capBps_     Annual net yield cap in bps. Range: 1–10_000.
    /// @param feeBps_     Fixed fee on gross yield in bps. 50 = Standard, 0 = Paktol.
    /// @param guardian_   Emergency pause address. Cannot be address(0).
    /// @param harvester_  Keeper bot allowed to call harvest(). Cannot be address(0).
    /// @param aavePool_   AAVE v3 Pool on Gnosis Chain. Cannot be address(0).
    /// @param aToken_     AAVE aEURe on Gnosis Chain. Cannot be address(0).
    /// @param maxTvl_     Maximum total assets. 0 = uncapped.
    ///
    /// @dev DEPLOYMENT CHECKLIST — execute atomically after deploy:
    ///      1. Approve MIN_DEPOSIT EURe to this vault.
    ///      2. Call deposit(MIN_DEPOSIT, 0x000...dEaD) to seed dead shares.
    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address owner_,
        address treasury_,
        uint256 capBps_,
        uint256 feeBps_,
        address guardian_,
        address harvester_,
        address aavePool_,
        address aToken_,
        uint256 maxTvl_
    ) ERC4626(asset_) ERC20(name_, symbol_) Ownable(owner_) {
        if (address(asset_) == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (guardian_ == address(0)) revert ZeroAddress();
        if (harvester_ == address(0)) revert ZeroAddress();
        if (aavePool_ == address(0)) revert ZeroAddress();
        if (aToken_ == address(0)) revert ZeroAddress();
        if (capBps_ == 0 || capBps_ > BPS_DENOMINATOR) revert CapOutOfRange(capBps_);
        if (feeBps_ >= BPS_DENOMINATOR) revert FeeOutOfRange(feeBps_);

        TREASURY = treasury_;
        CAP_BPS = capBps_;
        FEE_BPS = feeBps_;
        guardian = guardian_;
        harvester = harvester_;
        AAVE_POOL = aavePool_;
        ATOKEN = aToken_;
        MAX_TVL = maxTvl_;

        lastHarvestTimestamp = block.timestamp;
    }

    /* ───────────────────────── VIRTUAL SHARES ──────────────────────── */

    /// @dev 10^3 virtual shares — makes inflation attacks require 1000× more capital.
    ///      Combined with MIN_DEPOSIT, protects against first-depositor manipulation.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    /* ──────────────────────── ERC-4626 OVERRIDES ───────────────────── */

    /// @notice Returns 0 when paused or TVL cap is reached, per ERC-4626 spec.
    function maxDeposit(
        address
    ) public view override returns (uint256) {
        if (paused()) return 0;
        if (MAX_TVL == 0) return type(uint256).max;
        uint256 current = totalAssets();
        return current >= MAX_TVL ? 0 : MAX_TVL - current;
    }

    /// @notice Derived from maxDeposit, per ERC-4626 spec.
    function maxMint(
        address receiver
    ) public view override returns (uint256) {
        uint256 maxDep = maxDeposit(receiver);
        if (maxDep == type(uint256).max) return type(uint256).max;
        return previewDeposit(maxDep);
    }

    /// @notice Maximum assets owner_ can withdraw, bounded by AAVE available liquidity.
    ///         Returns less than the full position if AAVE liquidity is insufficient.
    ///         Withdrawals are always open (no whenNotPaused).
    function maxWithdraw(
        address owner_
    ) public view override returns (uint256) {
        uint256 userAssets = convertToAssets(balanceOf(owner_));
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 aaveLiquidity = IERC20(asset()).balanceOf(ATOKEN);
        uint256 vaultATokenBal = IERC20(ATOKEN).balanceOf(address(this));
        uint256 fromAave = vaultATokenBal < aaveLiquidity ? vaultATokenBal : aaveLiquidity;
        uint256 liquid = idle + fromAave;
        return userAssets < liquid ? userAssets : liquid;
    }

    /// @notice Maximum shares owner_ can redeem, bounded by AAVE available liquidity.
    ///         Returns balanceOf(owner_) directly when not liquidity-constrained to
    ///         avoid double-rounding (convertToShares(convertToAssets(x)) < x).
    function maxRedeem(
        address owner_
    ) public view override returns (uint256) {
        uint256 userShares = balanceOf(owner_);
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 aaveLiquidity = IERC20(asset()).balanceOf(ATOKEN);
        uint256 vaultATokenBal = IERC20(ATOKEN).balanceOf(address(this));
        uint256 fromAave = vaultATokenBal < aaveLiquidity ? vaultATokenBal : aaveLiquidity;
        uint256 liquid = idle + fromAave;
        uint256 userAssets = convertToAssets(userShares);

        // Not liquidity-constrained: return all shares directly.
        // Avoids convertToShares(convertToAssets(x)) < x double-rounding.
        if (userAssets <= liquid) return userShares;

        // Liquidity-constrained: how many shares the available liquid covers (rounds down).
        return convertToShares(liquid);
    }

    /* ──────────────────────────── TOTAL ASSETS ─────────────────────── */

    /// @notice Returns aEURe balance + any idle EURe held by the vault.
    ///         aEURe rebases 1:1 with EURe — no conversion needed.
    ///         Idle EURe exists only transiently during a deposit transaction.
    function totalAssets() public view override returns (uint256) {
        return IERC20(ATOKEN).balanceOf(address(this)) + IERC20(asset()).balanceOf(address(this));
    }

    /* ───────────────────────────── AAVE ROUTING ────────────────────── */

    /// @dev Pushes all idle EURe into AAVE. Called at end of every deposit/mint.
    function _depositToAave() internal {
        uint256 amount = IERC20(asset()).balanceOf(address(this));
        if (amount == 0) return;
        IERC20(asset()).forceApprove(AAVE_POOL, amount);
        IAavePool(AAVE_POOL).supply(asset(), amount, address(this), 0);
    }

    /// @dev Pulls EURe from AAVE. Uses idle balance first, then pulls remainder.
    ///      `to` = address(this) for user withdrawals, TREASURY for harvest.
    function _withdrawFromAave(
        uint256 amount,
        address to
    ) internal {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 needed = idle >= amount ? 0 : amount - idle;
        if (needed > 0) {
            IAavePool(AAVE_POOL).withdraw(asset(), needed, address(this));
        }
        if (to != address(this)) {
            IERC20(asset()).safeTransfer(to, amount);
        }
    }

    /* ──────────────────────── DEPOSIT / WITHDRAW ───────────────────── */

    /// @dev Shared deposit logic — called by deposit() and depositWithPermit().
    ///      Assumes caller holds nonReentrant lock and whenNotPaused check has passed.
    function _executeDeposit(
        uint256 assets,
        address receiver
    ) internal returns (uint256) {
        if (assets < MIN_DEPOSIT) revert DepositTooSmall(assets, MIN_DEPOSIT);
        uint256 current = totalAssets();
        if (MAX_TVL != 0 && current + assets > MAX_TVL) {
            revert TvlCapExceeded(current, MAX_TVL);
        }
        uint256 shares = super.deposit(assets, receiver);
        _depositToAave();
        lastTotalAssets = totalAssets();
        return shares;
    }

    /// @notice Deposit EURe. Blocked when paused.
    function deposit(
        uint256 assets,
        address receiver
    ) public override whenNotPaused nonReentrant returns (uint256) {
        return _executeDeposit(assets, receiver);
    }

    /// @notice Deposit EURe using an EIP-2612 permit — approve + deposit in one transaction.
    /// @param assets    Amount of EURe to deposit.
    /// @param receiver  Address that will receive the vault shares.
    /// @param deadline  Permit expiry timestamp. Reverts if block.timestamp > deadline.
    /// @param v         Permit signature component.
    /// @param r         Permit signature component.
    /// @param s         Permit signature component.
    function depositWithPermit(
        uint256 assets,
        address receiver,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external whenNotPaused nonReentrant returns (uint256) {
        if (assets < MIN_DEPOSIT) revert DepositTooSmall(assets, MIN_DEPOSIT);
        // Front-run mitigation: if a front-runner already submitted the permit,
        // the nonce is consumed and permit() would revert. We catch that case
        // and check the allowance directly — the deposit proceeds either way.
        try IERC20Permit(asset()).permit(msg.sender, address(this), assets, deadline, v, r, s) { } catch { }
        if (IERC20(asset()).allowance(msg.sender, address(this)) < assets) {
            revert InsufficientAllowance();
        }
        return _executeDeposit(assets, receiver);
    }

    /// @notice Mint shares. Blocked when paused.
    function mint(
        uint256 shares,
        address receiver
    ) public override whenNotPaused nonReentrant returns (uint256) {
        uint256 assets = previewMint(shares);
        if (assets < MIN_DEPOSIT) revert DepositTooSmall(assets, MIN_DEPOSIT);
        uint256 current = totalAssets();
        if (MAX_TVL != 0 && current + assets > MAX_TVL) {
            revert TvlCapExceeded(current, MAX_TVL);
        }
        uint256 assetsUsed = super.mint(shares, receiver);
        _depositToAave();
        lastTotalAssets = totalAssets();
        return assetsUsed;
    }

    /// @notice Withdraw EURe. Always available, even when paused.
    function withdraw(
        uint256 assets,
        address receiver,
        address owner_
    ) public override nonReentrant returns (uint256) {
        // CEI exception: assets must be present in the vault before super.withdraw()
        // can transfer them to the receiver. Safe: nonReentrant + EURe has no callbacks.
        _withdrawFromAave(assets, address(this));
        uint256 shares = super.withdraw(assets, receiver, owner_);
        lastTotalAssets = totalAssets();
        return shares;
    }

    /// @notice Redeem shares. Always available, even when paused.
    function redeem(
        uint256 shares,
        address receiver,
        address owner_
    ) public override nonReentrant returns (uint256) {
        // CEI exception: same rationale as withdraw() above.
        _withdrawFromAave(previewRedeem(shares), address(this));
        uint256 assets = super.redeem(shares, receiver, owner_);
        lastTotalAssets = totalAssets();
        return assets;
    }

    /* ───────────────────────────── HARVEST ─────────────────────────── */

    /// @notice Collects yield generated since last harvest and routes it per plan rules.
    ///         Callable by owner or harvester (keeper bot).
    ///
    ///         aumFee     = lastTotalAssets × FEE_BPS × elapsed / (BPS_DENOMINATOR × SECONDS_PER_YEAR)
    ///         aumFee     = min(aumFee, grossYield)     [never touch principal]
    ///         remaining  = grossYield − aumFee
    ///         toUsers    = min(remaining, maxNetYield) [pro-rated annual cap]
    ///         toTreasury = grossYield − toUsers        [aumFee + surplus above cap]
    ///
    ///         Treasury portion is withdrawn from AAVE and transferred directly.
    function harvest() external nonReentrant {
        if (msg.sender != owner() && msg.sender != harvester) revert NotHarvester();

        uint256 current = totalAssets();

        // No yield or loss — reset snapshot and exit cleanly.
        if (current <= lastTotalAssets) {
            lastTotalAssets = current;
            lastHarvestTimestamp = block.timestamp;
            return;
        }

        uint256 elapsed = block.timestamp - lastHarvestTimestamp;

        // Same-block guard: elapsed == 0 → maxNetYield == 0 → all yield to treasury.
        // Return early — state is already up to date from the previous call.
        if (elapsed == 0) return;

        uint256 grossYield = current - lastTotalAssets;

        // AUM fee on capital, pro-rated for elapsed period.
        uint256 maxAumFee = (lastTotalAssets * FEE_BPS * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);

        // Floored fee: when APY < FLOOR_BPS (2%), fee scales down with yield.
        // flooredFee = grossYield × FEE_BPS / FLOOR_BPS
        // At APY = 2%: flooredFee == maxAumFee (seamless transition).
        // At APY < 2%: flooredFee < maxAumFee (user protected).
        uint256 flooredFee = (grossYield * FEE_BPS) / FLOOR_BPS;

        // Take the smaller of the two — never touches principal.
        uint256 aumFee = maxAumFee < flooredFee ? maxAumFee : flooredFee;

        // Remaining yield after AUM fee, capped at the pro-rated annual cap.
        uint256 remaining = grossYield - aumFee;
        uint256 maxNetYield = (lastTotalAssets * CAP_BPS * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
        uint256 toUsers = remaining < maxNetYield ? remaining : maxNetYield;
        uint256 toTreasury = grossYield - toUsers;

        // CEI: update state before external interaction.
        lastTotalAssets = current - toTreasury;
        lastHarvestTimestamp = block.timestamp;

        emit Harvested(grossYield, toTreasury, toUsers, block.timestamp);

        if (toTreasury > 0) {
            _withdrawFromAave(toTreasury, TREASURY);
        }
    }

    /* ───────────────────────────── GUARDIAN ────────────────────────── */

    /// @notice Replaces the guardian. Owner only.
    function setGuardian(
        address newGuardian_
    ) external onlyOwner {
        if (newGuardian_ == address(0)) revert ZeroAddress();
        emit GuardianChanged(guardian, newGuardian_);
        guardian = newGuardian_;
    }

    /// @notice Replaces the harvester. Owner only.
    function setHarvester(
        address newHarvester_
    ) external onlyOwner {
        if (newHarvester_ == address(0)) revert ZeroAddress();
        emit HarvesterChanged(harvester, newHarvester_);
        harvester = newHarvester_;
    }

    /* ──────────────────────────────  PAUSE  ────────────────────────── */

    /// @notice Pauses deposits. Withdrawals remain open. Callable by owner or guardian.
    function pause() external {
        if (msg.sender != owner() && msg.sender != guardian) revert NotGuardian();
        _pause();
    }

    /// @notice Unpauses. Owner only.
    function unpause() external onlyOwner {
        _unpause();
    }

    /* ────────────────────────── EMERGENCY EXIT ──────────────────────── */

    /// @notice Pulls all aEURe out of AAVE back into the vault as idle EURe.
    ///         Use when AAVE freezes or pauses the EURe market.
    ///
    ///         Recommended sequence:
    ///           1. guardian calls pause()       — blocks new deposits
    ///           2. owner   calls emergencyExitAave() — withdraws all from AAVE
    ///           3. users   call withdraw() / redeem() — served from idle balance
    ///
    ///         If AAVE is fully paused (not just frozen), this call will revert.
    ///         In that case there is no on-chain remedy until AAVE unpauses.
    function emergencyExitAave() external onlyOwner nonReentrant {
        uint256 aTokenBalance = IERC20(ATOKEN).balanceOf(address(this));
        if (aTokenBalance == 0) return;
        IAavePool(AAVE_POOL).withdraw(asset(), aTokenBalance, address(this));
        emit EmergencyExitAave(aTokenBalance, block.timestamp);
    }
}
