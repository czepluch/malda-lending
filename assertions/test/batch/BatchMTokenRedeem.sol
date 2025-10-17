// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ImErc20} from "../../../src/interfaces/ImErc20.sol";

/**
 * @title BatchMTokenRedeem
 * @notice Batch contract for testing mToken redeem operations
 * @dev Allows executing multiple redeem operations in a single transaction to test cumulative tracking
 */
contract BatchMTokenRedeem {
    /**
     * @notice Execute multiple small redeem operations in a single transaction
     * @dev This tests cumulative outflow tracking across multiple redeems
     * @param mToken The mToken being redeemed
     * @param redeemAmount The amount per individual redeem (in mToken units)
     * @param count Number of redeem operations to execute
     */
    function executeMultipleRedeems(
        ImErc20 mToken,
        uint256 redeemAmount,
        uint256 count
    ) external {
        for (uint256 i = 0; i < count; i++) {
            mToken.redeem(redeemAmount);
        }
    }
}
