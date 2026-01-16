// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IOperatorDefender, IOperator} from "../../../src/interfaces/IOperator.sol";
import {IRoles} from "../../../src/interfaces/IRoles.sol";
import {IBlacklister} from "../../../src/interfaces/IBlacklister.sol";
import {ImToken, ImTokenOperationTypes} from "../../../src/interfaces/ImToken.sol";

/**
 * @title MockOperatorVulnerable
 * @notice Mock implementation of IOperatorDefender and IOperator that can simulate vulnerable behavior
 * @dev Uses flags to toggle between secure and vulnerable behavior for testing assertions
 */
contract MockOperatorVulnerable is IOperatorDefender, IOperator {
    // ============ Behavior Control Flags ============

    bool public bypassBorrowLiquidityCheck;
    bool public bypassLiquidationLiquidityCheck;
    bool public bypassRedeemLiquidityCheck;
    bool public bypassSeizeLiquidityCheck;

    // Outflow limiter vulnerability flags
    bool public allowOutflowExceedLimit;
    bool public allowCumulativeDecrease;
    bool public allowEarlyReset;
    bool public skipResetAfterExpiry;
    bool public mismatchOutflowTracking;

    // ============ State Management ============

    struct LiquidityState {
        uint256 liquidity;
        uint256 shortfall;
        bool isOverridden;
    }

    mapping(address => LiquidityState) public liquidityOverrides;
    mapping(address => bool) public whitelistedUsers;

    // Oracle address for price queries
    address public oracleAddress;

    // Outflow limiter state
    uint256 private _limitPerTimePeriod;
    uint256 private _outflowResetTimeWindow;
    uint256 private _cumulativeOutflowVolume;
    uint256 private _lastOutflowResetTimestamp;

    // ============ Configuration Functions ============

    function setBypassBorrowLiquidityCheck(bool _bypass) external {
        bypassBorrowLiquidityCheck = _bypass;
    }

    function setBypassLiquidationLiquidityCheck(bool _bypass) external {
        bypassLiquidationLiquidityCheck = _bypass;
    }

    function setBypassRedeemLiquidityCheck(bool _bypass) external {
        bypassRedeemLiquidityCheck = _bypass;
    }

    function setBypassSeizeLiquidityCheck(bool _bypass) external {
        bypassSeizeLiquidityCheck = _bypass;
    }

    function setLiquidityOverride(address account, uint256 liquidity, uint256 shortfall) external {
        liquidityOverrides[account] = LiquidityState({
            liquidity: liquidity,
            shortfall: shortfall,
            isOverridden: true
        });
    }

    function setWhitelistedUser(address user, bool whitelisted) external {
        whitelistedUsers[user] = whitelisted;
    }

    function setOracleAddress(address _oracle) external {
        oracleAddress = _oracle;
    }

    // ============ Outflow Limiter Configuration Functions ============

    function setAllowOutflowExceedLimit(bool _allow) external {
        allowOutflowExceedLimit = _allow;
    }

    function setAllowCumulativeDecrease(bool _allow) external {
        allowCumulativeDecrease = _allow;
    }

    function setAllowEarlyReset(bool _allow) external {
        allowEarlyReset = _allow;
    }

    function setSkipResetAfterExpiry(bool _skip) external {
        skipResetAfterExpiry = _skip;
    }

    function setMismatchOutflowTracking(bool _mismatch) external {
        mismatchOutflowTracking = _mismatch;
    }

    function setLimitPerTimePeriod(uint256 _limit) external {
        _limitPerTimePeriod = _limit;
    }

    function setOutflowResetTimeWindow(uint256 _window) external {
        _outflowResetTimeWindow = _window;
    }

    function setCumulativeOutflowVolume(uint256 _volume) external {
        _cumulativeOutflowVolume = _volume;
    }

    function setLastOutflowResetTimestamp(uint256 _timestamp) external {
        _lastOutflowResetTimestamp = _timestamp;
    }

    // ============ IOperatorDefender Implementation ============

    function beforeRebalancing(address mToken) external {
        // Minimal implementation
    }

    function beforeMTokenTransfer(address mToken, address src, address dst, uint256 transferTokens) external {
        // Minimal implementation
    }

    function beforeMTokenMint(address mToken, address minter, address receiver) external view {
        // Minimal implementation
    }

    function afterMTokenMint(address mToken) external view {
        // Minimal implementation
    }

    function beforeMTokenRedeem(address mToken, address redeemer, uint256 redeemTokens) external view {
        if (bypassRedeemLiquidityCheck) {
            // Vulnerable: Allow redeem without proper checks
            return;
        }
        // Normal secure behavior would check liquidity here
        // NOTE: Outflow limit checking is simulated via manual state changes in tests
        // NOTE: accrueInterest() is called by mToken.triggerRedeemHook() before calling this
    }

    function beforeMTokenBorrow(address mToken, address borrower, uint256 borrowAmount) external {
        // NOTE: accrueInterest is called by mToken BEFORE calling this hook
        // So assertions can't detect interest accrual changes during this call
        // Tests need batch contracts instead (see Phase 1B in SKIPPED_TESTS_PLAN.md)

        // Simulate outflow limit checking (like real operator)
        _checkOutflowVolumeLimit(mToken, borrowAmount);

        if (bypassBorrowLiquidityCheck) {
            // Vulnerable: Allow borrow without liquidity check
            return;
        }
        // Normal secure behavior would check liquidity here
    }

    function beforeMTokenRepay(address mToken, address borrower) external view {
        // Minimal implementation - repay is always safe
    }

    function beforeMTokenLiquidate(
        address mTokenBorrowed,
        address mTokenCollateral,
        address borrower,
        uint256 repayAmount
    ) external view {
        if (bypassLiquidationLiquidityCheck) {
            // Vulnerable: Allow liquidation without checking if borrower is underwater
            return;
        }
        // Normal secure behavior would verify borrower has shortfall > 0
        // NOTE: accrueInterest() is called by mToken.triggerLiquidationHook() before calling this
    }

    function beforeMTokenSeize(address mTokenCollateral, address mTokenBorrowed, address liquidator)
        external
        view
    {
        if (bypassSeizeLiquidityCheck) {
            // Vulnerable: Allow seize without parameter validation
            return;
        }
        // Normal secure behavior would validate parameters
    }

    function checkOutflowVolumeLimit(uint256 amount) external {
        // Call internal helper that handles outflow tracking with vulnerability flags
        _checkOutflowVolumeLimit(address(msg.sender), amount);
    }

    // ============ IOperator Implementation ============

    function userWhitelisted(address _user) external view returns (bool) {
        return whitelistedUsers[_user];
    }

    function limitPerTimePeriod() external view returns (uint256) {
        return _limitPerTimePeriod;
    }

    function cumulativeOutflowVolume() external view returns (uint256) {
        // Just return the actual state - vulnerabilities are simulated in _checkOutflowVolumeLimit
        return _cumulativeOutflowVolume;
    }

    function lastOutflowResetTimestamp() external view returns (uint256) {
        return _lastOutflowResetTimestamp;
    }

    function outflowResetTimeWindow() external view returns (uint256) {
        return _outflowResetTimeWindow;
    }

    // ========== INTERNAL HELPERS ==========

    /**
     * @dev Internal function to simulate outflow limit checking like real operator
     */
    function _checkOutflowVolumeLimit(address mToken, uint256 amount) internal {
        // Skip if limit is disabled (0 means no limit)
        if (_limitPerTimePeriod == 0) {
            return;
        }

        // Check if we need to reset the time window
        if (block.timestamp > _lastOutflowResetTimestamp + _outflowResetTimeWindow) {
            if (!skipResetAfterExpiry) {
                _cumulativeOutflowVolume = 0;
                _lastOutflowResetTimestamp = block.timestamp;
            }
        } else if (allowEarlyReset) {
            // Vulnerability: Reset early
            _cumulativeOutflowVolume = 0;
            _lastOutflowResetTimestamp = block.timestamp;
        }

        // Get USD value of amount (simplified for testing)
        // Tests pass in amounts already in the expected format
        uint256 amountInUSD = amount;

        // Check new cumulative limits
        if (!allowOutflowExceedLimit) {
            require(_cumulativeOutflowVolume + amountInUSD <= _limitPerTimePeriod, "Outflow limit exceeded");
        }

        // Update cumulative volume (unless vulnerability is enabled)
        if (allowCumulativeDecrease && _cumulativeOutflowVolume > 0) {
            // Vulnerability: Decrease cumulative
            _cumulativeOutflowVolume -= 1;
        } else if (mismatchOutflowTracking) {
            // Vulnerability: Track incorrect amount (half of actual)
            _cumulativeOutflowVolume += amountInUSD / 2;
        } else {
            // Normal behavior: Add to cumulative
            _cumulativeOutflowVolume += amountInUSD;
        }
    }

    // ========== INTERFACE IMPLEMENTATIONS ==========

    function isPaused(address mToken, ImTokenOperationTypes.OperationType _type) external pure returns (bool) {
        return false;
    }

    function rolesOperator() external view returns (IRoles) {
        return IRoles(address(0));
    }

    function blacklistOperator() external view returns (IBlacklister) {
        return IBlacklister(address(0));
    }

    function oracleOperator() external view returns (address) {
        return oracleAddress;
    }

    function closeFactorMantissa() external pure returns (uint256) {
        return 0.5e18; // 50%
    }

    function liquidationIncentiveMantissa(address market) external pure returns (uint256) {
        return 1.08e18; // 8% incentive
    }

    function isMarketListed(address market) external pure returns (bool) {
        return true;
    }

    function getAssetsIn(address _user) external pure returns (address[] memory mTokens) {
        return new address[](0);
    }

    function getAllMarkets() external pure returns (address[] memory mTokens) {
        return new address[](0);
    }

    function borrowCaps(address _mToken) external pure returns (uint256) {
        return type(uint256).max;
    }

    function supplyCaps(address _mToken) external pure returns (uint256) {
        return type(uint256).max;
    }

    function minBorrowSize(address _mToken) external pure returns (uint256) {
        return 0;
    }

    function checkMembership(address account, address mToken) external pure returns (bool) {
        return true;
    }

    /**
     * @notice Returns hypothetical account liquidity - can be overridden for testing
     * @dev This is the key function that assertions check - we control its output
     */
    function getHypotheticalAccountLiquidity(
        address account,
        address mTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    ) external view returns (uint256, uint256) {
        if (liquidityOverrides[account].isOverridden) {
            return (liquidityOverrides[account].liquidity, liquidityOverrides[account].shortfall);
        }
        // Default to safe values (healthy account)
        return (1000e18, 0);
    }

    function getUSDValueForAllMarkets() external pure returns (uint256) {
        return 0;
    }

    function isDeprecated(address mToken) external pure returns (bool) {
        return false;
    }

    function setPaused(address mToken, ImTokenOperationTypes.OperationType _type, bool state) external {
        // Minimal implementation
    }

    function enterMarkets(address[] calldata _mTokens) external {
        // Minimal implementation
    }

    function enterMarketsWithSender(address _account) external {
        // Minimal implementation
    }

    function exitMarket(address _mToken) external {
        // Minimal implementation
    }
}
