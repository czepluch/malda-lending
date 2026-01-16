// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IOracleOperator} from "../../../src/interfaces/IOracleOperator.sol";

/**
 * @title MockOracleVulnerable
 * @notice Mock oracle that can simulate vulnerable price behavior for testing assertions
 * @dev Allows controlled manipulation of prices, staleness, and feed deviations
 */
contract MockOracleVulnerable is IOracleOperator {
    // ============ Behavior Control Flags ============

    bool public returnZeroPrice;
    bool public returnStalePrice;
    bool public allowExcessiveFeedDeviation;

    // ============ State Management ============

    // Price overrides per mToken
    mapping(address => uint256) public priceOverrides;
    mapping(address => bool) public hasPriceOverride; // Track if override is explicitly set

    // Staleness control - timestamp overrides
    mapping(address => uint256) public stalenessOverrides;
    bool public useCustomStaleness;

    // Feed deviation simulation (for cross-feed tests)
    mapping(address => FeedPrices) public feedPriceOverrides;
    bool public useCustomFeedPrices;

    struct FeedPrices {
        uint256 api3Price;
        uint256 eOraclePrice;
        bool isSet;
    }

    // Default safe values
    uint256 public constant DEFAULT_PRICE = 1e30; // Standard 30 decimal oracle price
    uint256 public defaultTimestamp;

    constructor() {
        defaultTimestamp = block.timestamp;
    }

    // ============ Configuration Functions ============

    function setReturnZeroPrice(bool _return) external {
        returnZeroPrice = _return;
    }

    function setReturnStalePrice(bool _return) external {
        returnStalePrice = _return;
    }

    function setAllowExcessiveFeedDeviation(bool _allow) external {
        allowExcessiveFeedDeviation = _allow;
    }

    function setPriceOverride(address mToken, uint256 price) external {
        priceOverrides[mToken] = price;
        hasPriceOverride[mToken] = true;
    }

    function setStalenessOverride(address mToken, uint256 timestamp) external {
        stalenessOverrides[mToken] = timestamp;
        useCustomStaleness = true;
    }

    function setFeedPrices(address mToken, uint256 api3Price, uint256 eOraclePrice) external {
        feedPriceOverrides[mToken] = FeedPrices({
            api3Price: api3Price,
            eOraclePrice: eOraclePrice,
            isSet: true
        });
        useCustomFeedPrices = true;
    }

    function setDefaultTimestamp(uint256 timestamp) external {
        defaultTimestamp = timestamp;
    }

    // ============ IOracleOperator Implementation ============

    /**
     * @notice Returns the price for an mToken (alias for getUnderlyingPrice)
     * @dev Required by IOracleOperator interface
     */
    function getPrice(address mToken) external view returns (uint256) {
        return this.getUnderlyingPrice(mToken);
    }

    /**
     * @notice Returns the price for an mToken
     * @dev Can return zero, stale, or custom prices based on flags
     */
    function getUnderlyingPrice(address mToken) external view returns (uint256) {
        // Return zero if flag is set
        if (returnZeroPrice) {
            return 0;
        }

        // Return custom price if explicitly set (even if zero)
        if (hasPriceOverride[mToken]) {
            return priceOverrides[mToken];
        }

        // Default safe price
        return DEFAULT_PRICE;
    }

    /**
     * @notice Returns the timestamp of the last price update
     * @dev Can return stale timestamps if flag is set
     */
    function getUnderlyingPriceTimestamp(address mToken) external view returns (uint256) {
        // Return stale timestamp if flag is set
        if (returnStalePrice) {
            return block.timestamp - 8 days; // Older than typical 7-day max staleness
        }

        // Return custom timestamp if set
        if (useCustomStaleness && stalenessOverrides[mToken] > 0) {
            return stalenessOverrides[mToken];
        }

        // Default to current timestamp
        return defaultTimestamp;
    }

    /**
     * @notice Mock implementation of price feed validation
     * @dev Can be used to simulate feed deviation issues
     */
    function validateFeeds(address mToken) external view returns (bool) {
        // If excessive deviation is allowed, validation "passes" (vulnerable behavior)
        if (allowExcessiveFeedDeviation) {
            return true;
        }

        // Normal behavior: validation passes
        return true;
    }

    /**
     * @notice Get individual feed prices (for cross-feed deviation testing)
     * @dev Returns custom feed prices if set, otherwise returns same price for both
     */
    function getFeedPrices(address mToken) external view returns (uint256 api3Price, uint256 eOraclePrice) {
        if (useCustomFeedPrices && feedPriceOverrides[mToken].isSet) {
            return (feedPriceOverrides[mToken].api3Price, feedPriceOverrides[mToken].eOraclePrice);
        }

        // Default: both feeds return same price
        uint256 price = priceOverrides[mToken] > 0 ? priceOverrides[mToken] : DEFAULT_PRICE;
        return (price, price);
    }

    /**
     * @notice Reset all overrides to default state
     */
    function resetOverrides() external {
        returnZeroPrice = false;
        returnStalePrice = false;
        allowExcessiveFeedDeviation = false;
        useCustomStaleness = false;
        useCustomFeedPrices = false;
        defaultTimestamp = block.timestamp;
    }
}
