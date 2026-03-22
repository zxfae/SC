// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PaktolVault.sol";
import "../src/mocks/MockEURe.sol";
import "./mocks/MockAavePool.sol";

contract PaktolVaultTest is Test {
    MockEURe internal eure;
    MockAavePool internal pool;

    // Standard vault — 0.5% fee, 3.5% cap
    PaktolVault internal vaultStd;
    // Paktol subscription vault — 0% fee, 5% cap
    PaktolVault internal vaultPkt;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal guardian = makeAddr("guardian");
    address internal harvester = makeAddr("harvester");
    address internal user = makeAddr("user");
    address internal user2 = makeAddr("user2");

    uint256 constant CAP_STD = 350; // 3.5%
    uint256 constant CAP_PKT = 500; // 5%
    uint256 constant FEE_STD = 50; // 0.5%
    uint256 constant FEE_PKT = 0; // none

    uint256 constant DEPOSIT = 1_000e18; // 1 000 EURe
    uint256 constant USER_BALANCE = 10_000e18;

    function setUp() public {
        eure = new MockEURe();
        pool = new MockAavePool(address(eure));

        address aToken = address(pool.aToken());

        vaultStd = new PaktolVault(
            IERC20(address(eure)),
            "Paktol Standard",
            "pkEUR-S",
            owner,
            treasury,
            CAP_STD,
            FEE_STD,
            guardian,
            harvester,
            address(pool),
            aToken,
            0
        );

        vaultPkt = new PaktolVault(
            IERC20(address(eure)),
            "Paktol Subscription",
            "pkEUR-P",
            owner,
            treasury,
            CAP_PKT,
            FEE_PKT,
            guardian,
            harvester,
            address(pool),
            aToken,
            0
        );

        eure.mint(user, USER_BALANCE);
        eure.mint(user2, USER_BALANCE);
    }

    /* ─────────────────────── HELPERS ────────────────────────────────── */

    function _deposit(
        PaktolVault vault,
        address who,
        uint256 amount
    ) internal returns (uint256 shares) {
        vm.startPrank(who);
        eure.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }

    /// @dev Mints EURe to aToken (backing) then rebases aToken to simulate AAVE yield.
    ///      In real AAVE v3, underlying is held by the aToken contract — mock mirrors this.
    function _simulateYield(
        PaktolVault vault,
        uint256 amount
    ) internal {
        eure.mint(address(pool.aToken()), amount);
        pool.simulateYield(address(vault), amount);
    }

    function _warp(
        uint256 secs
    ) internal {
        vm.warp(block.timestamp + secs);
    }

    /* ── Constructor revert helpers ────────────────────────────────────
       vm.expectRevert does not intercept CREATE opcodes in the same frame.
       Each helper is external so the deployment is a proper sub-call.
    ── */

    function helper_deployZeroAsset() external {
        new PaktolVault(
            IERC20(address(0)),
            "x",
            "x",
            owner,
            treasury,
            CAP_STD,
            FEE_STD,
            guardian,
            harvester,
            address(pool),
            address(pool.aToken()),
            0
        );
    }

    function helper_deployZeroTreasury() external {
        new PaktolVault(
            IERC20(address(eure)),
            "x",
            "x",
            owner,
            address(0),
            CAP_STD,
            FEE_STD,
            guardian,
            harvester,
            address(pool),
            address(pool.aToken()),
            0
        );
    }

    function helper_deployCapZero() external {
        new PaktolVault(
            IERC20(address(eure)),
            "x",
            "x",
            owner,
            treasury,
            0,
            FEE_STD,
            guardian,
            harvester,
            address(pool),
            address(pool.aToken()),
            0
        );
    }

    function helper_deployCapAboveMax() external {
        new PaktolVault(
            IERC20(address(eure)),
            "x",
            "x",
            owner,
            treasury,
            10_001,
            FEE_STD,
            guardian,
            harvester,
            address(pool),
            address(pool.aToken()),
            0
        );
    }

    function helper_deployFee100pct() external {
        new PaktolVault(
            IERC20(address(eure)),
            "x",
            "x",
            owner,
            treasury,
            CAP_STD,
            10_000,
            guardian,
            harvester,
            address(pool),
            address(pool.aToken()),
            0
        );
    }

    /* ─────────────────────── CONSTRUCTOR ────────────────────────────── */

    function test_constructor_immutables() public view {
        assertEq(vaultStd.CAP_BPS(), CAP_STD);
        assertEq(vaultStd.FEE_BPS(), FEE_STD);
        assertEq(vaultStd.TREASURY(), treasury);
        assertEq(vaultStd.AAVE_POOL(), address(pool));
        assertEq(vaultStd.ATOKEN(), address(pool.aToken()));
        assertEq(vaultStd.MAX_TVL(), 0);
        assertEq(vaultStd.guardian(), guardian);
        assertEq(vaultStd.harvester(), harvester);
    }

    function test_constructor_revert_zeroAsset() public {
        vm.expectRevert(PaktolVault.ZeroAddress.selector);
        this.helper_deployZeroAsset();
    }

    function test_constructor_revert_zeroTreasury() public {
        vm.expectRevert(PaktolVault.ZeroAddress.selector);
        this.helper_deployZeroTreasury();
    }

    function test_constructor_revert_capZero() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVault.CapOutOfRange.selector, 0));
        this.helper_deployCapZero();
    }

    function test_constructor_revert_capAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVault.CapOutOfRange.selector, 10_001));
        this.helper_deployCapAboveMax();
    }

    function test_constructor_revert_fee100pct() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVault.FeeOutOfRange.selector, 10_000));
        this.helper_deployFee100pct();
    }

    /* ─────────────────────── DEPOSIT ────────────────────────────────── */

    function test_deposit_basic() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);

        assertGt(shares, 0);
        assertEq(vaultStd.totalAssets(), DEPOSIT);
        // All EURe must be deployed to AAVE — no idle balance.
        assertEq(eure.balanceOf(address(vaultStd)), 0);
        assertEq(IERC20(vaultStd.ATOKEN()).balanceOf(address(vaultStd)), DEPOSIT);
    }

    function test_deposit_updates_lastTotalAssets() public {
        _deposit(vaultStd, user, DEPOSIT);
        assertEq(vaultStd.lastTotalAssets(), DEPOSIT);
    }

    function test_deposit_revert_tooSmall() public {
        vm.startPrank(user);
        eure.approve(address(vaultStd), 1);
        vm.expectRevert(abi.encodeWithSelector(PaktolVault.DepositTooSmall.selector, 1, vaultStd.MIN_DEPOSIT()));
        vaultStd.deposit(1, user);
        vm.stopPrank();
    }

    function test_deposit_revert_whenPaused() public {
        vm.prank(guardian);
        vaultStd.pause();

        vm.startPrank(user);
        eure.approve(address(vaultStd), DEPOSIT);
        vm.expectRevert();
        vaultStd.deposit(DEPOSIT, user);
        vm.stopPrank();
    }

    function test_mint_basic() public {
        uint256 sharesToMint = 500e18;
        vm.startPrank(user);
        eure.approve(address(vaultStd), DEPOSIT);
        uint256 assetsUsed = vaultStd.mint(sharesToMint, user);
        vm.stopPrank();

        assertGt(assetsUsed, 0);
        assertEq(vaultStd.balanceOf(user), sharesToMint);
    }

    /* ─────────────────────── WITHDRAW / REDEEM ──────────────────────── */

    function test_withdraw_basic() public {
        _deposit(vaultStd, user, DEPOSIT);
        uint256 balBefore = eure.balanceOf(user);

        vm.prank(user);
        vaultStd.withdraw(DEPOSIT, user, user);

        assertEq(eure.balanceOf(user), balBefore + DEPOSIT);
        assertEq(vaultStd.totalAssets(), 0);
    }

    function test_withdraw_works_when_paused() public {
        _deposit(vaultStd, user, DEPOSIT);

        vm.prank(guardian);
        vaultStd.pause();

        // Must succeed even while paused.
        vm.prank(user);
        vaultStd.withdraw(DEPOSIT, user, user);

        assertEq(eure.balanceOf(user), USER_BALANCE);
    }

    function test_redeem_basic() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);
        uint256 balBefore = eure.balanceOf(user);

        vm.prank(user);
        vaultStd.redeem(shares, user, user);

        assertApproxEqAbs(eure.balanceOf(user), balBefore + DEPOSIT, 1e9);
        assertApproxEqAbs(vaultStd.totalAssets(), 0, 1e9);
    }

    function test_withdraw_updates_lastTotalAssets() public {
        _deposit(vaultStd, user, DEPOSIT);

        vm.prank(user);
        vaultStd.withdraw(DEPOSIT / 2, user, user);

        assertApproxEqAbs(vaultStd.lastTotalAssets(), DEPOSIT / 2, 1e9);
    }

    /* ─────────────────────── HARVEST — STANDARD ─────────────────────── */

    function test_harvest_std_belowCap() public {
        // 20 EURe yield on 1000 = 2% gross, 1 year elapsed.
        // aumFee   = 1000 × 0.5% = 5 EURe
        // remaining = 20 - 5 = 15 EURe
        // maxNetYield = 1000 × 3.5% = 35 EURe → toUsers = 15, toTreasury = 5
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        _simulateYield(vaultStd, 20e18);

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 expectedAumFee = (DEPOSIT * FEE_STD) / 10_000; // 5 EURe
        assertApproxEqAbs(eure.balanceOf(treasury), expectedAumFee, 1e9);
        assertApproxEqAbs(vaultStd.totalAssets(), DEPOSIT + 20e18 - expectedAumFee, 1e9);
    }

    function test_harvest_std_atCap() public {
        // 40 EURe yield = 4% gross, 1 year elapsed.
        // aumFee    = 1000 × 0.5% = 5 EURe
        // remaining = 40 - 5 = 35 EURe
        // maxNetYield = 1000 × 3.5% = 35 EURe → toUsers = 35, toTreasury = 5
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        _simulateYield(vaultStd, 40e18);

        vm.prank(harvester);
        vaultStd.harvest();

        assertApproxEqAbs(eure.balanceOf(treasury), 5e18, 1e9);
        assertApproxEqAbs(vaultStd.totalAssets(), DEPOSIT + 35e18, 1e9);
    }

    function test_harvest_std_aboveCap() public {
        // 60 EURe yield = 6% gross, 1 year elapsed.
        // aumFee    = 1000 × 0.5% = 5 EURe
        // remaining = 60 - 5 = 55 EURe
        // maxNetYield = 35 EURe → toUsers = 35, surplus = 20, toTreasury = 5 + 20 = 25
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        _simulateYield(vaultStd, 60e18);

        vm.prank(harvester);
        vaultStd.harvest();

        assertApproxEqAbs(eure.balanceOf(treasury), 25e18, 1e9);
        assertApproxEqAbs(vaultStd.totalAssets(), DEPOSIT + 35e18, 1e9);
    }

    function test_harvest_std_noYield() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);

        vm.prank(harvester);
        vaultStd.harvest();

        assertEq(eure.balanceOf(treasury), 0);
        assertEq(vaultStd.totalAssets(), DEPOSIT);
    }

    function test_harvest_std_loss() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        pool.simulateLoss(address(vaultStd), 100e18);

        vm.prank(harvester);
        vaultStd.harvest(); // must not revert, no treasury payment

        assertEq(eure.balanceOf(treasury), 0);
        assertEq(vaultStd.totalAssets(), DEPOSIT - 100e18);
    }

    function test_harvest_std_emitsEvent() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        _simulateYield(vaultStd, 40e18);

        vm.expectEmit(false, false, false, false);
        emit PaktolVault.Harvested(0, 0, 0, 0); // just check it emits

        vm.prank(harvester);
        vaultStd.harvest();
    }

    function test_harvest_std_belowFloor() public {
        // APY = 1.5% (below 2% floor) — fee is pro-rated down.
        // grossYield = 15 EURe
        // flooredFee = 15 × 50/200 = 3.75 EURe  < maxAumFee 5 EURe → takes 3.75
        // remaining  = 15 - 3.75 = 11.25 EURe
        // maxNetYield = 35 EURe → toUsers = 11.25, toTreasury = 3.75
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        _simulateYield(vaultStd, 15e18);

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 expectedFee = (15e18 * 50) / 200; // 3.75 EURe
        assertApproxEqAbs(eure.balanceOf(treasury), expectedFee, 1e9);
        assertApproxEqAbs(vaultStd.totalAssets(), DEPOSIT + 15e18 - expectedFee, 1e9);
    }

    function test_harvest_std_atFloor() public {
        // APY = 2% exactly — flooredFee == maxAumFee, seamless transition.
        // grossYield = 20 EURe
        // flooredFee = 20 × 50/200 = 5 EURe == maxAumFee → takes 5
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        _simulateYield(vaultStd, 20e18);

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 expectedFee = (DEPOSIT * 50) / 10_000; // 5 EURe — full AUM fee
        assertApproxEqAbs(eure.balanceOf(treasury), expectedFee, 1e9);
    }

    /* ─────────────────────── HARVEST — PAKTOL ───────────────────────── */

    function test_harvest_pkt_belowCap() public {
        // 40 EURe = 4% gross, cap = 5% → no treasury.
        _deposit(vaultPkt, user, DEPOSIT);
        _warp(365 days);
        _simulateYield(vaultPkt, 40e18);

        vm.prank(harvester);
        vaultPkt.harvest();

        assertEq(eure.balanceOf(treasury), 0);
        assertApproxEqAbs(vaultPkt.totalAssets(), DEPOSIT + 40e18, 1e9);
    }

    function test_harvest_pkt_atCap() public {
        // 50 EURe = 5% gross = exactly cap → no treasury.
        _deposit(vaultPkt, user, DEPOSIT);
        _warp(365 days);
        _simulateYield(vaultPkt, 50e18);

        vm.prank(harvester);
        vaultPkt.harvest();

        assertApproxEqAbs(eure.balanceOf(treasury), 0, 1e9);
        assertApproxEqAbs(vaultPkt.totalAssets(), DEPOSIT + 50e18, 1e9);
    }

    function test_harvest_pkt_aboveCap() public {
        // 70 EURe = 7% gross, cap = 5% → 20 EURe to treasury.
        _deposit(vaultPkt, user, DEPOSIT);
        _warp(365 days);
        _simulateYield(vaultPkt, 70e18);

        vm.prank(harvester);
        vaultPkt.harvest();

        assertApproxEqAbs(eure.balanceOf(treasury), 20e18, 1e9);
        assertApproxEqAbs(vaultPkt.totalAssets(), DEPOSIT + 50e18, 1e9);
    }

    /* ─────────────────────── HARVEST GUARDS ─────────────────────────── */

    function test_harvest_revert_unauthorized() public {
        vm.expectRevert(PaktolVault.NotHarvester.selector);
        vm.prank(user);
        vaultStd.harvest();
    }

    function test_harvest_owner_canHarvest() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        _simulateYield(vaultStd, 40e18);

        vm.prank(owner);
        vaultStd.harvest();

        assertGt(eure.balanceOf(treasury), 0);
    }

    function test_harvest_sameBlock_noAction() public {
        _deposit(vaultStd, user, DEPOSIT);
        _simulateYield(vaultStd, 40e18); // same block as deposit

        uint256 treasuryBefore = eure.balanceOf(treasury);

        vm.prank(harvester);
        vaultStd.harvest(); // elapsed == 0 → early return

        assertEq(eure.balanceOf(treasury), treasuryBefore);
    }

    function test_harvest_updatesTimestamp() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(7 days);

        uint256 before = vaultStd.lastHarvestTimestamp();

        vm.prank(harvester);
        vaultStd.harvest();

        assertGt(vaultStd.lastHarvestTimestamp(), before);
    }

    /* ─────────────────────── PAUSE / GUARDIAN ───────────────────────── */

    function test_pause_byGuardian() public {
        vm.prank(guardian);
        vaultStd.pause();
        assertTrue(vaultStd.paused());
    }

    function test_pause_byOwner() public {
        vm.prank(owner);
        vaultStd.pause();
        assertTrue(vaultStd.paused());
    }

    function test_pause_revert_unauthorized() public {
        vm.expectRevert(PaktolVault.NotGuardian.selector);
        vm.prank(user);
        vaultStd.pause();
    }

    function test_unpause_byOwner() public {
        vm.prank(guardian);
        vaultStd.pause();

        vm.prank(owner);
        vaultStd.unpause();

        assertFalse(vaultStd.paused());
    }

    function test_unpause_revert_guardian() public {
        vm.prank(guardian);
        vaultStd.pause();

        vm.expectRevert();
        vm.prank(guardian);
        vaultStd.unpause(); // guardian cannot unpause
    }

    /* ─────────────────────── ADMIN ──────────────────────────────────── */

    function test_setGuardian() public {
        address newGuardian = makeAddr("newGuardian");
        vm.prank(owner);
        vaultStd.setGuardian(newGuardian);
        assertEq(vaultStd.guardian(), newGuardian);
    }

    function test_setGuardian_revert_zeroAddress() public {
        vm.expectRevert(PaktolVault.ZeroAddress.selector);
        vm.prank(owner);
        vaultStd.setGuardian(address(0));
    }

    function test_setGuardian_revert_unauthorized() public {
        vm.expectRevert();
        vm.prank(user);
        vaultStd.setGuardian(makeAddr("x"));
    }

    function test_setHarvester() public {
        address newHarvester = makeAddr("newHarvester");
        vm.prank(owner);
        vaultStd.setHarvester(newHarvester);
        assertEq(vaultStd.harvester(), newHarvester);
    }

    function test_setHarvester_revert_zeroAddress() public {
        vm.expectRevert(PaktolVault.ZeroAddress.selector);
        vm.prank(owner);
        vaultStd.setHarvester(address(0));
    }

    function test_setHarvester_revert_unauthorized() public {
        vm.expectRevert();
        vm.prank(user);
        vaultStd.setHarvester(makeAddr("x"));
    }

    /* ─────────────────────── MAX TVL ────────────────────────────────── */

    function test_maxTvl_blocksDeposit() public {
        uint256 tvl = 500e18;
        PaktolVault capped = new PaktolVault(
            IERC20(address(eure)),
            "Capped",
            "cpkEUR",
            owner,
            treasury,
            CAP_STD,
            FEE_STD,
            guardian,
            harvester,
            address(pool),
            address(pool.aToken()),
            tvl
        );

        eure.mint(user, tvl);
        vm.startPrank(user);
        eure.approve(address(capped), tvl + 1e18);
        capped.deposit(tvl, user); // fills cap exactly

        vm.expectRevert(abi.encodeWithSelector(PaktolVault.TvlCapExceeded.selector, tvl, tvl));
        capped.deposit(1e18, user); // over cap
        vm.stopPrank();
    }

    function test_maxDeposit_returnsZero_whenPaused() public {
        vm.prank(guardian);
        vaultStd.pause();
        assertEq(vaultStd.maxDeposit(user), 0);
    }

    function test_maxDeposit_returnsRemaining_whenPartiallyFilled() public {
        uint256 tvl = 1_000e18;
        PaktolVault capped = new PaktolVault(
            IERC20(address(eure)),
            "Capped",
            "cpkEUR",
            owner,
            treasury,
            CAP_STD,
            FEE_STD,
            guardian,
            harvester,
            address(pool),
            address(pool.aToken()),
            tvl
        );
        eure.mint(user, 500e18);
        vm.startPrank(user);
        eure.approve(address(capped), 500e18);
        capped.deposit(500e18, user);
        vm.stopPrank();

        assertEq(capped.maxDeposit(user), 500e18);
    }

    /* ─────────────────────── MULTI-USER ─────────────────────────────── */

    function test_multiUser_equalShares() public {
        uint256 shares1 = _deposit(vaultStd, user, DEPOSIT);
        uint256 shares2 = _deposit(vaultStd, user2, DEPOSIT);

        assertEq(shares1, shares2);
    }

    function test_multiUser_proportionalYield() public {
        _deposit(vaultStd, user, DEPOSIT);
        _deposit(vaultStd, user2, DEPOSIT);

        _warp(365 days);
        _simulateYield(vaultStd, 70e18); // 3.5% for each user = 70 total

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 assets1 = vaultStd.convertToAssets(vaultStd.balanceOf(user));
        uint256 assets2 = vaultStd.convertToAssets(vaultStd.balanceOf(user2));

        // Both users receive equal yield (equal deposits, equal shares).
        assertApproxEqAbs(assets1, assets2, 1e9);

        // aumFee = (1000+1000) × 0.5% = 10 EURe
        // remaining = 70 - 10 = 60 EURe, maxNetYield = 2000 × 3.5% = 70 → toUsers = 60
        // per user = 30 EURe
        uint256 aumFee = (2 * DEPOSIT * FEE_STD) / 10_000;
        uint256 expectedNet = (70e18 - aumFee) / 2;
        assertApproxEqAbs(assets1, DEPOSIT + expectedNet, 1e9);
    }

    function test_multiUser_laterDepositor_noBackpay() public {
        // user1 deposits, yield accrues and is harvested, user2 deposits after.
        // user2 should NOT receive yield earned before their deposit.
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        _simulateYield(vaultStd, 35e18); // exactly 3.5%

        vm.prank(harvester);
        vaultStd.harvest();

        // aumFee = 1000 × 0.5% = 5 EURe, remaining = 35 - 5 = 30 EURe
        // maxNetYield = 1000 × 3.5% = 35 → toUsers = 30 EURe
        uint256 expectedNet = 35e18 - (DEPOSIT * FEE_STD) / 10_000;
        assertApproxEqAbs(vaultStd.convertToAssets(vaultStd.balanceOf(user)), DEPOSIT + expectedNet, 1e9);

        // user2 deposits at the new share price — only gets their deposit back.
        uint256 shares2 = _deposit(vaultStd, user2, DEPOSIT);
        assertApproxEqAbs(vaultStd.convertToAssets(shares2), DEPOSIT, 1e9);
    }

    /* ─────────────────────── FUZZ ───────────────────────────────────── */

    function testFuzz_deposit_withdraw_roundtrip(
        uint256 amount
    ) public {
        amount = bound(amount, vaultStd.MIN_DEPOSIT(), 1_000_000e18);
        eure.mint(user, amount);

        uint256 shares = _deposit(vaultStd, user, amount);
        assertApproxEqAbs(vaultStd.totalAssets(), amount, 1e9);

        vm.prank(user);
        vaultStd.redeem(shares, user, user);

        // User recovers their full deposit (within 1e9 rounding tolerance).
        assertApproxEqAbs(eure.balanceOf(user), USER_BALANCE + amount, 1e9);
    }

    function testFuzz_harvest_std_userNeverExceedsCap(
        uint256 yieldBps
    ) public {
        // Gross yield anywhere from 0% to 10% annually.
        yieldBps = bound(yieldBps, 0, 1_000);
        uint256 yieldAmount = (DEPOSIT * yieldBps) / 10_000;

        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        if (yieldAmount > 0) _simulateYield(vaultStd, yieldAmount);

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 userAssets = vaultStd.convertToAssets(vaultStd.balanceOf(user));
        uint256 maxUserAssets = DEPOSIT + (DEPOSIT * CAP_STD) / 10_000;
        assertLe(userAssets, maxUserAssets + 1e9); // 1e9 rounding tolerance
    }

    function testFuzz_harvest_pkt_userNeverExceedsCap(
        uint256 yieldBps
    ) public {
        yieldBps = bound(yieldBps, 0, 1_500);
        uint256 yieldAmount = (DEPOSIT * yieldBps) / 10_000;

        _deposit(vaultPkt, user, DEPOSIT);
        _warp(365 days);
        if (yieldAmount > 0) _simulateYield(vaultPkt, yieldAmount);

        vm.prank(harvester);
        vaultPkt.harvest();

        uint256 userAssets = vaultPkt.convertToAssets(vaultPkt.balanceOf(user));
        uint256 maxUserAssets = DEPOSIT + (DEPOSIT * CAP_PKT) / 10_000;
        assertLe(userAssets, maxUserAssets + 1e9);
    }

    /* ─────────────────────── MAX WITHDRAW / REDEEM ──────────────────── */

    function test_maxWithdraw_fullLiquidity() public {
        // AAVE aToken holds >= vault position → user can withdraw full position.
        _deposit(vaultStd, user, DEPOSIT);

        uint256 expected = vaultStd.convertToAssets(vaultStd.balanceOf(user));
        assertApproxEqAbs(vaultStd.maxWithdraw(user), expected, 1e9);
    }

    function test_maxWithdraw_limitedByAaveLiquidity() public {
        // Drain aToken's EURe backing to simulate shallow AAVE liquidity.
        _deposit(vaultStd, user, DEPOSIT);

        // Burn 900 EURe from aToken — only 100 EURe remains available.
        eure.burn(address(pool.aToken()), 900e18);

        assertEq(eure.balanceOf(address(pool.aToken())), 100e18);
        assertApproxEqAbs(vaultStd.maxWithdraw(user), 100e18, 1e9);
    }

    function test_maxWithdraw_zeroWhenNoPosition() public view {
        assertEq(vaultStd.maxWithdraw(user), 0);
    }

    function test_maxRedeem_limitedByAaveLiquidity() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);

        // Only 100 EURe left in aToken.
        eure.burn(address(pool.aToken()), 900e18);

        uint256 maxR = vaultStd.maxRedeem(user);
        // maxRedeem must be <= actual shares
        assertLe(maxR, shares);
        // Converting maxRedeem shares → assets should be ~100 EURe
        assertApproxEqAbs(vaultStd.convertToAssets(maxR), 100e18, 1e9);
    }

    function test_maxWithdraw_idleCountsTowardLiquidity() public {
        // Deposit, then simulate vault holding idle EURe (e.g. right after emergencyExit).
        _deposit(vaultStd, user, DEPOSIT);

        vm.prank(owner);
        vaultStd.emergencyExitAave(); // all funds now idle in vault

        // aToken balance is 0, but idle is 1000 — maxWithdraw should still return full position.
        uint256 expected = vaultStd.convertToAssets(vaultStd.balanceOf(user));
        assertApproxEqAbs(vaultStd.maxWithdraw(user), expected, 1e9);
    }

    /* ─────────────────────── EMERGENCY EXIT ─────────────────────────── */

    function test_emergencyExit_pullsAllFromAave() public {
        _deposit(vaultStd, user, DEPOSIT);

        // Pre-exit: all funds in AAVE.
        assertEq(IERC20(vaultStd.ATOKEN()).balanceOf(address(vaultStd)), DEPOSIT);
        assertEq(eure.balanceOf(address(vaultStd)), 0);

        vm.prank(owner);
        vaultStd.emergencyExitAave();

        // Post-exit: no aToken, full balance idle.
        assertEq(IERC20(vaultStd.ATOKEN()).balanceOf(address(vaultStd)), 0);
        assertEq(eure.balanceOf(address(vaultStd)), DEPOSIT);
    }

    function test_emergencyExit_usersCanWithdraw() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);

        vm.prank(guardian);
        vaultStd.pause();

        vm.prank(owner);
        vaultStd.emergencyExitAave();

        // Withdrawal from idle balance — must succeed even though vault is paused.
        uint256 balBefore = eure.balanceOf(user);
        vm.prank(user);
        vaultStd.redeem(shares, user, user);

        assertApproxEqAbs(eure.balanceOf(user), balBefore + DEPOSIT, 1e9);
    }

    function test_emergencyExit_emitsEvent() public {
        _deposit(vaultStd, user, DEPOSIT);

        vm.expectEmit(false, false, false, false);
        emit PaktolVault.EmergencyExitAave(0, 0);

        vm.prank(owner);
        vaultStd.emergencyExitAave();
    }

    function test_emergencyExit_noOp_whenNoAaveBalance() public {
        // No deposit — aToken balance is 0. Should not revert.
        vm.prank(owner);
        vaultStd.emergencyExitAave();
    }

    function test_emergencyExit_revert_unauthorized() public {
        _deposit(vaultStd, user, DEPOSIT);

        vm.expectRevert();
        vm.prank(user);
        vaultStd.emergencyExitAave();

        vm.expectRevert();
        vm.prank(guardian);
        vaultStd.emergencyExitAave();
    }

    /* ─────────────────────── depositWithPermit ──────────────────────── */

    uint256 constant PERMIT_USER_KEY = 0xA11CE;

    function _permitUser() internal view returns (address) {
        return vm.addr(PERMIT_USER_KEY);
    }

    /// @dev Builds and signs an EIP-2612 permit digest for EURe.
    function _signPermit(
        PaktolVault vault_,
        address owner_,
        uint256 ownerKey_,
        uint256 amount_,
        uint256 deadline_
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner_, address(vault_), amount_, eure.nonces(owner_), deadline_));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", eure.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(ownerKey_, digest);
    }

    function test_depositWithPermit_success() public {
        address permitUser = _permitUser();
        eure.mint(permitUser, DEPOSIT);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(vaultStd, permitUser, PERMIT_USER_KEY, DEPOSIT, deadline);

        vm.prank(permitUser);
        uint256 shares = vaultStd.depositWithPermit(DEPOSIT, permitUser, deadline, v, r, s);

        assertGt(shares, 0, "shares minted");
        assertEq(eure.balanceOf(permitUser), 0, "EURe spent");
        assertEq(eure.allowance(permitUser, address(vaultStd)), 0, "allowance consumed");
        assertApproxEqAbs(vaultStd.totalAssets(), DEPOSIT, 1e9, "totalAssets updated");
    }

    function test_depositWithPermit_expiredDeadline() public {
        address permitUser = _permitUser();
        eure.mint(permitUser, DEPOSIT);

        uint256 deadline = block.timestamp - 1; // already expired
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(vaultStd, permitUser, PERMIT_USER_KEY, DEPOSIT, deadline);

        vm.prank(permitUser);
        vm.expectRevert();
        vaultStd.depositWithPermit(DEPOSIT, permitUser, deadline, v, r, s);
    }

    function test_depositWithPermit_invalidSignature() public {
        address permitUser = _permitUser();
        eure.mint(permitUser, DEPOSIT);

        uint256 deadline = block.timestamp + 1 hours;
        // Sign with a different key — signature won't match permitUser's address
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(vaultStd, permitUser, 0xBAD, DEPOSIT, deadline);

        vm.prank(permitUser);
        vm.expectRevert();
        vaultStd.depositWithPermit(DEPOSIT, permitUser, deadline, v, r, s);
    }

    function test_depositWithPermit_tooSmall() public {
        address permitUser = _permitUser();
        uint256 tiny = vaultStd.MIN_DEPOSIT() - 1;
        eure.mint(permitUser, tiny);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(vaultStd, permitUser, PERMIT_USER_KEY, tiny, deadline);

        vm.prank(permitUser);
        vm.expectRevert(abi.encodeWithSelector(PaktolVault.DepositTooSmall.selector, tiny, vaultStd.MIN_DEPOSIT()));
        vaultStd.depositWithPermit(tiny, permitUser, deadline, v, r, s);
    }

    function test_depositWithPermit_blockedWhenPaused() public {
        address permitUser = _permitUser();
        eure.mint(permitUser, DEPOSIT);

        vm.prank(guardian);
        vaultStd.pause();

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(vaultStd, permitUser, PERMIT_USER_KEY, DEPOSIT, deadline);

        vm.prank(permitUser);
        vm.expectRevert();
        vaultStd.depositWithPermit(DEPOSIT, permitUser, deadline, v, r, s);
    }
}
