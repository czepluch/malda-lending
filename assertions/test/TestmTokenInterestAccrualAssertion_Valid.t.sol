// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseAssertionTest, MockInterestRateModel} from "./BaseAssertionTest.t.sol";
import {mTokenInterestAccrualAssertion} from "../src/mTokenInterestAccrualAssertion.a.sol";
import {mErc20Immutable} from "../../src/mToken/mErc20Immutable.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";

/**
 * @title mToken Interest Accrual Assertion Valid Tests
 * @notice Tests for mTokenInterestAccrualAssertion using real contracts (happy path)
 * @dev These tests verify assertions pass when protocol behaves correctly
 * @dev Uses mToken as adopter (not operator) - matches mTokenLiquidationAssertion pattern
 */
contract TestmTokenInterestAccrualAssertion_Valid is BaseAssertionTest {
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

    function testBorrowInterestMonotonicity_ProperAccrual_Passes() public {
        _setupCollateralReal(address(mUSDC), alice, 100e6);
        operator.setWhitelistedUser(alice, true);

        cl.assertion({
            adopter: address(mUSDC),
            createData: type(mTokenInterestAccrualAssertion).creationCode,
            fnSelector: mTokenInterestAccrualAssertion.assertionBorrowInterestMonotonicity.selector
        });

        vm.prank(alice);
        mUSDC.borrow(5e6);
    }

    function testRedeemInterestMonotonicity_ProperAccrual_Passes() public {
        _setupCollateralReal(address(mUSDC), alice, 100e6);
        operator.setWhitelistedUser(alice, true);

        cl.assertion({
            adopter: address(mUSDC),
            createData: type(mTokenInterestAccrualAssertion).creationCode,
            fnSelector: mTokenInterestAccrualAssertion.assertionRedeemInterestMonotonicity.selector
        });

        vm.prank(alice);
        mUSDC.redeem(10e6);
    }

    function testBorrowRateCap_ReasonableRate_Passes() public {
        _setupCollateralReal(address(mUSDC), alice, 100e6);
        operator.setWhitelistedUser(alice, true);

        cl.assertion({
            adopter: address(mUSDC),
            createData: type(mTokenInterestAccrualAssertion).creationCode,
            fnSelector: mTokenInterestAccrualAssertion.assertionBorrowRateCap.selector
        });

        vm.prank(alice);
        mUSDC.borrow(5e6);
    }

    function testBorrowRateCap_AtThreshold_Passes() public {
        _setupCollateralReal(address(mUSDC), alice, 100e6);
        operator.setWhitelistedUser(alice, true);

        cl.assertion({
            adopter: address(mUSDC),
            createData: type(mTokenInterestAccrualAssertion).creationCode,
            fnSelector: mTokenInterestAccrualAssertion.assertionBorrowRateCap.selector
        });

        vm.prank(alice);
        mUSDC.borrow(5e6);
    }
}
