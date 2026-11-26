// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {EscrowERC20} from "./EscrowERC20.sol";
import {ReceiveAuthorization} from "./utils/ReceiveAuthorization.sol";

/// @notice Single-token escrow funded by one payee-bound ERC-3009 authorization at deployment.
contract EscrowERC203009 is EscrowERC20 {
    constructor(
        address asset,
        uint256 amount,
        bytes32 commitment,
        bytes32 domain,
        bytes32 requestId,
        address signer,
        uint256 reward,
        uint256 advance
    ) EscrowERC20(asset, amount, commitment, domain, requestId, signer, reward, advance) {}

    function _pullDeploymentAsset(address asset, uint256 amount) internal override {
        ReceiveAuthorization.Authorization memory auth = ReceiveAuthorization.read();
        if (auth.token != asset) revert ReceiveAuthorization.InvalidFundingAuthorization();
        ReceiveAuthorization.receiveDeposit(auth, amount);
    }
}
