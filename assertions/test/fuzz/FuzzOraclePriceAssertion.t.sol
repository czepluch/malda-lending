// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CredibleTest} from "credible-std/CredibleTest.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {OraclePriceAssertion} from "../../src/OraclePriceAssertion.a.sol";
import {BaseAssertionTest} from "../unit/BaseAssertionTest.t.sol";
import {mErc20Immutable} from "../../../src/mToken/mErc20Immutable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "../../../test/mocks/ERC20Mock.sol";
import {MockOperatorVulnerable} from "../mocks/MockOperatorVulnerable.sol";
import {MockOracleVulnerable} from "../mocks/MockOracleVulnerable.sol";
import {BatchPriceManipulator} from "../batch/BatchPriceManipulator.sol";

/**
 * @title Fuzz Tests for Oracle Price Assertion
 * @notice Fuzz testing for oracle price assertions to find edge cases
 * @dev Tests both valid cases (no false positives) and invalid cases (catches manipulation)
 *
 * Tests intra-transaction price stability using BatchPriceManipulator
 * to simulate price changes within a single transaction.
 *
 * Run with: FOUNDRY_PROFILE=fuzz-assertions pcl test
 * Or for quick fuzzing: FOUNDRY_PROFILE=fuzz-assertions-quick pcl test
 */
contract FuzzOraclePriceAssertion is BaseAssertionTest {
    OraclePriceAssertion public assertion;

    // Real mToken for sanity tests
    mErc20Immutable public mUSDC;

    // Mock infrastructure for price stability tests
    MockOperatorVulnerable public mockOperator;
    MockOracleVulnerable public mockOracle;
    BatchPriceManipulator public batchManipulator;

    address public constant MOCK_MTOKEN = address(0x1234567890123456789012345678901234567890);

    function setUp() public override {
        super.setUp();
        assertion = new OraclePriceAssertion();

        // Setup real mToken for sanity tests
        _setupRealMToken();

        // Setup mock infrastructure for price stability tests
        mockOperator = new MockOperatorVulnerable();
        mockOracle = new MockOracleVulnerable();
        batchManipulator = new BatchPriceManipulator();

        // Connect mock oracle to mock operator
        mockOperator.setOracleAddress(address(mockOracle));

        // Setup users for mock tests
        mockOperator.setWhitelistedUser(alice, true);
        mockOperator.setWhitelistedUser(bob, true);
    }

    /**
     * @notice Setup mToken market instance
     * @dev Creates mUSDC market for testing price assertions
     */
    function _setupRealMToken() internal {
        // Deploy mUSDC (borrow market)
        mUSDC = new mErc20Immutable(
            address(usdc),
            address(operator),
            address(interestModel),
            1e18,
            "Market USDC",
            "mUSDC",
            6, // USDC has 6 decimals
            payable(address(this))
        );
        vm.label(address(mUSDC), "mUSDC");

        // Setup market in operator
        operator.supportMarket(address(mUSDC));
    }

    /**
     * @notice Helper to setup collateral for a user
     */
    function _setupCollateral(address user, uint256 supplyAmount) internal {
        // Mint underlying tokens to the user
        usdc.mint(user, supplyAmount);

        // User approves mToken to spend their underlying tokens
        vm.prank(user);
        IERC20(address(usdc)).approve(address(mUSDC), supplyAmount);

        // User supplies tokens to the mToken market
        vm.prank(user);
        mUSDC.mint(supplyAmount, user, 0);
    }

    // ============ Fuzz Tests ============

    /**
     * @notice Fuzz test for price sanity checks across different price ranges
     * @dev Tests that legitimate non-zero prices always pass sanity checks
     *
     * @param price The oracle price to test
     *
     * Invariants tested:
     * - Non-zero prices should always pass sanity checks
     * - Works across realistic price ranges
     * - No false positives for valid oracle prices
     */
    function testFuzz_BorrowPriceSanity_NonZeroPrice_Passes(uint256 price) public {
        // Constrain to realistic non-zero prices
        // Range: $0.0001 to $100,000 (in 8 decimals)
        vm.assume(price >= 1e4 && price <= 100_000e8);

        // Setup Alice with collateral
        _setupCollateral(alice, 10_000e6);
        operator.setCollateralFactor(address(mUSDC), 0.8e18);
        operator.setWhitelistedUser(alice, true);

        // Setup oracle price
        api3Feed.setPrice(int256(price));
        eOracleFeed.setPrice(int256(price));
        api3Feed.setUpdatedAt(block.timestamp);
        eOracleFeed.setUpdatedAt(block.timestamp);

        // Add liquidity to borrow pool
        usdc.mint(address(this), 100_000e6);
        usdc.approve(address(mUSDC), 100_000e6);
        mUSDC.mint(100_000e6, address(this), 0);

        // Register assertion
        cl.assertion({
            adopter: address(operator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionBorrowPriceSanity.selector
        });

        // Execute borrow - should NOT revert with valid non-zero price
        vm.prank(alice);
        mUSDC.borrow(1000e6);

        // Verify borrow succeeded
        assertGt(mUSDC.borrowBalanceStored(alice), 0, "Borrow should succeed with non-zero price");
    }

    // ============ Price Stability Fuzz Tests (Valid Cases) ============

    /**
     * @notice Fuzz test for intra-transaction price stability with valid small changes
     * @dev Tests that price changes UNDER 5% threshold don't trigger false positives
     *
     * @param initialPrice The starting oracle price (in 30 decimals to match mock)
     * @param priceChangeBps Price change in basis points (-490 to +490 = -4.9% to +4.9%)
     *
     * Invariants tested:
     * - Price changes within 5% threshold should always pass
     * - Works across different initial price ranges
     * - No false positives for legitimate intra-tx price movements
     */
    function testFuzz_BorrowPriceStability_ValidIntraTxChange_Passes(
        uint256 initialPrice,
        int256 priceChangeBps
    ) public {
        // Constrain inputs
        // Price range: $0.01 to $1,000,000 (in 30 decimals for mock oracle)
        vm.assume(initialPrice >= 1e28 && initialPrice <= 1_000_000e30);

        // Price change: -4.9% to +4.9% (stays well within 5% threshold)
        vm.assume(priceChangeBps >= -490 && priceChangeBps <= 490);

        // Calculate manipulated price
        int256 priceChange = (int256(initialPrice) * priceChangeBps) / 10000;
        uint256 manipulatedPrice = uint256(int256(initialPrice) + priceChange);

        // Ensure price stays positive and reasonable
        vm.assume(manipulatedPrice > 0 && manipulatedPrice <= 2_000_000e30);

        // Setup: Set initial price in mock oracle
        mockOracle.setPriceOverride(MOCK_MTOKEN, initialPrice);

        // Allow borrow to proceed (we're testing price stability, not liquidity)
        mockOperator.setBypassBorrowLiquidityCheck(true);

        // Register assertion for price stability
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionBorrowPriceStability.selector
        });

        // Execute batch operation that changes price mid-transaction
        // Should NOT revert since price change is within 5% threshold
        batchManipulator.executeBorrowWithPriceChange(
            mockOperator,
            mockOracle,
            MOCK_MTOKEN,
            alice,
            1000e6,
            manipulatedPrice
        );

        // Verify operation completed successfully (no revert = success)
        // The assertion checked the price change and allowed it
    }

    /**
     * @notice Fuzz test for price stability across different initial prices with fixed small change
     * @dev Tests that a fixed 3% change works across all price ranges
     *
     * @param initialPrice The starting oracle price
     * @param increasePrice Whether to increase (true) or decrease (false) price
     *
     * Invariants tested:
     * - 3% price changes should always pass regardless of initial price
     * - Both price increases and decreases are handled correctly
     */
    function testFuzz_BorrowPriceStability_ThreePercentChange_Passes(
        uint256 initialPrice,
        bool increasePrice
    ) public {
        // Constrain to realistic prices
        vm.assume(initialPrice >= 1e28 && initialPrice <= 1_000_000e30);

        // Calculate 3% change (well under 5% threshold)
        uint256 priceChange = (initialPrice * 300) / 10000; // 3%
        uint256 manipulatedPrice = increasePrice
            ? initialPrice + priceChange
            : initialPrice - priceChange;

        // Ensure manipulated price is valid
        vm.assume(manipulatedPrice > 0 && manipulatedPrice <= 2_000_000e30);

        // Setup
        mockOracle.setPriceOverride(MOCK_MTOKEN, initialPrice);
        mockOperator.setBypassBorrowLiquidityCheck(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionBorrowPriceStability.selector
        });

        // Execute - should pass with 3% change
        batchManipulator.executeBorrowWithPriceChange(
            mockOperator,
            mockOracle,
            MOCK_MTOKEN,
            alice,
            1000e6,
            manipulatedPrice
        );
    }

    // ============ Price Stability Fuzz Tests (Invalid Cases - Single Variable) ============

    /**
     * @notice Simple fuzz test: Fixed 10% increase, varying initial prices
     * @dev Tests that 10% manipulation is caught across all price ranges
     *
     * @param initialPriceSeed Seed for initial price (will be bounded)
     *
     * Invariants tested:
     * - 10% manipulation caught regardless of initial price
     * - Works from pennies to millions
     */
    function testFuzz_BorrowPriceStability_TenPercentIncrease_Caught(uint256 initialPriceSeed) public {
        // Bound to realistic price range
        uint256 initialPrice = (initialPriceSeed % 1_000_000e30) + 1e28;

        // Fixed 10% increase
        uint256 manipulatedPrice = initialPrice + (initialPrice * 1000) / 10000;

        // Setup
        mockOracle.setPriceOverride(MOCK_MTOKEN, initialPrice);
        mockOperator.setBypassBorrowLiquidityCheck(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionBorrowPriceStability.selector
        });

        // Execute - should REVERT
        vm.expectRevert("Oracle price deviated too much during borrow operation");
        batchManipulator.executeBorrowWithPriceChange(
            mockOperator,
            mockOracle,
            MOCK_MTOKEN,
            alice,
            1000e6,
            manipulatedPrice
        );
    }

    /**
     * @notice Simple fuzz test: Fixed 10% decrease, varying initial prices
     * @dev Tests that 10% manipulation is caught in both directions
     *
     * @param initialPriceSeed Seed for initial price (will be bounded)
     *
     * Invariants tested:
     * - Downward manipulation caught as well as upward
     * - Works across all price ranges
     */
    function testFuzz_BorrowPriceStability_TenPercentDecrease_Caught(uint256 initialPriceSeed) public {
        // Bound to realistic price range
        uint256 initialPrice = (initialPriceSeed % 1_000_000e30) + 1e28;

        // Fixed 10% decrease
        uint256 manipulatedPrice = initialPrice - (initialPrice * 1000) / 10000;

        // Setup
        mockOracle.setPriceOverride(MOCK_MTOKEN, initialPrice);
        mockOperator.setBypassBorrowLiquidityCheck(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionBorrowPriceStability.selector
        });

        // Execute - should REVERT
        vm.expectRevert("Oracle price deviated too much during borrow operation");
        batchManipulator.executeBorrowWithPriceChange(
            mockOperator,
            mockOracle,
            MOCK_MTOKEN,
            alice,
            1000e6,
            manipulatedPrice
        );
    }

    /**
     * @notice Simple fuzz test: Fixed $1 price, varying increase percentages
     * @dev Tests that various manipulation sizes are caught
     *
     * @param priceChangeBpsSeed Seed for price change percentage (will be bounded)
     *
     * Invariants tested:
     * - All manipulation sizes from 6% to 50% are caught
     * - Boundary behavior consistent across manipulation sizes
     */
    function testFuzz_BorrowPriceStability_FixedPriceVaryingIncrease_Caught(uint256 priceChangeBpsSeed) public {
        // Fixed $1 price (in 30 decimals)
        uint256 initialPrice = 1e30;

        // Varying increase: 6% to 50%
        uint256 priceChangeBps = (priceChangeBpsSeed % 4400) + 600;
        uint256 manipulatedPrice = initialPrice + (initialPrice * priceChangeBps) / 10000;

        // Setup
        mockOracle.setPriceOverride(MOCK_MTOKEN, initialPrice);
        mockOperator.setBypassBorrowLiquidityCheck(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionBorrowPriceStability.selector
        });

        // Execute - should REVERT
        vm.expectRevert("Oracle price deviated too much during borrow operation");
        batchManipulator.executeBorrowWithPriceChange(
            mockOperator,
            mockOracle,
            MOCK_MTOKEN,
            alice,
            1000e6,
            manipulatedPrice
        );
    }

    /**
     * @notice Simple fuzz test: Fixed $1 price, varying decrease percentages
     * @dev Tests that various downward manipulation sizes are caught
     *
     * @param priceChangeBpsSeed Seed for price change percentage (will be bounded)
     *
     * Invariants tested:
     * - All downward manipulation sizes from -6% to -50% are caught
     * - Symmetry with upward manipulation
     */
    function testFuzz_BorrowPriceStability_FixedPriceVaryingDecrease_Caught(uint256 priceChangeBpsSeed) public {
        // Fixed $1 price (in 30 decimals)
        uint256 initialPrice = 1e30;

        // Varying decrease: -6% to -50%
        uint256 priceChangeBps = (priceChangeBpsSeed % 4400) + 600;
        uint256 manipulatedPrice = initialPrice - (initialPrice * priceChangeBps) / 10000;

        // Setup
        mockOracle.setPriceOverride(MOCK_MTOKEN, initialPrice);
        mockOperator.setBypassBorrowLiquidityCheck(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionBorrowPriceStability.selector
        });

        // Execute - should REVERT
        vm.expectRevert("Oracle price deviated too much during borrow operation");
        batchManipulator.executeBorrowWithPriceChange(
            mockOperator,
            mockOracle,
            MOCK_MTOKEN,
            alice,
            1000e6,
            manipulatedPrice
        );
    }
}
