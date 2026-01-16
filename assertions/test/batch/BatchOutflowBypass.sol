// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IOperatorDefender} from "../../../src/interfaces/IOperator.sol";

/**
 * @title BatchOutflowBypass
 * @notice Batch contract for testing outflow limit bypass attempts via multiple small transactions
 * @dev Allows simulating an attack where many small borrows/redeems try to bypass cumulative limits
 */
contract BatchOutflowBypass {
    /**
     * @notice Execute multiple small borrow operations in a single transaction
     * @dev This simulates an attack attempting to bypass outflow limits via many small transactions
     * @param operator The operator to call for borrow operations
     * @param mToken The mToken being borrowed
     * @param borrower The address borrowing
     * @param smallAmount The amount per individual borrow
     * @param count Number of borrow operations to execute
     */
    function executeMultipleSmallBorrows(
        IOperatorDefender operator,
        address mToken,
        address borrower,
        uint256 smallAmount,
        uint256 count
    ) external {
        for (uint256 i = 0; i < count; i++) {
            operator.beforeMTokenBorrow(mToken, borrower, smallAmount);
        }
    }

    /**
     * @notice Execute multiple small redeem operations in a single transaction
     * @dev This simulates an attack attempting to bypass outflow limits via many small redeems
     * @param operator The operator to call for redeem operations
     * @param mToken The mToken being redeemed
     * @param redeemer The address redeeming
     * @param smallAmount The amount per individual redeem
     * @param count Number of redeem operations to execute
     */
    function executeMultipleSmallRedeems(
        IOperatorDefender operator,
        address mToken,
        address redeemer,
        uint256 smallAmount,
        uint256 count
    ) external {
        for (uint256 i = 0; i < count; i++) {
            operator.beforeMTokenRedeem(mToken, redeemer, smallAmount);
        }
    }
}
