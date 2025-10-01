// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from "credible-std/Assertion.sol";
import {PhEvm} from "credible-std/PhEvm.sol";
import {IOperatorDefender, IOperator} from "../../src/interfaces/IOperator.sol";
import {IOracleOperator} from "../../src/interfaces/IOracleOperator.sol";
import {ImToken} from "../../src/interfaces/ImToken.sol";

/**
 * INVARIANTS PROTECTED:
 * 1. OUTFLOW LIMIT ENFORCEMENT: Total USD value leaving the protocol in any time window
 *    must not exceed the configured limit. This prevents rapid drainage of protocol funds.
 *
 * 2. ATOMIC TIME WINDOW RESETS: When the time window expires, the cumulative counter must
 *    reset atomically to prevent manipulation through transaction ordering.
 *
 * 3. CUMULATIVE TRACKING INTEGRITY: The sum of all outflows (borrows + redeems) within a
 *    window must be accurately tracked in USD terms using oracle prices.
 *
 * 4. NO BYPASS MECHANISMS: Multiple small transactions cannot be used to bypass the limit -
 *    all outflows accumulate regardless of transaction count or user.
 */

/**
 * @title Outflow Volume Limiter Assertion
 * @notice Ensures the total value of assets leaving the protocol within any time window cannot exceed configured limits
 * @dev This assertion verifies that:
 *      1. Cumulative outflow volume is tracked correctly
 *      2. Time window resets are applied properly
 *      3. USD-based limits are enforced consistently
 *      4. No single transaction can bypass the outflow limits
 *      5. The limit cannot be manipulated through multiple transactions
 */
contract OutflowLimiterAssertion is Assertion {
    /**
     * @notice Register triggers for outflow volume monitoring
     * @dev Triggers on operations that result in assets leaving the protocol
     */
    function triggers() external view override {
        // Monitor outflows during borrow operations
        registerCallTrigger(this.assertionBorrowOutflowLimit.selector, IOperatorDefender.beforeMTokenBorrow.selector);

        // Monitor outflows during redeem operations
        registerCallTrigger(this.assertionRedeemOutflowLimit.selector, IOperatorDefender.beforeMTokenRedeem.selector);

        // Monitor cumulative outflow tracking
        registerCallTrigger(this.assertionCumulativeOutflowTracking.selector, IOperatorDefender.beforeMTokenBorrow.selector);
        registerCallTrigger(this.assertionCumulativeOutflowTracking.selector, IOperatorDefender.beforeMTokenRedeem.selector);

        // Monitor time window reset logic
        registerCallTrigger(this.assertionTimeWindowReset.selector, IOperatorDefender.beforeMTokenBorrow.selector);
        registerCallTrigger(this.assertionTimeWindowReset.selector, IOperatorDefender.beforeMTokenRedeem.selector);
    }

    /**
     * @notice Assert that borrow operations respect outflow limits
     * @dev Verifies that borrowing doesn't exceed the USD-based outflow limit
     */
    function assertionBorrowOutflowLimit() external {
        IOperator operator = IOperator(ph.getAssertionAdopter());
        IOracleOperator oracle = IOracleOperator(operator.oracleOperator());

        // Get the configured limit
        uint256 limitPerTimePeriod = operator.limitPerTimePeriod();

        // Skip if limit is disabled (0 means no limit)
        if (limitPerTimePeriod == 0) {
            return;
        }

        // Get all borrow calls in this transaction
        PhEvm.CallInputs[] memory borrowCalls =
            ph.getCallInputs(address(operator), IOperatorDefender.beforeMTokenBorrow.selector);

        for (uint256 i = 0; i < borrowCalls.length; i++) {
            (address mToken, address borrower, uint256 borrowAmount) =
                abi.decode(borrowCalls[i].input, (address, address, uint256));

            // Get the USD value of the borrow amount
            uint256 price = oracle.getUnderlyingPrice(mToken);
            require(price > 0, "Invalid oracle price for outflow calculation");

            // Calculate USD value (price is scaled by 1e18, amount by token decimals)
            uint256 borrowValueUSD = (borrowAmount * price) / 1e18;

            // Check cumulative outflow before and after
            ph.forkPreCall(borrowCalls[i].id);
            uint256 cumulativeOutflowBefore = operator.cumulativeOutflowVolume();

            ph.forkPostCall(borrowCalls[i].id);
            uint256 cumulativeOutflowAfter = operator.cumulativeOutflowVolume();

            // Verify that the outflow was properly tracked
            if (cumulativeOutflowAfter > cumulativeOutflowBefore) {
                uint256 outflowIncrease = cumulativeOutflowAfter - cumulativeOutflowBefore;

                // The increase should match the borrowed value (with some tolerance for rounding)
                // Why 0.1% tolerance:
                // - Oracle price conversions and integer division can introduce small rounding errors
                // - 0.1% is small enough to catch significant tracking errors
                // - But large enough to avoid false positives from legitimate rounding
                uint256 tolerance = borrowValueUSD / 1000; // 0.1% tolerance
                require(
                    outflowIncrease >= borrowValueUSD - tolerance &&
                    outflowIncrease <= borrowValueUSD + tolerance,
                    "Outflow tracking mismatch for borrow"
                );
            }

            // Verify the limit is not exceeded
            require(cumulativeOutflowAfter <= limitPerTimePeriod, "Borrow would exceed outflow limit");
        }
    }

    /**
     * @notice Assert that redeem operations respect outflow limits
     * @dev Verifies that redemptions don't exceed the USD-based outflow limit
     */
    function assertionRedeemOutflowLimit() external {
        IOperator operator = IOperator(ph.getAssertionAdopter());
        IOracleOperator oracle = IOracleOperator(operator.oracleOperator());

        // Get the configured limit
        uint256 limitPerTimePeriod = operator.limitPerTimePeriod();

        // Skip if limit is disabled
        if (limitPerTimePeriod == 0) {
            return;
        }

        // Get all redeem calls in this transaction
        PhEvm.CallInputs[] memory redeemCalls =
            ph.getCallInputs(address(operator), IOperatorDefender.beforeMTokenRedeem.selector);

        for (uint256 i = 0; i < redeemCalls.length; i++) {
            (address mToken, address redeemer, uint256 redeemTokens) =
                abi.decode(redeemCalls[i].input, (address, address, uint256));

            // Calculate the underlying amount being redeemed
            uint256 exchangeRate = ImToken(mToken).exchangeRateStored();
            uint256 redeemAmount = (redeemTokens * exchangeRate) / 1e18;

            // Get the USD value of the redeem amount
            uint256 price = oracle.getUnderlyingPrice(mToken);
            require(price > 0, "Invalid oracle price for outflow calculation");

            uint256 redeemValueUSD = (redeemAmount * price) / 1e18;

            // Check cumulative outflow before and after
            ph.forkPreCall(redeemCalls[i].id);
            uint256 cumulativeOutflowBefore = operator.cumulativeOutflowVolume();

            ph.forkPostCall(redeemCalls[i].id);
            uint256 cumulativeOutflowAfter = operator.cumulativeOutflowVolume();

            // Verify that the outflow was properly tracked
            if (cumulativeOutflowAfter > cumulativeOutflowBefore) {
                uint256 outflowIncrease = cumulativeOutflowAfter - cumulativeOutflowBefore;

                // The increase should match the redeemed value (with some tolerance for rounding)
                uint256 tolerance = redeemValueUSD / 1000; // 0.1% tolerance
                require(
                    outflowIncrease >= redeemValueUSD - tolerance &&
                    outflowIncrease <= redeemValueUSD + tolerance,
                    "Outflow tracking mismatch for redeem"
                );
            }

            // Verify the limit is not exceeded
            require(cumulativeOutflowAfter <= limitPerTimePeriod, "Redeem would exceed outflow limit");
        }
    }

    /**
     * @notice Assert that cumulative outflow is tracked correctly across operations
     * @dev Verifies that the cumulative outflow volume is monotonically increasing within a time window
     */
    function assertionCumulativeOutflowTracking() external {
        IOperator operator = IOperator(ph.getAssertionAdopter());

        // Get the configured limit
        uint256 limitPerTimePeriod = operator.limitPerTimePeriod();

        // Skip if limit is disabled
        if (limitPerTimePeriod == 0) {
            return;
        }

        // Check pre-transaction state
        ph.forkPreTx();
        uint256 cumulativeOutflowStart = operator.cumulativeOutflowVolume();
        uint256 lastResetTimestampStart = operator.lastOutflowResetTimestamp();
        uint256 timeWindow = operator.outflowResetTimeWindow();

        // Check post-transaction state
        ph.forkPostTx();
        uint256 cumulativeOutflowEnd = operator.cumulativeOutflowVolume();
        uint256 lastResetTimestampEnd = operator.lastOutflowResetTimestamp();

        // If no reset occurred, cumulative outflow should only increase or stay the same
        if (lastResetTimestampEnd == lastResetTimestampStart) {
            require(
                cumulativeOutflowEnd >= cumulativeOutflowStart,
                "Cumulative outflow decreased without reset"
            );
        }

        // If a reset occurred, verify it was legitimate (time window passed)
        if (lastResetTimestampEnd > lastResetTimestampStart) {
            // The reset should only happen if enough time has passed
            require(
                block.timestamp >= lastResetTimestampStart + timeWindow,
                "Outflow reset occurred before time window expired"
            );

            // After reset, cumulative outflow should start from 0 (or the new transaction's value)
            require(
                cumulativeOutflowEnd <= limitPerTimePeriod,
                "Cumulative outflow exceeds limit after reset"
            );
        }

        // The cumulative outflow should never exceed the limit
        require(cumulativeOutflowEnd <= limitPerTimePeriod, "Cumulative outflow exceeds configured limit");
    }

    /**
     * @notice Assert that time window resets are applied correctly
     * @dev Verifies that the outflow volume resets properly when the time window expires
     */
    function assertionTimeWindowReset() external {
        IOperator operator = IOperator(ph.getAssertionAdopter());

        // Get the configured parameters
        uint256 limitPerTimePeriod = operator.limitPerTimePeriod();
        uint256 timeWindow = operator.outflowResetTimeWindow();

        // Skip if limit is disabled
        if (limitPerTimePeriod == 0) {
            return;
        }

        // Check if a reset should have occurred
        ph.forkPreTx();
        uint256 lastResetTimestampBefore = operator.lastOutflowResetTimestamp();
        uint256 cumulativeOutflowBefore = operator.cumulativeOutflowVolume();

        ph.forkPostTx();
        uint256 lastResetTimestampAfter = operator.lastOutflowResetTimestamp();
        uint256 cumulativeOutflowAfter = operator.cumulativeOutflowVolume();

        // If enough time has passed since last reset
        if (block.timestamp >= lastResetTimestampBefore + timeWindow) {
            // Edge case: A reset should have occurred if there was any outflow operation
            // This catches bugs where the reset logic might be bypassed or not triggered properly
            PhEvm.CallInputs[] memory borrowCalls =
                ph.getCallInputs(address(operator), IOperatorDefender.beforeMTokenBorrow.selector);
            PhEvm.CallInputs[] memory redeemCalls =
                ph.getCallInputs(address(operator), IOperatorDefender.beforeMTokenRedeem.selector);

            bool hasOutflowOperation = borrowCalls.length > 0 || redeemCalls.length > 0;

            if (hasOutflowOperation) {
                // If there was an operation and time window expired, reset should have occurred
                require(
                    lastResetTimestampAfter >= block.timestamp,
                    "Outflow reset timestamp not updated after time window expired"
                );

                // After reset, the cumulative volume should only contain the current transaction's outflow
                // It should be less than or equal to what it was before (unless new outflows were added)
                require(
                    cumulativeOutflowAfter <= limitPerTimePeriod,
                    "Cumulative outflow not properly reset after time window"
                );
            }
        } else {
            // If time window hasn't expired, no reset should occur
            require(
                lastResetTimestampAfter == lastResetTimestampBefore,
                "Outflow reset occurred before time window expired"
            );
        }

        // Verify time window is reasonable (between 1 minute and 7 days)
        require(timeWindow >= 60, "Time window too short (less than 1 minute)");
        require(timeWindow <= 7 days, "Time window too long (more than 7 days)");
    }
}