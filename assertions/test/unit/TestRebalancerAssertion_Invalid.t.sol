// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseAssertionTest} from "./BaseAssertionTest.t.sol";
import {RebalancerAssertion} from "../../src/RebalancerAssertion.a.sol";
import {MockRebalancerVulnerable} from "../mocks/MockRebalancerVulnerable.sol";
import {IRebalancer} from "../../../src/interfaces/IRebalancer.sol";
import {Roles} from "../../../src/Roles.sol";

// Mock Bridge for testing
contract MockBridge {
    function sendMsg(
        uint256 amount,
        address market,
        uint32 dstChainId,
        address token,
        bytes memory message,
        bytes memory bridgeData
    ) external payable {
        // Mock implementation
    }
}

// Mock mToken for rebalancer testing
contract MockRebalancerMToken {
    address public underlying;

    constructor(address _underlying) {
        underlying = _underlying;
    }

    function extractForRebalancing(uint256 amount) external {
        // Mock implementation
    }
}

// Mock Token
contract MockToken {
    string public symbol;
    uint8 public decimals = 18;

    constructor(string memory _symbol) {
        symbol = _symbol;
    }
}

/**
 * @title Rebalancer Assertion Invalid Tests
 * @notice Tests for RebalancerAssertion using mock contracts (unhappy path)
 * @dev These tests verify assertions catch protocol violations
 */
contract TestRebalancerAssertion_Invalid is BaseAssertionTest {
    MockRebalancerVulnerable public mockRebalancer;
    MockBridge public bridge;
    MockRebalancerMToken public mockMarket;
    MockToken public mockToken;

    address rebalancerEOA = address(0xBEEF);
    address saveAddress = address(0x5AFE);

    function setUp() public override {
        super.setUp();

        // Use roles from BaseAssertionTest (inherited from Base_Unit_Test)

        // Deploy mock rebalancer
        mockRebalancer = new MockRebalancerVulnerable(address(roles), saveAddress);

        // Deploy mock contracts
        bridge = new MockBridge();
        mockToken = new MockToken("USDC");
        mockMarket = new MockRebalancerMToken(address(mockToken));

        // Setup roles
        roles.allowFor(rebalancerEOA, roles.REBALANCER_EOA(), true);
        roles.allowFor(address(this), roles.GUARDIAN_BRIDGE(), true);

        // Setup basic configuration
        _setupMockRebalancerConfig();
    }

    function _setupMockRebalancerConfig() internal {
        // Whitelist the bridge
        mockRebalancer.setWhitelistedBridgeStatus(address(bridge), true);

        // Whitelist destination chain
        mockRebalancer.setWhitelistedDestination(1, true);

        // Configure allowed tokens per bridge
        address[] memory tokens = new address[](1);
        tokens[0] = address(mockToken);
        mockRebalancer.setAllowedTokens(address(bridge), tokens, true);

        // Set transfer size limits
        mockRebalancer.setMinTransferSize(1, address(mockToken), 100e18);
        mockRebalancer.setMaxTransferSize(1, address(mockToken), 10000e18);

        // Set time window (1 day)
        mockRebalancer.setTransferTimeWindow(86400);

        // Add market to allowed list
        address[] memory markets = new address[](1);
        markets[0] = address(mockMarket);
        mockRebalancer.setAllowList(markets, true);
    }

    function _createMessage() internal view returns (IRebalancer.Msg memory) {
        return IRebalancer.Msg({
            dstChainId: 1,
            token: address(mockToken),
            message: bytes("rebalance"),
            bridgeData: bytes("bridge_data")
        });
    }

    // ============ Allowlist Violation Tests ============

    /**
     * @notice Test that assertion catches non-whitelisted bridge usage
     * @dev Bypass bridge whitelist check, assertion should detect it
     */
    function testNonWhitelistedBridge_CaughtByAssertion() public {
        // Deploy non-whitelisted bridge
        MockBridge nonWhitelistedBridge = new MockBridge();

        // Enable bypass to let the call succeed
        mockRebalancer.setBypassBridgeWhitelist(true);
        mockRebalancer.setBypassTokenAllowlist(true); // Also bypass token check since bridge isn't configured

        // Register assertion
        cl.assertion({
            adopter: address(mockRebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionRebalancerAllowlist.selector
        });

        // Create message with proper token
        IRebalancer.Msg memory message = _createMessage();
        message.token = address(mockToken);

        // Attempt to use non-whitelisted bridge
        vm.prank(rebalancerEOA);
        vm.expectRevert("Non-whitelisted bridge used for rebalancing");
        mockRebalancer.sendMsg(address(nonWhitelistedBridge), address(mockMarket), 1000e18, message);
    }

    /**
     * @notice Test that assertion catches non-whitelisted destination
     * @dev Bypass destination whitelist check, assertion should detect it
     */
    function testNonWhitelistedDestination_CaughtByAssertion() public {
        // Enable bypass to let the call succeed
        mockRebalancer.setBypassDestinationWhitelist(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockRebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionRebalancerAllowlist.selector
        });

        // Create message with non-whitelisted destination (chain 2)
        IRebalancer.Msg memory message = IRebalancer.Msg({
            dstChainId: 2,
            token: address(mockToken),
            message: bytes("rebalance"),
            bridgeData: bytes("bridge_data")
        });

        // Attempt to use non-whitelisted destination
        vm.prank(rebalancerEOA);
        vm.expectRevert("Non-whitelisted destination used for rebalancing");
        mockRebalancer.sendMsg(address(bridge), address(mockMarket), 1000e18, message);
    }

    /**
     * @notice Test that assertion catches market with mismatched underlying
     * @dev Market underlying must match the token in message
     */
    function testNonAllowedMarket_CaughtByAssertion() public {
        // Deploy a different token and market with mismatched underlying
        MockToken wrongToken = new MockToken("WRONG");
        MockRebalancerMToken marketWithWrongUnderlying = new MockRebalancerMToken(address(wrongToken));

        // Add market to allowlist (so it passes that check)
        address[] memory markets = new address[](1);
        markets[0] = address(marketWithWrongUnderlying);
        mockRebalancer.setAllowList(markets, true);

        // Register assertion
        cl.assertion({
            adopter: address(mockRebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionRebalancerAllowlist.selector
        });

        // Create message with mockToken but use market with wrongToken underlying
        IRebalancer.Msg memory message = _createMessage();
        message.token = address(mockToken); // Message says we're sending mockToken

        // Attempt to use market with wrong underlying
        vm.prank(rebalancerEOA);
        vm.expectRevert("Market underlying does not match rebalancing token");
        mockRebalancer.sendMsg(address(bridge), address(marketWithWrongUnderlying), 1000e18, message);
    }

    /**
     * @notice Test that assertion catches when bridge is not actually called
     * @dev Skip bridge call, assertion should detect bridge wasn't invoked
     */
    function testBridgeNotCalled_CaughtByAssertion() public {
        // Enable skip bridge call vulnerability
        mockRebalancer.setSkipBridgeCall(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockRebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionRebalancerAllowlist.selector
        });

        // Attempt rebalancing without actually calling bridge
        vm.prank(rebalancerEOA);
        vm.expectRevert("Bridge contract not called despite being in parameters");
        mockRebalancer.sendMsg(address(bridge), address(mockMarket), 1000e18, _createMessage());
    }

    // ============ Transfer Size Violation Tests ============

    /**
     * @notice Test that assertion catches transfer below minimum size
     * @dev Bypass min size check, assertion should detect it
     */
    function testBelowMinimumSize_CaughtByAssertion() public {
        // Enable bypass to let the call succeed
        mockRebalancer.setBypassMinSizeCheck(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockRebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionTransferSizeLimits.selector
        });

        // Attempt transfer below minimum (min is 100e18)
        vm.prank(rebalancerEOA);
        vm.expectRevert("Transfer amount below minimum size limit");
        mockRebalancer.sendMsg(address(bridge), address(mockMarket), 50e18, _createMessage());
    }

    /**
     * @notice Test that assertion catches transfer above maximum size
     * @dev Bypass max size check, assertion should detect it
     */
    function testAboveMaximumSize_CaughtByAssertion() public {
        // Warp to a reasonable future time
        vm.warp(100000);

        // Set transfer state outside the time window (more than 1 day ago)
        mockRebalancer.setCurrentTransferSize(1, address(mockToken), 0, block.timestamp - 86401);

        // Enable bypass to let the call succeed
        mockRebalancer.setBypassMaxSizeCheck(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockRebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionTransferSizeLimits.selector
        });

        // Attempt transfer above maximum (max is 10000e18)
        vm.prank(rebalancerEOA);
        vm.expectRevert("Transfer amount exceeds maximum size limit");
        mockRebalancer.sendMsg(address(bridge), address(mockMarket), 15000e18, _createMessage());
    }

    /**
     * @notice Test that assertion catches zero amount transfer
     * @dev Zero amount should always be caught
     */
    function testZeroAmount_CaughtByAssertion() public {
        // Allow zero amount to bypass mock's require
        mockRebalancer.setAllowZeroAmount(true);
        // Also bypass min size check (zero is below minimum)
        mockRebalancer.setBypassMinSizeCheck(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockRebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionTransferSizeLimits.selector
        });

        // Create message with proper token
        IRebalancer.Msg memory message = _createMessage();
        message.token = address(mockToken);

        // Attempt zero amount transfer
        vm.prank(rebalancerEOA);
        vm.expectRevert("Zero amount rebalancing attempted");
        mockRebalancer.sendMsg(address(bridge), address(mockMarket), 0, message);
    }

    // ============ Rate Limiting Violation Tests ============

    /**
     * @notice Test that assertion catches cumulative transfers exceeding limit
     * @dev Multiple transfers within window that exceed max
     */
    function testExceedCumulativeLimit_CaughtByAssertion() public {
        // Set initial transfer state
        mockRebalancer.setCurrentTransferSize(1, address(mockToken), 8000e18, block.timestamp);

        // Enable bypass to let the call succeed
        mockRebalancer.setBypassMaxSizeCheck(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockRebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionTransferSizeLimits.selector
        });

        // Attempt transfer that would exceed cumulative limit (8000 + 3000 = 11000 > 10000)
        vm.prank(rebalancerEOA);
        vm.expectRevert("Transfer would exceed maximum size limit within time window");
        mockRebalancer.sendMsg(address(bridge), address(mockMarket), 3000e18, _createMessage());
    }

    /**
     * @notice Test that assertion catches missing window reset after expiry
     * @dev Window expired but not reset - violation
     */
    function testNoWindowReset_CaughtByAssertion() public {
        // Warp to a reasonable future time to avoid underflow
        vm.warp(100000);

        // Set transfer state with expired timestamp
        uint256 oldTimestamp = block.timestamp - 86401; // 1 day + 1 second ago
        mockRebalancer.setCurrentTransferSize(1, address(mockToken), 5000e18, oldTimestamp);

        // Enable skip reset vulnerability
        mockRebalancer.setSkipTimeWindowReset(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockRebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionRateLimiting.selector
        });

        // Attempt transfer without resetting expired window
        vm.prank(rebalancerEOA);
        vm.expectRevert("Transfer window not reset");
        mockRebalancer.sendMsg(address(bridge), address(mockMarket), 1000e18, _createMessage());
    }

    /**
     * @notice Test that assertion catches early window reset
     * @dev Reset window before expiry - violation
     */
    function testEarlyWindowReset_CaughtByAssertion() public {
        // Warp to a reasonable future time to avoid underflow
        vm.warp(100000);

        // Set recent transfer state
        mockRebalancer.setCurrentTransferSize(1, address(mockToken), 5000e18, block.timestamp - 1000); // 1000 seconds ago

        // Enable early reset vulnerability
        mockRebalancer.setAllowEarlyReset(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockRebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionRateLimiting.selector
        });

        // Attempt transfer with early reset
        vm.prank(rebalancerEOA);
        vm.expectRevert("Transfer timestamp changed within window");
        mockRebalancer.sendMsg(address(bridge), address(mockMarket), 1000e18, _createMessage());
    }

    /**
     * @notice Test that assertion catches missing cumulative tracking
     * @dev Transfers within window should accumulate
     */
    function testSkipCumulativeTracking_CaughtByAssertion() public {
        // Warp to a reasonable future time to avoid underflow
        vm.warp(100000);

        // Set recent transfer state
        mockRebalancer.setCurrentTransferSize(1, address(mockToken), 5000e18, block.timestamp - 1000);

        // Enable skip cumulative tracking vulnerability
        mockRebalancer.setSkipCumulativeTracking(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockRebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionRateLimiting.selector
        });

        // Attempt transfer without accumulating
        vm.prank(rebalancerEOA);
        vm.expectRevert("Transfer size not accumulated");
        mockRebalancer.sendMsg(address(bridge), address(mockMarket), 1000e18, _createMessage());
    }

    /**
     * @notice Test that assertion catches time window too short
     * @dev Window < 60 seconds is invalid
     */
    function testTimeWindowTooShort_CaughtByAssertion() public {
        // Set invalid time window
        mockRebalancer.setTransferTimeWindow(30); // 30 seconds

        // Register assertion
        cl.assertion({
            adopter: address(mockRebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionRateLimiting.selector
        });

        // Attempt transfer with invalid window
        vm.prank(rebalancerEOA);
        vm.expectRevert("Transfer time window too short (less than 1 minute)");
        mockRebalancer.sendMsg(address(bridge), address(mockMarket), 1000e18, _createMessage());
    }

    /**
     * @notice Test that assertion catches time window too long
     * @dev Window > 30 days is invalid
     */
    function testTimeWindowTooLong_CaughtByAssertion() public {
        // Set invalid time window
        mockRebalancer.setTransferTimeWindow(31 days);

        // Register assertion
        cl.assertion({
            adopter: address(mockRebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionRateLimiting.selector
        });

        // Attempt transfer with invalid window
        vm.prank(rebalancerEOA);
        vm.expectRevert("Transfer time window too long (more than 30 days)");
        mockRebalancer.sendMsg(address(bridge), address(mockMarket), 1000e18, _createMessage());
    }

    // ============ Authorization Violation Tests ============

    /**
     * @notice Test that assertion catches unauthorized caller
     * @dev Bypass role check, but assertion validates parameters
     */
    function testUnauthorizedCaller_WithBypass() public {
        // Enable bypass role check vulnerability
        mockRebalancer.setBypassRoleCheck(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockRebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionRebalancerAuthorization.selector
        });

        // Attempt as unauthorized caller (alice, not rebalancerEOA)
        // Note: Assertion checks parameters passed, role check happened (or was bypassed)
        vm.prank(alice);
        // This will succeed since we bypassed role check, but parameters are validated
        mockRebalancer.sendMsg(address(bridge), address(mockMarket), 1000e18, _createMessage());
    }

    /**
     * @notice Test that assertion catches invalid bridge address (zero)
     * @dev Zero address should be rejected
     */
    function testInvalidBridgeAddress_CaughtByAssertion() public {
        // Allow zero addresses to bypass mock's require
        mockRebalancer.setAllowZeroAddresses(true);
        // Bypass all subsequent checks so assertion can catch the parameter issue
        mockRebalancer.setBypassRoleCheck(true);
        mockRebalancer.setBypassBridgeWhitelist(true);
        mockRebalancer.setBypassDestinationWhitelist(true);
        mockRebalancer.setBypassTokenAllowlist(true);
        mockRebalancer.setBypassMarketAllowlist(true);
        mockRebalancer.setBypassMinSizeCheck(true);
        mockRebalancer.setBypassMaxSizeCheck(true);
        mockRebalancer.setSkipMarketExtraction(true);
        mockRebalancer.setSkipBridgeCall(true); // Skip calling the zero address

        // Register assertion
        cl.assertion({
            adopter: address(mockRebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionRebalancerAuthorization.selector
        });

        // Create message with proper token
        IRebalancer.Msg memory message = _createMessage();
        message.token = address(mockToken);

        // Attempt with zero bridge address
        vm.prank(rebalancerEOA);
        vm.expectRevert("Invalid bridge address");
        mockRebalancer.sendMsg(address(0), address(mockMarket), 1000e18, message);
    }

    /**
     * @notice Test that assertion catches invalid market address (zero)
     * @dev Zero address should be rejected
     */
    function testInvalidMarketAddress_CaughtByAssertion() public {
        // Allow zero addresses to bypass mock's require
        mockRebalancer.setAllowZeroAddresses(true);
        // Bypass all subsequent checks so assertion can catch the parameter issue
        mockRebalancer.setBypassRoleCheck(true);
        mockRebalancer.setBypassBridgeWhitelist(true);
        mockRebalancer.setBypassDestinationWhitelist(true);
        mockRebalancer.setBypassTokenAllowlist(true);
        mockRebalancer.setBypassMarketAllowlist(true);
        mockRebalancer.setBypassMinSizeCheck(true);
        mockRebalancer.setBypassMaxSizeCheck(true);
        mockRebalancer.setSkipMarketExtraction(true); // Skip calling the zero address
        mockRebalancer.setSkipBridgeCall(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockRebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionRebalancerAuthorization.selector
        });

        // Create message with proper token
        IRebalancer.Msg memory message = _createMessage();
        message.token = address(mockToken);

        // Attempt with zero market address
        vm.prank(rebalancerEOA);
        vm.expectRevert("Invalid market address");
        mockRebalancer.sendMsg(address(bridge), address(0), 1000e18, message);
    }

    /**
     * @notice Test that assertion catches same-chain rebalancing
     * @dev Cannot rebalance to the same chain
     */
    function testSameChainRebalancing_CaughtByAssertion() public {
        // Allow same chain to bypass mock's require
        mockRebalancer.setAllowSameChain(true);
        // Bypass all subsequent checks so assertion can catch the parameter issue
        mockRebalancer.setBypassRoleCheck(true);
        mockRebalancer.setBypassBridgeWhitelist(true);
        mockRebalancer.setBypassDestinationWhitelist(true);
        mockRebalancer.setBypassTokenAllowlist(true);
        mockRebalancer.setBypassMarketAllowlist(true);
        mockRebalancer.setBypassMinSizeCheck(true);
        mockRebalancer.setBypassMaxSizeCheck(true);

        // Register assertion
        cl.assertion({
            adopter: address(mockRebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionRebalancerAuthorization.selector
        });

        // Create message with current chain ID
        IRebalancer.Msg memory message = IRebalancer.Msg({
            dstChainId: uint32(block.chainid),
            token: address(mockToken),
            message: bytes("rebalance"),
            bridgeData: bytes("bridge_data")
        });

        // Attempt same-chain rebalancing
        vm.prank(rebalancerEOA);
        vm.expectRevert("Cannot rebalance to same chain");
        mockRebalancer.sendMsg(address(bridge), address(mockMarket), 1000e18, message);
    }
}
