// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IInterestRateModel} from "../../../src/interfaces/IInterestRateModel.sol";

/**
 * @title Mock Interest Rate Model with Excessive Rate Capability
 * @notice Mock implementation of IInterestRateModel that can return excessively high rates
 * @dev This mock allows tests to bypass rate caps to verify assertions catch violations
 */
contract MockInterestRateModelVulnerable is IInterestRateModel {
    uint256 public borrowRate = 1e16; // 1% per block (default reasonable)
    bool public returnExcessiveRate;

    // Excessive rate threshold: 0.03% per block (~1000% APY)
    uint256 public constant EXCESSIVE_RATE = 5e14; // Way above 3e14 threshold

    function isInterestRateModel() external pure override returns (bool) {
        return true;
    }

    function blocksPerYear() external pure override returns (uint256) {
        return 2628000; // ~10 blocks/min * 60 * 24 * 365
    }

    function multiplierPerBlock() external pure override returns (uint256) {
        return 2e15;
    }

    function baseRatePerBlock() external pure override returns (uint256) {
        return 1e15;
    }

    function jumpMultiplierPerBlock() external pure override returns (uint256) {
        return 5e15;
    }

    function kink() external pure override returns (uint256) {
        return 8e17; // 80% utilization
    }

    function name() external pure override returns (string memory) {
        return "MockInterestRateModelVulnerable";
    }

    function utilizationRate(uint256 cash, uint256 borrows, uint256 reserves)
        external
        pure
        override
        returns (uint256)
    {
        if (borrows == 0) return 0;
        return (borrows * 1e18) / (cash + borrows - reserves);
    }

    /**
     * @notice Returns borrow rate - can be excessive if flag is enabled
     * @dev When returnExcessiveRate is true, returns rate above the 3e14 cap
     */
    function getBorrowRate(uint256, uint256, uint256) external view override returns (uint256) {
        if (returnExcessiveRate) {
            return EXCESSIVE_RATE; // Returns rate > maxReasonableRate (3e14)
        }
        return borrowRate;
    }

    function getSupplyRate(uint256 cash, uint256 borrows, uint256 reserves, uint256 reserveFactorMantissa)
        external
        view
        override
        returns (uint256)
    {
        uint256 oneMinusReserveFactor = 1e18 - reserveFactorMantissa;
        uint256 borrowRateValue = returnExcessiveRate ? EXCESSIVE_RATE : borrowRate;
        uint256 rateToPool = (borrowRateValue * oneMinusReserveFactor) / 1e18;
        return (this.utilizationRate(cash, borrows, reserves) * rateToPool) / 1e18;
    }

    // ----- VULNERABILITY CONTROL -----
    function setReturnExcessiveRate(bool _return) external {
        returnExcessiveRate = _return;
    }

    function setBorrowRate(uint256 _rate) external {
        borrowRate = _rate;
    }
}
