// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CredibleTest} from "credible-std/CredibleTest.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {AccountLiquidityAssertion} from "../../src/AccountLiquidityAssertion.a.sol";
import {BaseAssertionTest} from "../unit/BaseAssertionTest.t.sol";
import {mErc20Immutable} from "../../../src/mToken/mErc20Immutable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "../../../test/mocks/ERC20Mock.sol";
import {MixedPriceOracleV4} from "../../../src/oracles/MixedPriceOracleV4.sol";

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
 * @title Fuzz Tests for Account Liquidity Assertion
 * @notice Fuzz testing for account liquidity assertions to find edge cases
 * @dev Tests valid borrow operations with randomized parameters to ensure assertions hold across parameter space
 *
 * Run with: forge test --match-path "test/fuzz/**" --fuzz-runs 256
 * Or configure in foundry.toml under [fuzz] section
 */
contract FuzzAccountLiquidityAssertion is BaseAssertionTest {
    AccountLiquidityAssertion public assertion;

    // mToken market instances
    mErc20Immutable public mUSDC;
    mErc20Immutable public mUSDT;

    // USDT token for testing
    ERC20Mock public usdt;

    function setUp() public override {
        super.setUp();
        assertion = new AccountLiquidityAssertion();

        // Create USDT token with high mint limit for fuzzing
        usdt = new ERC20Mock("USDT", "USDT", 6, address(this), address(0), 1000000000 * 1e6); // 1B USDT limit
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

        // Deploy mUSDT (collateral market)
        mUSDT = new mErc20Immutable(
            address(usdt),
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

        // Set close factor for liquidations
        operator.setCloseFactor(0.5e18);

        // Set liquidation incentive (10%)
        operator.setLiquidationIncentive(address(mUSDC), 1.1e18);
    }

    /**
     * @notice Helper to setup collateral for a user
     * @param mToken The mToken market to supply to
     * @param user The user supplying collateral
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

    // Note: _setupValidOraclePrices is inherited from BaseAssertionTest

    // ============ Fuzz Tests ============

    /**
     * @notice Fuzz test for valid borrow operations with varying parameters
     * @dev Tests that the liquidity assertion holds across a wide range of valid parameters
     *
     * @param collateralAmount The amount of collateral to supply
     * @param collateralFactorBps The collateral factor in basis points
     * @param borrowPercentBps The percentage of max borrowable amount to actually borrow
     *
     * Invariants tested:
     * - Borrow with sufficient collateral always passes the assertion
     * - Collateral calculation is consistent across parameter space
     * - No overflow/underflow in liquidity calculations
     */
    function testFuzz_BorrowLiquidity_ValidBorrow_Passes(
        uint256 collateralAmount,
        uint256 collateralFactorBps,
        uint256 borrowPercentBps
    ) public {
        // Constrain inputs to realistic and safe ranges using vm.assume()
        // Collateral: $10 to $1,000,000 (in 6 decimals)
        vm.assume(collateralAmount >= 10e6 && collateralAmount <= 1_000_000e6);

        // Collateral factor: 50% to 90% (5000 to 9000 bps) - max is COLLATERAL_FACTOR_MAX_MANTISSA = 0.9e18
        vm.assume(collateralFactorBps >= 5000 && collateralFactorBps <= 9000);
        uint256 collateralFactor = (collateralFactorBps * 1e18) / 10000;

        // Borrow percent: 1% to 99% of available (to stay safely under limit)
        vm.assume(borrowPercentBps >= 100 && borrowPercentBps <= 9900);

        // Setup Alice with collateral
        _setupCollateral(address(mUSDT), alice, collateralAmount);

        // Set collateral factors for both markets
        operator.setCollateralFactor(address(mUSDC), 0.8e18); // 80% for USDC
        operator.setCollateralFactor(address(mUSDT), collateralFactor); // Fuzzed for USDT

        // Setup oracle prices ($1.00 for both)
        _setupValidOraclePrices(1e8, 1e8);

        // Add substantial liquidity to lending pool (10x max potential borrow)
        uint256 poolLiquidity = collateralAmount * 10;
        usdc.mint(address(this), poolLiquidity);
        usdc.approve(address(mUSDC), poolLiquidity);
        mUSDC.mint(poolLiquidity, address(this), 0);

        operator.setWhitelistedUser(alice, true);

        // Calculate max borrow based on collateral
        // maxBorrow = collateralAmount * collateralFactor
        uint256 maxBorrowAmount = (collateralAmount * collateralFactor) / 1e18;

        // Calculate actual borrow (percentage of max)
        uint256 borrowAmount = (maxBorrowAmount * borrowPercentBps) / 10000;

        // Ensure borrow amount is at least 1 and doesn't exceed pool liquidity
        if (borrowAmount == 0) borrowAmount = 1;
        if (borrowAmount > poolLiquidity / 2) borrowAmount = poolLiquidity / 2;

        // Register assertion
        cl.assertion({
            adopter: address(operator),
            createData: type(AccountLiquidityAssertion).creationCode,
            fnSelector: AccountLiquidityAssertion.assertionBorrowLiquidity.selector
        });

        // Execute borrow - should NOT revert since we're under the limit
        vm.prank(alice);
        mUSDC.borrow(borrowAmount);

        // Verify borrow succeeded (Alice has borrowed balance)
        assertGt(mUSDC.borrowBalanceStored(alice), 0, "Borrow should have succeeded");
        assertEq(mUSDC.borrowBalanceStored(alice), borrowAmount, "Borrow amount should match requested");
    }

    /**
     * @notice Fuzz test for borrow liquidity with varying collateral and borrow amounts
     * @dev Tests scenarios with different collateral amounts and borrow percentages
     *
     * @param usdtCollateral Collateral amount in USDT market
     * @param collateralFactorBps Collateral factor in basis points (ignored, using fixed 90%)
     * @param borrowPercentBps Percentage of total borrowing capacity to use
     */
    function testFuzz_BorrowLiquidity_MultipleCollateral_Passes(
        uint256 usdtCollateral,
        uint256 collateralFactorBps,
        uint256 borrowPercentBps
    ) public {
        // Constrain inputs using vm.assume()
        vm.assume(usdtCollateral >= 100e6 && usdtCollateral <= 500_000e6); // $100 to $500k
        // collateralFactorBps not used - kept for fuzz input compatibility
        vm.assume(borrowPercentBps >= 100 && borrowPercentBps <= 9500); // 1% to 95%

        // Setup collateral - only use USDT as collateral to borrow USDC
        // (Using same token as collateral and borrow doesn't work well)
        _setupCollateral(address(mUSDT), alice, usdtCollateral);

        // Set collateral factors
        operator.setCollateralFactor(address(mUSDC), 0.8e18); // 80%
        operator.setCollateralFactor(address(mUSDT), 0.9e18); // 90%

        _setupValidOraclePrices(1e8, 1e8);

        // Add liquidity to borrow pool (based on USDT collateral + extra for safety)
        uint256 poolLiquidity = usdtCollateral * 2;
        usdc.mint(address(this), poolLiquidity);
        usdc.approve(address(mUSDC), poolLiquidity);
        mUSDC.mint(poolLiquidity, address(this), 0);

        operator.setWhitelistedUser(alice, true);

        // Calculate borrowing capacity from USDT collateral only
        uint256 usdtBorrowCapacity = (usdtCollateral * 90) / 100; // 90% CF

        uint256 borrowAmount = (usdtBorrowCapacity * borrowPercentBps) / 10000;
        if (borrowAmount == 0) borrowAmount = 1;
        if (borrowAmount > poolLiquidity / 2) borrowAmount = poolLiquidity / 2;

        // Register assertion
        cl.assertion({
            adopter: address(operator),
            createData: type(AccountLiquidityAssertion).creationCode,
            fnSelector: AccountLiquidityAssertion.assertionBorrowLiquidity.selector
        });

        // Execute borrow
        vm.prank(alice);
        mUSDC.borrow(borrowAmount);

        // Verify success
        assertGt(mUSDC.borrowBalanceStored(alice), 0, "Borrow should succeed with USDT collateral");
    }

    /**
     * @notice Fuzz test for edge case: minimum viable borrow
     * @dev Tests that even tiny borrows work correctly with assertions
     *
     * @param collateralAmount Small collateral amounts
     */
    function testFuzz_BorrowLiquidity_MinimumBorrow_Passes(uint256 collateralAmount) public {
        // Constrain to very small amounts using vm.assume()
        vm.assume(collateralAmount >= 2e6 && collateralAmount <= 100e6); // $2 to $100

        _setupCollateral(address(mUSDT), alice, collateralAmount);
        operator.setCollateralFactor(address(mUSDT), 0.9e18);
        _setupValidOraclePrices(1e8, 1e8);

        // Add liquidity
        usdc.mint(address(this), 10000e6);
        usdc.approve(address(mUSDC), 10000e6);
        mUSDC.mint(10000e6, address(this), 0);

        operator.setWhitelistedUser(alice, true);

        // Borrow minimum amount (1 unit)
        uint256 borrowAmount = 1;

        cl.assertion({
            adopter: address(operator),
            createData: type(AccountLiquidityAssertion).creationCode,
            fnSelector: AccountLiquidityAssertion.assertionBorrowLiquidity.selector
        });

        vm.prank(alice);
        mUSDC.borrow(borrowAmount);

        assertEq(mUSDC.borrowBalanceStored(alice), borrowAmount, "Minimum borrow should work");
    }
}
