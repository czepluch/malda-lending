// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CredibleTest} from "credible-std/CredibleTest.sol";
import {Test} from "forge-std/Test.sol";

// Real protocol imports
import {MixedPriceOracleV4} from "../../src/oracles/MixedPriceOracleV4.sol";
import {IOperatorDefender} from "../../src/interfaces/IOperator.sol";
import {IInterestRateModel} from "../../src/interfaces/IInterestRateModel.sol";

// Test utilities
import {Base_Unit_Test} from "../../test/Base_Unit_Test.t.sol";
import {mErc20Immutable} from "../../src/mToken/mErc20Immutable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";

// Mock adapters for oracle feeds
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

// Mock underlying token that returns configurable symbol
contract MockUnderlyingToken {
    string public symbol;

    constructor(string memory _symbol) {
        symbol = _symbol;
    }
}

// Mock mToken for testing operator hooks
contract MockMToken {
    MockUnderlyingToken public underlying;
    address public operator;
    string public symbol = "MOCK";

    constructor(address _operator, string memory _symbol) {
        underlying = new MockUnderlyingToken(_symbol);
        operator = _operator;
    }

    // Minimal implementation to satisfy operator requirements
    function borrowBalanceStored(address user) external view returns (uint256) {
        // Give Alice a borrow balance in the borrow market (USDC)
        if (user == address(0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf)) {
            // Check if this is the borrow mToken by checking the underlying symbol
            if (keccak256(bytes(underlying.symbol())) == keccak256(bytes("USDC"))) {
                return 100e6; // 100 USDC borrow balance
            }
        }
        return 0;
    }

    function totalBorrows() external pure returns (uint256) {
        return 0;
    }

    function getAccountSnapshot(address user) external view returns (uint256, uint256, uint256, uint256) {
        // Returns: (error, tokenBalance, borrowBalance, exchangeRateMantissa)
        // Give Alice some token balance to pass liquidity checks
        if (user == address(0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf)) {
            // Alice - give her tokens in the collateral market (USDT)
            // Check if this is the collateral mToken by checking the underlying symbol
            if (keccak256(bytes(underlying.symbol())) == keccak256(bytes("USDT"))) {
                return (0, 1000e6, 0, 1e18); // 1000 tokens (1000e6 in 6 decimals), no borrows
            }
        }
        return (0, 0, 0, 1e18);
    }

    // Function to trigger operator hooks (simulates real mToken behavior)
    function triggerBorrowHook(address borrower, uint256 amount) external {
        IOperatorDefender(operator).beforeMTokenBorrow(address(this), borrower, amount);
    }

    function triggerLiquidationHook(
        address mTokenBorrowed,
        address mTokenCollateral,
        address borrower,
        uint256 repayAmount
    ) external {
        IOperatorDefender(operator).beforeMTokenLiquidate(mTokenBorrowed, mTokenCollateral, borrower, repayAmount);
    }
}

// Mock interest rate model for testing
contract MockInterestRateModel is IInterestRateModel {
    uint256 public borrowRate = 1e14; // 0.01% per block

    function isInterestRateModel() external pure returns (bool) {
        return true;
    }

    function blocksPerYear() external pure returns (uint256) {
        return 2628000; // ~10 blocks/min * 60 * 24 * 365
    }

    function multiplierPerBlock() external pure returns (uint256) {
        return 2e15;
    }

    function baseRatePerBlock() external pure returns (uint256) {
        return 1e15;
    }

    function jumpMultiplierPerBlock() external pure returns (uint256) {
        return 5e15;
    }

    function kink() external pure returns (uint256) {
        return 8e17; // 80% utilization
    }

    function name() external pure returns (string memory) {
        return "MockInterestRateModel";
    }

    function utilizationRate(uint256 cash, uint256 borrows, uint256 reserves) external pure returns (uint256) {
        if (borrows == 0) return 0;
        return (borrows * 1e18) / (cash + borrows - reserves);
    }

    function getBorrowRate(uint256 cash, uint256 borrows, uint256 reserves) external view returns (uint256) {
        return borrowRate;
    }

    function getSupplyRate(uint256 cash, uint256 borrows, uint256 reserves, uint256 reserveFactorMantissa)
        external
        view
        returns (uint256)
    {
        uint256 oneMinusReserveFactor = 1e18 - reserveFactorMantissa;
        uint256 borrowRateMantissa = 1e14; // 0.01% per block
        uint256 rateToPool = (borrowRateMantissa * oneMinusReserveFactor) / 1e18;
        return (this.utilizationRate(cash, borrows, reserves) * rateToPool) / 1e18;
    }

    function setBorrowRate(uint256 _rate) external {
        borrowRate = _rate;
    }
}

/**
 * @title Base Assertion Test
 * @notice Shared setup for assertion tests with common oracle and protocol components
 * @dev Provides common setup functionality for all assertion tests to reduce redundancy
 */
abstract contract BaseAssertionTest is CredibleTest, Base_Unit_Test {
    MixedPriceOracleV4 public realOracle;

    // Mock price feeds
    MockPriceFeed public api3Feed;
    MockPriceFeed public eOracleFeed;

    // Mock mTokens for testing
    MockMToken public mockMToken;
    MockMToken public mockCollateralMToken; // Second mToken for collateral

    function setUp() public virtual override {
        // Call parent setup to initialize real protocol components
        super.setUp();

        // Deploy mock price feeds
        api3Feed = new MockPriceFeed();
        eOracleFeed = new MockPriceFeed();

        // Deploy mock mTokens with operator reference
        mockMToken = new MockMToken(address(operator), "USDC"); // Token to borrow from
        mockCollateralMToken = new MockMToken(address(operator), "USDT"); // Token to use as collateral

        // Setup real MixedPriceOracleV4
        _setupRealOracle();

        // Set the real oracle as the operator's oracle
        operator.setPriceOracle(address(realOracle));

        // Setup basic mToken market for testing
        _setupBasicMarket();
    }

    /**
     * @notice Setup the MixedPriceOracleV4 oracle
     * @dev Configures oracle with USDC symbol and default settings
     */
    function _setupRealOracle() internal {
        // Grant GUARDIAN_ORACLE role to this test contract
        roles.allowFor(address(this), roles.GUARDIAN_ORACLE(), true);

        // Create symbol array
        string[] memory symbols = new string[](2);
        symbols[0] = "USDC";
        symbols[1] = "USDT";

        // Create price config
        MixedPriceOracleV4.PriceConfig[] memory configs = new MixedPriceOracleV4.PriceConfig[](2);
        configs[0] = MixedPriceOracleV4.PriceConfig({
            api3Feed: address(api3Feed),
            eOracleFeed: address(eOracleFeed),
            toSymbol: "USD",
            underlyingDecimals: 6 // USDC has 6 decimals
        });
        configs[1] = MixedPriceOracleV4.PriceConfig({
            api3Feed: address(api3Feed),
            eOracleFeed: address(eOracleFeed),
            toSymbol: "USD",
            underlyingDecimals: 6 // USDT has 6 decimals
        });

        // Deploy real oracle
        realOracle = new MixedPriceOracleV4(symbols, configs, address(roles), 1 days);

        // Set reasonable staleness and delta configurations
        realOracle.setStaleness("USDC", 3600); // 1 hour staleness
        realOracle.setMaxPriceDelta(500); // 5% max delta
        realOracle.setSymbolMaxPriceDelta(300, "USDC"); // 3% per symbol delta

        // Set initial prices
        api3Feed.setPrice(1e8); // $1.00
        eOracleFeed.setPrice(1e8); // $1.00
        api3Feed.setUpdatedAt(block.timestamp);
        eOracleFeed.setUpdatedAt(block.timestamp);
    }

    /**
     * @notice Setup a basic mToken market for testing
     * @dev Creates a simple mToken market that can be used for borrow/liquidation testing
     */
    function _setupBasicMarket() internal {
        // List both mock mToken markets in the operator so that
        // operator.beforeMTokenBorrow() doesn't revert with "MarketNotListed"
        operator.supportMarket(address(mockMToken));
        operator.supportMarket(address(mockCollateralMToken));

        // Allow test users (alice, bob) to interact with the protocol
        operator.setWhitelistedUser(alice, true);
        operator.setWhitelistedUser(bob, true);
        operator.setWhitelistedUser(address(this), true);

        // Ensure the markets are not paused for borrow operations
        // (This might require additional setup depending on the operator implementation)
    }

    /**
     * @notice Set up valid oracle prices for testing
     * @param api3Price Price for API3 feed (in 8 decimals)
     * @param eOraclePrice Price for eOracle feed (in 8 decimals)
     */
    function _setupValidOraclePrices(int256 api3Price, int256 eOraclePrice) internal {
        api3Feed.setPrice(api3Price);
        eOracleFeed.setPrice(eOraclePrice);
        api3Feed.setUpdatedAt(block.timestamp);
        eOracleFeed.setUpdatedAt(block.timestamp);
    }

    /**
     * @notice Set up stale oracle prices for testing
     * @param api3Price Price for API3 feed (in 8 decimals)
     * @param eOraclePrice Price for eOracle feed (in 8 decimals)
     * @param stalenessSeconds How many seconds ago the prices were updated
     */
    function _setupStaleOraclePrices(int256 api3Price, int256 eOraclePrice, uint256 stalenessSeconds) internal {
        api3Feed.setPrice(api3Price);
        eOracleFeed.setPrice(eOraclePrice);
        api3Feed.setUpdatedAt(block.timestamp - stalenessSeconds);
        eOracleFeed.setUpdatedAt(block.timestamp - stalenessSeconds);
    }

    /**
     * @notice Set up oracle configuration for testing
     * @param maxDelta Maximum price delta (in basis points)
     * @param symbolDelta Symbol-specific price delta (in basis points)
     * @param staleness Staleness period in seconds
     */
    function _setupOracleConfig(uint256 maxDelta, uint256 symbolDelta, uint256 staleness) internal {
        realOracle.setMaxPriceDelta(maxDelta);
        realOracle.setSymbolMaxPriceDelta(symbolDelta, "USDC");
        realOracle.setStaleness("USDC", staleness);
    }

    /**
     * @notice Get the current oracle price for USDC
     * @return price The current underlying price for USDC
     */
    function _getCurrentOraclePrice() internal view returns (uint256 price) {
        return realOracle.getUnderlyingPrice(address(usdc));
    }

    /**
     * @notice Get the mock mToken address for testing
     */
    function _getMockMToken() internal view returns (address) {
        return address(mockMToken);
    }

    /**
     * @notice Simulate a borrow operation to trigger operator hooks
     * @param borrower The borrower address
     * @param amount The amount to borrow
     */
    function _simulateBorrowOperation(address borrower, uint256 amount) internal {
        // Use the mock mToken to trigger the operator hook (simulates real mToken behavior)
        mockMToken.triggerBorrowHook(borrower, amount);
    }

    /**
     * @notice Simulate a liquidation operation to trigger operator hooks
     * @param borrower The borrower address
     * @param repayAmount The amount to repay
     */
    function _simulateLiquidationOperation(address borrower, uint256 repayAmount) internal {
        // Use the mock mToken to trigger the operator hook (simulates real mToken behavior)
        mockMToken.triggerLiquidationHook(address(mockMToken), address(mockMToken), borrower, repayAmount);
    }

    /**
     * @notice Set up Alice with collateral in the collateral market
     * @dev This simulates Alice having deposited collateral that she can borrow against
     */
    function _setupAliceWithCollateral() internal {
        // Enter Alice into both markets so she has liquidity
        address[] memory markets = new address[](2);
        markets[0] = address(mockCollateralMToken); // USDT collateral
        markets[1] = address(mockMToken); // USDC borrow market

        // Use vm.prank to enter markets as Alice
        vm.prank(alice);
        operator.enterMarkets(markets);
    }

    /**
     * @notice Setup collateral using real mToken approach
     * @dev Based on _setupCollateral from OraclePriceAssertion.t.sol
     * @param mToken The mToken contract to use
     * @param user The user to set up collateral for
     * @param supplyAmount The amount to supply as collateral
     */
    function _setupCollateralReal(address mToken, address user, uint256 supplyAmount) internal {
        address underlying = mErc20Immutable(mToken).underlying();

        // Mint underlying tokens to the user
        ERC20Mock(underlying).mint(user, supplyAmount);

        // User approves mToken to spend their underlying tokens
        vm.prank(user);
        IERC20(underlying).approve(mToken, supplyAmount);

        // User supplies tokens to the mToken market
        vm.prank(user);
        mErc20Immutable(mToken).mint(supplyAmount, user, 0); // minAmountOut = 0 to account for 1000 token initial supply fee

        // User enters the market (required for borrowing)
        address[] memory mTokens = new address[](1);
        mTokens[0] = mToken;
        vm.prank(user);
        operator.enterMarkets(mTokens);
    }
}
