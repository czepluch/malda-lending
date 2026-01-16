// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CredibleTestWithBacktesting} from "credible-std/CredibleTestWithBacktesting.sol";
import {BacktestingTypes} from "credible-std/utils/BacktestingTypes.sol";
import {mTokenLiquidationAssertion} from "../../src/mTokenLiquidationAssertion.a.sol";
import {console} from "forge-std/console.sol";

contract BacktestMTokenLiquidation is CredibleTestWithBacktesting {
    // Target mToken contract address (UPDATE THIS)
    // Users call liquidate() directly on mToken, so this should work for backtesting
    address constant MTOKEN_ADDRESS = 0x1eEa258B505cd6381171c1075EC6934F8D0Faf3b; // Linea mainnet musdc token

    // Backtesting configuration
    uint256 constant BLOCK_RANGE = 10;
    uint256 constant END_BLOCK = 0; // TODO: Can't find liquidation activity

    /**
     * @notice Backtest liquidation price sanity against historical transactions
     * @dev Validates oracle prices are non-zero, fresh, and within delta bounds
     *      Expected: 0 assertion failures
     */
    function testBacktest_LiquidationPriceSanity() public {
        console.log("=== MTOKEN LIQUIDATION PRICE SANITY BACKTESTING ===");

        require(MTOKEN_ADDRESS != address(0), "MTOKEN_ADDRESS not configured");
        require(END_BLOCK != 0, "END_BLOCK not configured");

        // Get RPC URL from environment
        string memory rpcUrl = vm.envString("LINEA_RPC_URL");

        // Execute backtest against historical liquidation transactions
        // Target is mToken because:
        // 1. Users call mToken.liquidate() directly (top-level transaction)
        // 2. mToken is the assertion adopter for this assertion
        // 3. Bash script filters for tx.to == MTOKEN_ADDRESS, which matches liquidation transactions
        executeBacktest(
            BacktestingTypes.BacktestingConfig({
                targetContract: MTOKEN_ADDRESS,
                endBlock: END_BLOCK,
                blockRange: BLOCK_RANGE,
                assertionCreationCode: type(mTokenLiquidationAssertion).creationCode,
                assertionSelector: mTokenLiquidationAssertion.assertionLiquidationPriceSanity.selector,
                rpcUrl: rpcUrl,
                detailedBlocks: false,
                useTraceFilter: false,
                forkByTxHash: false
            })
        );
    }

    /**
     * @notice Backtest liquidation price stability against historical transactions
     * @dev Validates prices don't deviate >5% during liquidation operations
     *      Expected: 0 assertion failures
     */
    function testBacktest_LiquidationPriceStability() public {
        console.log("=== MTOKEN LIQUIDATION PRICE STABILITY BACKTESTING ===");

        require(MTOKEN_ADDRESS != address(0), "MTOKEN_ADDRESS not configured");
        require(END_BLOCK != 0, "END_BLOCK not configured");

        // Get RPC URL from environment
        string memory rpcUrl = vm.envString("LINEA_RPC_URL");

        // Execute backtest against historical liquidation transactions
        executeBacktest(
            BacktestingTypes.BacktestingConfig({
                targetContract: MTOKEN_ADDRESS,
                endBlock: END_BLOCK,
                blockRange: BLOCK_RANGE,
                assertionCreationCode: type(mTokenLiquidationAssertion).creationCode,
                assertionSelector: mTokenLiquidationAssertion.assertionLiquidationPriceStability.selector,
                rpcUrl: rpcUrl,
                detailedBlocks: false,
                useTraceFilter: false,
                forkByTxHash: false
            })
        );
    }
}
