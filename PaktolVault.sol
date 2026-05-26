// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
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

    /// @notice EIP-712 type hash for depositWithAuth authorization.
    bytes32 public constant DEPOSIT_AUTH_TYPEHASH =
        keccak256("DepositAuth(address sender,uint256 assets,address receiver,uint256 deadline,uint256 nonce)");

    /// @notice APY floor below which the AUM fee is pro-rated down.
    ///         200 = 2%. When AAVE APY < 2%, aumFee = grossYield × FEE_BPS / FLOOR_BPS
    ///         instead of the full capital-based fee — protecting users in low-yield periods.
    uint256 public constant FLOOR_BPS = 200;

    /// @notice Minimum deposit. EURe has 18 decimals: 1e9 = 0.000000001 EURe.
    ///         Negligible for users, but makes inflation attacks economically infeasible
    ///         combined with _decimalsOffset() = 3 (virtual shares).
    uint256 public constant MIN_DEPOSIT = 1e9;

    /// @notice Minimum time between two harvests. Prevents a compromised harvester
    ///         from draining yield to the treasury via high-frequency calls.
    uint256 public constant MIN_HARVEST_INTERVAL = 1 days;

    /// @notice Minimum hold time after a deposit before withdrawal is allowed.
    ///         Prevents sandwich attacks on harvest(): an attacker depositing just
    ///         before harvest() cannot withdraw until 4 hours have elapsed.
    ///         Bypassed when the vault is paused (emergency exit must always be possible).
    uint256 public constant WITHDRAWAL_COOLDOWN = 4 hours;

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

    /// @notice Backend signer wallet. Authorizes deposits on restricted vaults.
    ///         Must be non-zero. Unused when REQUIRES_AUTH = false.
    address public immutable SIGNER;

    /// @notice If true, deposit()/mint()/depositWithPermit() revert — only depositWithAuth() is accepted.
    ///         Set to true for the Paktol subscription vault (FEE_BPS = 0, CAP_BPS = 500).
    bool public immutable REQUIRES_AUTH;

    /// @notice EIP-712 domain separator. Computed once at deploy time.
    bytes32 public immutable DOMAIN_SEPARATOR;

    /* ───────────────────────────── STORAGE ─────────────────────────── */

    /// @notice totalAssets() snapshot — updated after every deposit, withdraw, and harvest.
    uint256 public lastTotalAssets;

    /// @dev Tracks EURe held idle by this contract (e.g. after emergencyExitAave()).
    ///      Explicit tracking prevents donations from inflating totalAssets() (F-10).
    uint256 private _idleBalance;

    /// @notice Per-address nonce for depositWithAuth replay protection.
    mapping(address => uint256) public nonces;

    /// @notice Timestamp of the last harvest.
    uint256 public lastHarvestTimestamp;

    /// @notice Timestamp of the last deposit per address. Used to enforce WITHDRAWAL_COOLDOWN.
    mapping(address => uint256) public depositTimestamp;

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

    error ZeroAddress(string param);
    error ATokenMismatch(address provided, address expected);
    error CapOutOfRange(uint256 provided);
    error FeeOutOfRange(uint256 provided);
    error NotGuardian();
    error NotHarvester();
    error DepositTooSmall(uint256 assets, uint256 minimum);
    error TvlCapExceeded(uint256 current, uint256 cap);
    error HarvestTooFrequent(uint256 elapsed, uint256 minimum);
    error InsufficientAllowance();
    error UseDepositWithAuth();
    error InvalidSignature();
    error SignatureExpired();
    error WithdrawalCooldown(uint256 availableAt);
    error RolesNotSeparated();

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
    /// @param aavePool_     AAVE v3 Pool on Gnosis Chain. Cannot be address(0).
    /// @param aToken_       AAVE aEURe on Gnosis Chain. Cannot be address(0).
    /// @param maxTvl_       Maximum total assets. 0 = uncapped.
    /// @param signer_       Backend wallet that signs depositWithAuth authorizations. Cannot be address(0).
    /// @param requiresAuth_ If true, only depositWithAuth() is accepted — deposit/mint/depositWithPermit revert.
    ///
    /// @dev DEPLOYMENT CHECKLIST — execute atomically after deploy:
    ///      1. Approve MIN_DEPOSIT EURe to this vault.
    ///      2. Call deposit(MIN_DEPOSIT, 0x000...dEaD) to seed dead shares (Standard vault only).
    ///         For restricted vaults, use depositWithAuth for the dead-share seed.
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
        uint256 maxTvl_,
        address signer_,
        bool    requiresAuth_
    ) ERC4626(asset_) ERC20(name_, symbol_) Ownable(owner_) {
        if (address(asset_) == address(0)) revert ZeroAddress("asset");
        if (treasury_ == address(0)) revert ZeroAddress("treasury");
        if (guardian_ == address(0)) revert ZeroAddress("guardian");
        if (harvester_ == address(0)) revert ZeroAddress("harvester");
        if (aavePool_ == address(0)) revert ZeroAddress("aavePool");
        if (aToken_ == address(0)) revert ZeroAddress("aToken");
        if (signer_ == address(0)) revert ZeroAddress("signer");
        if (capBps_ == 0 || capBps_ > BPS_DENOMINATOR) revert CapOutOfRange(capBps_);
        if (feeBps_ > FLOOR_BPS) revert FeeOutOfRange(feeBps_);
        if (owner_ == guardian_ || owner_ == harvester_ || guardian_ == harvester_) revert RolesNotSeparated();

        IAavePool.ReserveData memory reserve = IAavePool(aavePool_).getReserveData(address(asset_));
        if (reserve.aTokenAddress != aToken_) revert ATokenMismatch(aToken_, reserve.aTokenAddress);

        TREASURY = treasury_;
        CAP_BPS = capBps_;
        FEE_BPS = feeBps_;
        guardian = guardian_;
        harvester = harvester_;
        AAVE_POOL = aavePool_;
        ATOKEN = aToken_;
        MAX_TVL = maxTvl_;
        SIGNER = signer_;
        REQUIRES_AUTH = requiresAuth_;

        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(name_)),
            keccak256("1"),
            block.chainid,
            address(this)
        ));

        lastHarvestTimestamp = block.timestamp;
    }

    /* ───────────────────────── VIRTUAL SHARES ──────────────────────── */

    /// @dev 10^3 virtual shares — makes inflation attacks require 1000× more capital.
    ///      Combined with MIN_DEPOSIT, protects against first-depositor manipulation.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    /* ──────────────────────── ERC-4626 OVERRIDES ───────────────────── */

    /// @dev aEURe rebases continuously with AAVE interest. Between a preview call and actual execution,
    ///      the aEURe balance may change by a few wei per AAVE epoch. Implications:
    ///        • previewDeposit / previewMint: may return slightly fewer shares than actually minted.
    ///        • previewWithdraw / previewRedeem: may return slightly more assets than actually received.
    ///      Use withdrawSafe() / redeemSafe() from the frontend for slippage protection.

    /// @notice Returns 0 when paused or TVL cap is reached, per ERC-4626 spec.
    ///         Returns type(uint256).max when MAX_TVL == 0 (uncapped vault).
    ///         Integrators should treat type(uint256).max as "no practical limit", not as a literal amount.
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
    ///         Returns 0 if owner_ is within the WITHDRAWAL_COOLDOWN window (vault not paused).
    ///         Returns less than the full position if AAVE liquidity is insufficient.
    ///         Withdrawals are always open (no whenNotPaused).
    function maxWithdraw(
        address owner_
    ) public view override returns (uint256) {
        if (!paused() && block.timestamp < depositTimestamp[owner_] + WITHDRAWAL_COOLDOWN) return 0;
        uint256 userAssets = convertToAssets(balanceOf(owner_));
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 aaveLiquidity = IERC20(asset()).balanceOf(ATOKEN);
        uint256 vaultATokenBal = IERC20(ATOKEN).balanceOf(address(this));
        uint256 fromAave = vaultATokenBal < aaveLiquidity ? vaultATokenBal : aaveLiquidity;
        uint256 liquid = idle + fromAave;
        return userAssets < liquid ? userAssets : liquid;
    }

    /// @notice Maximum shares owner_ can redeem, bounded by AAVE available liquidity.
    ///         Returns 0 if owner_ is within the WITHDRAWAL_COOLDOWN window (vault not paused).
    ///         Returns balanceOf(owner_) directly when not liquidity-constrained to
    ///         avoid double-rounding (convertToShares(convertToAssets(x)) < x).
    function maxRedeem(
        address owner_
    ) public view override returns (uint256) {
        if (!paused() && block.timestamp < depositTimestamp[owner_] + WITHDRAWAL_COOLDOWN) return 0;
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
    /// @dev Uses _idleBalance instead of balanceOf(address(this)) to prevent donation
    ///      inflation (F-10). Direct EURe transfers to this contract are silently ignored
    ///      in yield accounting.
    function totalAssets() public view override returns (uint256) {
        return IERC20(ATOKEN).balanceOf(address(this)) + _idleBalance;
    }

    /* ───────────────────────────── AAVE ROUTING ────────────────────── */

    /// @dev Pushes all idle EURe into AAVE. Called at end of every deposit/mint.
    ///      forceApprove is called on every invocation rather than once in the constructor.
    ///      EURe (Monerium) may exhibit non-standard approval behaviour under future upgrades;
    ///      re-approving each time is the safest pattern for such tokens (EIP-20 §approve).
    function _depositToAave() internal {
        uint256 amount = IERC20(asset()).balanceOf(address(this));
        if (amount == 0) return;
        _idleBalance = 0;
        IERC20(asset()).forceApprove(AAVE_POOL, amount);
        IAavePool(AAVE_POOL).supply(asset(), amount, address(this), 0);
    }

    /// @dev Pulls EURe from AAVE. Uses idle balance first, then pulls remainder.
    ///      `to` = address(this) for user withdrawals, TREASURY for harvest.
    function _withdrawFromAave(
        uint256 amount,
        address to
    ) internal {
        uint256 idle = _idleBalance;
        uint256 needed = idle >= amount ? 0 : amount - idle;
        if (needed > 0) {
            IAavePool(AAVE_POOL).withdraw(asset(), needed, address(this));
        }
        if (idle > 0) {
            _idleBalance = idle > amount ? idle - amount : 0;
        }
        if (to != address(this)) {
            IERC20(asset()).safeTransfer(to, amount);
        }
    }

    /* ──────────────────────── DEPOSIT / WITHDRAW ───────────────────── */

    /// @dev Updates lastTotalAssets by a signed delta instead of re-reading totalAssets().
    ///      Preserves accumulated yield that has already been computed by harvest()
    ///      and must not be overwritten by a subsequent deposit or withdrawal.
    function _syncLastTotalAssets(int256 delta) internal {
        if (delta >= 0) {
            lastTotalAssets += uint256(delta);
        } else {
            uint256 decrease = uint256(-delta);
            lastTotalAssets = lastTotalAssets > decrease ? lastTotalAssets - decrease : 0;
        }
    }

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
        _syncLastTotalAssets(int256(assets));
        depositTimestamp[receiver] = block.timestamp;
        return shares;
    }

    /// @notice Deposit EURe. Blocked when paused or when REQUIRES_AUTH is set.
    function deposit(
        uint256 assets,
        address receiver
    ) public override whenNotPaused nonReentrant returns (uint256) {
        if (REQUIRES_AUTH) revert UseDepositWithAuth();
        return _executeDeposit(assets, receiver);
    }

    /// @notice Deposit up to `assets` EURe, capping at remaining TVL capacity.
    ///         Eliminates the TVL-cap griefing vector: instead of reverting when the cap
    ///         is nearly full, deposits only what fits and returns the accepted amount.
    ///         The caller must approve at least `assets`; any unused allowance is not consumed.
    /// @param assets   Maximum amount the caller wishes to deposit.
    /// @param receiver Address that will receive the vault shares.
    /// @return accepted Actual assets deposited (≤ assets).
    /// @return shares   Shares minted to receiver.
    function depositUpToCap(
        uint256 assets,
        address receiver
    ) external whenNotPaused nonReentrant returns (uint256 accepted, uint256 shares) {
        if (REQUIRES_AUTH) revert UseDepositWithAuth();
        uint256 remaining = maxDeposit(receiver);
        if (remaining == 0) return (0, 0);
        accepted = assets > remaining ? remaining : assets;
        shares = _executeDeposit(accepted, receiver);
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
        if (REQUIRES_AUTH) revert UseDepositWithAuth();
        if (assets < MIN_DEPOSIT) revert DepositTooSmall(assets, MIN_DEPOSIT);
        // Skip permit if allowance is already sufficient (e.g. pre-existing or front-run permit).
        // When permit is needed: record nonce before, attempt permit, then verify nonce advanced.
        // If nonce did not advance the permit failed for a reason other than front-run (expired
        // deadline, invalid signature) and no pre-existing allowance covers the deposit — revert.
        if (IERC20(asset()).allowance(msg.sender, address(this)) < assets) {
            uint256 nonceBefore = IERC20Permit(asset()).nonces(msg.sender);
            try IERC20Permit(asset()).permit(msg.sender, address(this), assets, deadline, v, r, s) { } catch { }
            if (IERC20Permit(asset()).nonces(msg.sender) == nonceBefore) revert InsufficientAllowance();
        }
        return _executeDeposit(assets, receiver);
    }

    /// @notice Deposit EURe with a backend-issued EIP-712 authorization.
    ///         Required on restricted vaults (REQUIRES_AUTH = true).
    ///         The backend signs after verifying an active Stripe subscription.
    ///
    /// @param assets    Amount of EURe to deposit.
    /// @param receiver  Address that will receive the vault shares.
    /// @param deadline  Signature expiry. Reverts if block.timestamp > deadline.
    /// @param sig       Backend signature over the EIP-712 DepositAuth struct.
    ///
    /// @dev Replay protection: nonce incremented per call per sender.
    ///      Cross-vault protection: address(this) in the signed struct.
    ///      Cross-chain protection: chainId in DOMAIN_SEPARATOR.
    function depositWithAuth(
        uint256 assets,
        address receiver,
        uint256 deadline,
        bytes calldata sig
    ) external whenNotPaused nonReentrant returns (uint256) {
        if (block.timestamp > deadline) revert SignatureExpired();

        bytes32 structHash = keccak256(abi.encode(
            DEPOSIT_AUTH_TYPEHASH,
            msg.sender,
            assets,
            receiver,
            deadline,
            nonces[msg.sender]++
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));

        if (ECDSA.recover(digest, sig) != SIGNER) revert InvalidSignature();

        return _executeDeposit(assets, receiver);
    }

    /// @notice Mint shares. Blocked when paused or when REQUIRES_AUTH is set.
    function mint(
        uint256 shares,
        address receiver
    ) public override whenNotPaused nonReentrant returns (uint256) {
        if (REQUIRES_AUTH) revert UseDepositWithAuth();
        uint256 assets = previewMint(shares);
        if (assets < MIN_DEPOSIT) revert DepositTooSmall(assets, MIN_DEPOSIT);
        uint256 current = totalAssets();
        if (MAX_TVL != 0 && current + assets > MAX_TVL) {
            revert TvlCapExceeded(current, MAX_TVL);
        }
        uint256 assetsUsed = super.mint(shares, receiver);
        _depositToAave();
        _syncLastTotalAssets(int256(assetsUsed));
        depositTimestamp[receiver] = block.timestamp;
        return assetsUsed;
    }

    /// @notice Withdraw EURe. Always available, even when paused.
    ///         Intentional design: users must be able to exit at all times per ERC-4626.
    ///         pause() only blocks new deposits — it does not block withdrawals.
    function withdraw(
        uint256 assets,
        address receiver,
        address owner_
    ) public override nonReentrant returns (uint256) {
        if (!paused() && block.timestamp < depositTimestamp[owner_] + WITHDRAWAL_COOLDOWN) {
            revert WithdrawalCooldown(depositTimestamp[owner_] + WITHDRAWAL_COOLDOWN);
        }
        uint256 shares = super.withdraw(assets, receiver, owner_);
        _syncLastTotalAssets(-int256(assets));
        return shares;
    }

    /// @notice Redeem shares. Always available, even when paused.
    ///         Intentional design: users must be able to exit at all times per ERC-4626.
    ///         pause() only blocks new deposits — it does not block redemptions.
    /// @dev    assets is computed as previewRedeem(shares) before _withdrawFromAave executes.
    ///         If aEURe rebases in the same block between computation and withdrawal, the vault
    ///         may attempt to pull 1 wei more than available from AAVE — causing a revert.
    ///         This is a known ERC-4626 edge case; use slippage-protected wrappers on the frontend.
    function redeem(
        uint256 shares,
        address receiver,
        address owner_
    ) public override nonReentrant returns (uint256) {
        if (!paused() && block.timestamp < depositTimestamp[owner_] + WITHDRAWAL_COOLDOWN) {
            revert WithdrawalCooldown(depositTimestamp[owner_] + WITHDRAWAL_COOLDOWN);
        }
        uint256 assets = super.redeem(shares, receiver, owner_);
        _syncLastTotalAssets(-int256(assets));
        return assets;
    }

    /// @dev Propagates depositTimestamp on share transfers to prevent cooldown bypass.
    ///      Without this, an attacker could deposit, transfer shares to a fresh address,
    ///      and that address would have no cooldown — bypassing the sandwich protection.
    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (from != address(0) && to != address(0)) {
            if (depositTimestamp[from] > depositTimestamp[to]) {
                depositTimestamp[to] = depositTimestamp[from];
            }
        }
    }

    /// @dev CEI-compliant internal hook called by withdraw() and redeem().
    ///      Shares are burned by OpenZeppelin BEFORE this hook executes,
    ///      so all state updates (Effects) precede external calls (Interactions).
    ///      Order: Check (allowance) → Effect (burn) → Interaction (AAVE + transfer).
    function _withdraw(
        address caller,
        address receiver,
        address owner_,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (caller != owner_) _spendAllowance(owner_, caller, shares);
        _burn(owner_, shares);
        emit Withdraw(caller, receiver, owner_, assets, shares);
        uint256 idle = _idleBalance;
        if (idle < assets) {
            IAavePool(AAVE_POOL).withdraw(asset(), assets - idle, address(this));
        }
        if (idle > 0) {
            _idleBalance = idle > assets ? idle - assets : 0;
        }
        IERC20(asset()).safeTransfer(receiver, assets);
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
    /// @dev    TREASURY must be an EOA or a contract with a minimal receive() function.
    ///         An expensive treasury receive() would increase the gas cost of every harvest()
    ///         call. Verify this assumption before deployment.
    function harvest() external nonReentrant {
        if (msg.sender != owner() && msg.sender != harvester) revert NotHarvester();

        uint256 elapsed = block.timestamp - lastHarvestTimestamp;
        if (elapsed < MIN_HARVEST_INTERVAL) revert HarvestTooFrequent(elapsed, MIN_HARVEST_INTERVAL);

        uint256 current = totalAssets();

        // No yield or loss — update snapshot but preserve timestamp.
        // Advancing the timestamp here would shrink the elapsed window on the next
        // profitable harvest, compressing maxNetYield and redirecting yield to treasury.
        if (current <= lastTotalAssets) {
            lastTotalAssets = current;
            return;
        }

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

        // Re-supply any residual idle EURe left after the treasury transfer.
        // _withdrawFromAave preferentially consumes idle balance before pulling from Aave;
        // if idle > toTreasury the surplus stays idle until the next deposit/mint.
        // Calling _depositToAave() here eliminates that yield gap.
        _depositToAave();
    }

    /* ───────────────────────────── GUARDIAN ────────────────────────── */

    /// @notice Replaces the guardian. Owner only.
    function setGuardian(
        address newGuardian_
    ) external onlyOwner {
        if (newGuardian_ == address(0)) revert ZeroAddress("newGuardian");
        if (newGuardian_ == owner() || newGuardian_ == harvester) revert RolesNotSeparated();
        emit GuardianChanged(guardian, newGuardian_);
        guardian = newGuardian_;
    }

    /// @notice Replaces the harvester. Owner only.
    function setHarvester(
        address newHarvester_
    ) external onlyOwner {
        if (newHarvester_ == address(0)) revert ZeroAddress("newHarvester");
        if (newHarvester_ == owner() || newHarvester_ == guardian) revert RolesNotSeparated();
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
    ///         Automatically pauses deposits if not already paused, so a concurrent
    ///         deposit cannot immediately re-route funds back into AAVE.
    ///
    ///         Recommended sequence:
    ///           1. owner calls emergencyExitAave() — pauses + withdraws atomically
    ///           2. users call withdraw() / redeem() — served from idle balance
    ///              withdraw() and redeem() intentionally omit whenNotPaused: users
    ///              can always exit regardless of pause state. This is a deliberate
    ///              ERC-4626 design trade-off; if the withdrawal path itself were
    ///              compromised, the only mitigation would be a contract upgrade.
    ///
    ///         lastTotalAssets and lastHarvestTimestamp are reset to reflect the
    ///         post-exit state. Any yield accrued since the last harvest is absorbed
    ///         into the new baseline — this is an acceptable trade-off in an emergency
    ///         to avoid an additional AAVE interaction that could fail if AAVE is degraded.
    ///
    ///         If AAVE is fully paused (not just frozen), this call will revert.
    ///         In that case there is no on-chain remedy until AAVE unpauses.
    function emergencyExitAave() external onlyOwner nonReentrant {
        if (!paused()) _pause();
        uint256 aTokenBalance = IERC20(ATOKEN).balanceOf(address(this));
        if (aTokenBalance == 0) return;
        // type(uint256).max lets Aave resolve the live balance server-side,
        // removing the 1-wei race condition caused by the rebasing aToken.
        uint256 withdrawn = IAavePool(AAVE_POOL).withdraw(asset(), type(uint256).max, address(this));
        _idleBalance = withdrawn;
        lastTotalAssets = totalAssets();
        lastHarvestTimestamp = block.timestamp;
        emit EmergencyExitAave(withdrawn, block.timestamp);
    }
}
