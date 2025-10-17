// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseAssertionTest, MockInterestRateModel} from "./BaseAssertionTest.t.sol";
import {mTokenRedeemOutflowAssertion} from "../src/mTokenRedeemOutflowAssertion.a.sol";
import {mErc20Immutable} from "../../src/mToken/mErc20Immutable.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";

/**
 * @title mToken Redeem Outflow Assertion Valid Tests
 * @notice Tests for mTokenRedeemOutflowAssertion using real contracts (happy path)
 * @dev These tests verify assertions pass when protocol behaves correctly
 * @dev Uses mToken as adopter (not operator) - matches mTokenLiquidationAssertion pattern
 */
contract TestmTokenRedeemOutflowAssertion_Valid is BaseAssertionTest {
    MockInterestRateModel public mockInterestModel;
    mErc20Immutable public mUSDC;

    function setUp() public override {
        super.setUp();

        mockInterestModel = new MockInterestRateModel();

        mUSDC = new mErc20Immutable(
            address(usdc),
            address(operator),
            address(mockInterestModel),
            1e18,
            "Market USDC",
            "mUSDC",
            6,
            payable(address(this))
        );

        operator.supportMarket(address(mUSDC));
        operator.setCollateralFactor(address(mUSDC), 0.8e18);
    }

    /**
     * @notice Test that redeem passes when outflow limit is disabled
     * @dev Real operator initializes with limitPerTimePeriod = 0 (disabled)
     */
    function testRedeemOutflow_DisabledLimit_Passes() public {
        _setupCollateralReal(address(mUSDC), alice, 100e6);
        operator.setWhitelistedUser(alice, true);

        assertEq(operator.limitPerTimePeriod(), 0, "Limit should be disabled");

        cl.assertion({
            adopter: address(mUSDC),
            createData: type(mTokenRedeemOutflowAssertion).creationCode,
            fnSelector: mTokenRedeemOutflowAssertion.assertionRedeemOutflowLimit.selector
        });

        vm.prank(alice);
        mUSDC.redeem(10e6);
    }

    /**
     * @notice Test that multiple redeems pass with disabled limit
     * @dev Verifies assertion handles multiple operations correctly
     */
    function testMultipleRedeems_DisabledLimit_Passes() public {
        _setupCollateralReal(address(mUSDC), alice, 100e6);
        operator.setWhitelistedUser(alice, true);

        assertEq(operator.limitPerTimePeriod(), 0, "Limit should be disabled");

        cl.assertion({
            adopter: address(mUSDC),
            createData: type(mTokenRedeemOutflowAssertion).creationCode,
            fnSelector: mTokenRedeemOutflowAssertion.assertionRedeemOutflowLimit.selector
        });

        vm.prank(alice);
        mUSDC.redeem(10e6);

        vm.prank(alice);
        mUSDC.redeem(10e6);

        vm.prank(alice);
        mUSDC.redeem(10e6);
    }

    /**
     * @notice Test that large redeem passes with disabled limit
     * @dev Even large operations pass when limit is disabled
     */
    function testLargeRedeem_DisabledLimit_Passes() public {
        _setupCollateralReal(address(mUSDC), alice, 1000e6);
        operator.setWhitelistedUser(alice, true);

        assertEq(operator.limitPerTimePeriod(), 0, "Limit should be disabled");

        cl.assertion({
            adopter: address(mUSDC),
            createData: type(mTokenRedeemOutflowAssertion).creationCode,
            fnSelector: mTokenRedeemOutflowAssertion.assertionRedeemOutflowLimit.selector
        });

        vm.prank(alice);
        mUSDC.redeem(500e6);
    }
}
