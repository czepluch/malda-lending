// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseAssertionTest, MockInterestRateModel} from "./BaseAssertionTest.t.sol";
import {OutflowLimiterAssertion} from "../../src/OutflowLimiterAssertion.a.sol";
import {mErc20Immutable} from "../../../src/mToken/mErc20Immutable.sol";
import {ERC20Mock} from "../../../test/mocks/ERC20Mock.sol";
import {BatchOutflowBypass} from "../batch/BatchOutflowBypass.sol";

/**
 * @title Outflow Limiter Assertion Valid Tests
 * @notice Tests for OutflowLimiterAssertion using real contracts (happy path)
 * @dev These tests verify assertions pass when protocol behaves correctly
 */
contract TestOutflowLimiterAssertion_Valid is BaseAssertionTest {
    MockInterestRateModel public mockInterestModel;
    mErc20Immutable public mUSDC;
    BatchOutflowBypass public batchBypass;

    function setUp() public override {
        super.setUp();

        // Deploy interest rate model
        mockInterestModel = new MockInterestRateModel();

        // Deploy real mUSDC for testing
        mUSDC = new mErc20Immutable(
            address(usdc), // USDC underlying (from Base_Unit_Test)
            address(operator),
            address(mockInterestModel),
            1e18,
            "Market USDC",
            "mUSDC",
            6, // USDC has 6 decimals
            payable(address(this))
        );

        // List the market
        operator.supportMarket(address(mUSDC));

        // Set collateral factor so users can borrow
        operator.setCollateralFactor(address(mUSDC), 0.8e18); // 80% collateral factor

        // Deploy batch contract for testing multiple operations
        batchBypass = new BatchOutflowBypass();

        // Note: Real operator's outflow limiter is configured at deployment
        // Most tests require specific limit values, so they use mocks (see Invalid tests)
    }

    /**
     * @notice Test that borrow passes when outflow limit is disabled
     * @dev Real operator initializes with limitPerTimePeriod = 0 (disabled)
     * @dev When limit is 0, assertions skip all checks and operations always pass
     */
    function testBorrowWithDisabledLimit_Passes() public {
        // Setup Alice with collateral (100 USDC = $100)
        _setupCollateralReal(address(mUSDC), alice, 100e6);
        operator.setWhitelistedUser(alice, true);

        // Verify limit is disabled (default state)
        assertEq(operator.limitPerTimePeriod(), 0, "Limit should be disabled by default");

        // Register assertion - it will skip checks when limit is 0
        cl.assertion({
            adopter: address(operator),
            createData: type(OutflowLimiterAssertion).creationCode,
            fnSelector: OutflowLimiterAssertion.assertionBorrowOutflowLimit.selector
        });

        // Alice can borrow any amount when limit is disabled
        vm.prank(alice);
        operator.beforeMTokenBorrow(address(mUSDC), alice, 50e6);
    }

    /**
     * @notice Test that redeem within limit passes
     * @dev Verifies redemption below configured limit passes all assertions
     * @dev Note: All assertions (redeem limit, cumulative tracking, time reset) are
     *      automatically checked since they all trigger on beforeMTokenRedeem
     */
    function testRedeemOutflowLimit_WithinLimit_Passes() public {
        // Setup Alice with collateral
        _setupCollateralReal(address(mUSDC), alice, 100e6);
        operator.setWhitelistedUser(alice, true);

        // Register assertion (this registers all assertion functions via triggers())
        cl.assertion({
            adopter: address(operator),
            createData: type(OutflowLimiterAssertion).creationCode,
            fnSelector: OutflowLimiterAssertion.assertionRedeemOutflowLimit.selector
        });

        // Alice redeems 10 mUSDC (worth ~$10 < default limit)
        vm.prank(alice);
        operator.beforeMTokenRedeem(address(mUSDC), alice, 10e6);
    }

    /**
     * @notice Test that multiple borrows pass when limit is disabled
     * @dev With limit disabled, multiple operations always pass regardless of volume
     */
    function testMultipleBorrowsWithDisabledLimit_Passes() public {
        // Setup Alice and Bob with collateral
        _setupCollateralReal(address(mUSDC), alice, 1000e6);
        _setupCollateralReal(address(mUSDC), bob, 1000e6);
        operator.setWhitelistedUser(alice, true);
        operator.setWhitelistedUser(bob, true);

        // Verify limit is disabled
        assertEq(operator.limitPerTimePeriod(), 0, "Limit should be disabled");

        // Register assertion - checks will be skipped with disabled limit
        cl.assertion({
            adopter: address(operator),
            createData: type(OutflowLimiterAssertion).creationCode,
            fnSelector: OutflowLimiterAssertion.assertionBorrowOutflowLimit.selector
        });

        // Alice borrows $500
        vm.prank(alice);
        operator.beforeMTokenBorrow(address(mUSDC), alice, 500e6);

        // Bob borrows $300 - both pass with disabled limit
        vm.prank(bob);
        operator.beforeMTokenBorrow(address(mUSDC), bob, 300e6);
    }

    /**
     * @notice Test that mixed borrow and redeem operations pass when limit is disabled
     * @dev With limit disabled, both operation types pass without accumulation checks
     */
    function testMixedOpsWithDisabledLimit_Passes() public {
        // Setup Alice with collateral
        _setupCollateralReal(address(mUSDC), alice, 1000e6);
        operator.setWhitelistedUser(alice, true);

        // Verify limit is disabled
        assertEq(operator.limitPerTimePeriod(), 0, "Limit should be disabled");

        // Register borrow assertion
        cl.assertion({
            adopter: address(operator),
            createData: type(OutflowLimiterAssertion).creationCode,
            fnSelector: OutflowLimiterAssertion.assertionBorrowOutflowLimit.selector
        });

        // Alice borrows $200
        vm.prank(alice);
        operator.beforeMTokenBorrow(address(mUSDC), alice, 200e6);

        // Register redeem assertion (separate transaction to avoid duplicate assertion error)
        cl.assertion({
            adopter: address(operator),
            createData: type(OutflowLimiterAssertion).creationCode,
            fnSelector: OutflowLimiterAssertion.assertionRedeemOutflowLimit.selector
        });

        // Alice redeems mTokens worth ~$100 - both operations pass
        vm.prank(alice);
        operator.beforeMTokenRedeem(address(mUSDC), alice, 100e6);
    }

    /**
     * @notice Test that operations work when limit is disabled (default state)
     * @dev Real operator initializes with limitPerTimePeriod = 0
     * @dev This test verifies large operations pass when limit is disabled
     */
    function testLargeOperationWithDisabledLimit_Passes() public {
        // Setup Alice with collateral for large borrow
        _setupCollateralReal(address(mUSDC), alice, 10000e6);
        operator.setWhitelistedUser(alice, true);

        // Verify limit is disabled (no need to set, it's the default)
        assertEq(operator.limitPerTimePeriod(), 0, "Limit is disabled by default");

        // Register assertion
        cl.assertion({
            adopter: address(operator),
            createData: type(OutflowLimiterAssertion).creationCode,
            fnSelector: OutflowLimiterAssertion.assertionBorrowOutflowLimit.selector
        });

        // Alice can borrow any amount when limit is disabled
        vm.prank(alice);
        operator.beforeMTokenBorrow(address(mUSDC), alice, 5000e6);
    }

    /**
     * @notice Test that time window bounds are validated even with disabled limit
     * @dev Real operator initializes with outflowResetTimeWindow = 1 hour (reasonable)
     * @dev Assertion validates window is between 1 minute and 7 days regardless of limit
     */
    function testTimeWindowBoundsWithDisabledLimit_Passes() public {
        // Setup Alice with collateral
        _setupCollateralReal(address(mUSDC), alice, 100e6);
        operator.setWhitelistedUser(alice, true);

        // Verify default time window is reasonable (1 hour)
        assertEq(operator.outflowResetTimeWindow(), 1 hours, "Default window should be 1 hour");
        assertTrue(operator.outflowResetTimeWindow() >= 60, "Window should be >= 1 minute");
        assertTrue(operator.outflowResetTimeWindow() <= 7 days, "Window should be <= 7 days");

        // Register assertion - will check time window bounds
        cl.assertion({
            adopter: address(operator),
            createData: type(OutflowLimiterAssertion).creationCode,
            fnSelector: OutflowLimiterAssertion.assertionTimeWindowReset.selector
        });

        // Simple borrow to trigger assertion - should pass with reasonable window
        vm.prank(alice);
        operator.beforeMTokenBorrow(address(mUSDC), alice, 10e6);
    }

    /**
     * @notice Test that 10 borrows pass when limit is enabled and check assertion gas usage
     * @dev Verifies cumulative tracking across 10 operations in a single transaction
     * @dev With limit enabled, operations are tracked and must stay within limit
     * @dev This test checks if assertion gas usage stays within limits for 10 operations
     */
    function testBorrowOutflowLimit_10Transactions_CheckAssertionGasUsage() public {
        // Setup Alice with sufficient collateral (1000 USDC = $1000)
        _setupCollateralReal(address(mUSDC), alice, 1000e6);
        operator.setWhitelistedUser(alice, true);

        // Add liquidity to mUSDC pool so borrows can succeed
        // Mint underlying tokens to this contract
        usdc.mint(address(this), 10000e6);
        usdc.approve(address(mUSDC), 10000e6);
        // Mint mTokens to add liquidity to the pool
        mUSDC.mint(10000e6, address(this), 0);

        // Enable outflow limit for testing
        // Set limit to 1000e18 USD (representing $1000)
        // Our test: 10 × 10e6 USDC = 100e6 USDC total
        // With USDC price = $1, that's $100 USD, well under $1000 limit
        operator.setOutflowTimeLimitInUSD(1000e18);
        operator.resetOutflowVolume(); // Reset cumulative volume to 0

        // Verify limit is enabled
        assertEq(operator.limitPerTimePeriod(), 1000e18, "Limit should be enabled");

        // Register assertion - will now track cumulative outflows
        cl.assertion({
            adopter: address(operator),
            createData: type(OutflowLimiterAssertion).creationCode,
            fnSelector: OutflowLimiterAssertion.assertionBorrowOutflowLimit.selector
        });

        // Execute 10 borrows in single transaction through mToken contract
        // 10 × 10e6 = 100e6 total, well within Alice's collateral capacity and outflow limit
        vm.startPrank(alice);
        for (uint256 i = 0; i < 10; i++) {
            mUSDC.borrow(10e6); // $10 per borrow (small amount)
        }
        vm.stopPrank();
    }
}
