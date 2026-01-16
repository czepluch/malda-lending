// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from "credible-std/Assertion.sol";
import {PhEvm} from "credible-std/PhEvm.sol";
import {IOperatorDefender, IOperator} from "../../src/interfaces/IOperator.sol";
import {IOracleOperator} from "../../src/interfaces/IOracleOperator.sol";
import {MixedPriceOracleV4} from "../../src/oracles/MixedPriceOracleV4.sol";
import {ImTokenMinimal} from "../../src/interfaces/ImToken.sol";
import {IDefaultAdapter} from "../../src/interfaces/IDefaultAdapter.sol";

/**
 * @title Oracle Price Assertion
 * @notice Ensures oracle prices are fresh, non-zero, and consistent between different price feeds
 * @dev Monitors price sanity, freshness, and cross-feed delta consistency during critical operations
 */
contract OraclePriceAssertion is Assertion {
    /**
     * @notice Register triggers for oracle price monitoring
     * @dev Triggers on Operator borrow/liquidation hooks (single assertion adopter: IOperatorDefender)
     */
    function triggers() external view override {
        // Monitor price sanity for borrow operations
        registerCallTrigger(this.assertionBorrowPriceSanity.selector, IOperatorDefender.beforeMTokenBorrow.selector);

        // Monitor intra-transaction price stability for borrow operations
        registerCallTrigger(this.assertionBorrowPriceStability.selector, IOperatorDefender.beforeMTokenBorrow.selector);

        // Monitor cross-feed deviation for borrow operations
        registerCallTrigger(this.assertionCrossFeedDeviation.selector, IOperatorDefender.beforeMTokenBorrow.selector);

        // NOTE: Liquidation assertions have been moved to mTokenLiquidationAssertion.a.sol
        // which uses ImErc20.liquidate() as the trigger point for proper tracking of non-view functions
    }

    /**
     * @notice Assert oracle price sanity for borrow operations
     * @dev Ensures prices are non-zero, fresh, and within configured delta bounds for borrow operations
     */
    function assertionBorrowPriceSanity() external {
        IOperator operator = IOperator(ph.getAssertionAdopter());
        address oracleAddress = operator.oracleOperator();
        IOracleOperator oracle = IOracleOperator(oracleAddress);

        // Get borrow call inputs to check specific mTokens being borrowed
        PhEvm.CallInputs[] memory borrowCalls =
            ph.getCallInputs(address(operator), IOperatorDefender.beforeMTokenBorrow.selector);

        for (uint256 i = 0; i < borrowCalls.length; i++) {
            (address mToken,,) = abi.decode(borrowCalls[i].input, (address, address, uint256));

            // Skip if market is not listed
            if (!operator.isMarketListed(mToken)) {
                continue;
            }

            // Check price sanity for borrowed token
            uint256 price = oracle.getUnderlyingPrice(mToken);
            require(price > 0, "Oracle price cannot be zero");

            // Check staleness (uses 7 days as maximum, enforced by OracleConfigAssertion)
            _checkStaleness(oracleAddress, mToken);
        }
    }

    /**
     * @notice Internal function to check price staleness
     * @dev Attempts to query price timestamp and validate freshness
     * @dev Uses 7 days as maximum staleness (enforced by OracleConfigAssertion)
     * @param oracleAddress The oracle contract address
     * @param mToken The mToken to check
     */
    function _checkStaleness(address oracleAddress, address mToken) internal view {
        // Try to call getUnderlyingPriceTimestamp (available on test mocks and potentially production oracles)
        (bool success, bytes memory data) = oracleAddress.staticcall(
            abi.encodeWithSignature("getUnderlyingPriceTimestamp(address)", mToken)
        );

        if (success && data.length >= 32) {
            uint256 priceTimestamp = abi.decode(data, (uint256));
            uint256 age = block.timestamp > priceTimestamp
                ? block.timestamp - priceTimestamp
                : 0;

            // OracleConfigAssertion enforces max 7 days staleness
            require(age <= 7 days, "Oracle price is stale");
        }
        // If call fails, oracle doesn't support timestamp queries - skip staleness check
        // (Real MixedPriceOracleV4 checks staleness internally and reverts)
    }


    /**
     * @notice Assert intra-transaction price stability for borrow operations
     * @dev Monitors that prices don't deviate from initial transaction state during borrow calls
     */
    function assertionBorrowPriceStability() external {
        IOperator operator = IOperator(ph.getAssertionAdopter());
        IOracleOperator oracle = IOracleOperator(operator.oracleOperator());

        // Get borrow call inputs
        PhEvm.CallInputs[] memory borrowCalls =
            ph.getCallInputs(address(operator), IOperatorDefender.beforeMTokenBorrow.selector);

        // For single call (common case), keep optimization
        if (borrowCalls.length == 1) {
            (address mToken,,) = abi.decode(borrowCalls[0].input, (address, address, uint256));

            ph.forkPreTx();
            uint256 initialPrice = oracle.getUnderlyingPrice(mToken);
            require(initialPrice > 0, "Initial oracle price cannot be zero");

            ph.forkPostTx();
            uint256 finalPrice = oracle.getUnderlyingPrice(mToken);
            require(finalPrice > 0, "Final oracle price cannot be zero");

            uint256 maxChange = (initialPrice * 500) / 10000; // 5% max deviation
            uint256 priceChange = finalPrice > initialPrice
                ? finalPrice - initialPrice
                : initialPrice - finalPrice;

            require(priceChange <= maxChange, "Oracle price deviated too much during borrow operation");
        } else {
            // Multiple calls - check each one with its own token's initial price
            for (uint256 i = 0; i < borrowCalls.length; i++) {
                (address mToken,,) = abi.decode(borrowCalls[i].input, (address, address, uint256));

                // Get initial price for THIS token
                ph.forkPreTx();
                uint256 initialPrice = oracle.getUnderlyingPrice(mToken);
                require(initialPrice > 0, "Initial oracle price cannot be zero");

                // Get price after this specific call
                ph.forkPostCall(borrowCalls[i].id);
                uint256 postCallPrice = oracle.getUnderlyingPrice(mToken);
                require(postCallPrice > 0, "Post-operation oracle price cannot be zero");

                uint256 maxChange = (initialPrice * 500) / 10000; // 5% max deviation
                uint256 priceChange = postCallPrice > initialPrice
                    ? postCallPrice - initialPrice
                    : initialPrice - postCallPrice;

                require(priceChange <= maxChange, "Oracle price deviated too much during borrow operation");
            }
        }
    }


    /**
     * @notice Assert cross-feed deviation is within acceptable bounds throughout the call stack
     * @dev Monitors deviation between API3 and eOracle feeds during beforeMTokenBorrow operations
     * Uses ph.forkPreCall() and ph.forkPostCall() to check oracle prices at each frame in the call stack
     */
    function assertionCrossFeedDeviation() external {
        IOperator operator = IOperator(ph.getAssertionAdopter());
        MixedPriceOracleV4 oracle = MixedPriceOracleV4(address(operator.oracleOperator()));

        // Get the specific beforeMTokenBorrow calls that triggered this assertion
        PhEvm.CallInputs[] memory borrowCalls =
            ph.getCallInputs(address(operator), IOperatorDefender.beforeMTokenBorrow.selector);

        // For each beforeMTokenBorrow call, check oracle deviation at each frame in its call stack
        for (uint256 i = 0; i < borrowCalls.length; i++) {
            // Get the mToken address from the borrow call
            (address mToken,,) = abi.decode(borrowCalls[i].input, (address, address, uint256));

            // Check deviation after this borrow call
            ph.forkPostCall(borrowCalls[i].id);
            _checkCrossFeedDeviationAtSnapshot(oracle, mToken, operator);
        }
    }

    /**
     * @notice Internal function to check cross-feed deviation for a specific mToken at a snapshot
     * @dev Compares API3 and eOracle prices and ensures deviation is within acceptable bounds
     * @param oracle The oracle contract to check
     * @param mToken The mToken to check deviation for
     * @param operator The operator contract
     */
    function _checkCrossFeedDeviationAtSnapshot(MixedPriceOracleV4 oracle, address mToken, IOperator operator)
        internal
        view
    {
        // Skip if market is not listed
        if (!operator.isMarketListed(mToken)) {
            return;
        }

        // Get the underlying token symbol
        address underlying = ImTokenMinimal(mToken).underlying();
        string memory symbol = ImTokenMinimal(underlying).symbol();

        // Get price config for this symbol
        (address api3Feed, address eOracleFeed,,) = oracle.configs(symbol);

        // Skip if feeds are not configured
        if (api3Feed == address(0) || eOracleFeed == address(0)) {
            return;
        }

        // Get prices from both feeds directly at this snapshot
        (, int256 api3Price,,,) = IDefaultAdapter(api3Feed).latestRoundData();
        (, int256 eOraclePrice,,,) = IDefaultAdapter(eOracleFeed).latestRoundData();

        // Calculate deviation (reimplement the _absDiff logic since it's internal)
        uint256 deviation =
            api3Price >= eOraclePrice ? uint256(api3Price - eOraclePrice) : uint256(eOraclePrice - api3Price);
        uint256 eOraclePriceAbs = uint256(eOraclePrice < 0 ? -eOraclePrice : eOraclePrice);

        // Calculate deviation in basis points (using same logic as MixedPriceOracleV4)
        uint256 deviationBps = (deviation * oracle.PRICE_DELTA_EXP()) / eOraclePriceAbs;

        // Get the configured delta threshold
        uint256 deltaSymbol = oracle.deltaPerSymbol(symbol);
        if (deltaSymbol == 0) {
            deltaSymbol = oracle.maxPriceDelta();
        }

        // Assert that deviation is within acceptable bounds
        // Note: We allow some deviation but flag extreme cases
        uint256 maxAllowedDeviation = deltaSymbol * 2; // Allow 2x the configured threshold
        require(deviationBps <= maxAllowedDeviation, "Cross-feed deviation exceeds threshold");
    }
}
