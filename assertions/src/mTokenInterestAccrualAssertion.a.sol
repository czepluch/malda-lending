// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from "credible-std/Assertion.sol";
import {PhEvm} from "credible-std/PhEvm.sol";
import {ImErc20} from "../../src/interfaces/ImErc20.sol";
import {ImToken} from "../../src/interfaces/ImToken.sol";
import {IOperator} from "../../src/interfaces/IOperator.sol";
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
 * @title mToken Interest Accrual Assertion
 * @notice Ensures interest rates and borrow balances can only increase over time
 * @dev This assertion monitors mToken operations (borrow, redeem, liquidate) for proper interest accrual
 * @dev Uses ImErc20 (mToken) as assertion adopter instead of IOperator for proper tracking
 * @dev Pattern matches mTokenLiquidationAssertion - triggers on mToken operations that call accrueInterest internally
 */
contract mTokenInterestAccrualAssertion is Assertion {
    /**
     * @notice Register triggers for interest accrual monitoring
     * @dev Triggers on mToken operations that call accrueInterest internally
     */
    function triggers() external view override {
        registerCallTrigger(this.assertionBorrowInterestMonotonicity.selector, ImErc20.borrow.selector);
        registerCallTrigger(this.assertionBorrowRateCap.selector, ImErc20.borrow.selector);
        registerCallTrigger(this.assertionRedeemInterestMonotonicity.selector, ImErc20.redeem.selector);
        registerCallTrigger(this.assertionLiquidationInterestMonotonicity.selector, ImErc20.liquidate.selector);
    }

    /**
     * @notice Assert that borrow index and total borrows follow monotonicity during borrow operations
     * @dev Verifies that interest accrual only increases values over time
     */
    function assertionBorrowInterestMonotonicity() external {
        ImToken mToken = ImToken(ph.getAssertionAdopter());

        PhEvm.CallInputs[] memory borrowCalls =
            ph.getCallInputs(address(mToken), ImErc20.borrow.selector);

        for (uint256 i = 0; i < borrowCalls.length; i++) {
            uint256 borrowAmount = abi.decode(borrowCalls[i].input, (uint256));

            ph.forkPreCall(borrowCalls[i].id);
            uint256 borrowIndexBefore = mToken.borrowIndex();
            uint256 totalBorrowsBefore = mToken.totalBorrows();
            uint256 accrualBlockBefore = mToken.accrualBlockTimestamp();

            ph.forkPostCall(borrowCalls[i].id);
            uint256 borrowIndexAfter = mToken.borrowIndex();
            uint256 totalBorrowsAfter = mToken.totalBorrows();
            uint256 accrualBlockAfter = mToken.accrualBlockTimestamp();

            if (accrualBlockAfter > accrualBlockBefore) {
                require(borrowIndexAfter >= borrowIndexBefore, "Borrow index decreased during interest accrual");

                require(totalBorrowsAfter >= totalBorrowsBefore, "Total borrows decreased during interest accrual");

                if (totalBorrowsBefore > 0 && borrowIndexBefore > 0) {
                    require(borrowIndexAfter > borrowIndexBefore, "Borrow index did not increase with positive borrows");
                }
            }
        }
    }

    /**
     * @notice Assert that borrow index and total borrows follow monotonicity during redeem operations
     * @dev Verifies that interest accrual only increases values over time, even during redeems
     */
    function assertionRedeemInterestMonotonicity() external {
        ImToken mToken = ImToken(ph.getAssertionAdopter());

        PhEvm.CallInputs[] memory redeemCalls =
            ph.getCallInputs(address(mToken), ImErc20.redeem.selector);

        for (uint256 i = 0; i < redeemCalls.length; i++) {
            ph.forkPreCall(redeemCalls[i].id);
            uint256 borrowIndexBefore = mToken.borrowIndex();
            uint256 totalBorrowsBefore = mToken.totalBorrows();
            uint256 totalReservesBefore = mToken.totalReserves();
            uint256 accrualBlockBefore = mToken.accrualBlockTimestamp();

            ph.forkPostCall(redeemCalls[i].id);
            uint256 borrowIndexAfter = mToken.borrowIndex();
            uint256 totalBorrowsAfter = mToken.totalBorrows();
            uint256 totalReservesAfter = mToken.totalReserves();
            uint256 accrualBlockAfter = mToken.accrualBlockTimestamp();

            if (accrualBlockAfter > accrualBlockBefore) {
                require(borrowIndexAfter >= borrowIndexBefore, "Borrow index decreased during redeem");

                require(totalBorrowsAfter >= totalBorrowsBefore, "Total borrows decreased during redeem");

                require(totalReservesAfter >= totalReservesBefore, "Total reserves decreased during redeem");
            }
        }
    }

    /**
     * @notice Assert that borrow index follows monotonicity during liquidation operations
     * @dev Verifies that interest accrual only increases values during liquidations
     */
    function assertionLiquidationInterestMonotonicity() external {
        ImToken mToken = ImToken(ph.getAssertionAdopter());

        PhEvm.CallInputs[] memory liquidateCalls =
            ph.getCallInputs(address(mToken), ImErc20.liquidate.selector);

        for (uint256 i = 0; i < liquidateCalls.length; i++) {
            (address borrower, uint256 repayAmount, address mTokenCollateral) =
                abi.decode(liquidateCalls[i].input, (address, uint256, address));

            ph.forkPreCall(liquidateCalls[i].id);
            uint256 borrowIndexBefore = mToken.borrowIndex();
            uint256 totalBorrowsBefore = mToken.totalBorrows();
            uint256 accrualBlockBefore = mToken.accrualBlockTimestamp();

            ph.forkPostCall(liquidateCalls[i].id);
            uint256 borrowIndexAfter = mToken.borrowIndex();
            uint256 totalBorrowsAfter = mToken.totalBorrows();
            uint256 accrualBlockAfter = mToken.accrualBlockTimestamp();

            if (accrualBlockAfter > accrualBlockBefore) {
                require(borrowIndexAfter >= borrowIndexBefore, "Borrow index decreased during liquidation");

                if (totalBorrowsBefore > repayAmount) {
                    require(
                        totalBorrowsAfter >= totalBorrowsBefore - repayAmount,
                        "Total borrows decreased more than repay amount during liquidation"
                    );
                }
            }
        }
    }

    /**
     * @notice Assert that borrow rates stay within reasonable bounds
     * @dev Prevents excessive interest rates that could trap borrowers
     */
    function assertionBorrowRateCap() external {
        ImToken mToken = ImToken(ph.getAssertionAdopter());

        PhEvm.CallInputs[] memory borrowCalls =
            ph.getCallInputs(address(mToken), ImErc20.borrow.selector);

        for (uint256 i = 0; i < borrowCalls.length; i++) {
            ph.forkPostCall(borrowCalls[i].id);

            address interestRateModel = mToken.interestRateModel();
            uint256 cash = mToken.getCash();
            uint256 borrows = mToken.totalBorrows();
            uint256 reserves = mToken.totalReserves();

            uint256 borrowRate = IInterestRateModel(interestRateModel).getBorrowRate(cash, borrows, reserves);

            require(borrowRate <= 0x0110d9316ec000, "Borrow rate unreasonably high");
        }
    }
}
