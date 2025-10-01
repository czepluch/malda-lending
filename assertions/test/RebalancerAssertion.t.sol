// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {CredibleTest} from "credible-std/CredibleTest.sol";
import {RebalancerAssertion} from "../src/RebalancerAssertion.a.sol";
import {IRebalancer} from "../../src/interfaces/IRebalancer.sol";
import {Rebalancer} from "../../src/rebalancer/Rebalancer.sol";
import {IRoles} from "../../src/interfaces/IRoles.sol";
import {Roles} from "../../src/Roles.sol";
import {ImToken} from "../../src/interfaces/ImToken.sol";

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
        // Mock implementation - just accept the call
    }
}

// Mock mToken for rebalancer testing - simplified without ImToken inheritance
contract MockRebalancerMToken {
    address public underlying;

    constructor(address _underlying) {
        underlying = _underlying;
    }

    function extractForRebalancing(uint256 amount) external {
        // Mock implementation - just accept the call
    }
}

// Mock ERC20 token
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
 * @title Rebalancer Assertion Test
 * @notice Tests for the RebalancerAssertion contract
 */
contract TestRebalancerAssertion is CredibleTest, Test {
    RebalancerAssertion public assertion;
    Rebalancer public rebalancer;
    Roles public roles;
    MockBridge public bridge;
    MockRebalancerMToken public mockMarket;
    MockToken public mockToken;

    address alice = address(0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf);
    address rebalancerEOA = address(0xBEEF);
    address saveAddress = address(0x5AFE);

    function setUp() public {
        // Deploy roles contract with owner
        roles = new Roles(address(this));

        // Deploy rebalancer
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

        // Deploy assertion
        assertion = new RebalancerAssertion();
    }

    function _setupRebalancerConfig() internal {
        // Whitelist the bridge
        rebalancer.setWhitelistedBridgeStatus(address(bridge), true);

        // Whitelist destination chain
        rebalancer.setWhitelistedDestination(1, true); // Chain ID 1

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

        // MockToken already has hardcoded balance of 1000000e18, no need for deal()
    }

    /**
     * @notice Test that assertion passes with valid rebalancing
     */
    function testAssertionPassesWithValidRebalancing() public {
        // Register assertion
        cl.assertion({
            adopter: address(rebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionRebalancerAllowlist.selector
        });

        // Create valid message
        IRebalancer.Msg memory message = IRebalancer.Msg({
            dstChainId: 1,
            token: address(mockToken),
            message: bytes("rebalance"),
            bridgeData: bytes("bridge_data")
        });

        // Execute rebalancing as authorized EOA
        vm.prank(rebalancerEOA);
        rebalancer.sendMsg(address(bridge), address(mockMarket), 1000e18, message);
    }

    /**
     * @notice Test that assertion fails with non-whitelisted bridge
     */
    function testAssertionFailsWithNonWhitelistedBridge() public {
        // Deploy a non-whitelisted bridge
        MockBridge nonWhitelistedBridge = new MockBridge();

        // Register assertion
        cl.assertion({
            adopter: address(rebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionRebalancerAllowlist.selector
        });

        IRebalancer.Msg memory message = IRebalancer.Msg({
            dstChainId: 1,
            token: address(mockToken),
            message: bytes("rebalance"),
            bridgeData: bytes("bridge_data")
        });

        vm.prank(rebalancerEOA);
        vm.expectRevert("Non-whitelisted bridge used for rebalancing");
        rebalancer.sendMsg(address(nonWhitelistedBridge), address(mockMarket), 1000e18, message);
    }

    /**
     * @notice Test transfer size limits enforcement
     */
    function testTransferSizeLimits() public {
        // Register assertion for size limits
        cl.assertion({
            adopter: address(rebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionTransferSizeLimits.selector
        });

        IRebalancer.Msg memory message = IRebalancer.Msg({
            dstChainId: 1,
            token: address(mockToken),
            message: bytes("rebalance"),
            bridgeData: bytes("bridge_data")
        });

        // Try to transfer below minimum (100e18)
        vm.prank(rebalancerEOA);
        vm.expectRevert();
        rebalancer.sendMsg(address(bridge), address(mockMarket), 50e18, message);

        // Valid transfer within limits
        cl.assertion({
            adopter: address(rebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionTransferSizeLimits.selector
        });

        vm.prank(rebalancerEOA);
        rebalancer.sendMsg(address(bridge), address(mockMarket), 5000e18, message);
    }

    /**
     * @notice Test rate limiting enforcement
     */
    function testRateLimiting() public {
        IRebalancer.Msg memory message = IRebalancer.Msg({
            dstChainId: 1,
            token: address(mockToken),
            message: bytes("rebalance"),
            bridgeData: bytes("bridge_data")
        });

        // First transfer - should succeed
        cl.assertion({
            adopter: address(rebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionRateLimiting.selector
        });

        vm.prank(rebalancerEOA);
        rebalancer.sendMsg(address(bridge), address(mockMarket), 5000e18, message);

        // Second transfer within same window - should accumulate
        cl.assertion({
            adopter: address(rebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionRateLimiting.selector
        });

        vm.prank(rebalancerEOA);
        rebalancer.sendMsg(address(bridge), address(mockMarket), 4000e18, message);

        // Third transfer that would exceed max - should fail
        vm.prank(rebalancerEOA);
        vm.expectRevert();
        rebalancer.sendMsg(address(bridge), address(mockMarket), 2000e18, message); // Total would be 11000 > 10000 max
    }

    /**
     * @notice Test authorization checks
     */
    function testAuthorizationChecks() public {
        // Register assertion for authorization
        cl.assertion({
            adopter: address(rebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionRebalancerAuthorization.selector
        });

        IRebalancer.Msg memory message = IRebalancer.Msg({
            dstChainId: 1,
            token: address(mockToken),
            message: bytes("rebalance"),
            bridgeData: bytes("bridge_data")
        });

        // Try as unauthorized user - should fail
        vm.prank(alice);
        vm.expectRevert();
        rebalancer.sendMsg(address(bridge), address(mockMarket), 1000e18, message);

        // Try as authorized user - should succeed
        cl.assertion({
            adopter: address(rebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionRebalancerAuthorization.selector
        });

        vm.prank(rebalancerEOA);
        rebalancer.sendMsg(address(bridge), address(mockMarket), 1000e18, message);
    }

    /**
     * @notice Test that non-whitelisted destination fails
     */
    function testNonWhitelistedDestination() public {
        // Register assertion
        cl.assertion({
            adopter: address(rebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionRebalancerAllowlist.selector
        });

        // Try to send to non-whitelisted chain
        IRebalancer.Msg memory message = IRebalancer.Msg({
            dstChainId: 999, // Non-whitelisted chain
            token: address(mockToken),
            message: bytes("rebalance"),
            bridgeData: bytes("bridge_data")
        });

        vm.prank(rebalancerEOA);
        vm.expectRevert("Non-whitelisted destination used for rebalancing");
        rebalancer.sendMsg(address(bridge), address(mockMarket), 1000e18, message);
    }

    /**
     * @notice Test time window reset for rate limiting
     */
    function testTimeWindowReset() public {
        IRebalancer.Msg memory message = IRebalancer.Msg({
            dstChainId: 1,
            token: address(mockToken),
            message: bytes("rebalance"),
            bridgeData: bytes("bridge_data")
        });

        // First transfer near max
        vm.prank(rebalancerEOA);
        rebalancer.sendMsg(address(bridge), address(mockMarket), 9000e18, message);

        // Try another large transfer - should fail
        vm.prank(rebalancerEOA);
        vm.expectRevert();
        rebalancer.sendMsg(address(bridge), address(mockMarket), 5000e18, message);

        // Warp time past the window (default is 24 hours)
        vm.warp(block.timestamp + 25 hours);

        // Register assertion after time window reset
        cl.assertion({
            adopter: address(rebalancer),
            createData: type(RebalancerAssertion).creationCode,
            fnSelector: RebalancerAssertion.assertionRateLimiting.selector
        });

        // Now should be able to transfer again
        vm.prank(rebalancerEOA);
        rebalancer.sendMsg(address(bridge), address(mockMarket), 5000e18, message);
    }
}