// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseAssertionTest} from "./BaseAssertionTest.t.sol";
import {RebalancerAssertion} from "../src/RebalancerAssertion.a.sol";
import {Rebalancer} from "../../src/rebalancer/Rebalancer.sol";
import {IRebalancer} from "../../src/interfaces/IRebalancer.sol";

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

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 1000000e18;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }
}

/**
 * @title Rebalancer Assertion Valid Tests
 * @notice Tests for RebalancerAssertion using real contracts (happy path)
 * @dev These tests verify assertions pass when protocol behaves correctly
 */
contract TestRebalancerAssertion_Valid is BaseAssertionTest {
    Rebalancer public rebalancer;
    MockBridge public bridge;
    MockRebalancerMToken public mockMarket;
    MockToken public mockToken;

    address rebalancerEOA = address(0xBEEF);
    address saveAddress = address(0x5AFE);

    function setUp() public override {
        super.setUp();

        // Deploy rebalancer with real Roles
        rebalancer = new Rebalancer(address(roles), saveAddress, address(this));

        // Deploy mock contracts
        bridge = new MockBridge();
        mockToken = new MockToken("USDC");
        mockMarket = new MockRebalancerMToken(address(mockToken));

        // Setup roles
        roles.allowFor(rebalancerEOA, roles.REBALANCER_EOA(), true);
        roles.allowFor(address(this), roles.GUARDIAN_BRIDGE(), true);

        // Setup rebalancer configuration
        _setupRebalancerConfig();
    }

    function _setupRebalancerConfig() internal {
        // Whitelist the bridge
        rebalancer.setWhitelistedBridgeStatus(address(bridge), true);

        // Whitelist destination chain
        rebalancer.setWhitelistedDestination(1, true);

        // Configure allowed tokens per bridge
        address[] memory tokens = new address[](1);
        tokens[0] = address(mockToken);
        rebalancer.setAllowedTokens(address(bridge), tokens, true);

        // Set transfer size limits
        rebalancer.setMinTransferSize(1, address(mockToken), 100e18);
        rebalancer.setMaxTransferSize(1, address(mockToken), 10000e18);

        // Add market to allowed list
        address[] memory markets = new address[](1);
        markets[0] = address(mockMarket);
        rebalancer.setAllowList(markets, true);
        rebalancer.setMarketStatus(markets, true);
    }

    function _createMessage() internal pure returns (IRebalancer.Msg memory) {
        return IRebalancer.Msg({
            dstChainId: 1,
            token: address(0), // Will be set per test
            message: bytes("rebalance"),
            bridgeData: bytes("bridge_data")
        });
    }

    // ============ Allowlist Tests ============

    /**
     * @notice Test that valid rebalancing passes all allowlist checks
     * @dev Uses whitelisted bridge, destination, and market
     */
    function testValidRebalancing_Passes() public {
        // Register assertion
        cl.assertion({
            adopter: address(rebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionRebalancerAllowlist.selector
        });

        // Create valid message
        IRebalancer.Msg memory message = _createMessage();
        message.token = address(mockToken);

        // Execute valid rebalancing
        vm.prank(rebalancerEOA);
        rebalancer.sendMsg(address(bridge), address(mockMarket), 1000e18, message);
    }

    // ============ Transfer Size Tests ============

    /**
     * @notice Test that transfers within size limits pass
     * @dev Amount above min and below max
     */
    function testTransferWithinSizeLimits_Passes() public {
        // Register assertion
        cl.assertion({
            adopter: address(rebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionTransferSizeLimits.selector
        });

        // Create valid message
        IRebalancer.Msg memory message = _createMessage();
        message.token = address(mockToken);

        // Execute transfer within limits (100 < 1000 < 10000)
        vm.prank(rebalancerEOA);
        rebalancer.sendMsg(address(bridge), address(mockMarket), 1000e18, message);
    }

    /**
     * @notice Test that multiple transfers within cumulative limit pass
     * @dev Verifies proper accumulation within time window
     */
    function testMultipleTransfersWithinWindow_Passes() public {
        // Register assertion
        cl.assertion({
            adopter: address(rebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionTransferSizeLimits.selector
        });

        // Create valid message
        IRebalancer.Msg memory message = _createMessage();
        message.token = address(mockToken);

        // First transfer: 3000
        vm.prank(rebalancerEOA);
        rebalancer.sendMsg(address(bridge), address(mockMarket), 3000e18, message);

        // Second transfer: 3000 (total = 6000 < 10000 max)
        vm.prank(rebalancerEOA);
        rebalancer.sendMsg(address(bridge), address(mockMarket), 3000e18, message);
    }

    // ============ Rate Limiting Tests ============

    /**
     * @notice Test that transfer after window expiry properly resets
     * @dev Verifies window reset mechanism works correctly
     */
    function testTransferAfterWindowExpiry_Passes() public {
        // Create valid message
        IRebalancer.Msg memory message = _createMessage();
        message.token = address(mockToken);

        // First transfer to set initial state
        vm.prank(rebalancerEOA);
        rebalancer.sendMsg(address(bridge), address(mockMarket), 5000e18, message);

        // Advance time past window (default is 1 day)
        vm.warp(block.timestamp + 86401);

        // Register assertion
        cl.assertion({
            adopter: address(rebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionRateLimiting.selector
        });

        // Second transfer after window expiry should reset and pass
        vm.prank(rebalancerEOA);
        rebalancer.sendMsg(address(bridge), address(mockMarket), 8000e18, message);
    }

    /**
     * @notice Test that transfer time window is within reasonable bounds
     * @dev Default window is 1 day (86400 seconds), which is reasonable
     */
    function testTimeWindowBounds_Passes() public {
        // Verify default time window is reasonable
        uint256 window = rebalancer.transferTimeWindow();
        assertEq(window, 86400, "Default window should be 1 day");
        assertTrue(window >= 60, "Window should be >= 1 minute");
        assertTrue(window <= 30 days, "Window should be <= 30 days");

        // Register assertion
        cl.assertion({
            adopter: address(rebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionRateLimiting.selector
        });

        // Create valid message
        IRebalancer.Msg memory message = _createMessage();
        message.token = address(mockToken);

        // Execute transfer - should pass with reasonable window
        vm.prank(rebalancerEOA);
        rebalancer.sendMsg(address(bridge), address(mockMarket), 1000e18, message);
    }

    // ============ Authorization Tests ============

    /**
     * @notice Test that authorized rebalancer can execute transfers
     * @dev Verifies role-based access control works correctly
     */
    function testAuthorizedRebalancer_Passes() public {
        // Register assertion
        cl.assertion({
            adopter: address(rebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionRebalancerAuthorization.selector
        });

        // Create valid message
        IRebalancer.Msg memory message = _createMessage();
        message.token = address(mockToken);

        // Execute as authorized rebalancer
        vm.prank(rebalancerEOA);
        rebalancer.sendMsg(address(bridge), address(mockMarket), 1000e18, message);
    }
}
