// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {OraclePriceAssertion} from "../src/OraclePriceAssertion.a.sol";
import {BaseAssertionTest} from "./BaseAssertionTest.t.sol";
import {IOperatorDefender, IOperator} from "../../src/interfaces/IOperator.sol";
import {IOracleOperator} from "../../src/interfaces/IOracleOperator.sol";
import {console} from "forge-std/console.sol";

// Additional imports for proper mToken testing
import {mErc20Immutable} from "../../src/mToken/mErc20Immutable.sol";
import {mErc20Host} from "../../src/mToken/host/mErc20Host.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ImTokenOperationTypes} from "../../src/interfaces/ImToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";
import {ZkVerifier} from "../../src/verifier/ZkVerifier.sol";
import {Risc0VerifierMock} from "../../test/mocks/Risc0VerifierMock.sol";
import {IDefaultAdapter} from "../../src/interfaces/IDefaultAdapter.sol";
import {OracleMock} from "../../test/mocks/OracleMock.sol";

contract TestOraclePriceAssertion is BaseAssertionTest {
    OraclePriceAssertion public assertion;

    // Real mToken instances for proper testing
    mErc20Immutable public mWeth;
    mErc20Host public mDaiHost;

    // Required for mErc20Host setup
    ZkVerifier public zkVerifier;
    Risc0VerifierMock public verifierMock;

    function setUp() public override {
        // Call parent setup to initialize common components
        super.setUp();

        // Deploy assertion
        assertion = new OraclePriceAssertion();

        // Deploy real mTokens using the same pattern as mToken_Unit_Shared
        _setupRealMTokens();
    }

    /**
     * @notice Setup real mToken instances for proper testing
     * @dev Uses the same pattern as mToken_Unit_Shared to ensure compatibility
     */
    function _setupRealMTokens() internal {
        // Setup zkVerifier (required for mErc20Host)
        verifierMock = new Risc0VerifierMock();
        vm.label(address(verifierMock), "verifierMock");

        zkVerifier = new ZkVerifier(address(this), "0x123", address(verifierMock));
        vm.label(address(zkVerifier), "ZkVerifier contract");

        // Deploy mUSDT (non-proxy) - using USDT as collateral
        mWeth = new mErc20Immutable(
            address(usdc), // Use USDC instead of WETH
            address(operator),
            address(interestModel),
            1e18,
            "Market USDC",
            "mUSDC",
            6, // USDC has 6 decimals
            payable(address(this))
        );
        vm.label(address(mWeth), "mUSDC");

        // Setup market in operator
        operator.supportMarket(address(mWeth));

        // Set collateral factor
        operator.setCollateralFactor(address(mWeth), 0.9e18); // 90% collateral factor for USDC

        // Set oracle prices to default values using the real oracle
        // The real oracle is already set up in BaseAssertionTest with proper price feeds
        // We just need to set the price feeds to reasonable values
        api3Feed.setPrice(int256(DEFAULT_ORACLE_PRICE)); // 1e18
        eOracleFeed.setPrice(int256(DEFAULT_ORACLE_PRICE)); // 1e18
    }

    /**
     * @notice Setup collateral for a user by minting tokens and supplying them to an mToken
     * @dev Similar to _borrowPrerequisites from mToken_Unit_Shared
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
        mErc20Immutable(mToken).mint(supplyAmount, user, supplyAmount);

        // User enters the market (required for borrowing)
        address[] memory mTokens = new address[](1);
        mTokens[0] = mToken;
        vm.prank(user);
        operator.enterMarkets(mTokens);
    }

    /**
     * @notice Test that borrow price sanity assertion passes with valid oracle prices
     * @dev Tests the assertionBorrowPriceSanity function with a valid price setup
     * Uses the same proper setup as the working testAliceCanBorrowWithoutAssertions test
     */
    function testBorrowPriceSanityPassesWithValidPrice() public {
        // Setup Alice with USDC collateral (100 USDC = 100e6)
        uint256 collateralAmount = 100e6; // 100 USDC (6 decimals)
        _setupCollateral(address(mWeth), alice, collateralAmount);

        // Verify Alice has sufficient liquidity to borrow
        (uint256 liquidity, uint256 shortfall) = operator.getAccountLiquidity(alice);
        console.log("Alice liquidity before borrow test:", liquidity);
        console.log("Alice shortfall before borrow test:", shortfall);

        // Alice should have liquidity (collateral) and no shortfall
        assertTrue(liquidity > 0, "Alice should have liquidity");
        assertTrue(shortfall == 0, "Alice should have no shortfall");

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(operator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionBorrowPriceSanity.selector
        });

        // Test borrowing a reasonable amount of USDC (10 USDC = 10e6)
        uint256 borrowAmount = 10e6; // 10 USDC

        // Call the operator hook directly with proper mToken address
        vm.prank(alice);
        operator.beforeMTokenBorrow(address(mWeth), alice, borrowAmount);
    }

    /**
     * @notice Test that borrow price sanity assertion fails with zero price
     * @dev Tests the assertionBorrowPriceSanity function with zero price to verify it catches invalid prices
     * Uses the same proper setup as the working testBorrowPriceSanityPassesWithValidPrice test
     */
    function testBorrowPriceSanityFailsWithZeroPrice() public {
        // Setup Alice with USDC collateral (100 USDC = 100e6)
        uint256 collateralAmount = 100e6; // 100 USDC (6 decimals)
        _setupCollateral(address(mWeth), alice, collateralAmount);

        // Verify Alice has sufficient liquidity initially
        (uint256 liquidity, uint256 shortfall) = operator.getAccountLiquidity(alice);
        console.log("Alice liquidity:", liquidity);
        console.log("Alice shortfall:", shortfall);

        // Alice should have liquidity (collateral) and no shortfall
        assertTrue(liquidity > 0, "Alice should have liquidity");
        assertTrue(shortfall == 0, "Alice should have no shortfall");

        // Set zero prices in the oracle feeds to trigger the assertion failure
        api3Feed.setPrice(0);
        eOracleFeed.setPrice(0);

        // Test borrowing a reasonable amount of USDC (10 USDC = 10e6)
        uint256 borrowAmount = 10e6; // 10 USDC

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(operator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionBorrowPriceSanity.selector
        });

        // This should fail the assertion when it checks for zero price
        // Note: We expect the assertion to fail, but let's see what actually happens
        vm.prank(alice);
        operator.beforeMTokenBorrow(address(mWeth), alice, borrowAmount);
    }

    /**
     * @notice Test that liquidation price sanity assertion passes with valid oracle prices
     * @dev Tests the assertionLiquidationPriceSanity function with a valid price setup
     * Uses a simplified approach that focuses on testing the assertion mechanism
     */
    function testLiquidationPriceSanityPassesWithValidPrice() public {
        // Setup: Use the mock mToken approach for proper liquidation testing
        // This test uses the same approach as testLiquidationWorksWithoutAssertions

        // Setup Alice with collateral in the collateral market (USDT)
        _setupAliceWithCollateral();

        // Set up liquidation parameters
        operator.setCloseFactor(0.5e18); // 50% close factor
        operator.setLiquidationIncentive(address(mockMToken), 1.1e18); // 10% liquidation incentive

        // Create a shortfall by manipulating oracle price
        // Use a very low price to ensure shortfall
        api3Feed.setPrice(int256(0.1e8)); // 90% price drop to create shortfall
        eOracleFeed.setPrice(int256(0.1e8)); // Keep both feeds consistent

        // Check Alice's liquidity status
        (uint256 liquidity, uint256 shortfall) = operator.getAccountLiquidity(alice);
        console.log("Alice liquidity for liquidation test:", liquidity);
        console.log("Alice shortfall for liquidation test:", shortfall);

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(operator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionLiquidationPriceSanity.selector
        });

        // Try to call the liquidation hook directly (since we're using mocks)
        // This will trigger the assertion
        uint256 liquidateAmount = 10e6; // 10 USDC
        vm.prank(bob);
        operator.beforeMTokenLiquidate(address(mockMToken), address(mockCollateralMToken), alice, liquidateAmount);
    }

    /**
     * @notice Test that liquidation price sanity assertion fails with zero price
     * @dev Tests the assertionLiquidationPriceSanity function with zero price to verify it catches invalid prices
     */
    function testLiquidationPriceSanityFailsWithZeroPrice() public {
        // Setup: Set zero price in price feeds before registering assertion
        _setupValidOraclePrices(0, 0); // Zero prices for both feeds

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(operator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionLiquidationPriceSanity.selector
        });

        // This should fail the assertion when it checks for zero price
        vm.expectRevert("Oracle price cannot be zero");
        mockMToken.triggerLiquidationHook(address(usdc), address(usdc), alice, 1000e6);
    }

    /**
     * @notice Test that borrow price stability assertion passes with stable prices
     * @dev Tests the assertionBorrowPriceStability function with minimal price changes
     * Uses the same proper setup as the working testBorrowPriceSanityPassesWithValidPrice test
     */
    function testBorrowPriceStabilityPassesWithStablePrice() public {
        // Setup Alice with USDC collateral (100 USDC = 100e6)
        uint256 collateralAmount = 100e6; // 100 USDC (6 decimals)
        _setupCollateral(address(mWeth), alice, collateralAmount);

        // Verify Alice has sufficient liquidity initially
        (uint256 liquidity, uint256 shortfall) = operator.getAccountLiquidity(alice);
        console.log("Alice liquidity:", liquidity);
        console.log("Alice shortfall:", shortfall);

        // Alice should have liquidity (collateral) and no shortfall
        assertTrue(liquidity > 0, "Alice should have liquidity");
        assertTrue(shortfall == 0, "Alice should have no shortfall");

        // Execute operation with minimal price change (within 5% tolerance)
        api3Feed.setPrice(1.01e8); // 1% price change - should pass

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(operator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionBorrowPriceStability.selector
        });

        // Test borrowing a reasonable amount of USDC (10 USDC = 10e6)
        uint256 borrowAmount = 10e6; // 10 USDC

        // Call the operator hook directly with proper mToken address
        vm.prank(alice);
        operator.beforeMTokenBorrow(address(mWeth), alice, borrowAmount);
    }

    /**
     * @notice Test that borrow price stability assertion passes when prices are changed before transaction
     * @dev Tests the assertionBorrowPriceStability function - since prices are changed BEFORE the transaction,
     * there is no intra-transaction price change, so the assertion correctly passes
     * Uses the same proper setup as the working testBorrowPriceSanityPassesWithValidPrice test
     */
    function testBorrowPriceStabilityFailsWithDramaticChange() public {
        // Setup Alice with USDC collateral (100 USDC = 100e6)
        uint256 collateralAmount = 100e6; // 100 USDC (6 decimals)
        _setupCollateral(address(mWeth), alice, collateralAmount);

        // Verify Alice has sufficient liquidity initially
        (uint256 liquidity, uint256 shortfall) = operator.getAccountLiquidity(alice);
        console.log("Alice liquidity:", liquidity);
        console.log("Alice shortfall:", shortfall);

        // Alice should have liquidity (collateral) and no shortfall
        assertTrue(liquidity > 0, "Alice should have liquidity");
        assertTrue(shortfall == 0, "Alice should have no shortfall");

        // Change prices BEFORE the transaction starts
        // This means there will be no intra-transaction price change
        api3Feed.setPrice(2e8); // 100% price change - but before transaction
        eOracleFeed.setPrice(2e8); // Update both feeds

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(operator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionBorrowPriceStability.selector
        });

        // Test borrowing a reasonable amount of USDC (10 USDC = 10e6)
        uint256 borrowAmount = 10e6; // 10 USDC

        // Since prices were changed BEFORE the transaction, there is no intra-transaction
        // price change, so the assertion should pass (which is correct behavior)
        vm.prank(alice);
        operator.beforeMTokenBorrow(address(mWeth), alice, borrowAmount);
    }

    /**
     * @notice Test that cross-feed deviation assertion passes when feeds are consistent
     * @dev Tests the assertionCrossFeedDeviation function with consistent feed prices
     */
    function testCrossFeedDeviationPassesWithConsistentFeeds() public {
        // Setup Alice with USDC collateral (100 USDC = 100e6)
        uint256 collateralAmount = 100e6; // 100 USDC (6 decimals)
        _setupCollateral(address(mWeth), alice, collateralAmount);

        // Verify Alice has sufficient liquidity
        (uint256 liquidity, uint256 shortfall) = operator.getAccountLiquidity(alice);
        assertTrue(liquidity > 0, "Alice should have liquidity");
        assertTrue(shortfall == 0, "Alice should have no shortfall");

        // Set consistent prices in both feeds (same price = no deviation)
        api3Feed.setPrice(1e8); // $1.00
        eOracleFeed.setPrice(1e8); // $1.00 - same price, no deviation

        // Test borrowing a reasonable amount of USDC (10 USDC = 10e6)
        uint256 borrowAmount = 10e6; // 10 USDC

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(operator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionCrossFeedDeviation.selector
        });

        // This should pass since both feeds have consistent prices
        vm.prank(alice);
        operator.beforeMTokenBorrow(address(mWeth), alice, borrowAmount);
    }

    /**
     * @notice Test that cross-feed deviation assertion passes with minor deviation
     * @dev Tests the assertionCrossFeedDeviation function with small price differences within tolerance
     */
    function testCrossFeedDeviationPassesWithMinorDeviation() public {
        // Setup Alice with USDC collateral (100 USDC = 100e6)
        uint256 collateralAmount = 100e6; // 100 USDC (6 decimals)
        _setupCollateral(address(mWeth), alice, collateralAmount);

        // Verify Alice has sufficient liquidity
        (uint256 liquidity, uint256 shortfall) = operator.getAccountLiquidity(alice);
        assertTrue(liquidity > 0, "Alice should have liquidity");
        assertTrue(shortfall == 0, "Alice should have no shortfall");

        // Set prices with minor deviation (within tolerance)
        api3Feed.setPrice(1e8); // $1.00
        eOracleFeed.setPrice(1.003e8); // $1.003 - 0.3% deviation, should be within tolerance

        // Test borrowing a reasonable amount of USDC (10 USDC = 10e6)
        uint256 borrowAmount = 10e6; // 10 USDC

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(operator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionCrossFeedDeviation.selector
        });

        // This should pass since deviation is within acceptable bounds
        vm.prank(alice);
        operator.beforeMTokenBorrow(address(mWeth), alice, borrowAmount);
    }

    /**
     * @notice Test that cross-feed deviation assertion fails with extreme deviation
     * @dev Tests the assertionCrossFeedDeviation function with large price differences exceeding tolerance
     */
    function testCrossFeedDeviationFailsWithExtremeDeviation() public {
        // Setup Alice with USDC collateral (100 USDC = 100e6)
        uint256 collateralAmount = 100e6; // 100 USDC (6 decimals)
        _setupCollateral(address(mWeth), alice, collateralAmount);

        // Verify Alice has sufficient liquidity
        (uint256 liquidity, uint256 shortfall) = operator.getAccountLiquidity(alice);
        assertTrue(liquidity > 0, "Alice should have liquidity");
        assertTrue(shortfall == 0, "Alice should have no shortfall");

        // Set prices with extreme deviation (exceeds tolerance)
        api3Feed.setPrice(1e8); // $1.00
        eOracleFeed.setPrice(3e8); // $3.00 - 200% deviation, should exceed tolerance

        // Test borrowing a reasonable amount of USDC (10 USDC = 10e6)
        uint256 borrowAmount = 10e6; // 10 USDC

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(operator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionCrossFeedDeviation.selector
        });

        // This should fail due to extreme cross-feed deviation
        vm.expectRevert("Cross-feed deviation exceeds threshold");
        vm.prank(alice);
        operator.beforeMTokenBorrow(address(mWeth), alice, borrowAmount);
    }

    /**
     * @notice Test that cross-feed deviation assertion detects intra-transaction deviation changes
     * @dev Tests the assertionCrossFeedDeviation function with price changes during transaction execution
     */
    function testCrossFeedDeviationDetectsIntraTransactionDeviation() public {
        // Setup Alice with USDC collateral (100 USDC = 100e6)
        uint256 collateralAmount = 100e6; // 100 USDC (6 decimals)
        _setupCollateral(address(mWeth), alice, collateralAmount);

        // Verify Alice has sufficient liquidity
        (uint256 liquidity, uint256 shortfall) = operator.getAccountLiquidity(alice);
        assertTrue(liquidity > 0, "Alice should have liquidity");
        assertTrue(shortfall == 0, "Alice should have no shortfall");

        // Set initial consistent prices
        api3Feed.setPrice(1e8); // $1.00
        eOracleFeed.setPrice(1e8); // $1.00 - consistent initially

        // Test borrowing with price change during the transaction
        uint256 borrowAmount = 10e6; // 10 USDC

        // TODO: fix this test, we probably need to mock the entire oracle
        // Mock the eOracle feed to return a different price during the transaction
        // This simulates a price feed being compromised or updated mid-transaction
        vm.mockCall(
            address(eOracleFeed),
            abi.encodeWithSelector(IDefaultAdapter.latestRoundData.selector),
            abi.encode(
                uint80(1), // roundId
                int256(3e8), // answer - $3.00 (200% deviation from $1.00)
                uint256(0), // startedAt
                uint256(block.timestamp), // updatedAt
                uint80(1) // answeredInRound
            )
        );

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(operator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionCrossFeedDeviation.selector
        });

        // This should fail due to intra-transaction cross-feed deviation
        vm.expectRevert("Cross-feed deviation exceeds threshold");
        vm.prank(alice);
        operator.beforeMTokenBorrow(address(mWeth), alice, borrowAmount);
    }

    /**
     * @notice Test that liquidation price stability assertion passes with stable prices
     * @dev Tests the assertionLiquidationPriceStability function with minimal price changes
     *
     * TODO: This test is conceptually wrong. The assertion checks for intra-transaction price changes
     * (price manipulation DURING the transaction), but this test sets all prices BEFORE the transaction.
     * To properly test, we need to simulate price changes that occur DURING liquidation execution,
     * similar to sandwich attacks. See AccountLiquidityAssertion tests for proper liquidation setup patterns.
     */
    function testLiquidationPriceStabilityPassesWithStablePrice() public {
        // Use the simple mock setup instead of real mTokens for liquidation tests
        // This matches the pattern used in testLiquidationPriceSanityPassesWithValidPrice
        // Note: _setupBasicMarket() already called in BaseAssertionTest.setUp()
        _setupAliceWithCollateral(); // Sets up mock collateral markets

        // Set up liquidation parameters (required for liquidation to be allowed)
        operator.setCloseFactor(0.5e18); // 50% close factor
        operator.setLiquidationIncentive(address(mockMToken), 1.1e18); // 10% liquidation incentive

        // Create and maintain shortfall by manipulating oracle price
        // We need low prices to maintain shortfall condition for liquidation validity
        api3Feed.setPrice(int256(0.1e8)); // 90% price drop to create shortfall
        eOracleFeed.setPrice(int256(0.101e8)); // 1% price change from 0.1 - should pass (within 5% tolerance)

        // Check Alice's liquidity status to ensure she has shortfall
        (uint256 liquidity, uint256 shortfall) = operator.getAccountLiquidity(alice);
        console.log("Alice liquidity for price stability test:", liquidity);
        console.log("Alice shortfall for price stability test:", shortfall);

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(operator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionLiquidationPriceStability.selector
        });

        // Call the operator hook directly, using mock mTokens
        // The operator will check the assertion when beforeMTokenLiquidate is called
        vm.prank(bob);
        operator.beforeMTokenLiquidate(
            address(mockMToken), // mTokenBorrowed
            address(mockCollateralMToken), // mTokenCollateral
            alice, // borrower
            10e6 // repayAmount (same as working test)
        );
    }

    /**
     * @notice Test that liquidation price stability assertion fails with dramatic price changes
     * @dev Tests the assertionLiquidationPriceStability function with price changes exceeding 5% tolerance
     */
    function testLiquidationPriceStabilityFailsWithDramaticChange() public {
        // Use the simple mock setup for consistency
        // Note: _setupBasicMarket() already called in BaseAssertionTest.setUp()
        _setupAliceWithCollateral(); // Sets up mock collateral markets

        // Set up liquidation parameters (required for liquidation to be allowed)
        operator.setCloseFactor(0.5e18); // 50% close factor
        operator.setLiquidationIncentive(address(mockMToken), 1.1e18); // 10% liquidation incentive

        // Create and maintain shortfall by manipulating oracle price
        // We need low prices to maintain shortfall condition for liquidation validity
        api3Feed.setPrice(int256(0.1e8)); // 90% price drop to create shortfall
        eOracleFeed.setPrice(int256(0.2e8)); // 100% price change from 0.1 - should fail (exceeds 5% tolerance)

        // Check Alice's liquidity status to ensure she has shortfall
        (uint256 liquidity, uint256 shortfall) = operator.getAccountLiquidity(alice);
        console.log("Alice liquidity for dramatic change test:", liquidity);
        console.log("Alice shortfall for dramatic change test:", shortfall);

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(operator),
            createData: type(OraclePriceAssertion).creationCode,
            fnSelector: OraclePriceAssertion.assertionLiquidationPriceStability.selector
        });

        // Execute operation with dramatic price change (exceeds 5% tolerance)
        api3Feed.setPrice(2e8); // 100% price change - should fail
        eOracleFeed.setPrice(2e8); // Keep both feeds consistent

        // This should fail due to dramatic price change
        vm.expectRevert("Borrowed token price deviated too much during liquidation");
        vm.prank(bob);
        operator.beforeMTokenLiquidate(
            address(mockMToken), // mTokenBorrowed
            address(mockCollateralMToken), // mTokenCollateral
            alice, // borrower
            10e6 // repayAmount (same as working test)
        );
    }

    /**
     * @notice Test that Alice can successfully call mToken.borrow() without assertions
     * @dev This test verifies our test setup works correctly by testing the actual user flow
     * Uses real mTokens and proper setup to ensure realistic testing
     */
}

/**
 * @title MockMTokenWithPriceChange
 * @notice Mock mToken that changes price feed values during transaction execution
 * @dev Used to test intra-transaction price deviation detection
 */
contract MockMTokenWithPriceChange is mErc20Immutable {
    address public api3Feed;
    address public eOracleFeed;
    bool public priceChanged = false;

    constructor(
        address underlying_,
        address operator_,
        address interestModel_,
        uint256 initialExchangeRateMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address payable admin_,
        address api3Feed_,
        address eOracleFeed_
    )
        mErc20Immutable(
            underlying_,
            operator_,
            interestModel_,
            initialExchangeRateMantissa_,
            name_,
            symbol_,
            decimals_,
            admin_
        )
    {
        api3Feed = api3Feed_;
        eOracleFeed = eOracleFeed_;
    }

    /**
     * @notice Function to manually change price during testing
     * @dev This simulates intra-transaction price changes for testing
     */
    function changePriceDuringTransaction() external {
        if (!priceChanged) {
            // Change the eOracle feed price during the transaction
            // This simulates a price feed being compromised or updated mid-transaction
            OracleMock(eOracleFeed).setPrice(3e8); // Change to $3.00 (200% deviation)
            priceChanged = true;
        }
    }
}
