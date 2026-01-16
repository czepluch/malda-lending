// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CredibleTest} from "credible-std/CredibleTest.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {mTokenLiquidationAssertion} from "../../src/mTokenLiquidationAssertion.a.sol";
import {BaseAssertionTest} from "./BaseAssertionTest.t.sol";
import {MockOracleVulnerable} from "../mocks/MockOracleVulnerable.sol";
import {MockMTokenVulnerable} from "../mocks/MockMTokenVulnerable.sol";
import {MockOperatorVulnerable} from "../mocks/MockOperatorVulnerable.sol";
import {BatchPriceManipulator} from "../batch/BatchPriceManipulator.sol";

/**
 * @title mToken Liquidation Assertion Tests - Invalid (Unhappy Path)
 * @notice Tests for liquidation price assertions using ImErc20.liquidate() as trigger
 * @dev These tests verify that mTokenLiquidationAssertion properly detects price manipulation
 *      during liquidation operations by triggering on the non-view liquidate() function
 */
contract TestmTokenLiquidationAssertion_Invalid is BaseAssertionTest {
    mTokenLiquidationAssertion public assertion;
    MockOracleVulnerable public mockOracle;
    MockMTokenVulnerable public mockMTokenBorrowed;
    MockMTokenVulnerable public mockMTokenCollateral;
    MockOperatorVulnerable public mockOperator;
    BatchPriceManipulator public batchManipulator;

    address constant BORROWED_TOKEN_ADDR = address(0x1111111111111111111111111111111111111111);
    address constant COLLATERAL_TOKEN_ADDR = address(0x2222222222222222222222222222222222222222);

    function setUp() public override {
        super.setUp();

        // Deploy mocks
        mockOperator = new MockOperatorVulnerable();
        mockOracle = new MockOracleVulnerable();

        // Create mTokens with mock operator and oracle
        mockMTokenBorrowed = new MockMTokenVulnerable(
            address(mockOperator),
            BORROWED_TOKEN_ADDR,
            address(0) // interestRateModel not needed for price tests
        );

        mockMTokenCollateral = new MockMTokenVulnerable(
            address(mockOperator),
            COLLATERAL_TOKEN_ADDR,
            address(0) // interestRateModel not needed for price tests
        );

        // Configure operator to use oracle
        mockOperator.setOracleAddress(address(mockOracle));

        // Deploy batch manipulator
        batchManipulator = new BatchPriceManipulator();

        // Setup mock with reasonable defaults
        mockOperator.setWhitelistedUser(alice, true);
        mockOperator.setWhitelistedUser(bob, true);

        // Allow liquidations to bypass liquidity checks for these tests
        mockOperator.setBypassLiquidationLiquidityCheck(true);
    }

    // ============ Single Liquidation Call Tests ============

    /**
     * @notice Test that assertion catches intra-transaction price manipulation during liquidation
     * @dev Price changes >5% mid-transaction, assertion should revert
     */
    function testLiquidationPriceStability_IntraTxPriceChange_CaughtByAssertion() public {
        // Setup: Set initial prices for both tokens
        uint256 borrowedInitialPrice = 1e30; // $1 with 30 decimals
        uint256 collateralInitialPrice = 2e30; // $2 with 30 decimals
        mockOracle.setPriceOverride(address(mockMTokenBorrowed), borrowedInitialPrice);
        mockOracle.setPriceOverride(address(mockMTokenCollateral), collateralInitialPrice);

        // Calculate manipulated prices with >5% deviation (10% increases)
        uint256 borrowedManipulatedPrice = (borrowedInitialPrice * 110) / 100; // 10% increase
        uint256 collateralManipulatedPrice = (collateralInitialPrice * 110) / 100; // 10% increase

        // Configure mToken to manipulate prices mid-execution (BEFORE registering assertion)
        mockMTokenBorrowed.setPriceManipulationDuringLiquidation(
            true, // enable manipulation
            address(mockOracle),
            borrowedManipulatedPrice,
            collateralManipulatedPrice,
            false // manipulate on every call (single-call test)
        );

        // Register assertion with mToken as adopter (not operator!)
        cl.assertion({
            adopter: address(mockMTokenBorrowed),
            createData: type(mTokenLiquidationAssertion).creationCode,
            fnSelector: mTokenLiquidationAssertion.assertionLiquidationPriceStability.selector
        });

        // Execute liquidation - should revert due to price manipulation
        vm.expectRevert("Borrowed token price deviated too much during liquidation");
        mockMTokenBorrowed.liquidate(alice, 1000e6, address(mockMTokenCollateral));
    }

    /**
     * @notice Test that assertion allows liquidation when price changes are within threshold
     * @dev Price changes <5% mid-transaction, assertion should NOT revert
     */
    function testLiquidationPriceStability_WithinThreshold_Passes() public {
        // Setup: Set initial prices for both tokens
        uint256 borrowedInitialPrice = 1e30; // $1 with 30 decimals
        uint256 collateralInitialPrice = 2e30; // $2 with 30 decimals
        mockOracle.setPriceOverride(address(mockMTokenBorrowed), borrowedInitialPrice);
        mockOracle.setPriceOverride(address(mockMTokenCollateral), collateralInitialPrice);

        // Calculate acceptable prices with <5% deviation (3% changes)
        uint256 borrowedAcceptablePrice = (borrowedInitialPrice * 103) / 100; // 3% increase
        uint256 collateralAcceptablePrice = (collateralInitialPrice * 97) / 100; // 3% decrease

        // Configure mToken to manipulate prices mid-execution (BEFORE registering assertion)
        mockMTokenBorrowed.setPriceManipulationDuringLiquidation(
            true, // enable manipulation
            address(mockOracle),
            borrowedAcceptablePrice,
            collateralAcceptablePrice,
            false // manipulate on every call (single-call test)
        );

        // Register assertion with mToken as adopter
        cl.assertion({
            adopter: address(mockMTokenBorrowed),
            createData: type(mTokenLiquidationAssertion).creationCode,
            fnSelector: mTokenLiquidationAssertion.assertionLiquidationPriceStability.selector
        });

        // Execute liquidation - should NOT revert because changes are within 5% threshold
        mockMTokenBorrowed.liquidate(alice, 1000e6, address(mockMTokenCollateral));

        // If we get here, the test passed - assertion allowed the operation
    }

    // ============ Multiple Liquidation Call Tests ============

    /**
     * @notice Test that assertion catches price deviation across multiple liquidation calls
     * @dev This triggers the multiple-calls path using forkPreTx/forkPostCall
     * @dev Uses batch contract to execute multiple liquidations in a SINGLE transaction
     */
    function testLiquidationPriceStability_MultipleCalls_PriceDeviation_CaughtByAssertion() public {
        // Setup: Set initial prices for both tokens
        uint256 borrowedInitialPrice = 1e30; // $1 with 30 decimals
        uint256 collateralInitialPrice = 2e30; // $2 with 30 decimals
        mockOracle.setPriceOverride(address(mockMTokenBorrowed), borrowedInitialPrice);
        mockOracle.setPriceOverride(address(mockMTokenCollateral), collateralInitialPrice);

        // Calculate manipulated prices with >5% deviation (10% increases)
        uint256 borrowedManipulatedPrice = (borrowedInitialPrice * 110) / 100; // 10% increase
        uint256 collateralManipulatedPrice = (collateralInitialPrice * 110) / 100; // 10% increase

        // Register assertion with mToken as adopter
        cl.assertion({
            adopter: address(mockMTokenBorrowed),
            createData: type(mTokenLiquidationAssertion).creationCode,
            fnSelector: mTokenLiquidationAssertion.assertionLiquidationPriceStability.selector
        });

        // Use batch contract to execute multiple liquidations with price manipulation between them
        // This executes both liquidations in a SINGLE transaction:
        // 1. First liquidation (alice) at initial prices
        // 2. Prices manipulated to 110% (10% increase - exceeds 5% threshold)
        // 3. Second liquidation (bob) should be caught comparing against initial prices
        vm.expectRevert("Borrowed token price deviated too much during liquidation");
        batchManipulator.executeMultipleLiquidationsWithPriceManipulation(
            mockMTokenBorrowed,
            mockOracle,
            address(mockMTokenCollateral),
            alice, // borrower1
            1000e6, // repayAmount1
            bob, // borrower2
            500e6, // repayAmount2
            borrowedManipulatedPrice,
            collateralManipulatedPrice
        );
    }

    /**
     * @notice Test that assertion allows multiple liquidations when price changes are within threshold
     * @dev Multiple calls with acceptable price changes should NOT revert
     * @dev Uses batch contract to execute multiple liquidations in a SINGLE transaction
     */
    function testLiquidationPriceStability_MultipleCalls_WithinThreshold_Passes() public {
        // Setup: Set initial prices for both tokens
        uint256 borrowedInitialPrice = 1e30; // $1 with 30 decimals
        uint256 collateralInitialPrice = 2e30; // $2 with 30 decimals
        mockOracle.setPriceOverride(address(mockMTokenBorrowed), borrowedInitialPrice);
        mockOracle.setPriceOverride(address(mockMTokenCollateral), collateralInitialPrice);

        // Calculate acceptable prices with <5% deviation (3% changes)
        uint256 borrowedAcceptablePrice = (borrowedInitialPrice * 103) / 100; // 3% increase
        uint256 collateralAcceptablePrice = (collateralInitialPrice * 97) / 100; // 3% decrease

        // Register assertion with mToken as adopter
        cl.assertion({
            adopter: address(mockMTokenBorrowed),
            createData: type(mTokenLiquidationAssertion).creationCode,
            fnSelector: mTokenLiquidationAssertion.assertionLiquidationPriceStability.selector
        });

        // Use batch contract to execute multiple liquidations with acceptable price changes
        // This executes both liquidations in a SINGLE transaction:
        // 1. First liquidation (alice) at initial prices
        // 2. Prices change to 103%/97% (within 5% threshold)
        // 3. Second liquidation (bob) - should pass because 3% deviation is acceptable
        batchManipulator.executeMultipleLiquidationsWithPriceManipulation(
            mockMTokenBorrowed,
            mockOracle,
            address(mockMTokenCollateral),
            alice, // borrower1
            1000e6, // repayAmount1
            bob, // borrower2
            500e6, // repayAmount2
            borrowedAcceptablePrice,
            collateralAcceptablePrice
        );

        // If we get here, the test passed - assertion allowed both operations
    }

    /**
     * @notice Test that assertion catches gradual price manipulation across three liquidation calls
     * @dev Tests that assertion checks each call against initial state, not previous call state
     * @dev Uses batch contract to execute three liquidations in a SINGLE transaction
     */
    function testLiquidationPriceStability_ThreeCalls_GradualManipulation_CaughtByAssertion() public {
        // Setup: Set initial prices for both tokens
        uint256 borrowedInitialPrice = 1e30; // $1 with 30 decimals
        uint256 collateralInitialPrice = 2e30; // $2 with 30 decimals
        mockOracle.setPriceOverride(address(mockMTokenBorrowed), borrowedInitialPrice);
        mockOracle.setPriceOverride(address(mockMTokenCollateral), collateralInitialPrice);

        // Calculate gradual price changes:
        // After 1st liquidation: 3% change (within 5% threshold - should pass)
        uint256 borrowedPrice2 = (borrowedInitialPrice * 103) / 100; // 3% increase
        uint256 collateralPrice2 = (collateralInitialPrice * 103) / 100; // 3% increase

        // After 2nd liquidation: 8% change from initial (exceeds 5% threshold - should fail)
        uint256 borrowedPrice3 = (borrowedInitialPrice * 108) / 100; // 8% increase
        uint256 collateralPrice3 = (collateralInitialPrice * 108) / 100; // 8% increase

        // Register assertion with mToken as adopter
        cl.assertion({
            adopter: address(mockMTokenBorrowed),
            createData: type(mTokenLiquidationAssertion).creationCode,
            fnSelector: mTokenLiquidationAssertion.assertionLiquidationPriceStability.selector
        });

        // Use batch contract to execute three liquidations with gradual manipulation
        // This executes all three liquidations in a SINGLE transaction:
        // 1. First liquidation (alice) at initial prices - passes
        // 2. Prices change to +3% (within 5% threshold)
        // 3. Second liquidation (bob) at +3% - still passes (checked against initial)
        // 4. Prices change to +8% (exceeds 5% threshold)
        // 5. Third liquidation (foo) at +8% - should be caught by assertion
        address[3] memory borrowers = [alice, bob, foo];
        uint256[3] memory repayAmounts = [uint256(1000e6), uint256(500e6), uint256(300e6)];
        uint256[2] memory borrowedPrices = [borrowedPrice2, borrowedPrice3];
        uint256[2] memory collateralPrices = [collateralPrice2, collateralPrice3];

        vm.expectRevert("Borrowed token price deviated too much during liquidation");
        batchManipulator.executeThreeLiquidationsWithGradualManipulation(
            mockMTokenBorrowed,
            mockOracle,
            address(mockMTokenCollateral),
            borrowers,
            repayAmounts,
            borrowedPrices,
            collateralPrices
        );
    }

    /**
     * @notice Test 10 liquidation calls with price manipulation and check assertion gas usage
     * @dev Tests assertion gas usage with 10 operations in a single transaction
     * @dev Uses prices within threshold (3% change) so operations pass
     */
    function testLiquidationPriceStability_10Transactions_CheckAssertionGasUsage() public {
        // Setup: Set initial prices for both tokens
        uint256 borrowedInitialPrice = 1e30; // $1 with 30 decimals
        uint256 collateralInitialPrice = 2e30; // $2 with 30 decimals
        mockOracle.setPriceOverride(address(mockMTokenBorrowed), borrowedInitialPrice);
        mockOracle.setPriceOverride(address(mockMTokenCollateral), collateralInitialPrice);

        // Calculate acceptable prices with <5% deviation (3% changes)
        uint256 borrowedAcceptablePrice = (borrowedInitialPrice * 103) / 100; // 3% increase
        uint256 collateralAcceptablePrice = (collateralInitialPrice * 103) / 100; // 3% increase

        // Setup 10 borrower addresses
        address[10] memory borrowers = [
            alice,
            bob,
            address(0xCAFE),
            address(0xBEEF),
            address(0xDEAD),
            address(0xFACE),
            address(0x1234),
            address(0x5678),
            address(0x9ABC),
            address(0xDEF0)
        ];

        // Setup 10 repay amounts (small amounts for gas testing)
        uint256[10] memory repayAmounts = [
            uint256(100e6),
            uint256(100e6),
            uint256(100e6),
            uint256(100e6),
            uint256(100e6),
            uint256(100e6),
            uint256(100e6),
            uint256(100e6),
            uint256(100e6),
            uint256(100e6)
        ];

        // Register assertion with mToken as adopter
        cl.assertion({
            adopter: address(mockMTokenBorrowed),
            createData: type(mTokenLiquidationAssertion).creationCode,
            fnSelector: mTokenLiquidationAssertion.assertionLiquidationPriceStability.selector
        });

        // Execute batch with 10 liquidation calls - should pass and check gas usage
        batchManipulator.executeTenLiquidationsWithPriceManipulation(
            mockMTokenBorrowed,
            mockOracle,
            address(mockMTokenCollateral),
            borrowers,
            repayAmounts,
            borrowedAcceptablePrice,
            collateralAcceptablePrice
        );
    }

    // ============ Price Sanity Tests ============

    /**
     * @notice Test that assertion catches zero borrowed token price during liquidation
     * @dev Price sanity checks should prevent liquidations with invalid oracle data
     */
    function testLiquidationPriceSanity_ZeroBorrowedPrice_CaughtByAssertion() public {
        // Setup: Set borrowed price to zero, collateral price valid
        mockOracle.setPriceOverride(address(mockMTokenBorrowed), 0);
        mockOracle.setPriceOverride(address(mockMTokenCollateral), 2e30);

        // Register assertion with mToken as adopter
        cl.assertion({
            adopter: address(mockMTokenBorrowed),
            createData: type(mTokenLiquidationAssertion).creationCode,
            fnSelector: mTokenLiquidationAssertion.assertionLiquidationPriceSanity.selector
        });

        // Attempt liquidation - should revert due to zero borrowed price
        vm.expectRevert("Borrowed token oracle price cannot be zero");
        mockMTokenBorrowed.liquidate(alice, 1000e6, address(mockMTokenCollateral));
    }

    /**
     * @notice Test that assertion catches zero collateral token price during liquidation
     * @dev Price sanity checks should prevent liquidations with invalid oracle data
     */
    function testLiquidationPriceSanity_ZeroCollateralPrice_CaughtByAssertion() public {
        // Setup: Set borrowed price valid, collateral price to zero
        mockOracle.setPriceOverride(address(mockMTokenBorrowed), 1e30);
        mockOracle.setPriceOverride(address(mockMTokenCollateral), 0);

        // Register assertion with mToken as adopter
        cl.assertion({
            adopter: address(mockMTokenBorrowed),
            createData: type(mTokenLiquidationAssertion).creationCode,
            fnSelector: mTokenLiquidationAssertion.assertionLiquidationPriceSanity.selector
        });

        // Attempt liquidation - should revert due to zero collateral price
        vm.expectRevert("Collateral token oracle price cannot be zero");
        mockMTokenBorrowed.liquidate(alice, 1000e6, address(mockMTokenCollateral));
    }
}
