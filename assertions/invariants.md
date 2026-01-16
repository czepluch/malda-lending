## Malda Lending – Critical Protocol Invariants (prioritized)

This focuses on the highest-impact invariants to protect with Credible Layer assertions, plus a note on zk-proof verification.

**Analysis of what's NOT directly checked in code:**

- **Oracle prices**: Code checks non-zero but NOT staleness or cross-feed delta consistency
- **Liquidity soundness**: Code checks individual operations but NOT consistency across a transaction
- **Exchange rate integrity**: Code computes rate but does NOT verify it matches accounting formula
- **Interest accrual**: Code enforces rate caps but does NOT verify monotonicity across operations
- **Outflow limits**: Code enforces per-call but does NOT verify cumulative tracking accuracy
- **Rebalancer limits**: Code enforces per-operation but does NOT verify cross-operation consistency

### Highest priority (P0)

- Oracle price sanity, freshness, and cross-feed delta
  - **Invariant**: Oracle prices must be fresh, non-zero, and consistent between different price feeds within configured tolerance limits.
  - Why: Price manipulation/staleness directly breaks liquidity checks, borrow limits, and liquidation correctness.
  - Assert: During `Operator.beforeMTokenBorrow` and `beforeMTokenLiquidate`, ensure `getUnderlyingPrice` is non-zero, not stale per per-symbol/global staleness, and delta between API3 and eOracle is within symbol/global limits; no intra-tx jump beyond configured bps.
  - Triggers: `Operator.beforeMTokenBorrow`, `Operator.beforeMTokenLiquidate`, `MixedPriceOracleV4.set*` config.

- Account liquidity soundness across a transaction
  - **Invariant**: Borrowers can only borrow when they have sufficient collateral, and liquidations can only occur when borrowers are underwater.
  - Why: Ensures borrowing never passes with shortfall and liquidation only occurs when shortfall > 0, under current prices/exchange rates.
  - Assert: Pre/post `_getHypotheticalAccountLiquidity` consistency with the attempted operation; borrowing requires zero shortfall; liquidation requires shortfall > 0; redeem cannot both proceed and keep account unsafe if it should restore safety.
  - Triggers: `Operator.beforeMTokenBorrow`, `beforeMTokenRedeem`, `beforeMTokenLiquidate`, `beforeMTokenSeize`.

- Exchange rate integrity vs accounting
  - **Invariant**: The exchange rate between mTokens and underlying assets must always reflect the true value of deposits and cannot be manipulated downward.
  - Why: Prevents silent drift in share accounting leading to unfair mints/redeems and reserve mis-accounting.
  - Assert: After `__mint/__redeem/__borrow/__repay/_addReserves/reduceReserves/_seize`, recompute `exchangeRate` from post-state storage equals `(cash + totalBorrows - totalReserves) / totalSupply` (allowing 1 wei tolerance). Detect unexpected decreases not explained by operation semantics.
  - Triggers: mToken internal ops listed above.

### High priority (P1)

- Interest accrual monotonicity and rate-cap adherence
  - **Invariant**: Interest rates and borrow balances can only increase over time and must never exceed configured maximum rates.
  - Why: Prevents under-accrual/overflow or model misconfig causing negative movements.
  - Assert: `borrowIndex` strictly increases; `totalBorrows`/`totalReserves` never decrease due only to accrual; rate never exceeds `borrowRateMaxMantissa`; deltas consistent with elapsed time bounds.
  - Triggers: `mToken.accrueInterest`, and functions that call it.

- Outflow volume limiter enforcement (USD-based)
  - **Invariant**: The total value of assets leaving the protocol within any time window cannot exceed the configured limit.
  - Why: Limits cross-chain/systemic drains via host/extension flows.
  - Assert: `checkOutflowVolumeLimit` recomputation matches stored cumulative volume in USD with proper window reset; hosts/gateways must call it for any outbound transfer-equivalent action.
  - Triggers: `Operator.checkOutflowVolumeLimit`, `mErc20Host.performExtensionCall`, `repayExternal`.

- Rebalancer allowlists and rate limits
  - **Invariant**: Rebalancing operations can only move assets between approved markets and bridges within configured size limits.
  - Why: Prevents unauthorized or oversized bridge transfers.
  - Assert: `Rebalancer.sendMsg` only for markets in `allowedList`, to whitelisted bridges/destinations; transfers observe min/max per `transferTimeWindow`; extracted amount equals bridged amount; rebalancing not paused on market.
  - Triggers: `Rebalancer.sendMsg`, `mErc20Host.extractForRebalancing`, `mTokenGateway.extractForRebalancing`.

### Medium priority (P2)

- Genesis mint seed correctness
  - Assert: First mint applies one-time seed; subsequent mints do not.
  - Triggers: first `__mint` per market.

- Collateral factor bounds and config consistency
  - Assert: Factor within [0, max]; changes don’t enable a borrow that would have failed in same tx context.
  - Triggers: collateral factor updates (if/where exposed), Operator config events.

### zk-proof verification invariant (explicit)

- Offchain-driven calls must be backed by valid proofs or authorized forwarders, and invoke outflow checks when value exits
  - Why: Prevents bypass of cross-chain safeguards and spoofed state transitions.
  - Scope functions:
    - Host: `mErc20Host.repayExternal`, `performExtensionCall` (withdraw/borrow); requires `_verifyProof(journalData, seal)` unless caller has `PROOF_BATCH_FORWARDER`/`PROOF_FORWARDER`. Must call `IOperatorDefender.checkOutflowVolumeLimit` with correct amount.
    - Gateway: `mTokenGateway.outHere`, `supplyOnHost`; proof path or authorized forwarder; gas fee rules; allowed chains.
  - Assert:
    - If caller lacks forwarder role, require that `_verifyProof` was executed and succeeded for each journal entry; validate `dstChainId`/`chainId`/`market` match, and L1 inclusion when required.
    - Confirm `checkOutflowVolumeLimit(amount)` called once with the precise amount(s) being sent/redeemed for outbound actions.
  - Triggers: The four functions above; also monitor role-changing functions to adjust assertion expectations.

## Malda Lending – Crucial Protocol Invariants (for Credible Layer assertions)

This document highlights cross-cutting safety properties that are not fully enforced by local require checks and are ideal targets for Credible Layer assertions. Each item suggests where to hook assertions using call/storage triggers per the assertions rules.

- **Oracle price sanity and freshness**
  - Invariant: For any market `mToken`, `IOracleOperator.getUnderlyingPrice(mToken)` must be non-zero, fresh, and within configured delta bounds across sources during a single transaction.
  - Rationale: `Operator._getHypotheticalAccountLiquidity` and borrow/liquidation paths rely on prices; local code checks non-zero but cannot detect stale/cross-feed divergence mid-tx.
  - Assertion hooks:
    - Trigger on `MixedPriceOracleV4.setConfig`, `setStaleness`, `setMaxPriceDelta`, `setSymbolMaxPriceDelta` to ensure future quotes remain valid.
    - Trigger on `Operator.beforeMTokenBorrow`/`beforeMTokenLiquidate` to fetch pre/post prices and verify: price not stale; API3 vs eOracle within per-symbol or global delta; no sudden intra-tx jump exceeding configured bps.

- **Exchange rate integrity vs accounting**
  - Invariant: `exchangeRate = (cash + totalBorrows - totalReserves) / totalSupply` must hold after state-changing operations; it must not decrease due to manipulation unrelated to accrued interest and normal flows.
  - Rationale: `_exchangeRateStored` computes from storage; mint/redeem/borrow/repay update `totalUnderlying`, `totalBorrows`, `totalReserves`, `totalSupply`. There’s a seed protection when `totalSupply==0`, but cross-function sequences could drift.
  - Assertion hooks:
    - Trigger on `mToken.__mint`, `__redeem`, `__borrow`, `__repay`, `_addReserves`, `reduceReserves`, `_seize`.
    - Compare pre/post computed exchange rate equality within 1 wei tolerance of formula using post-state values; flag negative drift not explained by the operation.

- **Interest accrual monotonicity**
  - Invariant: Calling any path that accrues interest must not decrease `totalBorrows`, `borrowIndex`, or `totalReserves`; `borrowIndex` increases monotonically; `totalReserves` increases when interest accrues (minus explicit `reduceReserves`).
  - Rationale: `_accrueInterest` updates `borrowIndex`, `totalBorrows`, `totalReserves` based on rate and elapsed time; invariants ensure no counter drift.
  - Assertion hooks:
    - Trigger on `mToken.accrueInterest`, and any external that calls `_accrueInterest` indirectly: `borrow*Current`, `exchangeRateCurrent`, `_mint/_redeem/_borrow/_repay/_liquidate`, `_addReserves`, `reduceReserves`.
    - Verify: `borrowIndex_post >= borrowIndex_pre`; `totalBorrows_post >= totalBorrows_pre` unless followed by `__repay` or exact borrow decrement; `totalReserves_post >= totalReserves_pre` except when `reduceReserves` executed.

- **Borrow/supply caps and market listing consistency**
  - Invariant: No borrow or mint occurs when `market.isListed == false` or when paused; caps are respected across tx even under re-entrancy or cross-chain extensions.
  - Rationale: Operator checks caps/pauses per call, but assertions can catch unexpected bypass or ordering issues.
  - Assertion hooks:
    - Trigger on `Operator.setMarketBorrowCaps`, `setMarketSupplyCaps`, `setPaused`, `supportMarket` and on `mToken.__mint/__borrow` and gateway/host entrypoints that mint/borrow (`mErc20Host.performExtensionCall`, `mTokenGateway.outHere`, `supplyOnHost`). Validate effects obey caps and pause states.

- **Account liquidity soundness across a transaction**
  - Invariant: For any borrower, health factor cannot move from safe to unsafe without a qualifying state change consistent with the executed call(s). Conversely, `beforeMTokenLiquidate` requires shortfall > 0; assertions ensure prices/exchange rates used are consistent intra-tx.
  - Rationale: Liquidity uses prices, exchange rates, collateral factors, and balances.
  - Assertion hooks:
    - Trigger on `Operator.beforeMTokenBorrow`, `beforeMTokenRedeem`, `beforeMTokenLiquidate`, `beforeMTokenSeize`.
    - Compare `(_getHypotheticalAccountLiquidity)` pre/post; ensure redemption doesn’t make shortfall zero during liquidation, and borrowing never passes with `shortfall>0`.

- **Protocol reserves conservation on liquidation**
  - Invariant: On liquidation, protocol seize share added to reserves equals `exchangeRate * protocolSeizeTokens`; total reserves must increase accordingly and never decrease.
  - Rationale: `_seize` computes and adds `protocolSeizeAmount`.
  - Assertion hooks:
    - Trigger on `mToken._seize` and `__liquidate`; verify `totalReserves_post == totalReserves_pre + protocolSeizeAmount`.

- **Outflow volume limiter enforcement (USD-based)**
  - Invariant: Cumulative USD outflows within `outflowResetTimeWindow` across listed markets must not exceed `limitPerTimePeriod`.
  - Rationale: `Operator.checkOutflowVolumeLimit` mutates cumulative volume; used by `mErc20Host` for external repay/extension flows.
  - Assertion hooks:
    - Trigger on `Operator.checkOutflowVolumeLimit` to recompute the same USD conversion and verify cumulative result; ensure reset after window and no bypass by missing calls from hosts/gateways when funds leave the protocol.

- **Rebalancer rate-limits and allowlists**
  - Invariant: Rebalancing transfers only occur for markets on `allowedList`, to whitelisted bridges/destinations, within configured min/max per `transferTimeWindow`.
  - Rationale: `Rebalancer.sendMsg` enforces checks; `mErc20Host.extractForRebalancing` and `mTokenGateway.extractForRebalancing` must be gated and not paused.
  - Assertion hooks:
    - Trigger on `Rebalancer.sendMsg`: verify `allowedList[market]`, `whitelistedBridges[bridge]`, `whitelistedDestinations[dst]`, `size` aggregation within window, and the extracted amount matches send amount.
    - Trigger on `mErc20Host.extractForRebalancing` and `mTokenGateway.extractForRebalancing`: ensure `beforeRebalancing` not paused and caller has correct role.

- **Cross-chain proof integrity for host/gateway**
  - Invariant: For offchain-driven actions (repayExternal, outHere, performExtensionCall), the proof verification or allowlisted forwarder must be used, and outflow checks must run.
  - Rationale: Functions allow bypass when caller has forwarder roles; assertions can require either a permitted role or a successful proof path.
  - Assertion hooks:
    - Trigger on `mErc20Host.repayExternal`, `performExtensionCall`; `mTokenGateway.outHere`, `supplyOnHost`: verify gas fee conditions, allowed chains, and that `checkOutflowVolumeLimit` was invoked with the correct amount.

- **No mint inflation at genesis beyond guarded seed**
  - Invariant: When `totalSupply==0`, first mint must apply the 1000-token seed offset; subsequent exchange rate must reflect deposited underlying fairly.
  - Rationale: Code seeds supply to prevent rate manipulation; assertion ensures seed path is used exactly once and then disabled.
  - Assertion hooks:
    - Trigger on first `__mint` per-market: verify seed creation and that later mints do not re-apply.

- **Borrow rate cap adherence**
  - Invariant: `getBorrowRate` must never exceed `borrowRateMaxMantissa` if set, and `borrowIndex` growth is consistent with elapsed time and rate bounds.
  - Rationale: `_accrueInterest` enforces a cap; assertions can detect misconfigured models or timestamp jumps.
  - Assertion hooks:
    - Trigger on `mToken._accrueInterest` and interest model parameter updates; recompute an upper bound and ensure observed deltas do not exceed it.

- **Collateral factor bounds and market configuration consistency**
  - Invariant: `collateralFactor` per market remains within [0, COLLATERAL_FACTOR_MAX_MANTISSA] and changes do not retroactively break safety for already-safe accounts within a single tx.
  - Rationale: Storage allows updates; assertions ensure no out-of-bounds and that sudden increases do not permit unsafe borrow.
  - Assertion hooks:
    - Trigger on `Operator.setCollateralFactor` (if present) or equivalent configuration writes; validate bounds and simulate impacted accounts’ liquidity.

Notes for assertion authors

- Prefer `ph.getCallInputs` on Operator hooks (`beforeMToken*`) to decode user-initiated actions and parameter amounts.
- Use `ph.forkPreTx`/`ph.forkPostTx` and when needed `ph.forkPostCall(id)` to check intra-tx intermediate states, especially for oracle price jumps and liquidity checks.
- For USD conversions, reuse oracle symbols and decimals as in `IOracleOperator.getUnderlyingPrice` and recompute with the same precision.
