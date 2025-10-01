# Malda Protocol Invariants - Summary

## Overview

This document provides an summary of the critical invariants protected by Phylax assertions in the Malda lending protocol. Each invariant is enforced through runtime checks that prevent insolvency, price manipulation, and other security risks.

## Testing

There are happy path tests in place for each assertion function, checking that assertions are triggered and don't revert unexpectedly when it shouldn't.

For tests that should revert, we need to implement mocks that can manipulate state during transaction execution. This will be done in the next phase, once we agreed on the assertions for enforcement.

---

## 1. Oracle Price Integrity

**Invariant:** Oracle prices must be fresh, non-zero, and consistent between different price feeds within configured tolerance limits.

**Protection Mechanism:**

- **Price Sanity Checks** - Ensures oracle prices are never zero and feeds are not stale
- **Intra-Transaction Price Stability** - Detects sandwich attacks by monitoring price changes during transaction execution (≤5% deviation allowed)
- **Cross-Feed Deviation Monitoring** - Verifies API3 and eOracle feeds remain consistent within configured delta bounds
- **Multi-Token Support** - Properly validates both borrowed and collateral token prices during liquidations

**Implementation:** `OraclePriceAssertion.a.sol`

- `assertionBorrowPriceSanity()` / `assertionLiquidationPriceSanity()`
- `assertionBorrowPriceStability()` / `assertionLiquidationPriceStability()`
- `assertionCrossFeedDeviation()`

---

## 2. Account Liquidity Soundness

**Invariant:** Borrowers can only borrow when they have sufficient collateral, and liquidations can only occur when borrowers are underwater.

**Protection Mechanism:**

- **Borrow Gating** - Verifies borrowers have zero shortfall before allowing borrow operations
- **Liquidation Validation** - Ensures liquidations only occur when borrowers have positive shortfall (underwater)
- **Redeem Safety** - Prevents redeems that would cause accounts to become underwater
- **Seize Operation Checks** - Validates collateral seizure operations are part of legitimate liquidation flows
- **Mid-Transaction Monitoring** - Catches intra-transaction state changes that could violate liquidity requirements

**Implementation:** `AccountLiquidityAssertion.a.sol`

- `assertionBorrowLiquidity()`
- `assertionLiquidationLiquidity()`
- `assertionRedeemLiquidity()`
- `assertionSeizeLiquidity()`

---

## 3. Interest Accrual Monotonicity

**Invariant:** Interest rates and borrow balances can only increase over time and must never exceed configured maximum rates.

**Protection Mechanism:**

- **Monotonic Borrow Index** - Ensures borrow index never decreases when time advances
- **Borrow Balance Integrity** - Individual balances can only increase (via interest) or decrease (via repayment)
- **Rate Cap Enforcement** - Interest rates capped at 0.03% per block (~1000% APY) to prevent excessive accumulation
- **Total Borrows Consistency** - Protocol-wide borrows must reflect sum of individual borrows plus interest
- **Multi-Operation Coverage** - Validates monotonicity across borrows, liquidations, and redeems

**Implementation:** `InterestAccrualAssertion.a.sol`

- `assertionBorrowInterestMonotonicity()`
- `assertionLiquidationInterestMonotonicity()`
- `assertionRedeemInterestMonotonicity()`
- `assertionBorrowRateCap()`

---

## 4. Outflow Volume Limiting

**Invariant:** The total value of assets leaving the protocol within any time window cannot exceed the configured limit.

**Protection Mechanism:**

- **USD-Based Tracking** - Cumulative outflows tracked in USD terms using oracle prices
- **Per-Operation Validation** - Both borrows and redeems count toward the limit
- **Time Window Resets** - Atomic counter resets when configured window expires
- **Bypass Prevention** - Multiple small transactions cannot circumvent limits; all outflows accumulate
- **Accounting Verification** - Ensures tracked values match actual operation amounts (0.1% tolerance)

**Implementation:** `OutflowLimiterAssertion.a.sol`

- `assertionBorrowOutflowLimit()`
- `assertionRedeemOutflowLimit()`
- `assertionCumulativeOutflowTracking()`
- `assertionTimeWindowReset()`

**Note:** Currently only functional with mErc20Host (cross-chain markets). Standard mErc20Immutable markets return zero for cumulative outflow tracking.

**TODO:** Suggested improvement: iterate through all outflows from the operations resulting in outflow and compare against the cumulative outflow tracking to not rely on protocol calculations in case of bug

---

## 5. Rebalancer Access Control

**Invariant:** Rebalancing operations can only move assets between approved markets and bridges within configured size limits.

**Protection Mechanism:**

- **Bridge Allowlist** - Only pre-approved bridge contracts can be used
- **Destination Allowlist** - Only whitelisted destination chains can receive funds
- **Market Allowlist** - Only explicitly approved markets can be rebalancing sources
- **Transfer Size Limits** - Minimum and maximum size bounds prevent dust attacks and excessive single-transfer risk
- **Rate Limiting** - Cumulative transfer volume per destination/token pair capped within time windows
- **Role-Based Access** - Only addresses with REBALANCER_EOA role can initiate operations

**Implementation:** `RebalancerAssertion.a.sol`

- `assertionRebalancerAllowlist()`
- `assertionTransferSizeLimits()`
- `assertionRateLimiting()`
- `assertionRebalancerAuthorization()`

**Note:** Discovered a bug in the assertion logic, needs to be fixed.

---

## 6. Oracle Configuration Validity

**Invariant:** Oracle configuration changes must be valid and within reasonable bounds to prevent dangerous settings.

**Protection Mechanism:**

- **Feed Validation** - API3 and eOracle feed addresses must be non-zero
- **Staleness Bounds** - Price staleness periods capped at 7 days maximum
- **Delta Bounds** - Maximum price deviation between feeds capped at 10%
- **Decimals Validation** - Token decimals must be between 1 and 18
- **Per-Symbol Configuration** - Symbol-specific overrides validated with same rigor as global settings

**Implementation:** `OracleConfigAssertion.a.sol`

- `assertionConfigValidity()`
- `assertionStalenessValidity()`
- `assertionMaxDeltaValidity()`
- `assertionSymbolDeltaValidity()`

**Note:** Very basic checks, good for basic understanding of how assertions work. No need to enforce this.

---

## Defense in Depth Approach

These assertions provide **runtime invariant checking** that complements traditional security measures:

- **Continuous Monitoring** - Checks execute on every relevant transaction
- **Mid-Transaction Validation** - Catches state changes within call stacks
- **Price Manipulation Detection** - Identifies sandwich attacks and oracle manipulation attempts
- **Accounting Integrity** - Ensures protocol math remains sound across all operations
- **Configuration Safety** - Prevents dangerous parameter changes
