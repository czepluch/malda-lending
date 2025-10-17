// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IRebalancer, IRebalanceMarket} from "../../../src/interfaces/IRebalancer.sol";
import {IRoles} from "../../../src/interfaces/IRoles.sol";
import {IBridge} from "../../../src/interfaces/IBridge.sol";
import {ImTokenMinimal} from "../../../src/interfaces/ImToken.sol";

/**
 * @title MockRebalancerVulnerable
 * @notice Mock rebalancer with vulnerability flags for testing assertions
 * @dev Simulates various attack scenarios and misconfigurations
 */
contract MockRebalancerVulnerable is IRebalancer {
    // ========== STATE ==========

    IRoles public roles;
    uint256 public nonce;
    address public saveAddress;
    uint256 public transferTimeWindow;

    // Allowlists
    mapping(address => bool) public whitelistedBridges;
    mapping(uint32 => bool) public whitelistedDestinations;
    mapping(address => bool) public allowedList; // Markets
    mapping(address => mapping(address => bool)) public allowedTokensPerBridge;
    mapping(address => bool) public whitelistedMarkets;

    // Transfer size limits
    mapping(uint32 => mapping(address => uint256)) public minTransferSizes;
    mapping(uint32 => mapping(address => uint256)) public maxTransferSizes;

    // Transfer tracking for rate limiting
    struct TransferInfo {
        uint256 size;
        uint256 timestamp;
    }
    mapping(uint32 => mapping(address => TransferInfo)) public currentTransferSize;
    mapping(uint32 => uint256) public logs; // Simplified logs

    // ========== VULNERABILITY FLAGS ==========

    // Allowlist bypasses
    bool public bypassBridgeWhitelist;
    bool public bypassDestinationWhitelist;
    bool public bypassMarketAllowlist;
    bool public bypassTokenAllowlist;

    // Transfer size bypasses
    bool public bypassMinSizeCheck;
    bool public bypassMaxSizeCheck;

    // Rate limiting vulnerabilities
    bool public skipTimeWindowReset;
    bool public allowEarlyReset;
    bool public skipCumulativeTracking;

    // Authorization bypasses
    bool public bypassRoleCheck;

    // Operational bypasses
    bool public skipMarketExtraction;
    bool public skipBridgeCall;
    bool public returnWrongUnderlying;

    // Parameter validation bypasses
    bool public allowZeroAmount;
    bool public allowZeroAddresses;
    bool public allowSameChain;

    // ========== CONSTRUCTOR ==========

    constructor(address _roles, address _saveAddress) {
        roles = IRoles(_roles);
        saveAddress = _saveAddress;
        transferTimeWindow = 86400; // Default 1 day
    }

    // ========== VULNERABILITY FLAG SETTERS ==========

    function setBypassBridgeWhitelist(bool _bypass) external {
        bypassBridgeWhitelist = _bypass;
    }

    function setBypassDestinationWhitelist(bool _bypass) external {
        bypassDestinationWhitelist = _bypass;
    }

    function setBypassMarketAllowlist(bool _bypass) external {
        bypassMarketAllowlist = _bypass;
    }

    function setBypassTokenAllowlist(bool _bypass) external {
        bypassTokenAllowlist = _bypass;
    }

    function setBypassMinSizeCheck(bool _bypass) external {
        bypassMinSizeCheck = _bypass;
    }

    function setBypassMaxSizeCheck(bool _bypass) external {
        bypassMaxSizeCheck = _bypass;
    }

    function setSkipTimeWindowReset(bool _skip) external {
        skipTimeWindowReset = _skip;
    }

    function setAllowEarlyReset(bool _allow) external {
        allowEarlyReset = _allow;
    }

    function setSkipCumulativeTracking(bool _skip) external {
        skipCumulativeTracking = _skip;
    }

    function setBypassRoleCheck(bool _bypass) external {
        bypassRoleCheck = _bypass;
    }

    function setSkipMarketExtraction(bool _skip) external {
        skipMarketExtraction = _skip;
    }

    function setSkipBridgeCall(bool _skip) external {
        skipBridgeCall = _skip;
    }

    function setReturnWrongUnderlying(bool _wrong) external {
        returnWrongUnderlying = _wrong;
    }

    function setAllowZeroAmount(bool _allow) external {
        allowZeroAmount = _allow;
    }

    function setAllowZeroAddresses(bool _allow) external {
        allowZeroAddresses = _allow;
    }

    function setAllowSameChain(bool _allow) external {
        allowSameChain = _allow;
    }

    // ========== CONFIGURATION SETTERS ==========

    function setWhitelistedBridgeStatus(address bridge, bool status) external {
        whitelistedBridges[bridge] = status;
    }

    function setWhitelistedDestination(uint32 dstChainId, bool status) external {
        whitelistedDestinations[dstChainId] = status;
    }

    function setAllowList(address[] memory markets, bool status) external {
        for (uint256 i = 0; i < markets.length; i++) {
            allowedList[markets[i]] = status;
        }
    }

    function setMarketStatus(address[] memory markets, bool status) external {
        for (uint256 i = 0; i < markets.length; i++) {
            whitelistedMarkets[markets[i]] = status;
        }
    }

    function setAllowedTokens(address bridge, address[] memory tokens, bool status) external {
        for (uint256 i = 0; i < tokens.length; i++) {
            allowedTokensPerBridge[bridge][tokens[i]] = status;
        }
    }

    function setMinTransferSize(uint32 dstChainId, address token, uint256 size) external {
        minTransferSizes[dstChainId][token] = size;
    }

    function setMaxTransferSize(uint32 dstChainId, address token, uint256 size) external {
        maxTransferSizes[dstChainId][token] = size;
    }

    function setTransferTimeWindow(uint256 window) external {
        transferTimeWindow = window;
    }

    function setCurrentTransferSize(uint32 dstChainId, address token, uint256 size, uint256 timestamp) external {
        currentTransferSize[dstChainId][token] = TransferInfo({
            size: size,
            timestamp: timestamp
        });
    }

    // ========== CORE REBALANCER FUNCTION ==========

    function sendMsg(
        address _bridge,
        address _market,
        uint256 _amount,
        Msg calldata _msg
    ) external payable {
        // Parameter validation (can be bypassed)
        if (!allowZeroAmount) {
            require(_amount > 0, "Zero amount");
        }
        if (!allowZeroAddresses) {
            require(_bridge != address(0), "Zero bridge address");
            require(_market != address(0), "Zero market address");
            require(_msg.token != address(0), "Zero token address");
        }
        if (!allowSameChain) {
            require(_msg.dstChainId != block.chainid, "Same chain");
        }

        // Authorization check (can be bypassed)
        if (!bypassRoleCheck) {
            require(
                roles.isAllowedFor(msg.sender, roles.REBALANCER_EOA()),
                "Not authorized"
            );
        }

        // Bridge whitelist check (can be bypassed)
        if (!bypassBridgeWhitelist) {
            require(whitelistedBridges[_bridge], "Bridge not whitelisted");
        }

        // Destination whitelist check (can be bypassed)
        if (!bypassDestinationWhitelist) {
            require(whitelistedDestinations[_msg.dstChainId], "Destination not whitelisted");
        }

        // Token allowlist check (can be bypassed)
        if (!bypassTokenAllowlist) {
            require(
                allowedTokensPerBridge[_bridge][_msg.token],
                "Token not allowed for bridge"
            );
        }

        // Market allowlist check (can be bypassed)
        if (!bypassMarketAllowlist) {
            require(allowedList[_market], "Market not allowed");
        }

        // Min size check (can be bypassed)
        if (!bypassMinSizeCheck) {
            require(
                _amount > minTransferSizes[_msg.dstChainId][_msg.token],
                "Below minimum transfer size"
            );
        }

        // Rate limiting logic
        TransferInfo storage transferInfo = currentTransferSize[_msg.dstChainId][_msg.token];
        uint256 transferSizeDeadline = transferInfo.timestamp + transferTimeWindow;

        if (allowEarlyReset) {
            // Vulnerability: Reset window early
            transferInfo.size = _amount;
            transferInfo.timestamp = block.timestamp;
        } else if (transferSizeDeadline < block.timestamp) {
            // Normal reset after expiry
            if (!skipTimeWindowReset) {
                transferInfo.size = _amount;
                transferInfo.timestamp = block.timestamp;
            }
            // If skipTimeWindowReset is true, don't reset (vulnerability)
        } else {
            // Within window - accumulate
            if (!skipCumulativeTracking) {
                transferInfo.size += _amount;
            }
            // If skipCumulativeTracking is true, don't accumulate (vulnerability)
        }

        // Max size check (can be bypassed)
        if (!bypassMaxSizeCheck) {
            uint256 _maxTransferSize = maxTransferSizes[_msg.dstChainId][_msg.token];
            if (_maxTransferSize > 0) {
                require(
                    transferInfo.size <= _maxTransferSize,
                    "Exceeds maximum transfer size"
                );
            }
        }

        // Extract from market (can be skipped)
        if (!skipMarketExtraction) {
            IRebalanceMarket(_market).extractForRebalancing(_amount);
        }

        // Increment nonce
        unchecked {
            ++nonce;
        }

        // Call bridge (can be skipped)
        if (!skipBridgeCall) {
            IBridge(_bridge).sendMsg{value: msg.value}(
                _amount,
                _market,
                _msg.dstChainId,
                _msg.token,
                _msg.message,
                _msg.bridgeData
            );
        }

        emit MsgSent(_bridge, _msg.dstChainId, _msg.token, _msg.message, _msg.bridgeData);
    }

    // ========== VIEW FUNCTIONS ==========

    function isBridgeWhitelisted(address bridge) external view returns (bool) {
        return whitelistedBridges[bridge];
    }

    function isDestinationWhitelisted(uint32 dstId) external view returns (bool) {
        return whitelistedDestinations[dstId];
    }

    function isTokenAllowedForBridge(address bridge, address token) external view returns (bool) {
        return allowedTokensPerBridge[bridge][token];
    }

    function isMarketWhitelisted(address market) external view returns (bool) {
        return whitelistedMarkets[market];
    }
}
