# Backtesting for Malda Lending Assertions

This directory contains backtesting suites that validate assertions against **historical blockchain transactions**.

## What is Backtesting?

Backtesting replays real historical transactions through your assertions to verify they work correctly with actual protocol usage patterns. This helps:

- ✅ Catch edge cases that unit tests might miss
- ✅ Validate assertions against real user behavior
- ✅ Identify potential false positives or protocol violations
- ✅ Build confidence before production deployment

## Setup

### 1. Set RPC URL Environment Variable

```bash
export LINEA_SEPOLIA_RPC_URL="https://rpc.sepolia.linea.build"
```

Or use a paid RPC provider for better rate limits:
```bash
export LINEA_SEPOLIA_RPC_URL="https://linea-sepolia.infura.io/v3/YOUR_API_KEY"
```

### 2. Run Backtests

Run all backtests:
```bash
FOUNDRY_PROFILE=backtest pcl test --ffi --match-contract BacktestAccountLiquidityAssertion -v
```

Run a specific backtest:
```bash
FOUNDRY_PROFILE=backtest pcl test --ffi --match-test testBacktest_BorrowLiquidity -v
```

### 3. Verify Setup

Before running full backtests, verify your configuration:
```bash
FOUNDRY_PROFILE=backtest pcl test --ffi --match-test testBacktest_VerifySetup -v
```

## Current Backtests

### Understanding Assertion Adopters and Backtesting

**Important:** The backtesting bash script filters transactions by the **top-level `to` address**. This means:

- ✅ **Works:** Transactions sent directly to the assertion adopter contract
- ❌ **Doesn't Work:** Internal calls to the assertion adopter from another contract

**Example:** For `AccountLiquidityAssertion`:
- Users call `mToken.borrow()` → internally calls `operator.beforeMTokenBorrow()`
- Transaction `to` = mToken address, NOT operator
- Backtesting targeting Operator will find **0 transactions** (even though borrows happened)
- **This is a known limitation** - backtesting only works when users call the assertion adopter directly

### AccountLiquidityAssertion (Operator-based)

**File:** `BacktestAccountLiquidityAssertion.t.sol`

**Target Deployment:**
- Network: Linea Mainnet (Chain ID: 59144)
- Operator Contract: `0x1eEa258B505cd6381171c1075EC6934F8D0Faf3b`
- Block Range: 20 blocks (default)
- **Assertion Adopter:** Operator

**Tests:**
- `testBacktest_BorrowLiquidity` - Validates borrow liquidity checks
- `testBacktest_RedeemLiquidity` - Validates redeem liquidity checks

**⚠️ Known Issue:** These tests won't find borrow/redeem transactions because:
- Users call `mToken.borrow()` or `mToken.redeem()` (not Operator directly)
- Backtesting script filters for `tx.to == Operator`
- Result: 0 transactions found, even if borrows/redeems occurred

### mTokenRedeemOutflowAssertion (mToken-based) ✅

**File:** `BacktestMTokenRedeemOutflow.t.sol`

**Target Deployment:**
- Network: Linea Mainnet (Chain ID: 59144)
- mToken Contract: **TODO: Set mToken address**
- Block Range: 20 blocks (default)
- **Assertion Adopter:** mToken

**Tests:**
- `testBacktest_RedeemOutflow` - Validates redeem operations respect outflow limits

**✅ This should work!** Because:
- Users call `mToken.redeem()` directly
- Backtesting script filters for `tx.to == mToken`
- Result: Should find actual redeem transactions

### mTokenLiquidationAssertion (mToken-based) ✅

**File:** `BacktestMTokenLiquidation.t.sol`

**Target Deployment:**
- Network: Linea Mainnet (Chain ID: 59144)
- mToken Contract: **TODO: Set mToken address**
- Block Range: 20 blocks (default)
- **Assertion Adopter:** mToken

**Tests:**
- `testBacktest_LiquidationPriceSanity` - Validates oracle prices during liquidations
- `testBacktest_LiquidationPriceStability` - Validates price stability during liquidations

**✅ This should work!** Because:
- Users call `mToken.liquidate()` directly
- Backtesting script filters for `tx.to == mToken`
- Result: Should find actual liquidation transactions

## Customizing Block Ranges

To test against specific historical periods, update the constants in the test file:

```solidity
uint256 constant BLOCK_RANGE = 50;  // Test more blocks
uint256 constant END_BLOCK = 12345678;  // Specific end block
```

Or pass block parameters dynamically if you need to test multiple ranges.

## Understanding Results

Each backtest logs detailed results:

```
Total Transactions: 100          # All transactions in block range
Processed Transactions: 45       # Transactions that triggered the assertion
Successful Validations: 45       # Assertions that passed
Failed Validations: 0            # Assertions that reverted (expected behavior)
Assertion Failures: 0            # Protocol violations found ⚠️
Unknown Errors: 0                # Unexpected errors
```

**Key Metric:** `Assertion Failures` should always be **0** (indicates protocol is working correctly)

## RPC Considerations

- **Free RPC endpoints** may have rate limits (slow for large block ranges)
- **Paid RPC providers** recommended for:
  - Large block ranges (>100 blocks)
  - Faster execution
  - CI/CD pipelines

**RPC calls made:**
- 1 call per block in range
- 1 call per transaction that triggers the assertion

Example: 20 blocks with 50 relevant transactions = ~70 RPC calls

## Troubleshooting

### Error: "LINEA_SEPOLIA_RPC_URL not set"
```bash
export LINEA_SEPOLIA_RPC_URL="https://rpc.sepolia.linea.build"
```

### Error: "FFI cheatcode is disabled"
Make sure to use the `--ffi` flag:
```bash
pcl test --ffi --match-test testBacktest_BorrowLiquidity
```

### Tests Taking Too Long
- Reduce `BLOCK_RANGE` constant
- Use a paid RPC provider with better rate limits
- Test during off-peak hours

### No Transactions Found
The block range may not contain relevant transactions. Try:
- Increasing `BLOCK_RANGE`
- Using a different `END_BLOCK` with known activity
- Checking block explorer for recent protocol activity

## Adding New Backtests

To backtest additional assertions:

1. Create a new test function
2. Use `executeBacktest()` with your assertion
3. Assert `results.assertionFailures == 0`

Example:
```solidity
function testBacktest_MyNewAssertion() public {
    BacktestingTypes.BacktestingResults memory results = executeBacktest({
        targetContract: OPERATOR_ADDRESS,
        endBlock: END_BLOCK,
        blockRange: BLOCK_RANGE,
        assertionCreationCode: type(MyAssertion).creationCode,
        assertionSelector: MyAssertion.assertionMyCheck.selector,
        rpcUrl: vm.envString("LINEA_SEPOLIA_RPC_URL")
    });

    assertEq(results.assertionFailures, 0, "Protocol violation found!");
}
```

## Future Networks

When Malda is deployed to other networks, duplicate and modify the backtest file:

```
backtest/
├── BacktestAccountLiquidityAssertion_LineaSepolia.t.sol   (current)
├── BacktestAccountLiquidityAssertion_LineaMainnet.t.sol   (future)
└── BacktestAccountLiquidityAssertion_Optimism.t.sol       (future)
```

Update the `OPERATOR_ADDRESS` and RPC URL for each network.
