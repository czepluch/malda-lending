// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from "credible-std/Assertion.sol";
import {PhEvm} from "credible-std/PhEvm.sol";
import {ImErc20} from "../../src/interfaces/ImErc20.sol";
import {ImToken} from "../../src/interfaces/ImToken.sol";
import {IOperator} from "../../src/interfaces/IOperator.sol";
import {IOracleOperator} from "../../src/interfaces/IOracleOperator.sol";

/**
 * INVARIANTS PROTECTED:
 * 1. OUTFLOW VOLUME LIMITS: Cumulative redeem outflows must not exceed configured limits
 *    within a time window to prevent rapid capital extraction attacks.
 *
 * 2. TRACKING ACCURACY: Cumulative outflow volume must accurately reflect the sum of
 *    all redeem operations during the time window.
 */

/**
 * @title mToken Redeem Outflow Assertion
 * @notice Ensures redeem operations respect outflow volume limits
 * @dev This assertion monitors mToken redeem operations for outflow limit compliance
 * @dev Uses ImErc20 (mToken) as assertion adopter for proper state change tracking
 * @dev Pattern matches mTokenLiquidationAssertion - triggers on mToken operations
 */
contract mTokenRedeemOutflowAssertion is Assertion {
    /**
     * @notice Register triggers for redeem outflow monitoring
     * @dev Triggers on mToken redeem operation which calls outflow tracking internally
     */
    function triggers() external view override {
        registerCallTrigger(this.assertionRedeemOutflowLimit.selector, ImErc20.redeem.selector);
    }

    /**
     * @notice Assert that redeem operations respect outflow limits
     * @dev Verifies cumulative outflow does not exceed configured limit
     */
    function assertionRedeemOutflowLimit() external {
        ImToken mToken = ImToken(ph.getAssertionAdopter());
        IOperator operator = IOperator(mToken.operator());

        uint256 limitPerTimePeriod = operator.limitPerTimePeriod();
        if (limitPerTimePeriod == 0) {
            return;
        }

        PhEvm.CallInputs[] memory redeemCalls = ph.getCallInputs(address(mToken), ImErc20.redeem.selector);

        IOracleOperator oracle = IOracleOperator(operator.oracleOperator());

        for (uint256 i = 0; i < redeemCalls.length; i++) {
            uint256 redeemTokens = abi.decode(redeemCalls[i].input, (uint256));

            uint256 exchangeRate = mToken.exchangeRateStored();
            uint256 redeemAmount = (redeemTokens * exchangeRate) / 1e18;

            uint256 price = oracle.getUnderlyingPrice(address(mToken));
            require(price > 0, "Invalid oracle price for outflow calculation");

            // Match real operator calculation: (amount * price) / 1e10
            // This gives USD value in a format that works with the 18-decimal limit
            uint256 redeemAmountInUSD = (redeemAmount * price) / 1e10;

            ph.forkPreCall(redeemCalls[i].id);
            uint256 cumulativeBefore = operator.cumulativeOutflowVolume();

            ph.forkPostCall(redeemCalls[i].id);
            uint256 cumulativeAfter = operator.cumulativeOutflowVolume();

            require(cumulativeAfter <= limitPerTimePeriod, "Redeem would exceed outflow limit");

            uint256 expectedIncrease = redeemAmountInUSD;
            uint256 tolerancePercent = 10;
            uint256 actualIncrease = cumulativeAfter - cumulativeBefore;

            if (actualIncrease > 0) {
                uint256 lowerBound = (expectedIncrease * (100 - tolerancePercent)) / 100;
                uint256 upperBound = (expectedIncrease * (100 + tolerancePercent)) / 100;

                require(
                    actualIncrease >= lowerBound && actualIncrease <= upperBound,
                    "Outflow tracking mismatch for redeem"
                );
            }
        }
    }
}
