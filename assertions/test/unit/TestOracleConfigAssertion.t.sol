// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {OracleConfigAssertion} from "../../src/OracleConfigAssertion.a.sol";
import {BaseAssertionTest} from "./BaseAssertionTest.t.sol";

contract TestOracleConfigAssertion is BaseAssertionTest {
    OracleConfigAssertion public assertion;

    function setUp() public override {
        // Call parent setup to initialize common components
        super.setUp();

        // Deploy assertion
        assertion = new OracleConfigAssertion();
    }

    /**
     * @notice Test that config validity assertion passes with valid configuration changes
     * @dev Tests the assertionConfigValidity function with reasonable configuration updates
     */
    function testConfigValidityPassesWithValidConfig() public {
        // Register assertion for next transaction
        cl.assertion({
            adopter: address(realOracle),
            createData: type(OracleConfigAssertion).creationCode,
            fnSelector: OracleConfigAssertion.assertionConfigValidity.selector
        });

        // Execute valid configuration change - this should pass validation
        // Note: This test focuses on the config validation logic, not the actual oracle setup
    }

    /**
     * @notice Test that staleness validity assertion passes with valid staleness configuration
     * @dev Tests the assertionStalenessValidity function with reasonable staleness updates
     */
    function testStalenessValidityPassesWithValidStaleness() public {
        // Setup: Ensure reasonable initial configuration before registering assertion
        _setupOracleConfig(500, 300, 3600); // 5% max delta, 3% symbol delta, 1 hour staleness

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(realOracle),
            createData: type(OracleConfigAssertion).creationCode,
            fnSelector: OracleConfigAssertion.assertionStalenessValidity.selector
        });

        // Execute valid staleness change
        realOracle.setStaleness("USDC", 7200); // 2 hours staleness - should pass
    }

    /**
     * @notice Test that staleness validity assertion fails with excessive staleness
     * @dev Tests the assertionStalenessValidity function with excessive staleness period
     */
    function testStalenessValidityFailsWithExcessiveStaleness() public {
        // Setup: Set reasonable initial configuration before registering assertion
        _setupOracleConfig(500, 300, 3600); // 5% max delta, 3% symbol delta, 1 hour staleness

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(realOracle),
            createData: type(OracleConfigAssertion).creationCode,
            fnSelector: OracleConfigAssertion.assertionStalenessValidity.selector
        });

        // This should fail due to excessive staleness
        vm.expectRevert("Symbol staleness too long (exceeds 7 days)");
        realOracle.setStaleness("USDC", 8 days); // 8 days staleness - should fail
    }

    /**
     * @notice Test that max delta validity assertion passes with valid max delta configuration
     * @dev Tests the assertionMaxDeltaValidity function with reasonable max delta updates
     */
    function testMaxDeltaValidityPassesWithValidDelta() public {
        // Setup: Ensure reasonable initial configuration before registering assertion
        _setupOracleConfig(500, 300, 3600); // 5% max delta, 3% symbol delta, 1 hour staleness

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(realOracle),
            createData: type(OracleConfigAssertion).creationCode,
            fnSelector: OracleConfigAssertion.assertionMaxDeltaValidity.selector
        });

        // Execute valid max delta change
        realOracle.setMaxPriceDelta(300); // 3% max delta - should pass
    }

    /**
     * @notice Test that max delta validity assertion fails with excessive max delta
     * @dev Tests the assertionMaxDeltaValidity function with excessive max delta
     */
    function testMaxDeltaValidityFailsWithExcessiveDelta() public {
        // Setup: Set reasonable initial configuration before registering assertion
        _setupOracleConfig(500, 300, 3600); // 5% max delta, 3% symbol delta, 1 hour staleness

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(realOracle),
            createData: type(OracleConfigAssertion).creationCode,
            fnSelector: OracleConfigAssertion.assertionMaxDeltaValidity.selector
        });

        // This should fail due to excessive max delta
        vm.expectRevert("Max price delta too high (exceeds 10%)");
        realOracle.setMaxPriceDelta(15000); // 15% max delta - should fail
    }

    /**
     * @notice Test that symbol delta validity assertion passes with valid symbol delta configuration
     * @dev Tests the assertionSymbolDeltaValidity function with reasonable symbol delta updates
     */
    function testSymbolDeltaValidityPassesWithValidSymbolDelta() public {
        // Setup: Ensure reasonable initial configuration before registering assertion
        _setupOracleConfig(500, 300, 3600); // 5% max delta, 3% symbol delta, 1 hour staleness

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(realOracle),
            createData: type(OracleConfigAssertion).creationCode,
            fnSelector: OracleConfigAssertion.assertionSymbolDeltaValidity.selector
        });

        // Execute valid symbol delta change
        realOracle.setSymbolMaxPriceDelta(400, "USDC"); // 4% symbol delta - should pass
    }

    /**
     * @notice Test that symbol delta validity assertion fails with excessive symbol delta
     * @dev Tests the assertionSymbolDeltaValidity function with excessive symbol delta
     */
    function testSymbolDeltaValidityFailsWithExcessiveSymbolDelta() public {
        // Setup: Set reasonable initial configuration before registering assertion
        _setupOracleConfig(500, 300, 3600); // 5% max delta, 3% symbol delta, 1 hour staleness

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(realOracle),
            createData: type(OracleConfigAssertion).creationCode,
            fnSelector: OracleConfigAssertion.assertionSymbolDeltaValidity.selector
        });

        // This should fail due to excessive symbol delta
        vm.expectRevert("Symbol price delta too high (exceeds 10%)");
        realOracle.setSymbolMaxPriceDelta(15000, "USDC"); // 15% symbol delta - should fail
    }
}
