// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {OraclePriceAssertion} from "../../src/OraclePriceAssertion.a.sol";
import {BaseAssertionTest} from "./BaseAssertionTest.t.sol";
import {mErc20Immutable} from "../../../src/mToken/mErc20Immutable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "../../../test/mocks/ERC20Mock.sol";
import {console} from "forge-std/console.sol";

/**
 * @title Oracle Price Assertion Tests - Valid (Happy Path)
 * @notice Tests for oracle price assertions that should pass without reverting
 * @dev These tests use the real Operator and real MixedPriceOracleV4
 */
contract TestOraclePriceAssertion_Valid is BaseAssertionTest {
    OraclePriceAssertion public assertion;
    mErc20Immutable public mWeth;

    function setUp() public override {
        super.setUp();
        assertion = new OraclePriceAssertion();

        // Deploy real mToken
        mWeth = new mErc20Immutable(
            address(usdc),
            address(operator),
            address(interestModel),
            1e18,
            "Market USDC",
            "mUSDC",
            6,
            payable(address(this))
        );
        vm.label(address(mWeth), "mUSDC");

        operator.supportMarket(address(mWeth));
        operator.setCollateralFactor(address(mWeth), 0.9e18);

        // Set default oracle prices
        api3Feed.setPrice(1e8);
        eOracleFeed.setPrice(1e8);
    }

    // ============ Borrow Price Sanity Tests ============

    function testBorrowPriceSanity_ValidPrice_Passes() public {
        _setupCollateralReal(address(mWeth), alice, 100e6);

        cl.assertion({
            adopter: address(operator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionBorrowPriceSanity.selector
        });

        vm.prank(alice);
        operator.beforeMTokenBorrow(address(mWeth), alice, 10e6);
    }

    // ============ Borrow Price Stability Tests ============

    function testBorrowPriceStability_StablePrice_Passes() public {
        _setupCollateralReal(address(mWeth), alice, 100e6);

        api3Feed.setPrice(1.01e8); // 1% change - within 5% tolerance

        cl.assertion({
            adopter: address(operator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionBorrowPriceStability.selector
        });

        vm.prank(alice);
        operator.beforeMTokenBorrow(address(mWeth), alice, 10e6);
    }

    function testBorrowPriceStability_PreTxPriceChange_Passes() public {
        _setupCollateralReal(address(mWeth), alice, 100e6);

        // Change BEFORE transaction - no intra-tx change
        api3Feed.setPrice(2e8);
        eOracleFeed.setPrice(2e8);

        cl.assertion({
            adopter: address(operator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionBorrowPriceStability.selector
        });

        vm.prank(alice);
        operator.beforeMTokenBorrow(address(mWeth), alice, 10e6);
    }

    // ============ Cross-Feed Deviation Tests ============

    function testCrossFeedDeviation_ConsistentFeeds_Passes() public {
        _setupCollateralReal(address(mWeth), alice, 100e6);

        api3Feed.setPrice(1e8);
        eOracleFeed.setPrice(1e8); // Same price

        cl.assertion({
            adopter: address(operator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionCrossFeedDeviation.selector
        });

        vm.prank(alice);
        operator.beforeMTokenBorrow(address(mWeth), alice, 10e6);
    }

    function testCrossFeedDeviation_MinorDeviation_Passes() public {
        _setupCollateralReal(address(mWeth), alice, 100e6);

        api3Feed.setPrice(1e8);
        eOracleFeed.setPrice(1.003e8); // 0.3% deviation - within tolerance

        cl.assertion({
            adopter: address(operator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionCrossFeedDeviation.selector
        });

        vm.prank(alice);
        operator.beforeMTokenBorrow(address(mWeth), alice, 10e6);
    }

    function testCrossFeedDeviation_ExtremeDeviation_CaughtByAssertion() public {
        _setupCollateralReal(address(mWeth), alice, 100e6);

        api3Feed.setPrice(1e8);
        eOracleFeed.setPrice(3e8); // 200% deviation

        cl.assertion({
            adopter: address(operator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionCrossFeedDeviation.selector
        });

        vm.expectRevert("Cross-feed deviation exceeds threshold");
        vm.prank(alice);
        operator.beforeMTokenBorrow(address(mWeth), alice, 10e6);
    }
}
