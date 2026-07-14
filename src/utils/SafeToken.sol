// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

interface IERC20Call {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface ISendCall {
    function send(address to, uint256 amount) external returns (bool);
}

/// @dev ERC-20 calls that accept either an encoded `true` or no return data.
/// Tokens such as mainnet USDT return no data from transfer operations.
library SafeToken {
    function safeTransfer(address token, address to, uint256 amount) internal returns (bool) {
        return _callOptionalReturn(token, abi.encodeCall(IERC20Call.transfer, (to, amount)));
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal returns (bool) {
        return _callOptionalReturn(token, abi.encodeCall(IERC20Call.transferFrom, (from, to, amount)));
    }

    function safeSend(address token, address to, uint256 amount) internal returns (bool) {
        return _callOptionalReturn(token, abi.encodeCall(ISendCall.send, (to, amount)));
    }

    function _callOptionalReturn(address token, bytes memory callData) private returns (bool) {
        if (token.code.length == 0) return false;

        (bool success, bytes memory returnData) = token.call(callData);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }

        if (returnData.length == 0) return true;
        if (returnData.length < 32) return false;

        uint256 returnValue;
        assembly ("memory-safe") {
            returnValue := mload(add(returnData, 0x20))
        }
        return returnValue == 1;
    }
}
