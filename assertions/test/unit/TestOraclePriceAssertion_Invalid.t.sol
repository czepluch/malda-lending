// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {OraclePriceAssertion} from "../../src/OraclePriceAssertion.a.sol";
import {BaseAssertionTest} from "./BaseAssertionTest.t.sol";
import {MockOperatorVulnerable} from "../mocks/MockOperatorVulnerable.sol";
import {MockOracleVulnerable} from "../mocks/MockOracleVulnerable.sol";
import {MockMTokenVulnerable} from "../mocks/MockMTokenVulnerable.sol";
import {BatchPriceManipulator} from "../batch/BatchPriceManipulator.sol";
import {console} from "forge-std/console.sol";

/**
 * @title Oracle Price Assertion Tests - Invalid (Unhappy Path)
 * @notice Tests for oracle price assertions that should catch protocol violations
 * @dev These tests use MockOperatorVulnerable and MockOracleVulnerable to simulate vulnerable behavior
 */
contract TestOraclePriceAssertion_Invalid is BaseAssertionTest {
    OraclePriceAssertion public assertion;
    MockOperatorVulnerable public mockOperator;
    MockOracleVulnerable public mockOracle;
    MockMTokenVulnerable public mockMTokenVuln;
    BatchPriceManipulator public batchManipulator;

    address public constant MOCK_MTOKEN = address(0x1234567890123456789012345678901234567890);

    function setUp() public override {
        super.setUp();
        assertion = new OraclePriceAssertion();
        mockOperator = new MockOperatorVulnerable();
        mockOracle = new MockOracleVulnerable();
        mockMTokenVuln = new MockMTokenVulnerable(address(mockOperator), address(0), address(0));
        batchManipulator = new BatchPriceManipulator();

        // Connect mock oracle to mock operator
        mockOperator.setOracleAddress(address(mockOracle));

        // Setup default users
        mockOperator.setWhitelistedUser(alice, true);
        mockOperator.setWhitelistedUser(bob, true);
    }

    // ============ Borrow Price Sanity Tests ============

    function testBorrowPriceSanity_ZeroPrice_CaughtByAssertion() public {
        // Setup: Oracle returns zero price (vulnerable behavior)
        mockOracle.setReturnZeroPrice(true);
        mockOracle.setPriceOverride(MOCK_MTOKEN, 0);

        // Mock operator allows borrow despite zero price
        mockOperator.setBypassBorrowLiquidityCheck(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionBorrowPriceSanity.selector
        });

        // Expect assertion to catch zero price
        vm.expectRevert("Oracle price cannot be zero");
        mockOperator.beforeMTokenBorrow(MOCK_MTOKEN, alice, 100e6);
    }

    function testBorrowPriceSanity_StalePrice_CaughtByAssertion() public {
        // Setup: Oracle returns stale price (8 days old)
        mockOracle.setReturnStalePrice(true);

        // Warp time forward first to avoid underflow
        vm.warp(block.timestamp + 10 days);

        // Now set staleness to 8 days ago
        mockOracle.setStalenessOverride(MOCK_MTOKEN, block.timestamp - 8 days);

        // Mock operator allows borrow despite stale price
        mockOperator.setBypassBorrowLiquidityCheck(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionBorrowPriceSanity.selector
        });

        // Assertion should catch the stale price
        vm.expectRevert("Oracle price is stale");
        mockOperator.beforeMTokenBorrow(MOCK_MTOKEN, alice, 100e6);
    }

    // ============ Intra-Transaction Price Stability Tests ============

    /**
     * @notice Test that assertion catches intra-transaction price changes during borrow
     * @dev Uses batch contract to simulate price manipulation mid-transaction
     */
    function testBorrowPriceStability_IntraTxPriceChange_CaughtByAssertion() public {
        // Setup: Set initial price
        uint256 initialPrice = 1e30; // $1 with 30 decimals
        mockOracle.setPriceOverride(MOCK_MTOKEN, initialPrice);

        // Allow the borrow to bypass liquidity checks (we're testing price stability, not liquidity)
        mockOperator.setBypassBorrowLiquidityCheck(true);

        // Register assertion for price stability
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionBorrowPriceStability.selector
        });

        // Calculate a price with >5% deviation (e.g., 10% increase)
        uint256 manipulatedPrice = (initialPrice * 110) / 100; // 10% increase

        // Execute batch operation that manipulates price mid-transaction
        // The assertion should detect the >5% deviation and revert
        vm.expectRevert("Oracle price deviated too much during borrow operation");
        batchManipulator.executeBorrowWithPriceChange(
            mockOperator,
            mockOracle,
            MOCK_MTOKEN,
            alice,
            1000e6, // borrow amount
            manipulatedPrice
        );
    }

    /**
     * @notice Test that assertion allows price changes within threshold
     * @dev Validates batch contract works correctly when price change is <5%
     */
    function testBorrowPriceStability_WithinThreshold_Passes() public {
        // Setup: Set initial price
        uint256 initialPrice = 1e30; // $1 with 30 decimals
        mockOracle.setPriceOverride(MOCK_MTOKEN, initialPrice);

        // Allow the borrow to bypass liquidity checks
        mockOperator.setBypassBorrowLiquidityCheck(true);

        // Register assertion for price stability
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionBorrowPriceStability.selector
        });

        // Calculate a price with <5% deviation (e.g., 3% increase - well within threshold)
        uint256 acceptablePrice = (initialPrice * 103) / 100; // 3% increase

        // Execute batch operation with acceptable price change
        // The assertion should NOT revert because change is within 5% threshold
        batchManipulator.executeBorrowWithPriceChange(
            mockOperator,
            mockOracle,
            MOCK_MTOKEN,
            alice,
            1000e6, // borrow amount
            acceptablePrice
        );

        // If we get here, the test passed - assertion allowed the operation
    }

    /**
     * @notice Test that assertion catches multiple price updates that cumulatively exceed threshold
     * @dev Tests that gradual price stepping attack is detected
     */
    function testBorrowPriceStability_MultiplePriceChanges_CaughtByAssertion() public {
        // Setup: Set initial price
        uint256 initialPrice = 1e30; // $1 with 30 decimals
        mockOracle.setPriceOverride(MOCK_MTOKEN, initialPrice);

        // Allow the borrow to bypass liquidity checks
        mockOperator.setBypassBorrowLiquidityCheck(true);

        // Register assertion for price stability
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionBorrowPriceStability.selector
        });

        // Create array of 5 price changes
        // Each step is ~2% increase, but cumulative is 10% (exceeds 5% threshold)
        uint256[] memory prices = new uint256[](5);
        prices[0] = (initialPrice * 102) / 100; // $1.02 (+2%)
        prices[1] = (initialPrice * 104) / 100; // $1.04 (+4% from initial)
        prices[2] = (initialPrice * 106) / 100; // $1.06 (+6% from initial) <- exceeds threshold
        prices[3] = (initialPrice * 108) / 100; // $1.08 (+8% from initial)
        prices[4] = (initialPrice * 110) / 100; // $1.10 (+10% from initial)

        // Execute batch operation with multiple price changes
        // The assertion should detect deviation once cumulative change exceeds 5%
        vm.expectRevert("Oracle price deviated too much during borrow operation");
        batchManipulator.executeBorrowWithMultiplePriceChanges(
            mockOperator,
            mockOracle,
            MOCK_MTOKEN,
            alice,
            1000e6, // borrow amount
            prices
        );
    }

    // ============ Multiple Calls Path Tests (Else Branch) ============

    /**
     * @notice Test multiple borrow calls with price manipulation - caught by assertion
     * @dev This triggers the ELSE branch in assertionBorrowPriceStability (borrowCalls.length > 1)
     * @dev Uses forkPostCall() instead of forkPostTx() to check each call individually
     */
    function testBorrowPriceStability_MultipleCalls_PriceDeviation_CaughtByAssertion() public {
        // Setup: Set initial price
        uint256 initialPrice = 1e30; // $1 with 30 decimals
        mockOracle.setPriceOverride(MOCK_MTOKEN, initialPrice);

        // Allow borrows to bypass liquidity checks
        mockOperator.setBypassBorrowLiquidityCheck(true);

        // Register assertion for price stability
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionBorrowPriceStability.selector
        });

        // Calculate a price with >5% deviation (10% increase)
        uint256 manipulatedPrice = (initialPrice * 110) / 100;

        // Execute batch with TWO borrow calls - triggers else branch
        // The assertion should check each call individually using forkPostCall()
        vm.expectRevert("Oracle price deviated too much during borrow operation");
        batchManipulator.executeMultipleBorrowsWithPriceManipulation(
            mockOperator,
            mockOracle,
            MOCK_MTOKEN,
            alice, // borrower 1
            500e6, // borrow amount 1
            bob, // borrower 2
            500e6, // borrow amount 2
            manipulatedPrice
        );
    }

    /**
     * @notice Test multiple borrow calls with price change within threshold - passes
     * @dev Validates multiple-calls path works correctly when price change is <5%
     */
    function testBorrowPriceStability_MultipleCalls_WithinThreshold_Passes() public {
        // Setup: Set initial price
        uint256 initialPrice = 1e30; // $1 with 30 decimals
        mockOracle.setPriceOverride(MOCK_MTOKEN, initialPrice);

        // Allow borrows to bypass liquidity checks
        mockOperator.setBypassBorrowLiquidityCheck(true);

        // Calculate a price with <5% deviation (3% increase)
        uint256 acceptablePrice = (initialPrice * 103) / 100;

        // Register assertion for price stability
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionBorrowPriceStability.selector
        });

        // Execute batch with TWO borrow calls - should NOT revert
        batchManipulator.executeMultipleBorrowsWithPriceManipulation(
            mockOperator,
            mockOracle,
            MOCK_MTOKEN,
            alice, // borrower 1
            500e6, // borrow amount 1
            bob, // borrower 2
            500e6, // borrow amount 2
            acceptablePrice
        );
    }

    /**
     * @notice Test three borrow calls with gradual price manipulation
     * @dev Tests that assertion checks each call against initial state, not previous call state
     * @dev Important: Each call is checked against PreTx, not against previous PostCall state
     */
    function testBorrowPriceStability_ThreeCalls_GradualManipulation_CaughtByAssertion() public {
        // Setup: Set initial price
        uint256 initialPrice = 1e30; // $1 with 30 decimals
        mockOracle.setPriceOverride(MOCK_MTOKEN, initialPrice);

        // Allow borrows to bypass liquidity checks
        mockOperator.setBypassBorrowLiquidityCheck(true);

        // Create gradual price changes
        uint256 price2 = (initialPrice * 103) / 100; // +3% (within threshold)
        uint256 price3 = (initialPrice * 107) / 100; // +7% from initial (exceeds threshold)

        // Register assertion for price stability
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionBorrowPriceStability.selector
        });

        // Execute batch with THREE borrow calls
        // First call: price at initialPrice (should pass)
        // Second call: price at +3% (should pass, within 5% of initial)
        // Third call: price at +7% (should FAIL, exceeds 5% of initial)
        vm.expectRevert("Oracle price deviated too much during borrow operation");
        batchManipulator.executeThreeBorrowsWithGradualManipulation(
            mockOperator,
            mockOracle,
            MOCK_MTOKEN,
            alice, // borrower 1
            300e6, // borrow amount 1
            bob, // borrower 2
            300e6, // borrow amount 2
            address(0xCAFE), // borrower 3
            400e6, // borrow amount 3
            price2,
            price3
        );
    }
}
