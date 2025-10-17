// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IOperatorDefender} from "../../../src/interfaces/IOperator.sol";
import {MockOracleVulnerable} from "../mocks/MockOracleVulnerable.sol";
import {MockMTokenVulnerable} from "../mocks/MockMTokenVulnerable.sol";

/**
 * @title BatchPriceManipulator
 * @notice Batch contract for testing intra-transaction oracle price manipulation
 * @dev Allows simulating price changes DURING a transaction to test assertion detection
 */
contract BatchPriceManipulator {
    /**
     * @notice Execute a borrow operation with price manipulation mid-transaction
     * @dev This simulates an attack where oracle price changes during a transaction
     * @param operator The operator to call for the borrow operation
     * @param oracle The oracle to manipulate
     * @param mToken The mToken being borrowed
     * @param borrower The address borrowing
     * @param borrowAmount The amount to borrow
     * @param newPrice The manipulated price to set (should deviate >5% to trigger assertion)
     */
    function executeBorrowWithPriceChange(
        IOperatorDefender operator,
        MockOracleVulnerable oracle,
        address mToken,
        address borrower,
        uint256 borrowAmount,
        uint256 newPrice
    ) external {
        // Step 1: Start the borrow operation
        // The assertion will fork here and capture the initial price
        operator.beforeMTokenBorrow(mToken, borrower, borrowAmount);

        // Step 2: Manipulate the oracle price mid-transaction
        // This simulates a price manipulation attack
        // The assertion should detect this when it checks post-call state
        oracle.setPriceOverride(mToken, newPrice);

        // Step 3: Transaction completes
        // The assertion should have already reverted if it detected the deviation
    }

    /**
     * @notice Execute a liquidation with price manipulation mid-transaction
     * @dev Simulates price changes during liquidation to test assertion detection
     * @dev Uses mToken.liquidate() - a non-view state-changing function for proper Credible tracking
     * @param mTokenBorrowed The borrowed mToken (also serves as the liquidate() caller)
     * @param oracle The oracle to manipulate
     * @param mTokenCollateral The collateral mToken
     * @param borrower The borrower being liquidated
     * @param repayAmount The amount to repay
     * @param newBorrowedPrice New price for borrowed token
     * @param newCollateralPrice New price for collateral token
     */
    function executeLiquidationWithPriceChange(
        MockMTokenVulnerable mTokenBorrowed,
        MockOracleVulnerable oracle,
        address mTokenCollateral,
        address borrower,
        uint256 repayAmount,
        uint256 newBorrowedPrice,
        uint256 newCollateralPrice
    ) external {
        // Step 1: Call liquidate() - this is a non-view function that Credible can track
        // The borrowed mToken is the caller (address(mTokenBorrowed))
        mTokenBorrowed.liquidate(borrower, repayAmount, mTokenCollateral);

        // Step 2: Manipulate prices
        oracle.setPriceOverride(address(mTokenBorrowed), newBorrowedPrice);
        oracle.setPriceOverride(mTokenCollateral, newCollateralPrice);

        // Step 3: Complete (assertion should have reverted)
    }

    /**
     * @notice Execute multiple price changes in a single transaction
     * @dev Tests if assertion catches cumulative or multiple manipulations
     * @param operator The operator to call
     * @param oracle The oracle to manipulate
     * @param mToken The mToken being borrowed
     * @param borrower The address borrowing
     * @param borrowAmount The amount to borrow
     * @param prices Array of prices to set sequentially
     */
    function executeBorrowWithMultiplePriceChanges(
        IOperatorDefender operator,
        MockOracleVulnerable oracle,
        address mToken,
        address borrower,
        uint256 borrowAmount,
        uint256[] calldata prices
    ) external {
        // Step 1: Start the borrow operation
        operator.beforeMTokenBorrow(mToken, borrower, borrowAmount);

        // Step 2: Manipulate price multiple times
        for (uint256 i = 0; i < prices.length; i++) {
            oracle.setPriceOverride(mToken, prices[i]);
        }

        // Step 3: Complete (assertion should have caught the deviation)
    }

    /**
     * @notice Execute multiple borrow calls with price manipulation between them
     * @dev This triggers the ELSE branch (multiple calls path) in assertionBorrowPriceStability
     * @dev The assertion will check each call individually using forkPostCall()
     * @param operator The operator to call
     * @param oracle The oracle to manipulate
     * @param mToken The mToken being borrowed
     * @param borrower1 First borrower address
     * @param borrowAmount1 First borrow amount
     * @param borrower2 Second borrower address
     * @param borrowAmount2 Second borrow amount
     * @param manipulatedPrice The manipulated price to set between calls (should deviate >5%)
     */
    function executeMultipleBorrowsWithPriceManipulation(
        IOperatorDefender operator,
        MockOracleVulnerable oracle,
        address mToken,
        address borrower1,
        uint256 borrowAmount1,
        address borrower2,
        uint256 borrowAmount2,
        uint256 manipulatedPrice
    ) external {
        // First borrow call - should be checked against initial price
        operator.beforeMTokenBorrow(mToken, borrower1, borrowAmount1);

        // Manipulate price between calls
        oracle.setPriceOverride(mToken, manipulatedPrice);

        // Second borrow call - should be checked against initial price (not post-manipulation)
        // This is where the assertion should catch the deviation using forkPostCall()
        operator.beforeMTokenBorrow(mToken, borrower2, borrowAmount2);
    }

    /**
     * @notice Execute three borrow calls with gradual price manipulation
     * @dev Tests that assertion checks each call individually against initial state
     * @param operator The operator to call
     * @param oracle The oracle to manipulate
     * @param mToken The mToken being borrowed
     * @param borrower1 First borrower
     * @param borrowAmount1 First borrow amount
     * @param borrower2 Second borrower
     * @param borrowAmount2 Second borrow amount
     * @param borrower3 Third borrower
     * @param borrowAmount3 Third borrow amount
     * @param price2 Price to set after first borrow (small change)
     * @param price3 Price to set after second borrow (larger change that should trigger)
     */
    function executeThreeBorrowsWithGradualManipulation(
        IOperatorDefender operator,
        MockOracleVulnerable oracle,
        address mToken,
        address borrower1,
        uint256 borrowAmount1,
        address borrower2,
        uint256 borrowAmount2,
        address borrower3,
        uint256 borrowAmount3,
        uint256 price2,
        uint256 price3
    ) external {
        // First borrow at initial price
        operator.beforeMTokenBorrow(mToken, borrower1, borrowAmount1);

        // Small price change
        oracle.setPriceOverride(mToken, price2);

        // Second borrow at slightly changed price
        operator.beforeMTokenBorrow(mToken, borrower2, borrowAmount2);

        // Larger price change
        oracle.setPriceOverride(mToken, price3);

        // Third borrow at significantly changed price - should trigger violation
        operator.beforeMTokenBorrow(mToken, borrower3, borrowAmount3);
    }

    // ============ Multiple Liquidation Call Functions ============

    /**
     * @notice Execute multiple liquidation calls with price manipulation between them
     * @dev This triggers the multiple calls path in assertionLiquidationPriceStability
     * @dev The assertion will check each call individually using forkPostCall()
     * @dev Uses mToken.liquidate() - a non-view state-changing function for proper Credible tracking
     * @param mTokenBorrowed The borrowed mToken (also serves as the liquidate() caller)
     * @param oracle The oracle to manipulate
     * @param mTokenCollateral The collateral mToken
     * @param borrower1 First borrower being liquidated
     * @param repayAmount1 First repay amount
     * @param borrower2 Second borrower being liquidated
     * @param repayAmount2 Second repay amount
     * @param manipulatedBorrowedPrice New borrowed token price (should deviate >5%)
     * @param manipulatedCollateralPrice New collateral token price (should deviate >5%)
     */
    function executeMultipleLiquidationsWithPriceManipulation(
        MockMTokenVulnerable mTokenBorrowed,
        MockOracleVulnerable oracle,
        address mTokenCollateral,
        address borrower1,
        uint256 repayAmount1,
        address borrower2,
        uint256 repayAmount2,
        uint256 manipulatedBorrowedPrice,
        uint256 manipulatedCollateralPrice
    ) external {
        // First liquidation call - should be checked against initial prices
        mTokenBorrowed.liquidate(borrower1, repayAmount1, mTokenCollateral);

        // Manipulate prices between calls
        oracle.setPriceOverride(address(mTokenBorrowed), manipulatedBorrowedPrice);
        oracle.setPriceOverride(mTokenCollateral, manipulatedCollateralPrice);

        // Second liquidation call - should be checked against initial prices (not post-manipulation)
        // This is where the assertion should catch the deviation using forkPostCall()
        mTokenBorrowed.liquidate(borrower2, repayAmount2, mTokenCollateral);
    }

    /**
     * @notice Execute three liquidation calls with gradual price manipulation
     * @dev Tests that assertion checks each call individually against initial state
     * @dev Uses arrays to avoid stack too deep errors
     * @dev Uses mToken.liquidate() - a non-view state-changing function for proper Credible tracking
     * @param mTokenBorrowed The borrowed mToken (also serves as the liquidate() caller)
     * @param oracle The oracle to manipulate
     * @param mTokenCollateral The collateral mToken
     * @param borrowers Array of 3 borrowers
     * @param repayAmounts Array of 3 repay amounts
     * @param borrowedPrices Array of 2 borrowed prices (after 1st and 2nd liquidations)
     * @param collateralPrices Array of 2 collateral prices (after 1st and 2nd liquidations)
     */
    function executeThreeLiquidationsWithGradualManipulation(
        MockMTokenVulnerable mTokenBorrowed,
        MockOracleVulnerable oracle,
        address mTokenCollateral,
        address[3] calldata borrowers,
        uint256[3] calldata repayAmounts,
        uint256[2] calldata borrowedPrices,
        uint256[2] calldata collateralPrices
    ) external {
        // First liquidation at initial prices
        mTokenBorrowed.liquidate(borrowers[0], repayAmounts[0], mTokenCollateral);

        // Small price changes
        oracle.setPriceOverride(address(mTokenBorrowed), borrowedPrices[0]);
        oracle.setPriceOverride(mTokenCollateral, collateralPrices[0]);

        // Second liquidation at slightly changed prices
        mTokenBorrowed.liquidate(borrowers[1], repayAmounts[1], mTokenCollateral);

        // Larger price changes
        oracle.setPriceOverride(address(mTokenBorrowed), borrowedPrices[1]);
        oracle.setPriceOverride(mTokenCollateral, collateralPrices[1]);

        // Third liquidation at significantly changed prices - should trigger violation
        mTokenBorrowed.liquidate(borrowers[2], repayAmounts[2], mTokenCollateral);
    }
}
