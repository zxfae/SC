# PaktolVault — Smart Contract Documentation

## Overview

`PaktolVault` is an ERC-4626 tokenized vault that routes EURe (Monerium Euro stablecoin) deposits into AAVE v3 on Gnosis Chain to generate yield. Users receive vault shares (`pkEUR`) representing their proportional ownership of the deposited capital plus accrued yield.

The vault exists in two configurations, deployed as **separate contract instances**:

| Plan | AUM Fee | Net Yield Cap | Target |
|------|---------|--------------|--------|
| Standard | 0.5% / year | 3.5% / year | Retail users (B2C) |
| Paktol Subscription | 0% | 5% / year | Premium subscribers |

---

## Architecture

```
User (EURe)
    │
    ▼
PaktolVault (ERC-4626)
    │  deposit() / mint()      → issues pkEUR shares
    │  withdraw() / redeem()   → burns pkEUR shares
    │  harvest()               → distributes yield
    │
    ├─► AAVE v3 Pool (Gnosis Chain)
    │       supply() / withdraw()
    │       aEURe rebases 1:1 + interest
    │
    └─► Treasury (fee + surplus above cap)
```

**No proxy pattern** — all parameters are immutable at deployment. See [Upgrade Strategy](#upgrade-strategy) for rationale.

---

## Setup

```bash
# Install Foundry
curl -L https://foundry.paradigm.sh | bash
foundryup

# Install dependencies
forge install

# Compile
forge build

# Run tests
forge test -vvv

# Run JavaScript scenario tests
npm install
npm test
```

---

## Roles

| Role | Address type | Capabilities |
|------|-------------|--------------|
| `owner` | Gnosis Safe (multisig) | `setGuardian`, `setHarvester`, `unpause`, `emergencyExitAave`, `transferOwnership` |
| `guardian` | Hot wallet or multisig | `pause` (emergency only — cannot move funds) |
| `harvester` | Keeper bot EOA | `harvest` |

---

## Fee & Yield Mechanics

### Harvest Formula

Called by the `harvester` bot (or owner) once per month. The formula distributes the gross yield generated since the last harvest:

```
grossYield  = totalAssets() − lastTotalAssets

maxAumFee   = lastTotalAssets × FEE_BPS × elapsed
              ─────────────────────────────────────
              BPS_DENOMINATOR × SECONDS_PER_YEAR

flooredFee  = grossYield × FEE_BPS / FLOOR_BPS     [activated when APY < 2%]

aumFee      = min(maxAumFee, flooredFee)            [never takes from principal]

remaining   = grossYield − aumFee
maxNetYield = lastTotalAssets × CAP_BPS × elapsed
              ─────────────────────────────────────
              BPS_DENOMINATOR × SECONDS_PER_YEAR

toUsers     = min(remaining, maxNetYield)           [capped at annual yield cap]
toTreasury  = grossYield − toUsers                  [fee + surplus above cap]
```

### Example — Standard Plan (AAVE APY = 4%, 30-day period)

```
Capital         = 100,000 EURe
Elapsed         = 30 days (2,592,000 seconds)
grossYield      ≈ 329 EURe  (4% APY pro-rated 30 days)

maxAumFee       = 100,000 × 50 × 2,592,000 / (10,000 × 31,536,000) = 41 EURe
flooredFee      = 329 × 50 / 200 = 82 EURe
aumFee          = min(41, 82) = 41 EURe

remaining       = 329 − 41 = 288 EURe
maxNetYield     = 100,000 × 350 × 2,592,000 / (10,000 × 31,536,000) = 288 EURe
toUsers         = min(288, 288) = 288 EURe     (AAVE 4% → user gets 3.5% net)
toTreasury      = 329 − 288 = 41 EURe
```

### Example — Standard Plan (AAVE APY = 1.5%, low-yield period)

```
grossYield      ≈ 123 EURe  (1.5% APY pro-rated 30 days)

maxAumFee       = 41 EURe   (same capital-based calculation)
flooredFee      = 123 × 50 / 200 = 30 EURe   [floor kicks in: APY < 2%]
aumFee          = min(41, 30) = 30 EURe       [user protected]

remaining       = 123 − 30 = 93 EURe
maxNetYield     = 288 EURe  (cap not reached)
toUsers         = min(93, 288) = 93 EURe      (user keeps most of yield)
toTreasury      = 30 EURe
```

### Example — Paktol Subscription Plan (AAVE APY = 6%, high-yield period)

```
FEE_BPS = 0, CAP_BPS = 500

grossYield      ≈ 493 EURe  (6% APY pro-rated 30 days)
aumFee          = 0 EURe    (no fee)
remaining       = 493 EURe
maxNetYield     = 100,000 × 500 × 2,592,000 / (10,000 × 31,536,000) = 411 EURe
toUsers         = min(493, 411) = 411 EURe    (capped at 5%)
toTreasury      = 493 − 411 = 82 EURe        (surplus above cap)
```

---

## Security Measures

### Inflation Attack Defense
- `_decimalsOffset() = 3`: virtual shares offset. An attacker needs 1000× more capital to execute a share-price inflation attack.
- `MIN_DEPOSIT = 1e9` (0.000000001 EURe): prevents 1-wei first-depositor bootstrapping combined with the decimal offset.
- Dead shares seeded at deployment: `deposit(MIN_DEPOSIT, address(0xdead))` executed atomically after deploy.

### Reentrancy
- `nonReentrant` on all state-changing functions: `deposit`, `mint`, `withdraw`, `redeem`, `harvest`, `emergencyExitAave`.
- EURe (Monerium) is a standard ERC-20 with no callbacks — reentrancy via token transfer is infeasible.
- CEI exception in `withdraw`/`redeem`: AAVE withdrawal must precede `super.withdraw()`. Safe: `nonReentrant` + EURe has no hooks.

### Ownership
- `Ownable2Step`: transfer requires explicit acceptance. Prevents accidental key-loss transfers.
- Production owner = Gnosis Safe multisig (2/3 or 3/5 signers).

### Pausability
- `pause()`: callable by owner OR guardian. Blocks new deposits and mints only.
- `unpause()`: owner only.
- **Withdrawals are always open, even when paused** — users can always exit.

### TVL Cap
- `MAX_TVL`: set at deployment. `0` = uncapped. Prevents concentration risk during early stages.
- `maxDeposit()` returns `0` when cap is reached (ERC-4626 compliant).

### AAVE Liquidity Awareness
- `maxWithdraw()` / `maxRedeem()` account for AAVE available liquidity, not just user position size.
- Prevents ERC-4626 standard queries from reverting when AAVE market liquidity is low.

---

## Emergency Procedures

### Scenario A: AAVE market frozen (deposits blocked, withdrawals still work)
1. `guardian` calls `pause()` — new vault deposits blocked
2. `owner` calls `emergencyExitAave()` — pulls all aEURe back as idle EURe
3. Users call `withdraw()` / `redeem()` — served from idle EURe, no AAVE interaction needed

### Scenario B: AAVE market fully paused (all interactions blocked)
- `emergencyExitAave()` will revert — AAVE paused markets block everything
- No on-chain remedy until AAVE governance unpauses the EURe market
- Mitigation: monitor AAVE governance; vault guardian should pause preemptively

### Scenario C: Suspected vault exploit
1. `guardian` calls `pause()` immediately (single EOA, fast response)
2. Multisig owner investigates via on-chain data
3. If principal safe → deploy new vault version, users migrate voluntarily
4. If principal at risk → `emergencyExitAave()` then open withdrawals

---

## Upgrade Strategy

**The vault does not use a proxy pattern. This is intentional.**

Rationale:
1. **User trust**: `FEE_BPS`, `CAP_BPS`, `TREASURY`, `AAVE_POOL` are immutables. Users can verify on-chain that the fee rules cannot be changed retroactively after they deposit.
2. **Reduced attack surface**: Upgradeability introduces storage collision risks, initialization vulnerabilities (`initialize()` front-running), and requires trusting the upgrade key indefinitely.
3. **Regulatory clarity**: An immutable contract has clearer legal standing under ACPR/AMF frameworks than an upgradeable one where the rules can change.
4. **Migration path**: If a new version is needed (bug fix, new AAVE version), a new vault is deployed. The Paktol backend migrates users transparently: users withdraw from V1 and deposit into V2 in a single UX flow. V1 is paused (no new deposits), existing users are never forced.

The only mutable state post-deployment: `guardian` address, `harvester` address, pause status.

---

## Deployment Checklist

```bash
# 1. Set environment variables
export GNOSIS_RPC_URL=https://rpc.gnosischain.com
export DEPLOYER_KEY=<ledger or private key>

# 2. Deploy contract
forge script script/deploy/DeployVault.s.sol \
  --rpc-url $GNOSIS_RPC_URL \
  --broadcast \
  --ledger \
  --sender <safe-address>

# 3. Seed dead shares atomically (included in deploy script)
#    eure.approve(vaultAddress, MIN_DEPOSIT)
#    vault.deposit(MIN_DEPOSIT, 0x000000000000000000000000000000000000dEaD)

# 4. Verify on Gnosisscan
forge verify-contract <address> PaktolVault \
  --chain gnosis \
  --etherscan-api-key $GNOSISSCAN_API_KEY

# 5. Transfer ownership to Gnosis Safe
#    vault.transferOwnership(safeAddress)
#    From Safe: vault.acceptOwnership()
```

---

## Contract Parameters (Mainnet)

| Parameter | Standard Vault | Paktol Vault |
|-----------|---------------|-------------|
| `asset` | EURe (Gnosis Chain) | EURe (Gnosis Chain) |
| `CAP_BPS` | 350 (3.5%) | 500 (5%) |
| `FEE_BPS` | 50 (0.5%) | 0 |
| `AAVE_POOL` | `0xb50201558B00496A145fE76f7424749556E326D8` | same |
| `FLOOR_BPS` | 200 (2%) constant | 200 (2%) constant |
| `MIN_DEPOSIT` | 1e9 constant | 1e9 constant |
| `MAX_TVL` | TBD at launch | TBD at launch |

---

## Events

| Event | Emitted when | Key fields |
|-------|-------------|------------|
| `Harvested` | `harvest()` distributes yield | `grossYield`, `toTreasury`, `toUsers`, `timestamp` |
| `GuardianChanged` | `setGuardian()` called | `oldGuardian`, `newGuardian` |
| `HarvesterChanged` | `setHarvester()` called | `oldHarvester`, `newHarvester` |
| `EmergencyExitAave` | Emergency exit executed | `amount`, `timestamp` |
| `Deposit` (ERC-4626) | User deposits | `sender`, `owner`, `assets`, `shares` |
| `Withdraw` (ERC-4626) | User withdraws | `sender`, `receiver`, `owner`, `assets`, `shares` |

---

## Project Structure

```
contracts/
├── src/
│   ├── PaktolVault.sol          # Main vault contract
│   ├── interfaces/
│   │   └── IAavePool.sol        # AAVE v3 pool interface
│   └── mocks/
│       └── MockEURe.sol         # EURe mock for testing
├── test/
│   ├── PaktolVault.t.sol        # Foundry unit tests
│   ├── PaktolVault.fork.t.sol   # Foundry fork tests (Gnosis mainnet)
│   ├── PaktolVault.scenarios.js # JavaScript business scenario tests
│   └── mocks/
│       └── MockAavePool.sol     # AAVE mock for unit tests
├── script/
│   └── deploy/
│       └── DeployVault.s.sol    # Deployment script
├── lib/
│   └── openzeppelin-contracts/  # OpenZeppelin v5
└── foundry.toml
```

---

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `@openzeppelin/contracts` | 5.x | ERC-4626, ERC-20, Ownable2Step, Pausable, ReentrancyGuard |
| `forge-std` | latest | Foundry testing framework |
| `hardhat` | 2.x | JavaScript test runner |
| `ethers` | 6.x | Ethereum JS library |
| `@nomicfoundation/hardhat-toolbox` | 4.x | Hardhat plugins |
