// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CredibleTest} from "credible-std/CredibleTest.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {AccountLiquidityAssertion} from "../src/AccountLiquidityAssertion.a.sol";
import {BaseAssertionTest} from "./BaseAssertionTest.t.sol";
import {MockOperatorVulnerable} from "./mocks/MockOperatorVulnerable.sol";

/**
 * @title Account Liquidity Assertion Tests - Invalid (Unhappy Path)
 * @notice Tests for account liquidity assertions that should catch protocol violations
 * @dev These tests use MockOperatorVulnerable to simulate vulnerable protocol behavior
 */
contract TestAccountLiquidityAssertion_Invalid is BaseAssertionTest {
    AccountLiquidityAssertion public assertion;
    MockOperatorVulnerable public mockOperator;

    function setUp() public override {
        super.setUp();
        assertion = new AccountLiquidityAssertion();
        mockOperator = new MockOperatorVulnerable();

        // Setup mock with reasonable defaults
        mockOperator.setWhitelistedUser(alice, true);
        mockOperator.setWhitelistedUser(bob, true);
    }

    // ============ Borrow Liquidity Tests ============

    /**
     * @notice Test that assertion catches invalid borrow with insufficient liquidity
     * @dev Mock allows borrow despite shortfall > 0, assertion should revert
     */
    function testBorrowLiquidity_InvalidBorrow_CaughtByAssertion() public {
        // Setup: Alice has insufficient liquidity (shortfall > 0)
        mockOperator.setLiquidityOverride(alice, 0, 1000e18); // liquidity=0, shortfall=1000

        // Enable bypass so mock allows the invalid borrow
        mockOperator.setBypassBorrowLiquidityCheck(true);

        // Register assertion - should catch the violation
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(AccountLiquidityAssertion).creationCode,
            fnSelector: AccountLiquidityAssertion.assertionBorrowLiquidity.selector
        });

        // Expect assertion to revert when it detects invalid borrow
        vm.expectRevert("Borrow allowed despite insufficient liquidity");
        mockOperator.beforeMTokenBorrow(address(0x123), alice, 1000e6);
    }

    /**
     * @notice Test that assertion catches borrow when user has existing shortfall
     * @dev Even small borrows should fail if user is already underwater
     */
    function testBorrowLiquidity_ExistingShortfall_CaughtByAssertion() public {
        // Setup: Alice already has shortfall from previous operations
        mockOperator.setLiquidityOverride(alice, 0, 500e18); // Already underwater

        // Enable bypass
        mockOperator.setBypassBorrowLiquidityCheck(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(AccountLiquidityAssertion).creationCode,
            fnSelector: AccountLiquidityAssertion.assertionBorrowLiquidity.selector
        });

        // Expect assertion to catch this
        vm.expectRevert("Borrow allowed despite insufficient liquidity");
        mockOperator.beforeMTokenBorrow(address(0x123), alice, 100e6);
    }

    // ============ Liquidation Liquidity Tests ============

    /**
     * @notice Test that assertion catches liquidation of healthy account
     * @dev Mock allows liquidation despite shortfall = 0, assertion should revert
     */
    function testLiquidationLiquidity_HealthyAccount_CaughtByAssertion() public {
        // Setup: Alice is healthy (no shortfall)
        mockOperator.setLiquidityOverride(alice, 1000e18, 0); // liquidity=1000, shortfall=0

        // Enable bypass so mock allows the invalid liquidation
        mockOperator.setBypassLiquidationLiquidityCheck(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(AccountLiquidityAssertion).creationCode,
            fnSelector: AccountLiquidityAssertion.assertionLiquidationLiquidity.selector
        });

        // Expect assertion to revert when it detects invalid liquidation
        vm.expectRevert("Liquidation allowed despite sufficient liquidity");
        mockOperator.beforeMTokenLiquidate(address(0x123), address(0x456), alice, 100e6);
    }

    /**
     * @notice Test that assertion catches liquidation with zero repay amount
     * @dev Liquidation should not proceed with zero repay amount
     */
    function testLiquidationLiquidity_ZeroRepayAmount_CaughtByAssertion() public {
        // Setup: Alice is underwater (valid for liquidation)
        mockOperator.setLiquidityOverride(alice, 0, 500e18); // shortfall > 0

        // Enable bypass to allow zero repay
        mockOperator.setBypassLiquidationLiquidityCheck(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(AccountLiquidityAssertion).creationCode,
            fnSelector: AccountLiquidityAssertion.assertionLiquidationLiquidity.selector
        });

        // Expect assertion to catch zero repay amount
        vm.expectRevert("Liquidation with zero repay amount");
        mockOperator.beforeMTokenLiquidate(address(0x123), address(0x456), alice, 0);
    }

    // ============ Redeem Liquidity Tests ============

    /**
     * @notice Test that assertion catches redeem that causes shortfall
     * @dev Mock allows redeem that would make account underwater, assertion should revert
     */
    function testRedeemLiquidity_CausesShortfall_CaughtByAssertion() public {
        // Setup: Before redeem Alice is healthy, but after redeem she would be underwater
        // We simulate this by having the mock return shortfall after the redeem
        mockOperator.setLiquidityOverride(alice, 0, 100e18); // Will have shortfall after redeem

        // Enable bypass
        mockOperator.setBypassRedeemLiquidityCheck(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(AccountLiquidityAssertion).creationCode,
            fnSelector: AccountLiquidityAssertion.assertionRedeemLiquidity.selector
        });

        // Expect assertion to catch this
        vm.expectRevert("Redeem allowed despite insufficient liquidity");
        mockOperator.beforeMTokenRedeem(address(0x123), alice, 500e6);
    }

    /**
     * @notice Test that assertion catches redeem when user already has shortfall
     * @dev User shouldn't be able to redeem if already underwater
     */
    function testRedeemLiquidity_ExistingShortfall_CaughtByAssertion() public {
        // Setup: Alice already has shortfall
        mockOperator.setLiquidityOverride(alice, 0, 200e18);

        // Enable bypass
        mockOperator.setBypassRedeemLiquidityCheck(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(AccountLiquidityAssertion).creationCode,
            fnSelector: AccountLiquidityAssertion.assertionRedeemLiquidity.selector
        });

        // Expect assertion to catch this
        vm.expectRevert("Redeem allowed despite insufficient liquidity");
        mockOperator.beforeMTokenRedeem(address(0x123), alice, 100e6);
    }

    // ============ Seize Liquidity Tests ============

    /**
     * @notice Test that assertion catches seize with zero liquidator address
     * @dev Seize should fail with invalid parameters
     */
    function testSeizeLiquidity_ZeroLiquidator_CaughtByAssertion() public {
        // Enable bypass
        mockOperator.setBypassSeizeLiquidityCheck(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(AccountLiquidityAssertion).creationCode,
            fnSelector: AccountLiquidityAssertion.assertionSeizeLiquidity.selector
        });

        // Expect assertion to catch zero liquidator
        vm.expectRevert("Seize with zero liquidator address");
        mockOperator.beforeMTokenSeize(address(0x123), address(0x456), address(0));
    }

    /**
     * @notice Test that assertion catches seize with zero collateral mToken
     * @dev Seize should fail with invalid collateral address
     */
    function testSeizeLiquidity_ZeroCollateral_CaughtByAssertion() public {
        // Enable bypass
        mockOperator.setBypassSeizeLiquidityCheck(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(AccountLiquidityAssertion).creationCode,
            fnSelector: AccountLiquidityAssertion.assertionSeizeLiquidity.selector
        });

        // Expect assertion to catch zero collateral
        vm.expectRevert("Seize with zero collateral mToken");
        mockOperator.beforeMTokenSeize(address(0), address(0x456), bob);
    }

    /**
     * @notice Test that assertion catches seize with zero borrowed mToken
     * @dev Seize should fail with invalid borrowed token address
     */
    function testSeizeLiquidity_ZeroBorrowedToken_CaughtByAssertion() public {
        // Enable bypass
        mockOperator.setBypassSeizeLiquidityCheck(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockOperator),
            createData: type(AccountLiquidityAssertion).creationCode,
            fnSelector: AccountLiquidityAssertion.assertionSeizeLiquidity.selector
        });

        // Expect assertion to catch zero borrowed token
        vm.expectRevert("Seize with zero borrowed mToken");
        mockOperator.beforeMTokenSeize(address(0x123), address(0), bob);
    }
}
