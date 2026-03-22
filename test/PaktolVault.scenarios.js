/**
 * PaktolVault — Business Scenario Tests (JavaScript / Hardhat)
 *
 * These tests simulate end-to-end business flows from the perspective of
 * Paktol users, ambassadors, and operators.
 *
 * Run:
 *   npm install
 *   npm test
 */

import { expect } from "chai";
import hre from "hardhat";
const { ethers } = hre;
import { time } from "@nomicfoundation/hardhat-network-helpers";

// ─────────────────────── CONSTANTS ───────────────────────────────────────────

const BPS_DENOMINATOR = 10_000n;
const SECONDS_PER_YEAR = 365n * 24n * 3600n;
const FLOOR_BPS = 200n;
const MIN_DEPOSIT = 1_000_000_000n; // 1e9

const CAP_STD = 350n;  // 3.5%
const FEE_STD = 50n;   // 0.5%
const CAP_PKT = 500n;  // 5.0%
const FEE_PKT = 0n;    // no fee

const ONE_EURE       = ethers.parseEther("1");
const THOUSAND_EURE  = ethers.parseEther("1000");
const HUNDRED_K_EURE = ethers.parseEther("100000");

const THIRTY_DAYS = 30 * 24 * 3600;

// ─────────────────────── HELPERS ─────────────────────────────────────────────

/**
 * Simulate AAVE yield on a given vault:
 *   1. Mint EURe to aToken (funds future withdrawals)
 *   2. Mint aTokens to vault (increases vault's totalAssets)
 */
async function simulateYield(eure, pool, aToken, vault, amount) {
  await eure.mint(await aToken.getAddress(), amount);
  await pool.simulateYield(await vault.getAddress(), amount);
}

/**
 * Off-chain replication of the harvest formula (mirrors PaktolVault.sol exactly).
 */
function calculateHarvest(lastTotalAssets, grossYield, elapsed, feeBps, capBps) {
  const maxAumFee  = (lastTotalAssets * feeBps * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
  const flooredFee = (grossYield * feeBps) / FLOOR_BPS;
  const aumFee     = maxAumFee < flooredFee ? maxAumFee : flooredFee;
  const remaining  = grossYield - aumFee;
  const maxNetYield = (lastTotalAssets * capBps * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
  const toUsers    = remaining < maxNetYield ? remaining : maxNetYield;
  const toTreasury = grossYield - toUsers;
  return { aumFee, toUsers, toTreasury, maxNetYield };
}

// ─────────────────────── FIXTURE ─────────────────────────────────────────────

async function deployFixture() {
  const [deployer, owner, treasury, guardian, harvester, alice, bob, charlie, attacker] =
    await ethers.getSigners();

  const MockEURe = await ethers.getContractFactory("MockEURe");
  const eure = await MockEURe.deploy();

  const MockAavePool = await ethers.getContractFactory("MockAavePool");
  const pool = await MockAavePool.deploy(await eure.getAddress());
  const aToken = await ethers.getContractAt("MockAToken", await pool.aToken());

  const PaktolVault = await ethers.getContractFactory("PaktolVault");

  const vaultStd = await PaktolVault.deploy(
    await eure.getAddress(), "Paktol Standard", "pkEUR-S",
    owner.address, treasury.address,
    CAP_STD, FEE_STD,
    guardian.address, harvester.address,
    await pool.getAddress(), await aToken.getAddress(),
    0n
  );

  const vaultPkt = await PaktolVault.deploy(
    await eure.getAddress(), "Paktol Subscription", "pkEUR-P",
    owner.address, treasury.address,
    CAP_PKT, FEE_PKT,
    guardian.address, harvester.address,
    await pool.getAddress(), await aToken.getAddress(),
    0n
  );

  for (const user of [alice, bob, charlie, attacker]) {
    await eure.mint(user.address, HUNDRED_K_EURE);
  }

  return {
    eure, pool, aToken, vaultStd, vaultPkt,
    deployer, owner, treasury, guardian, harvester,
    alice, bob, charlie, attacker,
  };
}

// ─────────────────────── TEST SUITES ─────────────────────────────────────────

describe("PaktolVault — Business Scenarios", function () {

  // ═══════════════════════════════════════════════════════════════════════════
  // SCENARIO 1: First user deposit
  // ═══════════════════════════════════════════════════════════════════════════

  describe("Scenario 1: First user deposit", function () {
    it("User deposits 1,000 EURe — receives shares, EURe routed to AAVE", async function () {
      const { eure, vaultStd, alice } = await deployFixture();

      await eure.connect(alice).approve(await vaultStd.getAddress(), THOUSAND_EURE);
      await vaultStd.connect(alice).deposit(THOUSAND_EURE, alice.address);

      expect(await vaultStd.balanceOf(alice.address)).to.be.gt(0n);

      // All EURe forwarded to AAVE — vault holds 0 idle
      expect(await eure.balanceOf(await vaultStd.getAddress())).to.equal(0n);

      // totalAssets and lastTotalAssets reflect the deposit
      const total = await vaultStd.totalAssets();
      expect(total).to.be.gte(THOUSAND_EURE);
      expect(await vaultStd.lastTotalAssets()).to.equal(total);
    });

    it("Deposit below MIN_DEPOSIT (1e9 wei) is rejected", async function () {
      const { eure, vaultStd, alice } = await deployFixture();
      const tooSmall = MIN_DEPOSIT - 1n;

      await eure.connect(alice).approve(await vaultStd.getAddress(), tooSmall);
      await expect(
        vaultStd.connect(alice).deposit(tooSmall, alice.address)
      ).to.be.revertedWithCustomError(vaultStd, "DepositTooSmall");
    });

    it("Deposit is blocked when vault is paused", async function () {
      const { eure, vaultStd, guardian, alice } = await deployFixture();

      await vaultStd.connect(guardian).pause();
      await eure.connect(alice).approve(await vaultStd.getAddress(), THOUSAND_EURE);

      await expect(
        vaultStd.connect(alice).deposit(THOUSAND_EURE, alice.address)
      ).to.be.revertedWithCustomError(vaultStd, "EnforcedPause");
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // SCENARIO 2: User withdrawal
  // ═══════════════════════════════════════════════════════════════════════════

  describe("Scenario 2: User withdrawal", function () {
    it("User receives at least their initial deposit back after 30 days", async function () {
      const { eure, vaultStd, alice } = await deployFixture();

      await eure.connect(alice).approve(await vaultStd.getAddress(), THOUSAND_EURE);
      await vaultStd.connect(alice).deposit(THOUSAND_EURE, alice.address);

      const balanceBefore = await eure.balanceOf(alice.address);

      await time.increase(THIRTY_DAYS);

      const shares = await vaultStd.balanceOf(alice.address);
      await vaultStd.connect(alice).redeem(shares, alice.address, alice.address);

      const balanceAfter = await eure.balanceOf(alice.address);
      expect(balanceAfter - balanceBefore).to.be.gte(THOUSAND_EURE);
    });

    it("Withdrawal always works even when vault is paused", async function () {
      const { eure, vaultStd, guardian, alice } = await deployFixture();

      await eure.connect(alice).approve(await vaultStd.getAddress(), THOUSAND_EURE);
      await vaultStd.connect(alice).deposit(THOUSAND_EURE, alice.address);

      await vaultStd.connect(guardian).pause();

      const shares = await vaultStd.balanceOf(alice.address);
      await expect(
        vaultStd.connect(alice).redeem(shares, alice.address, alice.address)
      ).to.not.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // SCENARIO 3: Monthly harvest — Standard plan (AAVE APY = 4%)
  // ═══════════════════════════════════════════════════════════════════════════

  describe("Scenario 3: Monthly harvest — Standard plan (AAVE 4%)", function () {
    it("Harvest splits yield correctly: fee + surplus to treasury, capped net stays in vault", async function () {
      const { eure, pool, aToken, vaultStd, harvester, treasury, alice } = await deployFixture();

      await eure.connect(alice).approve(await vaultStd.getAddress(), HUNDRED_K_EURE);
      await vaultStd.connect(alice).deposit(HUNDRED_K_EURE, alice.address);

      const lastTotalAssets = await vaultStd.lastTotalAssets();

      await time.increase(THIRTY_DAYS);
      const elapsed = BigInt(THIRTY_DAYS);

      // Simulate 4% APY for 30 days on 100k EURe ≈ 329 EURe
      const grossYield = (HUNDRED_K_EURE * 400n * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
      await simulateYield(eure, pool, aToken, vaultStd, grossYield);

      const treasuryBefore = await eure.balanceOf(treasury.address);
      const tx = await vaultStd.connect(harvester).harvest();
      const receipt = await tx.wait();
      const toTreasuryActual = (await eure.balanceOf(treasury.address)) - treasuryBefore;

      const expected = calculateHarvest(lastTotalAssets, grossYield, elapsed, FEE_STD, CAP_STD);

      // Tolerance: 0.01 EURe — accounts for block timestamp drift between
      // time.increase() and the actual harvest block
      const TOLERANCE = ethers.parseEther("0.01");
      expect(toTreasuryActual).to.be.closeTo(expected.toTreasury, TOLERANCE);

      // Harvested event emitted with correct fields
      const harvestEvent = receipt.logs.find(log => log.fragment?.name === "Harvested");
      expect(harvestEvent).to.not.be.undefined;
      expect(harvestEvent.args.toTreasury).to.be.closeTo(expected.toTreasury, TOLERANCE);
      expect(harvestEvent.args.toUsers).to.be.closeTo(expected.toUsers, TOLERANCE);
    });

    it("Only harvester or owner can call harvest", async function () {
      const { vaultStd, alice } = await deployFixture();

      await expect(
        vaultStd.connect(alice).harvest()
      ).to.be.revertedWithCustomError(vaultStd, "NotHarvester");
    });

    it("Harvest with zero yield resets snapshot without sending to treasury", async function () {
      const { vaultStd, harvester, treasury, eure, alice } = await deployFixture();

      await eure.connect(alice).approve(await vaultStd.getAddress(), THOUSAND_EURE);
      await vaultStd.connect(alice).deposit(THOUSAND_EURE, alice.address);

      await time.increase(THIRTY_DAYS);

      const treasuryBefore = await eure.balanceOf(treasury.address);
      await vaultStd.connect(harvester).harvest();
      const treasuryAfter = await eure.balanceOf(treasury.address);

      expect(treasuryAfter).to.equal(treasuryBefore);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // SCENARIO 4: Fee floor protection (AAVE APY < 2%)
  // ═══════════════════════════════════════════════════════════════════════════

  describe("Scenario 4: Fee floor — low yield period (AAVE 1.5%)", function () {
    it("AUM fee is reduced proportionally when AAVE APY falls below the 2% floor", async function () {
      const { eure, pool, aToken, vaultStd, harvester, treasury, alice } = await deployFixture();

      await eure.connect(alice).approve(await vaultStd.getAddress(), HUNDRED_K_EURE);
      await vaultStd.connect(alice).deposit(HUNDRED_K_EURE, alice.address);

      const lastTotalAssets = await vaultStd.lastTotalAssets();

      await time.increase(THIRTY_DAYS);
      const elapsed = BigInt(THIRTY_DAYS);

      // 1.5% APY — below the 2% floor
      const grossYield = (HUNDRED_K_EURE * 150n * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
      await simulateYield(eure, pool, aToken, vaultStd, grossYield);

      const treasuryBefore = await eure.balanceOf(treasury.address);
      await vaultStd.connect(harvester).harvest();
      const toTreasuryActual = (await eure.balanceOf(treasury.address)) - treasuryBefore;

      const expected = calculateHarvest(lastTotalAssets, grossYield, elapsed, FEE_STD, CAP_STD);

      expect(toTreasuryActual).to.be.closeTo(expected.toTreasury, 100n);

      // Floor fee must be less than the uncapped AUM fee
      const fullAumFee = (HUNDRED_K_EURE * FEE_STD * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
      expect(expected.aumFee).to.be.lt(fullAumFee);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // SCENARIO 5: Paktol subscription — no fee, 5% cap
  // ═══════════════════════════════════════════════════════════════════════════

  describe("Scenario 5: Paktol subscription plan (AAVE 6%)", function () {
    it("No fee deducted, net yield capped at 5%, surplus goes to treasury", async function () {
      const { eure, pool, aToken, vaultPkt, harvester, treasury, alice } = await deployFixture();

      await eure.connect(alice).approve(await vaultPkt.getAddress(), HUNDRED_K_EURE);
      await vaultPkt.connect(alice).deposit(HUNDRED_K_EURE, alice.address);

      const lastTotalAssets = await vaultPkt.lastTotalAssets();

      await time.increase(THIRTY_DAYS);
      const elapsed = BigInt(THIRTY_DAYS);

      // 6% APY — above the 5% cap
      const grossYield = (HUNDRED_K_EURE * 600n * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
      await simulateYield(eure, pool, aToken, vaultPkt, grossYield);

      const treasuryBefore = await eure.balanceOf(treasury.address);
      await vaultPkt.connect(harvester).harvest();
      const toTreasuryActual = (await eure.balanceOf(treasury.address)) - treasuryBefore;

      const expected = calculateHarvest(lastTotalAssets, grossYield, elapsed, FEE_PKT, CAP_PKT);

      // No fee at all
      expect(expected.aumFee).to.equal(0n);

      // Treasury only receives surplus above 5% cap
      const TOLERANCE = ethers.parseEther("0.01");
      expect(toTreasuryActual).to.be.closeTo(expected.toTreasury, TOLERANCE);
      expect(toTreasuryActual).to.be.gt(0n);
    });

    it("Paktol plan user gets more net yield than Standard plan at same AAVE APY", async function () {
      const { eure, pool, aToken, vaultStd, vaultPkt, harvester, alice, bob } = await deployFixture();

      // Alice → Standard, Bob → Paktol — same amount
      await eure.connect(alice).approve(await vaultStd.getAddress(), HUNDRED_K_EURE);
      await vaultStd.connect(alice).deposit(HUNDRED_K_EURE, alice.address);

      await eure.connect(bob).approve(await vaultPkt.getAddress(), HUNDRED_K_EURE);
      await vaultPkt.connect(bob).deposit(HUNDRED_K_EURE, bob.address);

      await time.increase(THIRTY_DAYS);
      const elapsed = BigInt(THIRTY_DAYS);

      const grossYield = (HUNDRED_K_EURE * 400n * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
      await simulateYield(eure, pool, aToken, vaultStd, grossYield);
      await simulateYield(eure, pool, aToken, vaultPkt, grossYield);

      await vaultStd.connect(harvester).harvest();
      await vaultPkt.connect(harvester).harvest();

      const aliceAssets = await vaultStd.convertToAssets(await vaultStd.balanceOf(alice.address));
      const bobAssets   = await vaultPkt.convertToAssets(await vaultPkt.balanceOf(bob.address));

      // Paktol plan: no fee → Bob keeps more
      expect(bobAssets).to.be.gte(aliceAssets);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // SCENARIO 6: Multi-user proportional yield
  // ═══════════════════════════════════════════════════════════════════════════

  describe("Scenario 6: Multi-user proportional yield", function () {
    it("Two equal depositors receive equal yield after harvest", async function () {
      const { eure, pool, aToken, vaultStd, harvester, alice, bob } = await deployFixture();

      for (const user of [alice, bob]) {
        await eure.connect(user).approve(await vaultStd.getAddress(), THOUSAND_EURE);
        await vaultStd.connect(user).deposit(THOUSAND_EURE, user.address);
      }

      await time.increase(THIRTY_DAYS);
      const elapsed = BigInt(THIRTY_DAYS);

      const grossYield = (2n * THOUSAND_EURE * 400n * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
      await simulateYield(eure, pool, aToken, vaultStd, grossYield);
      await vaultStd.connect(harvester).harvest();

      const aliceAssets = await vaultStd.convertToAssets(await vaultStd.balanceOf(alice.address));
      const bobAssets   = await vaultStd.convertToAssets(await vaultStd.balanceOf(bob.address));

      expect(aliceAssets).to.be.closeTo(bobAssets, 1n);
    });

    it("User with 2× deposit receives 2× the yield", async function () {
      const { eure, pool, aToken, vaultStd, harvester, alice, bob } = await deployFixture();

      const aliceDeposit = THOUSAND_EURE;
      const bobDeposit   = 2n * THOUSAND_EURE;

      await eure.connect(alice).approve(await vaultStd.getAddress(), aliceDeposit);
      await vaultStd.connect(alice).deposit(aliceDeposit, alice.address);

      await eure.connect(bob).approve(await vaultStd.getAddress(), bobDeposit);
      await vaultStd.connect(bob).deposit(bobDeposit, bob.address);

      await time.increase(THIRTY_DAYS);
      const elapsed = BigInt(THIRTY_DAYS);

      const grossYield = ((aliceDeposit + bobDeposit) * 400n * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
      await simulateYield(eure, pool, aToken, vaultStd, grossYield);
      await vaultStd.connect(harvester).harvest();

      const aliceAssets = await vaultStd.convertToAssets(await vaultStd.balanceOf(alice.address));
      const bobAssets   = await vaultStd.convertToAssets(await vaultStd.balanceOf(bob.address));

      // Bob has ~2× Alice's assets (within 0.1%)
      const ratio = (bobAssets * 1000n) / aliceAssets;
      expect(ratio).to.be.closeTo(2000n, 10n);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // SCENARIO 7: TVL Cap
  // ═══════════════════════════════════════════════════════════════════════════

  describe("Scenario 7: TVL Cap enforcement", function () {
    it("Deposits are rejected when TVL cap is reached", async function () {
      const { eure, pool, aToken, owner, treasury, guardian, harvester, alice, bob } = await deployFixture();

      const TVL_CAP = THOUSAND_EURE;
      const PaktolVault = await ethers.getContractFactory("PaktolVault");
      const cappedVault = await PaktolVault.deploy(
        await eure.getAddress(), "Capped", "pkC",
        owner.address, treasury.address,
        CAP_STD, FEE_STD,
        guardian.address, harvester.address,
        await pool.getAddress(), await aToken.getAddress(),
        TVL_CAP
      );

      // Alice fills the cap exactly
      await eure.connect(alice).approve(await cappedVault.getAddress(), THOUSAND_EURE);
      await cappedVault.connect(alice).deposit(THOUSAND_EURE, alice.address);

      // Bob's deposit must revert
      await eure.connect(bob).approve(await cappedVault.getAddress(), ONE_EURE);
      await expect(
        cappedVault.connect(bob).deposit(ONE_EURE, bob.address)
      ).to.be.revertedWithCustomError(cappedVault, "TvlCapExceeded");
    });

    it("maxDeposit() returns 0 when cap is reached", async function () {
      const { eure, pool, aToken, owner, treasury, guardian, harvester, alice } = await deployFixture();

      const TVL_CAP = THOUSAND_EURE;
      const PaktolVault = await ethers.getContractFactory("PaktolVault");
      const cappedVault = await PaktolVault.deploy(
        await eure.getAddress(), "Capped", "pkC",
        owner.address, treasury.address,
        CAP_STD, FEE_STD,
        guardian.address, harvester.address,
        await pool.getAddress(), await aToken.getAddress(),
        TVL_CAP
      );

      await eure.connect(alice).approve(await cappedVault.getAddress(), THOUSAND_EURE);
      await cappedVault.connect(alice).deposit(THOUSAND_EURE, alice.address);

      expect(await cappedVault.maxDeposit(alice.address)).to.equal(0n);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // SCENARIO 8: Emergency exit from AAVE
  // ═══════════════════════════════════════════════════════════════════════════

  describe("Scenario 8: Emergency exit from AAVE", function () {
    it("Owner pulls all funds from AAVE — users can then withdraw from idle balance", async function () {
      const { eure, vaultStd, owner, guardian, alice } = await deployFixture();

      await eure.connect(alice).approve(await vaultStd.getAddress(), THOUSAND_EURE);
      await vaultStd.connect(alice).deposit(THOUSAND_EURE, alice.address);

      // Step 1: guardian pauses
      await vaultStd.connect(guardian).pause();

      // Step 2: owner executes emergency exit
      await vaultStd.connect(owner).emergencyExitAave();

      // Vault now holds idle EURe
      const idleEure = await eure.balanceOf(await vaultStd.getAddress());
      expect(idleEure).to.be.gte(THOUSAND_EURE);

      // Step 3: Alice withdraws from idle balance (no AAVE interaction needed)
      const shares = await vaultStd.balanceOf(alice.address);
      await expect(
        vaultStd.connect(alice).redeem(shares, alice.address, alice.address)
      ).to.not.be.reverted;
    });

    it("EmergencyExitAave event emitted on exit", async function () {
      const { eure, vaultStd, owner, alice } = await deployFixture();

      await eure.connect(alice).approve(await vaultStd.getAddress(), THOUSAND_EURE);
      await vaultStd.connect(alice).deposit(THOUSAND_EURE, alice.address);

      await expect(vaultStd.connect(owner).emergencyExitAave())
        .to.emit(vaultStd, "EmergencyExitAave");
    });

    it("Only owner can call emergencyExitAave — guardian and users cannot", async function () {
      const { vaultStd, guardian, alice } = await deployFixture();

      await expect(
        vaultStd.connect(alice).emergencyExitAave()
      ).to.be.revertedWithCustomError(vaultStd, "OwnableUnauthorizedAccount");

      await expect(
        vaultStd.connect(guardian).emergencyExitAave()
      ).to.be.revertedWithCustomError(vaultStd, "OwnableUnauthorizedAccount");
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // SCENARIO 9: Guardian pause flow
  // ═══════════════════════════════════════════════════════════════════════════

  describe("Scenario 9: Guardian pause and owner unpause", function () {
    it("Guardian pauses, but only owner can unpause", async function () {
      const { vaultStd, guardian, owner } = await deployFixture();

      await vaultStd.connect(guardian).pause();
      expect(await vaultStd.paused()).to.be.true;

      await expect(
        vaultStd.connect(guardian).unpause()
      ).to.be.revertedWithCustomError(vaultStd, "OwnableUnauthorizedAccount");

      await vaultStd.connect(owner).unpause();
      expect(await vaultStd.paused()).to.be.false;
    });

    it("Random address cannot pause", async function () {
      const { vaultStd, attacker } = await deployFixture();

      await expect(
        vaultStd.connect(attacker).pause()
      ).to.be.revertedWithCustomError(vaultStd, "NotGuardian");
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // SCENARIO 10: Ownable2Step — safe ownership transfer
  // ═══════════════════════════════════════════════════════════════════════════

  describe("Scenario 10: Ownable2Step", function () {
    it("Ownership requires explicit acceptance from the new owner", async function () {
      const { vaultStd, owner, alice } = await deployFixture();

      await vaultStd.connect(owner).transferOwnership(alice.address);
      expect(await vaultStd.pendingOwner()).to.equal(alice.address);
      expect(await vaultStd.owner()).to.equal(owner.address); // not yet transferred

      await vaultStd.connect(alice).acceptOwnership();
      expect(await vaultStd.owner()).to.equal(alice.address);
    });

    it("Without acceptance, owner stays unchanged", async function () {
      const { vaultStd, owner, alice } = await deployFixture();

      await vaultStd.connect(owner).transferOwnership(alice.address);
      expect(await vaultStd.owner()).to.equal(owner.address);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // SCENARIO 11: Inflation attack resistance
  // ═══════════════════════════════════════════════════════════════════════════

  describe("Scenario 11: Inflation attack resistance", function () {
    it("Attacker donating EURe to vault cannot steal victim's deposit", async function () {
      const { eure, vaultStd, attacker, alice } = await deployFixture();

      // Attacker deposits minimum to get shares
      await eure.connect(attacker).approve(await vaultStd.getAddress(), MIN_DEPOSIT);
      await vaultStd.connect(attacker).deposit(MIN_DEPOSIT, attacker.address);

      // Attacker donates large amount directly to inflate share price
      const donation = ethers.parseEther("100");
      await eure.connect(attacker).transfer(await vaultStd.getAddress(), donation);

      // Alice deposits 1,000 EURe — should receive fair shares
      await eure.connect(alice).approve(await vaultStd.getAddress(), THOUSAND_EURE);
      await vaultStd.connect(alice).deposit(THOUSAND_EURE, alice.address);

      const aliceShares = await vaultStd.balanceOf(alice.address);
      const aliceAssets = await vaultStd.convertToAssets(aliceShares);

      // Alice must not lose more than 0.1% of her deposit
      const lossPercent = ((THOUSAND_EURE - aliceAssets) * 10000n) / THOUSAND_EURE;
      expect(lossPercent).to.be.lt(10n);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // SCENARIO 12: Full year — 12 monthly harvests
  // ═══════════════════════════════════════════════════════════════════════════

  describe("Scenario 12: Full year simulation — yield cap enforced over 12 months", function () {
    it("Standard plan: user net yield stays near 3.5% after 12 harvests at 4% AAVE", async function () {
      const { eure, pool, aToken, vaultStd, harvester, alice } = await deployFixture();

      const deposit = HUNDRED_K_EURE;
      await eure.connect(alice).approve(await vaultStd.getAddress(), deposit);
      await vaultStd.connect(alice).deposit(deposit, alice.address);

      for (let month = 0; month < 12; month++) {
        const lastTotal = await vaultStd.lastTotalAssets();

        await time.increase(THIRTY_DAYS);
        const elapsed = BigInt(THIRTY_DAYS);

        const grossYield = (lastTotal * 400n * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
        await simulateYield(eure, pool, aToken, vaultStd, grossYield);
        await vaultStd.connect(harvester).harvest();
      }

      const aliceAssets = await vaultStd.convertToAssets(await vaultStd.balanceOf(alice.address));
      const aliceYield  = aliceAssets - deposit;

      // Expected: ~3.5% of 100k = ~3,500 EURe (allow 1% tolerance)
      const expectedNetYield = (deposit * CAP_STD) / BPS_DENOMINATOR;
      const tolerance = expectedNetYield / 100n;
      expect(aliceYield).to.be.closeTo(expectedNetYield, tolerance);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // SCENARIO 13: depositWithPermit (EIP-2612 gasless deposit)
  // ═══════════════════════════════════════════════════════════════════════════

  describe("Scenario 13: depositWithPermit — gasless EIP-2612 deposit", function () {
    it("User deposits with a signed permit — no prior approve transaction needed", async function () {
      const { eure, vaultStd, alice } = await deployFixture();

      const amount   = THOUSAND_EURE;
      const deadline = (await time.latest()) + 3600;
      const nonce    = await eure.nonces(alice.address);
      const chainId  = (await ethers.provider.getNetwork()).chainId;

      const domain = {
        name: await eure.name(),
        version: "1",
        chainId,
        verifyingContract: await eure.getAddress(),
      };
      const types = {
        Permit: [
          { name: "owner",    type: "address" },
          { name: "spender",  type: "address" },
          { name: "value",    type: "uint256" },
          { name: "nonce",    type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      };
      const permitValue = {
        owner:    alice.address,
        spender:  await vaultStd.getAddress(),
        value:    amount,
        nonce,
        deadline,
      };

      const sig = await alice.signTypedData(domain, types, permitValue);
      const { v, r, s } = ethers.Signature.from(sig);

      await expect(
        vaultStd.connect(alice).depositWithPermit(amount, alice.address, deadline, v, r, s)
      ).to.not.be.reverted;

      expect(await vaultStd.balanceOf(alice.address)).to.be.gt(0n);
    });
  });
});
