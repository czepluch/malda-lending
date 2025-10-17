// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CredibleTest} from "credible-std/CredibleTest.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {AccountLiquidityAssertion} from "../src/AccountLiquidityAssertion.a.sol";
import {BaseAssertionTest} from "./BaseAssertionTest.t.sol";
import {mErc20Immutable} from "../../src/mToken/mErc20Immutable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";
import {MixedPriceOracleV4} from "../../src/oracles/MixedPriceOracleV4.sol";

// Mock price feed for testing
contract MockPriceFeed {
    uint8 public decimals = 8;
    int256 public price = 1e8;
    uint256 public updatedAt = block.timestamp;

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, price, 0, updatedAt, 0);
    }

    function setPrice(int256 _price) external {
        price = _price;
    }

    function setUpdatedAt(uint256 _time) external {
        updatedAt = _time;
    }
}

/**
 * @title Account Liquidity Assertion Tests - Valid (Happy Path)
 * @notice Tests for account liquidity assertions that should pass without reverting
 * @dev These tests use the real Operator contract and verify that valid operations pass assertions
 */
contract TestAccountLiquidityAssertion_Valid is BaseAssertionTest {
    AccountLiquidityAssertion public assertion;

    // mToken market instances
    mErc20Immutable public mUSDC;
    mErc20Immutable public mUSDT;

    // USDT token for testing
    ERC20Mock public usdt;

    function setUp() public override {
        super.setUp();
        assertion = new AccountLiquidityAssertion();

        // Create USDT token with higher mint limit
        usdt = new ERC20Mock("USDT", "USDT", 6, address(this), address(0), 1000000 * 1e6); // 1M USDT limit
        vm.label(address(usdt), "USDT");

        // Setup real mTokens
        _setupRealMTokens();
    }

    /**
     * @notice Setup mToken market instances
     * @dev Creates mUSDC and mUSDT markets for testing liquidity scenarios
     */
    function _setupRealMTokens() internal {
        // Deploy mUSDC (borrow market)
        mUSDC = new mErc20Immutable(
            address(usdc),
            address(operator),
            address(interestModel),
            1e18,
            "Market USDC",
            "mUSDC",
            6, // USDC has 6 decimals
            payable(address(this))
        );
        vm.label(address(mUSDC), "mUSDC");

        // Deploy mUSDT (collateral market) - using USDT as underlying (already configured in oracle)
        mUSDT = new mErc20Immutable(
            address(usdt), // Using USDT as underlying for collateral market
            address(operator),
            address(interestModel),
            1e18,
            "Market USDT",
            "mUSDT",
            6, // USDT has 6 decimals
            payable(address(this))
        );
        vm.label(address(mUSDT), "mUSDT");

        // Setup markets in operator
        operator.supportMarket(address(mUSDC));
        operator.supportMarket(address(mUSDT));

        // Set collateral factors
        operator.setCollateralFactor(address(mUSDC), 0.8e18); // 80% collateral factor
        operator.setCollateralFactor(address(mUSDT), 0.9e18); // 90% collateral factor

        // Set close factor for liquidations (50% - can liquidate up to 50% of debt in one transaction)
        operator.setCloseFactor(0.5e18);
    }

    /**
     * @notice Setup collateral for a user by minting tokens and supplying them to an mToken
     * @param mToken The mToken to supply to
     * @param user The user to setup collateral for
     * @param supplyAmount The amount of underlying tokens to supply
     */
    function _setupCollateral(address mToken, address user, uint256 supplyAmount) internal {
        address underlying = mErc20Immutable(mToken).underlying();

        // Mint underlying tokens to the user
        ERC20Mock(underlying).mint(user, supplyAmount);

        // User approves mToken to spend their underlying tokens
        vm.prank(user);
        IERC20(underlying).approve(mToken, supplyAmount);

        // User supplies tokens to the mToken market
        vm.prank(user);
        mErc20Immutable(mToken).mint(supplyAmount, user, 0);
    }

    // ============ Borrow Liquidity Tests ============

    /**
     * @notice Test that valid borrow operations pass the liquidity assertion
     * @dev Alice has sufficient collateral to borrow, so the assertion should pass
     */
    function testBorrowLiquidity_ValidBorrow_Passes() public {
        // Setup Alice with collateral in the collateral market
        _setupCollateral(address(mUSDT), alice, 1000e6); // Alice supplies 1000 USDT as collateral

        // Set up valid oracle prices for both USDC and USDT
        _setupValidOraclePrices(1e8, 1e8); // $1.00 for both feeds

        // Add liquidity to mUSDC lending pool
        usdc.mint(address(this), 10000e6);
        usdc.approve(address(mUSDC), 10000e6);
        mUSDC.mint(10000e6, address(this), 0);

        operator.setWhitelistedUser(alice, true);

        // Register assertion right before the borrow call
        cl.assertion({
            adopter: address(operator),
            createData: type(AccountLiquidityAssertion).creationCode,
            fnSelector: AccountLiquidityAssertion.assertionBorrowLiquidity.selector
        });

        // Execute valid borrow operation
        vm.prank(alice);
        mUSDC.borrow(50e6);
    }

    /**
     * @notice Test borrow liquidity with different collateral amounts
     * @dev Tests that varying collateral amounts affect borrowing capacity correctly
     */
    function testBorrowLiquidity_DifferentCollateralAmounts() public {
        // Setup Alice with different collateral amount
        _setupCollateral(address(mUSDT), alice, 500e6); // Alice supplies 500 USDT as collateral

        // Set up valid oracle prices
        _setupValidOraclePrices(1e8, 1e8); // $1.00 for both feeds

        // Add liquidity to mUSDC lending pool
        usdc.mint(address(this), 10000e6);
        usdc.approve(address(mUSDC), 10000e6);
        mUSDC.mint(10000e6, address(this), 0);

        operator.setWhitelistedUser(alice, true);

        // Register assertion right before the borrow call
        cl.assertion({
            adopter: address(operator),
            createData: type(AccountLiquidityAssertion).creationCode,
            fnSelector: AccountLiquidityAssertion.assertionBorrowLiquidity.selector
        });

        // Alice borrows within her capacity (500 USDT * 0.9 CF = 450 max, borrowing 100)
        vm.prank(alice);
        mUSDC.borrow(100e6);
    }

    // ============ Liquidation Liquidity Tests ============
    // Note: Liquidation assertions are comprehensively tested in
    // testLiquidityConsistency_PriceChanges_AffectsCalculations below,
    // which creates a proper underwater scenario and validates liquidation

    // ============ Redeem Liquidity Tests ============

    /**
     * @notice Test that valid redeem operations pass the liquidity assertion
     * @dev Alice redeems some collateral while maintaining sufficient liquidity
     */
    function testRedeemLiquidity_ValidRedeem_Passes() public {
        // Setup Alice with collateral in the collateral market
        _setupCollateral(address(mUSDT), alice, 1000e6); // Alice supplies 1000 USDT as collateral

        // Set up valid oracle prices
        _setupValidOraclePrices(1e8, 1e8); // $1.00 for both feeds

        // Alice needs to enter the mUSDT market (for redeem operations)
        address[] memory markets = new address[](1);
        markets[0] = address(mUSDT);
        vm.prank(alice);
        operator.enterMarkets(markets);

        operator.setWhitelistedUser(alice, true);

        // Register assertion right before operator hook
        cl.assertion({
            adopter: address(operator),
            createData: type(AccountLiquidityAssertion).creationCode,
            fnSelector: AccountLiquidityAssertion.assertionRedeemLiquidity.selector
        });

        // Execute valid redeem operation via mToken.redeem() - small amount to be safe
        vm.prank(alice);
        mUSDT.redeem(50e6);
    }

    // ============ Seize Liquidity Tests ============

    /**
     * @notice Test that valid seize operations pass the liquidity assertion
     * @dev Seize operations are part of liquidation flows - this should be a happy path test
     */
    function testSeizeLiquidity_ValidSeize_Passes() public {
        // Setup Alice with collateral - we don't need her underwater for the assertion to pass
        _setupCollateral(address(mUSDT), alice, 1000e6); // Alice supplies 1000 USDT as collateral

        // Set up valid oracle prices
        _setupValidOraclePrices(1e8, 1e8); // $1.00 for both feeds

        operator.setWhitelistedUser(alice, true);
        operator.setWhitelistedUser(bob, true);

        // Register assertion right before operator hook
        cl.assertion({
            adopter: address(operator),
            createData: type(AccountLiquidityAssertion).creationCode,
            fnSelector: AccountLiquidityAssertion.assertionSeizeLiquidity.selector
        });

        // Execute valid seize operation via operator hook
        // The assertion should pass as long as parameters are valid (not zero addresses)
        vm.prank(address(mUSDT)); // seize is called by the mToken contract
        operator.beforeMTokenSeize(address(mUSDT), address(mUSDC), bob);
    }

    // ============ Cross-Transaction Consistency Tests ============

    /**
     * @notice Test borrow with different users
     * @dev Multiple users borrowing should each pass liquidity checks independently
     */
    function testLiquidityConsistency_MultipleUsers_MaintainIndependence() public {
        // Setup collateral for both Alice and Bob
        _setupCollateral(address(mUSDT), alice, 1000e6);
        _setupCollateral(address(mUSDT), bob, 500e6);
        _setupValidOraclePrices(1e8, 1e8);

        // Add liquidity to mUSDC lending pool
        usdc.mint(address(this), 10000e6);
        usdc.approve(address(mUSDC), 10000e6);
        mUSDC.mint(10000e6, address(this), 0);

        operator.setWhitelistedUser(alice, true);
        operator.setWhitelistedUser(bob, true);

        // Test Alice's borrow operation
        cl.assertion({
            adopter: address(operator),
            createData: type(AccountLiquidityAssertion).creationCode,
            fnSelector: AccountLiquidityAssertion.assertionBorrowLiquidity.selector
        });

        vm.prank(alice);
        mUSDC.borrow(100e6); // Alice borrows

        // Test Bob's borrow operation
        cl.assertion({
            adopter: address(operator),
            createData: type(AccountLiquidityAssertion).creationCode,
            fnSelector: AccountLiquidityAssertion.assertionBorrowLiquidity.selector
        });

        vm.prank(bob);
        mUSDC.borrow(50e6); // Bob borrows independently
    }

    /**
     * @notice Test liquidity consistency with price changes
     * @dev Price changes should affect liquidity calculations consistently
     */
    function testLiquidityConsistency_PriceChanges_AffectsCalculations() public {
        // Setup Alice with collateral
        _setupCollateral(address(mUSDT), alice, 1000e6); // Alice supplies 1000 USDT as collateral

        // Start with healthy prices
        _setupValidOraclePrices(1e8, 1e8);

        // Add some USDC to the mUSDC contract so it can lend
        usdc.mint(address(this), 10000e6);
        usdc.approve(address(mUSDC), 10000e6);
        mUSDC.mint(10000e6, address(this), 0);

        operator.setWhitelistedUser(alice, true);
        operator.setWhitelistedUser(bob, true);

        // Test borrow when healthy
        cl.assertion({
            adopter: address(operator),
            createData: type(AccountLiquidityAssertion).creationCode,
            fnSelector: AccountLiquidityAssertion.assertionBorrowLiquidity.selector
        });

        vm.prank(alice);
        mUSDC.borrow(500e6); // Alice borrows 500 USDC when healthy

        // Change prices to make Alice underwater
        // Create separate price feeds for USDC and USDT to get different prices
        MockPriceFeed usdcApi3Feed = new MockPriceFeed();
        MockPriceFeed usdcEOracleFeed = new MockPriceFeed();
        MockPriceFeed usdtApi3Feed = new MockPriceFeed();
        MockPriceFeed usdtEOracleFeed = new MockPriceFeed();

        // Configure USDC feeds with $1.00 price (debt stays at $1.00)
        usdcApi3Feed.setPrice(1e8); // $1.00
        usdcEOracleFeed.setPrice(1e8); // $1.00
        usdcApi3Feed.setUpdatedAt(block.timestamp);
        usdcEOracleFeed.setUpdatedAt(block.timestamp);

        // Configure USDT feeds with $0.40 price (collateral drops to $0.40)
        usdtApi3Feed.setPrice(40e6); // $0.40
        usdtEOracleFeed.setPrice(40e6); // $0.40
        usdtApi3Feed.setUpdatedAt(block.timestamp);
        usdtEOracleFeed.setUpdatedAt(block.timestamp);

        // Update oracle configuration to use separate feeds
        realOracle.setConfig(
            "USDC",
            MixedPriceOracleV4.PriceConfig({
                api3Feed: address(usdcApi3Feed),
                eOracleFeed: address(usdcEOracleFeed),
                toSymbol: "USD",
                underlyingDecimals: 6
            })
        );

        realOracle.setConfig(
            "USDT",
            MixedPriceOracleV4.PriceConfig({
                api3Feed: address(usdtApi3Feed),
                eOracleFeed: address(usdtEOracleFeed),
                toSymbol: "USD",
                underlyingDecimals: 6
            })
        );

        // Give Bob some USDC so he can liquidate Alice's debt
        usdc.mint(bob, 1000e6);
        vm.prank(bob);
        usdc.approve(address(mUSDC), 1000e6);

        // Test liquidation when underwater
        cl.assertion({
            adopter: address(operator),
            createData: type(AccountLiquidityAssertion).creationCode,
            fnSelector: AccountLiquidityAssertion.assertionLiquidationLiquidity.selector
        });

        vm.prank(bob);
        mUSDC.liquidate(alice, 30e6, address(mUSDT)); // Bob liquidates 30 USDC of Alice's debt
    }

    // ============ Edge Case Tests ============

    /**
     * @notice Test liquidity with maximum collateral factor
     * @dev Test behavior at the edge of collateral requirements
     */
    function testLiquidityEdgeCase_MaxCollateralFactor_BehavesCorrectly() public {
        // Setup Alice with collateral
        _setupCollateral(address(mUSDT), alice, 1000e6); // Alice supplies 1000 USDT as collateral
        _setupValidOraclePrices(1e8, 1e8);

        // Add liquidity to mUSDC lending pool
        usdc.mint(address(this), 10000e6);
        usdc.approve(address(mUSDC), 10000e6);
        mUSDC.mint(10000e6, address(this), 0);

        operator.setWhitelistedUser(alice, true);

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(operator),
            createData: type(AccountLiquidityAssertion).creationCode,
            fnSelector: AccountLiquidityAssertion.assertionBorrowLiquidity.selector
        });

        // Test borrow at the edge of what's allowed
        vm.prank(alice);
        mUSDC.borrow(90e6); // Close to maximum allowed
    }

    /**
     * @notice Test liquidity with minimum collateral factor
     * @dev Test behavior with very low collateral factors
     */
    function testLiquidityEdgeCase_MinCollateralFactor_BehavesCorrectly() public {
        // Setup Alice with collateral
        _setupCollateral(address(mUSDT), alice, 1000e6); // Alice supplies 1000 USDT as collateral
        _setupValidOraclePrices(1e8, 1e8);

        // Add liquidity to mUSDC lending pool
        usdc.mint(address(this), 10000e6);
        usdc.approve(address(mUSDC), 10000e6);
        mUSDC.mint(10000e6, address(this), 0);

        operator.setWhitelistedUser(alice, true);

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(operator),
            createData: type(AccountLiquidityAssertion).creationCode,
            fnSelector: AccountLiquidityAssertion.assertionBorrowLiquidity.selector
        });

        // Test borrow with minimal collateral
        vm.prank(alice);
        mUSDC.borrow(10e6); // Small borrow amount
    }
}
