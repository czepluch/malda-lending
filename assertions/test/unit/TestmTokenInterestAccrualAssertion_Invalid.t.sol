// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseAssertionTest} from "./BaseAssertionTest.t.sol";
import {mTokenInterestAccrualAssertion} from "../../src/mTokenInterestAccrualAssertion.a.sol";
import {MockMTokenVulnerable} from "../mocks/MockMTokenVulnerable.sol";
import {MockInterestRateModelVulnerable} from "../mocks/MockInterestRateModelVulnerable.sol";
import {MockOperatorVulnerable} from "../mocks/MockOperatorVulnerable.sol";

/**
 * @title mToken Interest Accrual Assertion Invalid Tests
 * @notice Tests for mTokenInterestAccrualAssertion using mock contracts (unhappy path)
 * @dev These tests verify assertions catch protocol violations during mToken operations
 * @dev Uses mToken as adopter (not operator) - matches mTokenLiquidationAssertion pattern
 */
contract TestmTokenInterestAccrualAssertion_Invalid is BaseAssertionTest {
    MockMTokenVulnerable public mockMTokenVuln;
    MockInterestRateModelVulnerable public mockInterestModel;
    MockOperatorVulnerable public mockOperator;

    function setUp() public override {
        super.setUp();

        mockInterestModel = new MockInterestRateModelVulnerable();
        mockOperator = new MockOperatorVulnerable();

        mockMTokenVuln = new MockMTokenVulnerable(address(mockOperator), address(usdc), address(mockInterestModel));

        mockOperator.setWhitelistedUser(alice, true);
        mockOperator.setWhitelistedUser(bob, true);
        mockOperator.setBypassLiquidationLiquidityCheck(true);
    }

    function testBorrowInterestMonotonicity_IndexDecrease_CaughtByAssertion() public {
        mockMTokenVuln.setTotalBorrows(1000e6);
        mockMTokenVuln.setBorrowIndex(1.1e18);
        mockMTokenVuln.setBorrowBalance(alice, 50e6);
        mockMTokenVuln.setAccrualBlockTimestamp(block.timestamp);

        mockMTokenVuln.setAllowIndexDecrease(true);

        vm.warp(block.timestamp + 100);

        cl.assertion({
            adopter: address(mockMTokenVuln),
            createData: type(mTokenInterestAccrualAssertion).creationCode,
            fnSelector: mTokenInterestAccrualAssertion.assertionBorrowInterestMonotonicity.selector
        });

        vm.expectRevert("Borrow index decreased during interest accrual");
        vm.prank(alice);
        mockMTokenVuln.borrow(5e6);
    }

    function testBorrowInterestMonotonicity_TotalBorrowsDecrease_CaughtByAssertion() public {
        mockMTokenVuln.setTotalBorrows(1000e6);
        mockMTokenVuln.setBorrowIndex(1e18);
        mockMTokenVuln.setBorrowBalance(alice, 50e6);
        mockMTokenVuln.setAccrualBlockTimestamp(block.timestamp);

        mockMTokenVuln.setAllowTotalBorrowsDecrease(true);

        vm.warp(block.timestamp + 100);

        cl.assertion({
            adopter: address(mockMTokenVuln),
            createData: type(mTokenInterestAccrualAssertion).creationCode,
            fnSelector: mTokenInterestAccrualAssertion.assertionBorrowInterestMonotonicity.selector
        });

        vm.expectRevert("Total borrows decreased during interest accrual");
        vm.prank(alice);
        mockMTokenVuln.borrow(5e6);
    }

    function testBorrowInterestMonotonicity_IndexStagnant_CaughtByAssertion() public {
        mockMTokenVuln.setTotalBorrows(1000e6);
        mockMTokenVuln.setBorrowIndex(1e18);
        mockMTokenVuln.setBorrowBalance(alice, 50e6);
        mockMTokenVuln.setAccrualBlockTimestamp(block.timestamp);

        mockMTokenVuln.setAllowIndexStagnation(true);

        vm.warp(block.timestamp + 100);

        cl.assertion({
            adopter: address(mockMTokenVuln),
            createData: type(mTokenInterestAccrualAssertion).creationCode,
            fnSelector: mTokenInterestAccrualAssertion.assertionBorrowInterestMonotonicity.selector
        });

        vm.expectRevert("Borrow index did not increase with positive borrows");
        vm.prank(alice);
        mockMTokenVuln.borrow(5e6);
    }

    function testBorrowRateCap_ExcessiveRate_CaughtByAssertion() public {
        mockInterestModel.setReturnExcessiveRate(true);

        cl.assertion({
            adopter: address(mockMTokenVuln),
            createData: type(mTokenInterestAccrualAssertion).creationCode,
            fnSelector: mTokenInterestAccrualAssertion.assertionBorrowRateCap.selector
        });

        vm.expectRevert("Borrow rate unreasonably high");
        vm.prank(alice);
        mockMTokenVuln.borrow(5e6);
    }

    function testLiquidationInterestMonotonicity_IndexDecrease_CaughtByAssertion() public {
        mockMTokenVuln.setTotalBorrows(1000e6);
        mockMTokenVuln.setBorrowIndex(1.1e18);
        mockMTokenVuln.setBorrowBalance(alice, 100e6);
        mockMTokenVuln.setAccrualBlockTimestamp(block.timestamp);

        mockMTokenVuln.setAllowIndexDecrease(true);

        vm.warp(block.timestamp + 100);

        cl.assertion({
            adopter: address(mockMTokenVuln),
            createData: type(mTokenInterestAccrualAssertion).creationCode,
            fnSelector: mTokenInterestAccrualAssertion.assertionLiquidationInterestMonotonicity.selector
        });

        vm.expectRevert("Borrow index decreased during liquidation");
        vm.prank(bob);
        mockMTokenVuln.liquidate(alice, 10e6, address(mockMTokenVuln));
    }

    function testRedeemInterestMonotonicity_IndexDecrease_CaughtByAssertion() public {
        mockMTokenVuln.setTotalBorrows(1000e6);
        mockMTokenVuln.setBorrowIndex(1.1e18);
        mockMTokenVuln.setAccrualBlockTimestamp(block.timestamp);

        mockMTokenVuln.setAllowIndexDecrease(true);

        vm.warp(block.timestamp + 100);

        cl.assertion({
            adopter: address(mockMTokenVuln),
            createData: type(mTokenInterestAccrualAssertion).creationCode,
            fnSelector: mTokenInterestAccrualAssertion.assertionRedeemInterestMonotonicity.selector
        });

        vm.expectRevert("Borrow index decreased during redeem");
        vm.prank(alice);
        mockMTokenVuln.redeem(10e6);
    }

    function testRedeemInterestMonotonicity_TotalBorrowsDecrease_CaughtByAssertion() public {
        mockMTokenVuln.setTotalBorrows(1000e6);
        mockMTokenVuln.setBorrowIndex(1e18);
        mockMTokenVuln.setAccrualBlockTimestamp(block.timestamp);

        mockMTokenVuln.setAllowTotalBorrowsDecrease(true);

        vm.warp(block.timestamp + 100);

        cl.assertion({
            adopter: address(mockMTokenVuln),
            createData: type(mTokenInterestAccrualAssertion).creationCode,
            fnSelector: mTokenInterestAccrualAssertion.assertionRedeemInterestMonotonicity.selector
        });

        vm.expectRevert("Total borrows decreased during redeem");
        vm.prank(alice);
        mockMTokenVuln.redeem(10e6);
    }
}
