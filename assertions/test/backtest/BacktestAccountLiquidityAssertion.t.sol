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
        executeBacktest({
            targetContract: OPERATOR_ADDRESS,
            endBlock: 23851082,
            blockRange: BLOCK_RANGE,
            assertionCreationCode: type(AccountLiquidityAssertion).creationCode,
            assertionSelector: AccountLiquidityAssertion.assertionBorrowLiquidity.selector,
            rpcUrl: rpcUrl
        });
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
        executeBacktest({
            targetContract: MUSDC_TOKEN_ADDRESS,
            endBlock: 23851262,
            blockRange: BLOCK_RANGE,
            assertionCreationCode: type(AccountLiquidityAssertion).creationCode,
            assertionSelector: AccountLiquidityAssertion.assertionRedeemLiquidity.selector,
            rpcUrl: rpcUrl
        });
    }

    /**
     * @notice Test helper to verify RPC connection and configuration
     * @dev Run this first if backtests are failing to verify setup
     */
    function testBacktest_VerifySetup() public {
        console.log("=== BACKTEST SETUP VERIFICATION ===");

        // Verify environment variable is set
        try vm.envString("LINEA_SEPOLIA_RPC_URL") returns (string memory rpcUrl) {
            console.log("RPC URL configured:", rpcUrl);
            console.log("Target Operator:", OPERATOR_ADDRESS);
            console.log("Block Range:", BLOCK_RANGE);
            console.log("Setup verification: PASSED");
        } catch {
            console.log("ERROR: LINEA_SEPOLIA_RPC_URL environment variable not set");
            console.log("Please set it before running backtests:");
            console.log('export LINEA_SEPOLIA_RPC_URL="https://rpc.sepolia.linea.build"');
            revert("LINEA_SEPOLIA_RPC_URL not configured");
        }
    }
}
