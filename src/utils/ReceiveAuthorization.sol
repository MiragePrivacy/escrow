// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IERC3009 {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

/// @dev An authorization is appended to the API's existing canonical constructor arguments.
/// Only the ERC-3009 variants read this trailer, and only during construction.
/// The token holder, receiving escrow and exact deposit are derived from the normal funding path.
library ReceiveAuthorization {
    struct Authorization {
        address token;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    error InvalidFundingAuthorization();

    function read() internal pure returns (Authorization memory auth) {
        bytes memory trailer = new bytes(7 * 32);
        assembly ("memory-safe") {
            codecopy(add(trailer, 32), sub(codesize(), 224), 224)
        }
        auth = abi.decode(trailer, (Authorization));
        if (auth.token == address(0) || auth.validBefore <= auth.validAfter || (auth.v != 27 && auth.v != 28)) {
            revert InvalidFundingAuthorization();
        }
    }

    function receiveDeposit(Authorization memory auth, uint256 amount) internal {
        uint256 beforeBalance = IERC20(auth.token).balanceOf(address(this));
        IERC3009(auth.token)
            .receiveWithAuthorization(
                msg.sender, address(this), amount, auth.validAfter, auth.validBefore, auth.nonce, auth.v, auth.r, auth.s
            );
        if (IERC20(auth.token).balanceOf(address(this)) != beforeBalance + amount) {
            revert InvalidFundingAuthorization();
        }
    }
}
