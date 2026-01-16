// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CredibleTestWithBacktesting} from "credible-std/CredibleTestWithBacktesting.sol";
import {BacktestingTypes} from "credible-std/utils/BacktestingTypes.sol";
import {AccountLiquidityAssertion} from "../../src/AccountLiquidityAssertion.a.sol";
import {console} from "forge-std/console.sol";

contract BacktestAccountLiquidityAssertion is CredibleTestWithBacktesting {
    // Target contract address
    address constant OPERATOR_ADDRESS = 0x4bbd2B599425026b8A504816D8A043636e2D7Ec7; // Linea mainnet operator
    address constant MUSDC_TOKEN_ADDRESS = 0x1eEa258B505cd6381171c1075EC6934F8D0Faf3b; // Linea mainnet musdc token

    // Backtesting configuration
    uint256 constant BLOCK_RANGE = 20;

    /**
     * @notice Backtest borrow liquidity assertions against historical transactions
     * @dev Validates that all historical borrow operations passed liquidity checks
     *      Expected: 0 assertion failures
     */
    function testBacktest_BorrowLiquidity() public {
        console.log("=== BORROW LIQUIDITY BACKTESTING ===");

        // Get RPC URL from environment
        string memory rpcUrl = vm.envString("LINEA_RPC_URL");

        // Execute backtest against historical borrow transactions
        executeBacktest(
            BacktestingTypes.BacktestingConfig({
                targetContract: OPERATOR_ADDRESS,
                endBlock: 23851082,
                blockRange: BLOCK_RANGE,
                assertionCreationCode: type(AccountLiquidityAssertion).creationCode,
                assertionSelector: AccountLiquidityAssertion.assertionBorrowLiquidity.selector,
                rpcUrl: rpcUrl,
                detailedBlocks: false,
                useTraceFilter: false,
                forkByTxHash: false
            })
        );
    }

    /**
     * @notice Backtest redeem liquidity assertions against historical transactions
     * @dev Validates that all historical redeem operations passed liquidity checks
     *      Expected: 0 assertion failures
     */
    function testBacktest_RedeemLiquidity() public {
        console.log("=== REDEEM LIQUIDITY BACKTESTING ===");

        // Get RPC URL from environment
        string memory rpcUrl = vm.envString("LINEA_RPC_URL");

        // Execute backtest against historical redeem transactions
        executeBacktest(
            BacktestingTypes.BacktestingConfig({
                targetContract: MUSDC_TOKEN_ADDRESS,
                endBlock: 23851262,
                blockRange: BLOCK_RANGE,
                assertionCreationCode: type(AccountLiquidityAssertion).creationCode,
                assertionSelector: AccountLiquidityAssertion.assertionRedeemLiquidity.selector,
                rpcUrl: rpcUrl,
                detailedBlocks: false,
                useTraceFilter: false,
                forkByTxHash: false
            })
        );
    }
}
