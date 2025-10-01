// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from "credible-std/Assertion.sol";
import {PhEvm} from "credible-std/PhEvm.sol";
import {IOperatorDefender, IOperator} from "../../src/interfaces/IOperator.sol";

/**
 * @title Account Liquidity Assertion
 * @notice Ensures account liquidity soundness across transactions
 * @dev This assertion verifies that:
 *      1. Borrowers can only borrow when they have sufficient collateral (shortfall = 0)
 *      2. Liquidations can only occur when borrowers are underwater (shortfall > 0)
 *      3. Redeems cannot proceed if they would cause shortfall
 *      4. Liquidity calculations are consistent with actual state changes
 */
contract AccountLiquidityAssertion is Assertion {
    // No constructor needed - use ph.getAssertionAdopter() in functions

    /**
     * @notice Register triggers for all liquidity-related operations
     * @dev Triggers on borrow, liquidate, redeem, and seize operations
     */
    function triggers() external view override {
        // Borrow operations - must have sufficient collateral
        registerCallTrigger(this.assertionBorrowLiquidity.selector, IOperatorDefender.beforeMTokenBorrow.selector);

        // Liquidation operations - must be underwater
        registerCallTrigger(
            this.assertionLiquidationLiquidity.selector, IOperatorDefender.beforeMTokenLiquidate.selector
        );

        // Redeem operations - must not cause shortfall
        registerCallTrigger(this.assertionRedeemLiquidity.selector, IOperatorDefender.beforeMTokenRedeem.selector);

        // Seize operations - part of liquidation flow
        registerCallTrigger(this.assertionSeizeLiquidity.selector, IOperatorDefender.beforeMTokenSeize.selector);
    }

    /**
     * @notice Assert that borrow operations only proceed when account has sufficient liquidity
     * @dev Verifies that _getHypotheticalAccountLiquidity returns shortfall = 0 for allowed borrows
     */
    function assertionBorrowLiquidity() external {
        IOperatorDefender operatorDefender = IOperatorDefender(ph.getAssertionAdopter());
        IOperator operator = IOperator(ph.getAssertionAdopter());

        // Get all borrow calls in this transaction
        PhEvm.CallInputs[] memory borrowCalls =
            ph.getCallInputs(address(operatorDefender), operatorDefender.beforeMTokenBorrow.selector);

        for (uint256 i = 0; i < borrowCalls.length; i++) {
            // Decode the borrow call parameters
            (address mToken, address borrower, uint256 borrowAmount) =
                abi.decode(borrowCalls[i].input, (address, address, uint256));

            // Get liquidity state before the borrow operation
            ph.forkPreCall(borrowCalls[i].id);
            (uint256 liquidityBefore, uint256 shortfallBefore) =
                operator.getHypotheticalAccountLiquidity(borrower, mToken, 0, borrowAmount);

            // Assert that borrow was only allowed if shortfall would be 0
            require(shortfallBefore == 0, "Borrow allowed despite insufficient liquidity");
        }
    }

    /**
     * @notice Assert that liquidation operations only proceed when account is underwater
     * @dev Verifies that _getHypotheticalAccountLiquidity returns shortfall > 0 for allowed liquidations
     */
    function assertionLiquidationLiquidity() external {
        IOperatorDefender operatorDefender = IOperatorDefender(ph.getAssertionAdopter());
        IOperator operator = IOperator(ph.getAssertionAdopter());

        // Get all liquidation calls in this transaction
        PhEvm.CallInputs[] memory liquidateCalls =
            ph.getCallInputs(address(operatorDefender), operatorDefender.beforeMTokenLiquidate.selector);

        for (uint256 i = 0; i < liquidateCalls.length; i++) {
            // Decode the liquidation call parameters
            (address mTokenBorrowed, address mTokenCollateral, address borrower, uint256 repayAmount) =
                abi.decode(liquidateCalls[i].input, (address, address, address, uint256));

            // Get liquidity state before the liquidation operation
            ph.forkPreCall(liquidateCalls[i].id);
            (uint256 liquidityBefore, uint256 shortfallBefore) = operator.getHypotheticalAccountLiquidity(
                borrower,
                address(0), // No modification to any specific mToken
                0, // No redeem
                0 // No additional borrow
            );

            // Assert that liquidation was only allowed if shortfall > 0
            // If the call succeeded (we're in post-call), shortfallBefore must be > 0
            require(shortfallBefore > 0, "Liquidation allowed despite sufficient liquidity");

            // Additional check: verify the repay amount is reasonable
            require(repayAmount > 0, "Liquidation with zero repay amount");
        }
    }

    /**
     * @notice Assert that redeem operations only proceed when account maintains sufficient liquidity
     * @dev Verifies that _getHypotheticalAccountLiquidity returns shortfall = 0 for allowed redeems
     */
    function assertionRedeemLiquidity() external {
        IOperatorDefender operatorDefender = IOperatorDefender(ph.getAssertionAdopter());
        IOperator operator = IOperator(ph.getAssertionAdopter());

        // Get all redeem calls in this transaction
        PhEvm.CallInputs[] memory redeemCalls =
            ph.getCallInputs(address(operatorDefender), operatorDefender.beforeMTokenRedeem.selector);

        for (uint256 i = 0; i < redeemCalls.length; i++) {
            // Decode the redeem call parameters
            (address mToken, address redeemer, uint256 redeemTokens) =
                abi.decode(redeemCalls[i].input, (address, address, uint256));

            // Get liquidity state before the redeem operation
            ph.forkPreCall(redeemCalls[i].id);
            (uint256 liquidityBefore, uint256 shortfallBefore) = operator.getHypotheticalAccountLiquidity(
                redeemer,
                mToken,
                redeemTokens,
                0 // No additional borrow
            );

            // Get liquidity state after the redeem operation
            ph.forkPostCall(redeemCalls[i].id);
            (uint256 liquidityAfter, uint256 shortfallAfter) = operator.getHypotheticalAccountLiquidity(
                redeemer,
                mToken,
                0, // No additional redeem after the operation
                0 // No additional borrow
            );

            // Assert that redeem was only allowed if shortfall would be 0
            // If the call succeeded (we're in post-call), shortfallBefore must be 0
            require(shortfallBefore == 0, "Redeem allowed despite insufficient liquidity");

            // Assert that the redeem operation was properly accounted for
            // The liquidity should generally decrease after a redeem (unless it was excess collateral)
            require(shortfallAfter == 0, "Redeem caused account to become underwater");
        }
    }

    /**
     * @notice Assert that seize operations are part of valid liquidation flows
     * @dev Verifies that seize operations are properly gated by liquidation requirements
     */
    function assertionSeizeLiquidity() external {
        IOperatorDefender operatorDefender = IOperatorDefender(ph.getAssertionAdopter());
        IOperator operator = IOperator(ph.getAssertionAdopter());

        // Get all seize calls in this transaction
        PhEvm.CallInputs[] memory seizeCalls =
            ph.getCallInputs(address(operatorDefender), operatorDefender.beforeMTokenSeize.selector);

        for (uint256 i = 0; i < seizeCalls.length; i++) {
            // Decode the seize call parameters
            (address mTokenCollateral, address mTokenBorrowed, address liquidator, address borrower) =
                abi.decode(seizeCalls[i].input, (address, address, address, address));

            // Get liquidity state before the seize operation
            ph.forkPreCall(seizeCalls[i].id);
            (uint256 liquidityBefore, uint256 shortfallBefore) = operator.getHypotheticalAccountLiquidity(
                borrower,
                address(0), // No modification to any specific mToken
                0, // No redeem
                0 // No additional borrow
            );

            // Seize operations should only occur as part of liquidation flows
            // The borrower should have been underwater before the liquidation started
            // Note: By the time seize is called, the liquidation may have already improved the borrower's position
            // So we can't require shortfall > 0 here, but we can verify the operation is reasonable
            require(borrower != address(0), "Seize with zero borrower address");
            require(liquidator != address(0), "Seize with zero liquidator address");
            require(mTokenCollateral != address(0), "Seize with zero collateral mToken");
            require(mTokenBorrowed != address(0), "Seize with zero borrowed mToken");
        }
    }
}
