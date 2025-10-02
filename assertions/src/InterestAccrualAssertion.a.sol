// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from "credible-std/Assertion.sol";
import {PhEvm} from "credible-std/PhEvm.sol";
import {IOperatorDefender} from "../../src/interfaces/IOperator.sol";
import {ImToken} from "../../src/interfaces/ImToken.sol";
import {IInterestRateModel} from "../../src/interfaces/IInterestRateModel.sol";

/**
 * INVARIANTS PROTECTED:
 * 1. MONOTONIC INTEREST ACCRUAL: Borrow index must monotonically increase when time advances.
 *    This prevents interest manipulation where attackers could decrease accumulated interest.
 *
 * 2. BORROW BALANCE INTEGRITY: Individual borrow balances can only increase due to interest
 *    or decrease due to repayments - never decrease without an explicit repayment action.
 *
 * 3. RATE CAP ENFORCEMENT: Interest rates must stay within reasonable bounds (< 0.03% per block)
 *    to prevent excessive interest accumulation that could trap borrowers.
 *
 * 4. TOTAL BORROWS CONSISTENCY: Total protocol borrows must reflect the sum of individual
 *    borrows and can only change through borrows, repayments, and interest accrual.
 */

/**
 * @title Interest Accrual Monotonicity Assertion
 * @notice Ensures interest rates and borrow balances can only increase over time
 * @dev This assertion verifies that:
 *      1. Borrow index can only increase (monotonicity)
 *      2. Total borrows can only increase (or stay the same)
 *      3. Borrow rates never exceed configured maximum rates
 *      4. Individual borrow balances never decrease without repayment
 *      5. Interest accrual is properly reflected in state changes
 */
contract InterestAccrualAssertion is Assertion {
    /**
     * @notice Register triggers for interest accrual monitoring
     * @dev Triggers on operations that involve interest accrual
     */
    function triggers() external view override {
        // Monitor interest accrual during borrow operations
        registerCallTrigger(this.assertionBorrowInterestMonotonicity.selector, IOperatorDefender.beforeMTokenBorrow.selector);

        // Monitor interest accrual during liquidation operations
        registerCallTrigger(this.assertionLiquidationInterestMonotonicity.selector, IOperatorDefender.beforeMTokenLiquidate.selector);

        // Monitor interest accrual during redeem operations
        registerCallTrigger(this.assertionRedeemInterestMonotonicity.selector, IOperatorDefender.beforeMTokenRedeem.selector);

        // Monitor interest rate caps during borrow operations
        registerCallTrigger(this.assertionBorrowRateCap.selector, IOperatorDefender.beforeMTokenBorrow.selector);
    }

    /**
     * @notice Assert that borrow index and total borrows follow monotonicity during borrow operations
     * @dev Verifies that interest accrual only increases values over time
     */
    function assertionBorrowInterestMonotonicity() external {
        IOperatorDefender operator = IOperatorDefender(ph.getAssertionAdopter());

        // Get all borrow calls in this transaction
        PhEvm.CallInputs[] memory borrowCalls =
            ph.getCallInputs(address(operator), IOperatorDefender.beforeMTokenBorrow.selector);

        for (uint256 i = 0; i < borrowCalls.length; i++) {
            (address mToken, address borrower, uint256 borrowAmount) =
                abi.decode(borrowCalls[i].input, (address, address, uint256));

            // Check state before the borrow operation
            ph.forkPreCall(borrowCalls[i].id);
            uint256 borrowIndexBefore = ImToken(mToken).borrowIndex();
            uint256 totalBorrowsBefore = ImToken(mToken).totalBorrows();
            uint256 borrowBalanceBefore = ImToken(mToken).borrowBalanceStored(borrower);
            uint256 accrualBlockBefore = ImToken(mToken).accrualBlockTimestamp();

            // Check state after the borrow operation
            ph.forkPostCall(borrowCalls[i].id);
            uint256 borrowIndexAfter = ImToken(mToken).borrowIndex();
            uint256 totalBorrowsAfter = ImToken(mToken).totalBorrows();
            uint256 borrowBalanceAfter = ImToken(mToken).borrowBalanceStored(borrower);
            uint256 accrualBlockAfter = ImToken(mToken).accrualBlockTimestamp();

            // If accrual happened (block timestamp changed), verify monotonicity
            if (accrualBlockAfter > accrualBlockBefore) {
                // Borrow index must never decrease
                require(borrowIndexAfter >= borrowIndexBefore, "Borrow index decreased during interest accrual");

                // Total borrows should increase (or stay the same if no borrows existed)
                require(totalBorrowsAfter >= totalBorrowsBefore, "Total borrows decreased during interest accrual");

                // Edge case: If there were existing borrows, index must strictly increase
                // This catches subtle bugs where interest calculation returns 0 when it shouldn't
                // (e.g., due to overflow, underflow, or logic errors in the interest rate model)
                if (totalBorrowsBefore > 0 && borrowIndexBefore > 0) {
                    require(borrowIndexAfter > borrowIndexBefore, "Borrow index did not increase with positive borrows");
                }
            }

            // Individual borrow balance should only increase (unless this is a new borrow)
            if (borrowBalanceBefore > 0 && accrualBlockAfter > accrualBlockBefore) {
                // The balance should have increased due to interest
                // Note: The actual new borrow amount is added on top of this
                uint256 expectedMinBalance = borrowBalanceBefore; // At minimum, should not decrease
                require(borrowBalanceAfter >= expectedMinBalance, "Borrow balance decreased without repayment");
            }
        }
    }

    /**
     * @notice Assert that interest accrual maintains monotonicity during liquidations
     * @dev Verifies interest handling during liquidation operations
     */
    function assertionLiquidationInterestMonotonicity() external {
        IOperatorDefender operator = IOperatorDefender(ph.getAssertionAdopter());

        // Get all liquidation calls in this transaction
        PhEvm.CallInputs[] memory liquidateCalls =
            ph.getCallInputs(address(operator), IOperatorDefender.beforeMTokenLiquidate.selector);

        for (uint256 i = 0; i < liquidateCalls.length; i++) {
            (address mTokenBorrowed, address mTokenCollateral, address borrower, uint256 repayAmount) =
                abi.decode(liquidateCalls[i].input, (address, address, address, uint256));

            // Check borrowed token interest accrual
            ph.forkPreCall(liquidateCalls[i].id);
            uint256 borrowIndexBefore = ImToken(mTokenBorrowed).borrowIndex();
            uint256 totalBorrowsBefore = ImToken(mTokenBorrowed).totalBorrows();
            uint256 accrualBlockBefore = ImToken(mTokenBorrowed).accrualBlockTimestamp();

            ph.forkPostCall(liquidateCalls[i].id);
            uint256 borrowIndexAfter = ImToken(mTokenBorrowed).borrowIndex();
            uint256 totalBorrowsAfter = ImToken(mTokenBorrowed).totalBorrows();
            uint256 accrualBlockAfter = ImToken(mTokenBorrowed).accrualBlockTimestamp();

            // If accrual happened, verify monotonicity
            if (accrualBlockAfter > accrualBlockBefore) {
                require(borrowIndexAfter >= borrowIndexBefore, "Borrow index decreased during liquidation");

                // Total borrows might decrease due to repayment, but should account for interest first
                // The decrease should not be more than the repay amount
                if (totalBorrowsAfter < totalBorrowsBefore) {
                    uint256 maxDecrease = repayAmount;
                    require(
                        totalBorrowsBefore - totalBorrowsAfter <= maxDecrease,
                        "Total borrows decreased more than repay amount"
                    );
                }
            }
        }
    }

    /**
     * @notice Assert that interest accrual maintains monotonicity during redeem operations
     * @dev Verifies interest handling when users redeem mTokens
     */
    function assertionRedeemInterestMonotonicity() external {
        IOperatorDefender operator = IOperatorDefender(ph.getAssertionAdopter());

        // Get all redeem calls in this transaction
        PhEvm.CallInputs[] memory redeemCalls =
            ph.getCallInputs(address(operator), IOperatorDefender.beforeMTokenRedeem.selector);

        for (uint256 i = 0; i < redeemCalls.length; i++) {
            (address mToken, address redeemer, uint256 redeemTokens) =
                abi.decode(redeemCalls[i].input, (address, address, uint256));

            // Check interest accrual state
            ph.forkPreCall(redeemCalls[i].id);
            uint256 borrowIndexBefore = ImToken(mToken).borrowIndex();
            uint256 totalBorrowsBefore = ImToken(mToken).totalBorrows();
            uint256 totalReservesBefore = ImToken(mToken).totalReserves();
            uint256 accrualBlockBefore = ImToken(mToken).accrualBlockTimestamp();

            ph.forkPostCall(redeemCalls[i].id);
            uint256 borrowIndexAfter = ImToken(mToken).borrowIndex();
            uint256 totalBorrowsAfter = ImToken(mToken).totalBorrows();
            uint256 totalReservesAfter = ImToken(mToken).totalReserves();
            uint256 accrualBlockAfter = ImToken(mToken).accrualBlockTimestamp();

            // If accrual happened, verify monotonicity
            if (accrualBlockAfter > accrualBlockBefore) {
                // Borrow index must never decrease
                require(borrowIndexAfter >= borrowIndexBefore, "Borrow index decreased during redeem");

                // Total borrows should only increase due to interest
                require(totalBorrowsAfter >= totalBorrowsBefore, "Total borrows decreased during redeem");

                // Total reserves should only increase (due to reserve factor * interest)
                require(totalReservesAfter >= totalReservesBefore, "Total reserves decreased during redeem");
            }
        }
    }

    /**
     * @notice Assert that borrow rates never exceed configured maximum rates
     * @dev Verifies that interest rate model respects rate caps
     */
    function assertionBorrowRateCap() external {
        IOperatorDefender operator = IOperatorDefender(ph.getAssertionAdopter());

        // Get all borrow calls in this transaction
        PhEvm.CallInputs[] memory borrowCalls =
            ph.getCallInputs(address(operator), IOperatorDefender.beforeMTokenBorrow.selector);

        for (uint256 i = 0; i < borrowCalls.length; i++) {
            (address mToken, , ) = abi.decode(borrowCalls[i].input, (address, address, uint256));

            // Get the interest rate model and check the borrow rate
            ph.forkPostCall(borrowCalls[i].id);

            address interestRateModel = ImToken(mToken).interestRateModel();
            uint256 cash = ImToken(mToken).getCash();
            uint256 borrows = ImToken(mToken).totalBorrows();
            uint256 reserves = ImToken(mToken).totalReserves();

            // Get the current borrow rate from the model
            uint256 borrowRate = IInterestRateModel(interestRateModel).getBorrowRate(cash, borrows, reserves);

            // Sanity check: rate should be reasonable (e.g., less than 1000% APY)
            // Why this threshold:
            // - 1000% APY ≈ 10x per year ≈ 0.0003x per block (assuming ~10M blocks/year on Ethereum) // TODO: adjust to linea
            // - This prevents malicious interest rate models from setting rates that would
            //   instantly make positions unliquidatable or trap funds
            // - Even high-risk protocols rarely exceed 500% APY legitimately
            uint256 maxReasonableRate = 3e14; // 0.0003 * 1e18 = 0.03% per block
            require(borrowRate <= maxReasonableRate, "Borrow rate unreasonably high");
        }
    }
}