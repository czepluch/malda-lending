// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ImToken, IRoles} from "../../../src/interfaces/ImToken.sol";
import {IOperatorDefender} from "../../../src/interfaces/IOperator.sol";
import {MockOracleVulnerable} from "./MockOracleVulnerable.sol";

/**
 * @title Mock mToken with Vulnerable Interest Accrual
 * @notice Mock implementation of ImToken that can simulate vulnerable interest accrual behavior
 * @dev This mock allows tests to bypass proper interest accrual checks to verify assertions catch violations
 */
contract MockMTokenVulnerable is ImToken {
    // ----- VULNERABILITY FLAGS -----
    bool public allowIndexDecrease;
    bool public allowTotalBorrowsDecrease;
    bool public allowExcessiveRate;
    bool public allowIndexStagnation; // Index doesn't increase despite positive borrows

    // ----- PRICE MANIPULATION FLAGS FOR LIQUIDATION TESTING -----
    bool public manipulatePricesDuringLiquidation;
    address public priceManipulationOracle;
    uint256 public manipulatedBorrowedPrice;
    uint256 public manipulatedCollateralPrice;
    bool public alreadyManipulatedOnce; // Track if manipulation already happened
    bool public manipulateOnSecondCallOnly; // If true, skip first call and manipulate on second

    // ----- STORAGE (from ImToken interface) -----
    address public override operator;
    address public override underlying;
    address public override interestRateModel;
    address payable public override admin;
    address payable public override pendingAdmin;

    uint256 public override borrowIndex = 1e18;
    uint256 public override totalBorrows = 0;
    uint256 public override totalReserves = 100e6;
    uint256 public override accrualBlockTimestamp;
    uint256 public override reserveFactorMantissa = 0.1e18; // 10%

    string public override name = "Mock mToken";
    string public override symbol = "mMOCK";
    uint8 public override decimals = 6;

    mapping(address => uint256) public borrowBalances;
    mapping(address => uint256) public collateralBalances;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // ----- CONSTRUCTOR -----
    constructor(address _operator, address _underlying, address _interestModel) {
        operator = _operator;
        underlying = _underlying;
        interestRateModel = _interestModel;
        accrualBlockTimestamp = block.timestamp;
        admin = payable(msg.sender);
    }

    // ----- VULNERABILITY CONTROL -----
    function setAllowIndexDecrease(bool _allow) external {
        allowIndexDecrease = _allow;
    }

    function setAllowTotalBorrowsDecrease(bool _allow) external {
        allowTotalBorrowsDecrease = _allow;
    }

    function setAllowExcessiveRate(bool _allow) external {
        allowExcessiveRate = _allow;
    }

    function setAllowIndexStagnation(bool _allow) external {
        allowIndexStagnation = _allow;
    }

    /**
     * @notice Configure price manipulation during liquidation for testing
     * @dev When enabled, liquidate() will change oracle prices mid-execution
     * @param _enable Whether to enable price manipulation
     * @param _oracle The oracle contract to manipulate
     * @param _borrowedPrice The price to set for the borrowed token (this mToken)
     * @param _collateralPrice The price to set for the collateral token
     * @param _onSecondCallOnly If true, skip first call and only manipulate on second+ calls
     */
    function setPriceManipulationDuringLiquidation(
        bool _enable,
        address _oracle,
        uint256 _borrowedPrice,
        uint256 _collateralPrice,
        bool _onSecondCallOnly
    ) external {
        manipulatePricesDuringLiquidation = _enable;
        priceManipulationOracle = _oracle;
        manipulatedBorrowedPrice = _borrowedPrice;
        manipulatedCollateralPrice = _collateralPrice;
        manipulateOnSecondCallOnly = _onSecondCallOnly;
        // Reset the flag when configuration changes
        alreadyManipulatedOnce = false;
    }

    // ----- INTEREST ACCRUAL SIMULATION -----
    /**
     * @notice Simulate proper interest accrual
     * @dev Increases borrow index and total borrows when time advances
     */
    function simulateInterestAccrual(bool increaseIndex, bool increaseBorrows) external {
        if (block.timestamp > accrualBlockTimestamp) {
            if (increaseIndex) {
                borrowIndex = (borrowIndex * 10001) / 10000; // 0.01% increase
            }
            if (increaseBorrows) {
                totalBorrows = (totalBorrows * 10001) / 10000; // 0.01% increase
                totalReserves = (totalReserves * 10001) / 10000; // 0.01% increase
            }
            accrualBlockTimestamp = block.timestamp;
        }
    }

    /**
     * @notice Simulate vulnerable interest accrual behavior
     * @dev ONLY callable when vulnerability flags are enabled
     */
    function simulateVulnerableAccrual(bool decreaseIndex, bool decreaseBorrows) external {
        require(allowIndexDecrease || allowTotalBorrowsDecrease, "Vulnerability flags not enabled");

        if (block.timestamp > accrualBlockTimestamp) {
            if (decreaseIndex && allowIndexDecrease) {
                borrowIndex = (borrowIndex * 9999) / 10000; // 0.01% decrease - INVALID!
            }
            if (decreaseBorrows && allowTotalBorrowsDecrease) {
                totalBorrows = (totalBorrows * 9999) / 10000; // 0.01% decrease - INVALID!
            }
            accrualBlockTimestamp = block.timestamp;
        }
    }

    // ----- TEST HELPERS -----
    function setBorrowBalance(address user, uint256 balance) external {
        borrowBalances[user] = balance;
    }

    function setCollateralBalance(address user, uint256 balance) external {
        collateralBalances[user] = balance;
    }

    function setTotalBorrows(uint256 _totalBorrows) external {
        totalBorrows = _totalBorrows;
    }

    function setBorrowIndex(uint256 _borrowIndex) external {
        borrowIndex = _borrowIndex;
    }

    function setAccrualBlockTimestamp(uint256 _timestamp) external {
        accrualBlockTimestamp = _timestamp;
    }

    function advanceTime(uint256 seconds_) external {
        accrualBlockTimestamp = block.timestamp + seconds_;
    }

    // ----- HOOK TRIGGERS -----
    /**
     * @notice Trigger borrow hook
     * @dev Operator will call accrueInterest() DURING its beforeMTokenBorrow() execution
     * @dev This allows assertions to detect interest accrual violations between forkPreCall and forkPostCall
     */
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

    function triggerRedeemHook(address redeemer, uint256 redeemTokens) external {
        IOperatorDefender(operator).beforeMTokenRedeem(address(this), redeemer, redeemTokens);
    }

    /**
     * @notice Mock implementation of ImErc20.borrow() for testing
     * @dev Simulates accrual BEFORE calling operator hook (matches real mToken behavior)
     * @param borrowAmount The amount to borrow
     */
    function borrow(uint256 borrowAmount) external {
        _simulateAccrual();

        IOperatorDefender(operator).beforeMTokenBorrow(address(this), msg.sender, borrowAmount);

        borrowBalances[msg.sender] += borrowAmount;
        if (!allowTotalBorrowsDecrease) {
            totalBorrows += borrowAmount;
        }
    }

    /**
     * @notice Mock implementation of ImErc20.redeem() for testing
     * @dev Simulates accrual BEFORE calling operator hook (matches real mToken behavior)
     * @dev Also simulates outflow tracking that happens in real protocol
     * @param redeemTokens The amount of mTokens to redeem
     */
    function redeem(uint256 redeemTokens) external {
        _simulateAccrual();

        IOperatorDefender(operator).beforeMTokenRedeem(address(this), msg.sender, redeemTokens);

        // Simulate outflow tracking (real mToken calls checkOutflowVolumeLimit after the view hook)
        // Convert mToken amount to underlying amount using exchange rate (1:1 in this mock)
        uint256 exchangeRate = 1e18; // Mock uses 1:1 exchange rate
        uint256 underlyingAmount = (redeemTokens * exchangeRate) / 1e18;
        _simulateOutflowTracking(underlyingAmount);
    }

    /**
     * @notice Mock implementation of ImErc20.liquidate() for testing
     * @dev This is a state-changing function that triggers the operator hook
     * @dev The borrowed mToken is this contract (address(this))
     * @dev Can optionally manipulate prices mid-execution if configured for testing
     * @param borrower The borrower being liquidated
     * @param repayAmount The amount to repay
     * @param mTokenCollateral The collateral mToken to seize
     */
    function liquidate(address borrower, uint256 repayAmount, address mTokenCollateral) external {
        _simulateAccrual();

        IOperatorDefender(operator).beforeMTokenLiquidate(
            address(this),
            mTokenCollateral,
            borrower,
            repayAmount
        );

        // If price manipulation is enabled, change prices AT THE END of execution
        // This simulates an intra-transaction price manipulation attack
        // forkPreCall will see old prices, forkPostCall will see new prices
        if (manipulatePricesDuringLiquidation && priceManipulationOracle != address(0)) {
            if (manipulateOnSecondCallOnly) {
                // For multi-call tests: Only manipulate if we haven't already manipulated once
                // This allows testing scenarios where prices change on the SECOND call, not the first
                if (!alreadyManipulatedOnce) {
                    // First time - just mark it and don't manipulate
                    alreadyManipulatedOnce = true;
                } else {
                    // Second time - now manipulate the prices
                    MockOracleVulnerable(priceManipulationOracle).setPriceOverride(
                        address(this), // borrowed token (this mToken)
                        manipulatedBorrowedPrice
                    );
                    MockOracleVulnerable(priceManipulationOracle).setPriceOverride(
                        mTokenCollateral,
                        manipulatedCollateralPrice
                    );
                }
            } else {
                // For single-call tests: manipulate immediately (every call)
                MockOracleVulnerable(priceManipulationOracle).setPriceOverride(
                    address(this), // borrowed token (this mToken)
                    manipulatedBorrowedPrice
                );
                MockOracleVulnerable(priceManipulationOracle).setPriceOverride(
                    mTokenCollateral,
                    manipulatedCollateralPrice
                );
            }
        }
    }

    /**
     * @notice Internal function to simulate outflow tracking
     * @dev Calls the operator's checkOutflowVolumeLimit to update cumulative state
     * @dev This matches how real mToken calls operator after view hook completes
     * @dev Converts amount to USD value using real operator's formula: (amount * price) / 1e10
     */
    function _simulateOutflowTracking(uint256 amount) internal {
        // Real operator uses: (amount * oraclePrice) / 1e10
        // For 6-decimal tokens like USDC with price 1e18:
        // (200e6 * 1e18) / 1e10 = 200e14
        uint256 amountInUSD = (amount * 1e18) / 1e10; // Mock price is 1e18
        IOperatorDefender(operator).checkOutflowVolumeLimit(amountInUSD);
    }

    /**
     * @notice Internal function to simulate accrual based on vulnerability flags
     * @dev Called automatically by hook triggers to simulate state changes during transaction
     */
    function _simulateAccrual() internal {
        // Only accrue if time has advanced
        if (block.timestamp <= accrualBlockTimestamp) {
            return;
        }

        // Apply vulnerable or normal accrual based on flags
        if (allowIndexDecrease) {
            borrowIndex = (borrowIndex * 9999) / 10000; // 0.01% decrease - INVALID!
        } else if (allowIndexStagnation) {
            // Index stays the same despite time passing - INVALID when borrows > 0!
            // Do nothing to borrowIndex
        } else if (totalBorrows > 0) {
            // Normal case: index should increase
            borrowIndex = (borrowIndex * 10001) / 10000; // 0.01% increase
        }

        if (allowTotalBorrowsDecrease) {
            totalBorrows = (totalBorrows * 9999) / 10000; // 0.01% decrease - INVALID!
        } else if (totalBorrows > 0) {
            // Normal case: total borrows increase with interest
            totalBorrows = (totalBorrows * 10001) / 10000; // 0.01% increase
        }

        // Update accrual timestamp
        accrualBlockTimestamp = block.timestamp;
    }

    // ----- ImToken INTERFACE IMPLEMENTATION -----
    function borrowBalanceStored(address user) external view override returns (uint256) {
        return borrowBalances[user];
    }

    function getCash() external pure override returns (uint256) {
        return 10000e6; // 10,000 units cash
    }

    function getAccountSnapshot(address user)
        external
        view
        override
        returns (uint256 tokenBalance, uint256 borrowBalance, uint256 exchangeRate)
    {
        return (collateralBalances[user], borrowBalances[user], 1e18); // 1:1 exchange rate
    }

    function rolesOperator() external pure override returns (IRoles) {
        return IRoles(address(0));
    }

    function borrowRatePerBlock() external pure override returns (uint256) {
        return 1e14; // 0.01% per block
    }

    function supplyRatePerBlock() external pure override returns (uint256) {
        return 5e13; // 0.005% per block
    }

    function totalBorrowsCurrent() external view override returns (uint256) {
        return totalBorrows;
    }

    function borrowBalanceCurrent(address account) external view override returns (uint256) {
        return borrowBalances[account];
    }

    function exchangeRateCurrent() external pure override returns (uint256) {
        return 1e18;
    }

    function exchangeRateStored() external pure override returns (uint256) {
        return 1e18;
    }

    function accrueInterest() external override {
        // Simulate interest accrual when called by operator
        _simulateAccrual();
    }

    function seize(address, address, uint256) external pure override {
        revert("Not implemented");
    }

    function reduceReserves(uint256) external pure override {
        revert("Not implemented");
    }

    // ----- ERC20-like FUNCTIONS -----
    function totalSupply() external pure override returns (uint256) {
        return 0;
    }

    function totalUnderlying() external pure override returns (uint256) {
        return 0;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address, uint256) external pure override returns (bool) {
        revert("Not implemented");
    }

    function transferFrom(address, address, uint256) external pure override returns (bool) {
        revert("Not implemented");
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function balanceOfUnderlying(address) external pure override returns (uint256) {
        return 0;
    }
}
