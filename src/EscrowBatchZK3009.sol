// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {EscrowBatchZK} from "./EscrowBatchZK.sol";
import {ReceiveAuthorization} from "./utils/ReceiveAuthorization.sol";

/// @notice Batched escrow with one ERC-3009 token bucket. Other tokens use exact allowances and ETH uses msg.value.
contract EscrowBatchZK3009 is EscrowBatchZK {
    constructor(
        address rewardAsset_,
        Row[] memory rows,
        uint256 reward,
        uint256 advance,
        address[] memory signers,
        bytes32 domain,
        bytes32 requestId
    ) payable EscrowBatchZK(rewardAsset_, rows, reward, advance, signers, domain, requestId) {
        if (reward > 0) {
            address token = ReceiveAuthorization.read().token;
            if (token != rewardAsset_ && totalAssetPaymentAmount[token] == 0) {
                revert ReceiveAuthorization.InvalidFundingAuthorization();
            }
        }
    }

    function _pullDeploymentAsset(address asset, uint256 amount) internal override {
        ReceiveAuthorization.Authorization memory auth = ReceiveAuthorization.read();
        if (asset == auth.token) ReceiveAuthorization.receiveDeposit(auth, amount);
        else _pullApprovedAsset(asset, amount);
    }
}
