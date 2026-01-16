// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from "credible-std/Assertion.sol";
import {PhEvm} from "credible-std/PhEvm.sol";
import {MixedPriceOracleV4} from "../../src/oracles/MixedPriceOracleV4.sol";

/**
 * @title Oracle Configuration Assertion
 * @notice Ensures oracle configuration changes are valid and reasonable
 * @dev Monitors oracle configuration changes to prevent invalid or dangerous settings
 */
contract OracleConfigAssertion is Assertion {
    /**
     * @notice Register triggers for oracle configuration monitoring
     * @dev Triggers on oracle configuration changes (single assertion adopter: MixedPriceOracleV4)
     */
    function triggers() external view override {
        // Monitor specific oracle configuration changes with focused assertions
        registerCallTrigger(this.assertionConfigValidity.selector, MixedPriceOracleV4.setConfig.selector);
        registerCallTrigger(this.assertionStalenessValidity.selector, MixedPriceOracleV4.setStaleness.selector);
        registerCallTrigger(this.assertionMaxDeltaValidity.selector, MixedPriceOracleV4.setMaxPriceDelta.selector);
        registerCallTrigger(
            this.assertionSymbolDeltaValidity.selector, MixedPriceOracleV4.setSymbolMaxPriceDelta.selector
        );
    }

    /**
     * @notice Assert oracle config validity
     * @dev Ensures setConfig calls are valid and don't introduce dangerous settings
     */
    function assertionConfigValidity() external {
        MixedPriceOracleV4 oracle = MixedPriceOracleV4(ph.getAssertionAdopter());

        // Get config calls in this transaction
        PhEvm.CallInputs[] memory configCalls = ph.getCallInputs(address(oracle), MixedPriceOracleV4.setConfig.selector);

        // Validate configuration calls
        _validateConfigCalls(configCalls);
    }

    /**
     * @notice Assert oracle staleness validity
     * @dev Ensures setStaleness calls are valid and don't introduce dangerous settings
     */
    function assertionStalenessValidity() external {
        MixedPriceOracleV4 oracle = MixedPriceOracleV4(ph.getAssertionAdopter());

        // Check that global staleness period is reasonable
        uint256 stalenessPeriod = oracle.STALENESS_PERIOD();
        require(stalenessPeriod <= 7 days, "Global staleness period too long (exceeds 7 days)");
        require(stalenessPeriod > 0, "Staleness period must be positive");

        // Get staleness calls in this transaction
        PhEvm.CallInputs[] memory stalenessCalls =
            ph.getCallInputs(address(oracle), MixedPriceOracleV4.setStaleness.selector);

        // Validate staleness calls
        _validateStalenessCalls(stalenessCalls);
    }

    /**
     * @notice Assert oracle max delta validity
     * @dev Ensures setMaxPriceDelta calls are valid and don't introduce dangerous settings
     */
    function assertionMaxDeltaValidity() external {
        MixedPriceOracleV4 oracle = MixedPriceOracleV4(ph.getAssertionAdopter());

        // Check that max price delta is reasonable
        uint256 maxDelta = oracle.maxPriceDelta();
        require(maxDelta <= 10e3, "Max price delta too high (exceeds 10%)");
        require(maxDelta > 0, "Max price delta must be positive");

        // Get delta calls in this transaction
        PhEvm.CallInputs[] memory deltaCalls =
            ph.getCallInputs(address(oracle), MixedPriceOracleV4.setMaxPriceDelta.selector);

        // Validate delta calls
        _validateDeltaCalls(deltaCalls);
    }

    /**
     * @notice Assert oracle symbol delta validity
     * @dev Ensures setSymbolMaxPriceDelta calls are valid and don't introduce dangerous settings
     */
    function assertionSymbolDeltaValidity() external {
        // Get symbol delta calls in this transaction
        MixedPriceOracleV4 oracle = MixedPriceOracleV4(ph.getAssertionAdopter());
        PhEvm.CallInputs[] memory symbolDeltaCalls =
            ph.getCallInputs(address(oracle), MixedPriceOracleV4.setSymbolMaxPriceDelta.selector);

        // Validate symbol delta calls
        _validateSymbolDeltaCalls(symbolDeltaCalls);
    }

    /**
     * @notice Validate configuration calls
     */
    function _validateConfigCalls(PhEvm.CallInputs[] memory calls) internal pure {
        for (uint256 i = 0; i < calls.length; i++) {
            (string memory symbol, MixedPriceOracleV4.PriceConfig memory config) =
                abi.decode(calls[i].input, (string, MixedPriceOracleV4.PriceConfig));

            // Validate config
            require(bytes(symbol).length > 0, "Symbol cannot be empty");
            require(config.api3Feed != address(0), "API3 feed cannot be zero address");
            require(config.eOracleFeed != address(0), "eOracle feed cannot be zero address");
            require(config.underlyingDecimals <= 18, "Underlying decimals cannot exceed 18");
            require(config.underlyingDecimals > 0, "Underlying decimals must be positive");
        }
    }

    /**
     * @notice Validate staleness calls
     */
    function _validateStalenessCalls(PhEvm.CallInputs[] memory calls) internal pure {
        for (uint256 i = 0; i < calls.length; i++) {
            (string memory symbol, uint256 staleness) = abi.decode(calls[i].input, (string, uint256));

            require(bytes(symbol).length > 0, "Symbol cannot be empty");
            require(staleness <= 7 days, "Symbol staleness too long (exceeds 7 days)");
            require(staleness > 0, "Symbol staleness must be positive");
        }
    }

    /**
     * @notice Validate max delta calls
     */
    function _validateDeltaCalls(PhEvm.CallInputs[] memory calls) internal pure {
        for (uint256 i = 0; i < calls.length; i++) {
            uint256 delta = abi.decode(calls[i].input, (uint256));

            require(delta <= 10e3, "Max price delta too high (exceeds 10%)");
            require(delta > 0, "Max price delta must be positive");
        }
    }

    /**
     * @notice Validate symbol delta calls
     */
    function _validateSymbolDeltaCalls(PhEvm.CallInputs[] memory calls) internal pure {
        for (uint256 i = 0; i < calls.length; i++) {
            (uint256 delta, string memory symbol) = abi.decode(calls[i].input, (uint256, string));

            require(bytes(symbol).length > 0, "Symbol cannot be empty");
            require(delta <= 10e3, "Symbol price delta too high (exceeds 10%)");
            require(delta > 0, "Symbol price delta must be positive");
        }
    }
}
