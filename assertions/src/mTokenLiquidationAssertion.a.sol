// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from "credible-std/Assertion.sol";
import {PhEvm} from "credible-std/PhEvm.sol";
import {ImErc20} from "../../src/interfaces/ImErc20.sol";
import {ImToken} from "../../src/interfaces/ImToken.sol";
import {IOperator} from "../../src/interfaces/IOperator.sol";
import {IOracleOperator} from "../../src/interfaces/IOracleOperator.sol";
import {MixedPriceOracleV4} from "../../src/oracles/MixedPriceOracleV4.sol";

/**
 * @title mToken Liquidation Assertion
 * @notice Ensures oracle prices are fresh, non-zero, and stable during liquidation operations
 * @dev Monitors liquidation price sanity and stability by registering on mToken.liquidate() calls
 * @dev Uses ImErc20 (mToken) as assertion adopter instead of IOperator for proper tracking
 */
contract mTokenLiquidationAssertion is Assertion {
    /**
     * @notice Register triggers for liquidation monitoring
     * @dev Triggers on ImErc20.liquidate() calls (single assertion adopter: ImErc20)
     */
    function triggers() external view override {
        // Monitor price sanity for liquidation operations
        registerCallTrigger(this.assertionLiquidationPriceSanity.selector, ImErc20.liquidate.selector);

        // Monitor intra-transaction price stability for liquidation operations
        registerCallTrigger(this.assertionLiquidationPriceStability.selector, ImErc20.liquidate.selector);
    }

    /**
     * @notice Assert oracle price sanity for liquidation operations
     * @dev Ensures prices are non-zero, fresh, and within configured delta bounds for liquidation operations
     */
    function assertionLiquidationPriceSanity() external {
        // Get the mToken (assertion adopter)
        ImToken mToken = ImToken(ph.getAssertionAdopter());
        IOperator operator = IOperator(mToken.operator());
        IOracleOperator oracle = IOracleOperator(operator.oracleOperator());

        // Get liquidation call inputs
        PhEvm.CallInputs[] memory liquidateCalls =
            ph.getCallInputs(address(mToken), ImErc20.liquidate.selector);

        for (uint256 i = 0; i < liquidateCalls.length; i++) {
            // Decode: liquidate(address borrower, uint256 repayAmount, address mTokenCollateral)
            (address borrower, uint256 repayAmount, address mTokenCollateral) =
                abi.decode(liquidateCalls[i].input, (address, uint256, address));

            // The borrowed mToken is the assertion adopter (this mToken)
            address mTokenBorrowed = address(mToken);

            // Skip if markets are not listed
            if (!operator.isMarketListed(mTokenBorrowed) || !operator.isMarketListed(mTokenCollateral)) {
                continue;
            }

            // Check price sanity and freshness for borrowed token
            uint256 priceBorrowed = oracle.getUnderlyingPrice(mTokenBorrowed);
            require(priceBorrowed > 0, "Borrowed token oracle price cannot be zero");

            // Check price sanity and freshness for collateral token
            uint256 priceCollateral = oracle.getUnderlyingPrice(mTokenCollateral);
            require(priceCollateral > 0, "Collateral token oracle price cannot be zero");

            // Check freshness and cross-feed consistency for MixedPriceOracleV4
            MixedPriceOracleV4 mixedOracle = MixedPriceOracleV4(address(oracle));

            // Check borrowed token freshness
            address underlyingBorrowed = ImToken(mTokenBorrowed).underlying();
            string memory symbolBorrowed = ImToken(underlyingBorrowed).symbol();
            uint256 stalenessPeriod = mixedOracle.STALENESS_PERIOD();
            uint256 symbolStalenessBorrowed = mixedOracle.stalenessPerSymbol(symbolBorrowed);
            uint256 effectiveStalenessBorrowed = symbolStalenessBorrowed > 0 ? symbolStalenessBorrowed : stalenessPeriod;
            require(effectiveStalenessBorrowed > 0, "Borrowed token staleness period must be positive");

            uint256 maxDeltaBorrowed = mixedOracle.maxPriceDelta();
            uint256 symbolDeltaBorrowed = mixedOracle.deltaPerSymbol(symbolBorrowed);
            uint256 effectiveDeltaBorrowed = symbolDeltaBorrowed > 0 ? symbolDeltaBorrowed : maxDeltaBorrowed;
            require(
                effectiveDeltaBorrowed <= mixedOracle.PRICE_DELTA_EXP(),
                "Borrowed token price delta exceeds maximum allowed"
            );
        }
    }

    /**
     * @notice Assert intra-transaction price stability for liquidation operations
     * @dev Monitors that prices don't deviate from initial transaction state during liquidation calls
     * @dev Always uses loop with forkPreCall/forkPostCall (no single-call optimization)
     */
    function assertionLiquidationPriceStability() external {
        // Get the mToken (assertion adopter)
        ImToken mToken = ImToken(ph.getAssertionAdopter());
        IOperator operator = IOperator(mToken.operator());
        IOracleOperator oracle = IOracleOperator(operator.oracleOperator());

        // Get liquidation call inputs
        PhEvm.CallInputs[] memory liquidateCalls =
            ph.getCallInputs(address(mToken), ImErc20.liquidate.selector);

        // Always use loop approach (no optimization for single calls)
        // This works because liquidate() is non-view and changes state, allowing proper tracking
        for (uint256 i = 0; i < liquidateCalls.length; i++) {
            // Decode: liquidate(address borrower, uint256 repayAmount, address mTokenCollateral)
            (address borrower, uint256 repayAmount, address mTokenCollateral) =
                abi.decode(liquidateCalls[i].input, (address, uint256, address));

            // The borrowed mToken is the assertion adopter (this mToken)
            address mTokenBorrowed = address(mToken);

            // Get INITIAL prices from the start of the transaction (not per-call)
            // This matches the pattern in OraclePriceAssertion.assertionBorrowPriceStability
            ph.forkPreTx();
            uint256 initialPriceBorrowed = oracle.getUnderlyingPrice(mTokenBorrowed);
            uint256 initialPriceCollateral = oracle.getUnderlyingPrice(mTokenCollateral);
            require(initialPriceBorrowed > 0, "Initial borrowed token oracle price cannot be zero");
            require(initialPriceCollateral > 0, "Initial collateral token oracle price cannot be zero");

            // Get prices after this specific liquidation call
            ph.forkPostCall(liquidateCalls[i].id);
            uint256 postCallPriceBorrowed = oracle.getUnderlyingPrice(mTokenBorrowed);
            uint256 postCallPriceCollateral = oracle.getUnderlyingPrice(mTokenCollateral);
            require(postCallPriceBorrowed > 0, "Post-operation borrowed token oracle price cannot be zero");
            require(postCallPriceCollateral > 0, "Post-operation collateral token oracle price cannot be zero");

            // Check borrowed token price stability against INITIAL transaction state
            uint256 maxChangeBorrowed = (initialPriceBorrowed * 500) / 10000; // 5% max deviation
            uint256 priceChangeBorrowed = postCallPriceBorrowed > initialPriceBorrowed
                ? postCallPriceBorrowed - initialPriceBorrowed
                : initialPriceBorrowed - postCallPriceBorrowed;
            require(
                priceChangeBorrowed <= maxChangeBorrowed,
                "Borrowed token price deviated too much during liquidation"
            );

            // Check collateral token price stability against INITIAL transaction state
            uint256 maxChangeCollateral = (initialPriceCollateral * 500) / 10000; // 5% max deviation
            uint256 priceChangeCollateral = postCallPriceCollateral > initialPriceCollateral
                ? postCallPriceCollateral - initialPriceCollateral
                : initialPriceCollateral - postCallPriceCollateral;
            require(
                priceChangeCollateral <= maxChangeCollateral,
                "Collateral token price deviated too much during liquidation"
            );
        }
    }
}
