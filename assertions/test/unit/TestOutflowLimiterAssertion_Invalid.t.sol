// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseAssertionTest} from "./BaseAssertionTest.t.sol";
import {OutflowLimiterAssertion} from "../../src/OutflowLimiterAssertion.a.sol";
import {MockOperatorVulnerable} from "../mocks/MockOperatorVulnerable.sol";
import {MockOracleVulnerable} from "../mocks/MockOracleVulnerable.sol";
import {BatchOutflowBypass} from "../batch/BatchOutflowBypass.sol";

/**
 * @title Outflow Limiter Assertion Invalid Tests
 * @notice Tests for OutflowLimiterAssertion using mock contracts (unhappy path)
 * @dev These tests verify assertions catch protocol violations
 */
contract TestOutflowLimiterAssertion_Invalid is BaseAssertionTest {
    MockOperatorVulnerable public mockOperator;
    MockOracleVulnerable public mockOracle;
    BatchOutflowBypass public batchBypass;

    function setUp() public override {
        super.setUp();

        mockOracle = new MockOracleVulnerable();

        mockOperator = new MockOperatorVulnerable();
        mockOperator.setOracleAddress(address(mockOracle));

        // Set limit in e14 format to match (amount * 1e18) / 1e10 calculation
        // 1000e14 = 1000 USD limit (for 6-decimal tokens like USDC)
        mockOperator.setLimitPerTimePeriod(1000e18);
        mockOperator.setOutflowResetTimeWindow(1 days);
        mockOperator.setLastOutflowResetTimestamp(block.timestamp);
        mockOperator.setCumulativeOutflowVolume(0);

        mockOracle.setPriceOverride(address(0x123), 1e18);

        batchBypass = new BatchOutflowBypass();
    }

    /**
     * @notice Test that assertion catches borrow exceeding limit
     * @dev Single large borrow that exceeds configured limit
     */
    function testBorrowOutflowLimit_ExceedsLimit_CaughtByAssertion() public {
        // Set cumulative outflow near limit
        mockOperator.setCumulativeOutflowVolume(900e18); // $900

        // Enable bypass so borrow proceeds despite limit
        mockOperator.setBypassBorrowLiquidityCheck(true);
        mockOperator.setAllowOutflowExceedLimit(true);

        // Manually set cumulative to exceed limit after this borrow
        // Real operator would enforce this, but mock bypasses it
        mockOperator.setCumulativeOutflowVolume(1100e18); // Would be $1100 after borrow

        // Register assertion
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(OutflowLimiterAssertion).creationCode,
            fnSelector: OutflowLimiterAssertion.assertionBorrowOutflowLimit.selector
        });

        // Try to borrow $200 (would exceed $1000 limit)
        vm.expectRevert("Borrow would exceed outflow limit");
        mockOperator.beforeMTokenBorrow(address(0x123), alice, 200e18);
    }

    /**
     * @notice Test that assertion catches decreasing cumulative outflow
     * @dev Cumulative should only increase within a time window
     */
    function testCumulativeTracking_Decreases_CaughtByAssertion() public {
        // Start with some cumulative outflow
        mockOperator.setCumulativeOutflowVolume(500e18);

        // Enable vulnerability that makes cumulative decrease
        mockOperator.setAllowCumulativeDecrease(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(OutflowLimiterAssertion).creationCode,
            fnSelector: OutflowLimiterAssertion.assertionCumulativeOutflowTracking.selector
        });

        // The mock will return decreased value (499e18 due to vulnerability flag)
        // Assertion should catch this
        vm.expectRevert("Cumulative outflow decreased without reset");
        mockOperator.beforeMTokenBorrow(address(0x123), alice, 10e18);
    }

    /**
     * @notice Test that assertion catches early reset
     * @dev Reset should only occur after time window expires
     */
    function testTimeWindowReset_EarlyReset_CaughtByAssertion() public {
        // Set initial state
        uint256 resetTime = block.timestamp;
        mockOperator.setLastOutflowResetTimestamp(resetTime);
        mockOperator.setCumulativeOutflowVolume(500e18);

        // Advance time but NOT past the window (only 12 hours, window is 1 day)
        vm.warp(block.timestamp + 12 hours);

        // Enable early reset vulnerability
        // This will cause _checkOutflowVolumeLimit to reset during the borrow call
        mockOperator.setAllowEarlyReset(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(OutflowLimiterAssertion).creationCode,
            fnSelector: OutflowLimiterAssertion.assertionTimeWindowReset.selector
        });

        // The borrow will trigger early reset (timestamp changes despite window not expiring)
        // Assertion should catch this
        vm.expectRevert("Outflow reset occurred before time window expired");
        mockOperator.beforeMTokenBorrow(address(0x123), alice, 10e18);
    }

    /**
     * @notice Test that assertion catches missing reset after expiry
     * @dev When window expires and there's an operation, reset should occur
     */
    function testTimeWindowReset_NoResetAfterExpiry_CaughtByAssertion() public {
        // Set initial state
        uint256 resetTime = block.timestamp;
        mockOperator.setLastOutflowResetTimestamp(resetTime);
        mockOperator.setCumulativeOutflowVolume(900e18); // Near limit

        // Advance time past the window
        vm.warp(block.timestamp + 1 days + 1);

        // Enable vulnerability: skip reset even though window expired
        mockOperator.setSkipResetAfterExpiry(true);
        // Don't update timestamp (simulating missing reset)

        // Register assertion
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(OutflowLimiterAssertion).creationCode,
            fnSelector: OutflowLimiterAssertion.assertionTimeWindowReset.selector
        });

        // Assertion should catch that reset didn't occur
        vm.expectRevert("Outflow reset timestamp not updated after time window expired");
        mockOperator.beforeMTokenBorrow(address(0x123), alice, 10e18);
    }

    /**
     * @notice Test that assertion catches outflow tracking mismatch
     * @dev Tracked value should match actual outflow
     */
    function testOutflowTracking_Mismatch_CaughtByAssertion() public {
        mockOperator.setCumulativeOutflowVolume(100e18);

        // Enable mismatch vulnerability (mock returns half the real value)
        mockOperator.setMismatchOutflowTracking(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(OutflowLimiterAssertion).creationCode,
            fnSelector: OutflowLimiterAssertion.assertionBorrowOutflowLimit.selector
        });

        // Mock will return wrong cumulative value (50e18 instead of actual value)
        // After borrow of $100, increase should be $100 but mock reports less
        // Set post-state manually to simulate mismatch
        vm.expectRevert("Outflow tracking mismatch for borrow");
        mockOperator.beforeMTokenBorrow(address(0x123), alice, 100e18);
    }

    /**
     * @notice Test that assertion catches exceeding limit after reset
     * @dev Even after reset, operations must respect the limit
     */
    function testCumulativeTracking_ExceedsAfterReset_CaughtByAssertion() public {
        // Simulate a reset just happened
        mockOperator.setLastOutflowResetTimestamp(block.timestamp);
        mockOperator.setCumulativeOutflowVolume(0);

        // Enable vulnerability allowing excess
        mockOperator.setAllowOutflowExceedLimit(true);

        // Set cumulative to exceed limit
        mockOperator.setCumulativeOutflowVolume(1500e18); // Exceeds $1000 limit

        // Register assertion
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(OutflowLimiterAssertion).creationCode,
            fnSelector: OutflowLimiterAssertion.assertionCumulativeOutflowTracking.selector
        });

        // Assertion should catch limit exceeded even after reset
        vm.expectRevert("Cumulative outflow exceeds configured limit");
        mockOperator.beforeMTokenBorrow(address(0x123), alice, 1500e18);
    }

    /**
     * @notice Test that assertion enforces time window bounds
     * @dev Time window must be between 1 minute and 7 days
     */
    function testTimeWindowReset_TooShort_CaughtByAssertion() public {
        // Set unreasonable time window (30 seconds)
        mockOperator.setOutflowResetTimeWindow(30);

        // Register assertion
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(OutflowLimiterAssertion).creationCode,
            fnSelector: OutflowLimiterAssertion.assertionTimeWindowReset.selector
        });

        // Assertion should catch unreasonable time window
        vm.expectRevert("Time window too short (less than 1 minute)");
        mockOperator.beforeMTokenBorrow(address(0x123), alice, 10e18);
    }

    function testTimeWindowReset_TooLong_CaughtByAssertion() public {
        // Set unreasonable time window (30 days)
        mockOperator.setOutflowResetTimeWindow(30 days);

        // Register assertion
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(OutflowLimiterAssertion).creationCode,
            fnSelector: OutflowLimiterAssertion.assertionTimeWindowReset.selector
        });

        // Assertion should catch unreasonable time window
        vm.expectRevert("Time window too long (more than 7 days)");
        mockOperator.beforeMTokenBorrow(address(0x123), alice, 10e18);
    }

    /**
     * @notice Test that multiple small transactions within limit pass
     * @dev Verifies that multiple small borrows under cumulative limit are allowed
     */
    function testMultipleSmallTransactions_WithinLimit_Passes() public {
        mockOperator.setCumulativeOutflowVolume(0);
        mockOperator.setBypassBorrowLiquidityCheck(true);

        cl.assertion({
            adopter: address(mockOperator),
            createData: type(OutflowLimiterAssertion).creationCode,
            fnSelector: OutflowLimiterAssertion.assertionBorrowOutflowLimit.selector
        });

        // 3 × $300 = $900 total, under $1000 limit
        batchBypass.executeMultipleSmallBorrows(
            mockOperator,
            address(0x123),
            alice,
            300e18, // $300 (e18 format for operator-based assertion)
            3
        );
    }

    /**
     * @notice Test that assertion catches multiple small transactions bypassing limit
     * @dev Simulates an attacker making many small borrows to bypass outflow limits
     * @dev Each individual borrow is under the limit, but cumulative exceeds it
     */
    function testMultipleSmallTransactions_BypassAttempt_CaughtByAssertion() public {
        mockOperator.setCumulativeOutflowVolume(0);
        mockOperator.setBypassBorrowLiquidityCheck(true);
        mockOperator.setAllowOutflowExceedLimit(true);

        cl.assertion({
            adopter: address(mockOperator),
            createData: type(OutflowLimiterAssertion).creationCode,
            fnSelector: OutflowLimiterAssertion.assertionBorrowOutflowLimit.selector
        });

        // 3 × $400 = $1200 total, exceeds $1000 limit on 3rd call
        vm.expectRevert("Borrow would exceed outflow limit");
        batchBypass.executeMultipleSmallBorrows(
            mockOperator,
            address(0x123),
            alice,
            400e18, // $400 (e18 format for operator-based assertion)
            3
        );
    }
}
