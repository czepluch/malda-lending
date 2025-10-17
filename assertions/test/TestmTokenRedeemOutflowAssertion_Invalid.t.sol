// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseAssertionTest} from "./BaseAssertionTest.t.sol";
import {mTokenRedeemOutflowAssertion} from "../src/mTokenRedeemOutflowAssertion.a.sol";
import {MockMTokenVulnerable} from "./mocks/MockMTokenVulnerable.sol";
import {MockOperatorVulnerable} from "./mocks/MockOperatorVulnerable.sol";
import {MockOracleVulnerable} from "./mocks/MockOracleVulnerable.sol";
import {MockInterestRateModelVulnerable} from "./mocks/MockInterestRateModelVulnerable.sol";
import {BatchMTokenRedeem} from "./batch/BatchMTokenRedeem.sol";
import {ImErc20} from "../../src/interfaces/ImErc20.sol";

/**
 * @title mToken Redeem Outflow Assertion Invalid Tests
 * @notice Tests for mTokenRedeemOutflowAssertion using mock contracts (unhappy path)
 * @dev These tests verify assertions catch protocol violations during redeem operations
 * @dev Uses mToken as adopter (not operator) - matches mTokenLiquidationAssertion pattern
 */
contract TestmTokenRedeemOutflowAssertion_Invalid is BaseAssertionTest {
    MockMTokenVulnerable public mockMTokenVuln;
    MockOperatorVulnerable public mockOperator;
    MockOracleVulnerable public mockOracle;
    MockInterestRateModelVulnerable public mockInterestModel;
    BatchMTokenRedeem public batchRedeem;

    function setUp() public override {
        super.setUp();

        mockOracle = new MockOracleVulnerable();
        mockOperator = new MockOperatorVulnerable();
        mockInterestModel = new MockInterestRateModelVulnerable();

        mockOperator.setOracleAddress(address(mockOracle));

        mockMTokenVuln = new MockMTokenVulnerable(address(mockOperator), address(usdc), address(mockInterestModel));

        // Set limit in e14 format to match (amount * 1e18) / 1e10 calculation
        // 1000e14 = 1000 USD limit
        mockOperator.setLimitPerTimePeriod(1000e14);
        mockOperator.setOutflowResetTimeWindow(1 days);
        mockOperator.setLastOutflowResetTimestamp(block.timestamp);
        mockOperator.setCumulativeOutflowVolume(0);

        mockOracle.setPriceOverride(address(mockMTokenVuln), 1e18);

        batchRedeem = new BatchMTokenRedeem();
    }

    /**
     * @notice Test that assertion catches redeem exceeding limit
     * @dev Single large redeem that exceeds configured limit
     */
    function testRedeemOutflowLimit_ExceedsLimit_CaughtByAssertion() public {
        // Set cumulative in e14 format: 900e14 (900 USD)
        // Redeeming 200e6 USDC will add 200e14, total 1100e14 > 1000e14 limit
        mockOperator.setCumulativeOutflowVolume(900e14);
        mockOperator.setBypassRedeemLiquidityCheck(true);
        mockOperator.setAllowOutflowExceedLimit(true);

        cl.assertion({
            adopter: address(mockMTokenVuln),
            createData: type(mTokenRedeemOutflowAssertion).creationCode,
            fnSelector: mTokenRedeemOutflowAssertion.assertionRedeemOutflowLimit.selector
        });

        vm.expectRevert("Redeem would exceed outflow limit");
        mockMTokenVuln.redeem(200e6);
    }

    /**
     * @notice Test that assertion catches outflow tracking mismatch
     * @dev Cumulative outflow should increase by redeem amount
     * @dev 100e6 USDC should add 100e14, but mock adds half (50e14)
     */
    function testRedeemOutflowTracking_Mismatch_CaughtByAssertion() public {
        mockOperator.setCumulativeOutflowVolume(100e14);
        mockOperator.setBypassRedeemLiquidityCheck(true);
        mockOperator.setMismatchOutflowTracking(true);

        cl.assertion({
            adopter: address(mockMTokenVuln),
            createData: type(mTokenRedeemOutflowAssertion).creationCode,
            fnSelector: mTokenRedeemOutflowAssertion.assertionRedeemOutflowLimit.selector
        });

        vm.expectRevert("Outflow tracking mismatch for redeem");
        mockMTokenVuln.redeem(100e6);
    }

    /**
     * @notice Test that multiple small redeems within limit pass
     * @dev Verifies cumulative tracking across multiple operations
     * @dev Each 300e6 USDC = 300e14 USD, total 900e14 < 1000e14 limit
     */
    function testMultipleRedeems_WithinLimit_Passes() public {
        mockOperator.setCumulativeOutflowVolume(0);
        mockOperator.setBypassRedeemLiquidityCheck(true);

        cl.assertion({
            adopter: address(mockMTokenVuln),
            createData: type(mTokenRedeemOutflowAssertion).creationCode,
            fnSelector: mTokenRedeemOutflowAssertion.assertionRedeemOutflowLimit.selector
        });

        // Use batch contract to execute multiple redeems in single transaction
        // 3 × $300 = $900 total, under $1000 limit
        batchRedeem.executeMultipleRedeems(
            ImErc20(address(mockMTokenVuln)),
            300e6, // $300 per redeem in 6-decimal USDC
            3
        );
    }

    /**
     * @notice Test that assertion catches cumulative exceeding limit across multiple redeems
     * @dev Uses batch contract to execute multiple redeems in a single transaction
     * @dev Each 400e6 USDC = 400e14 USD, third one exceeds 1000e14 limit
     */
    function testMultipleRedeems_ExceedsLimit_CaughtByAssertion() public {
        mockOperator.setCumulativeOutflowVolume(0);
        mockOperator.setBypassRedeemLiquidityCheck(true);
        mockOperator.setAllowOutflowExceedLimit(true);

        cl.assertion({
            adopter: address(mockMTokenVuln),
            createData: type(mTokenRedeemOutflowAssertion).creationCode,
            fnSelector: mTokenRedeemOutflowAssertion.assertionRedeemOutflowLimit.selector
        });

        // Use batch contract to execute multiple redeems in single transaction
        // 3 × $400 = $1200 total, exceeds $1000 limit on 3rd call
        vm.expectRevert("Redeem would exceed outflow limit");
        batchRedeem.executeMultipleRedeems(
            ImErc20(address(mockMTokenVuln)),
            400e6, // $400 per redeem in 6-decimal USDC
            3
        );
    }
}
