// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import "./EscrowERC20.sol";
import "./EscrowNative.sol";

contract EscrowFactory {
    event EscrowCreated(address indexed deployer, address escrow);

    function createEscrowERC20(
        uint256 nonce,
        address tokenContract,
        address expectedRecipient,
        uint256 expectedAmount
    ) external returns (address) {
        bytes32 salt = _salt(msg.sender, nonce);
        EscrowERC20 escrow = new EscrowERC20{salt: salt}(
            msg.sender,
            tokenContract,
            expectedRecipient,
            expectedAmount,
            0,
            0
        );
        emit EscrowCreated(msg.sender, address(escrow));
        return address(escrow);
    }

    function createEscrowNative(
        uint256 nonce,
        address expectedRecipient,
        uint256 expectedAmount
    ) external returns (address) {
        bytes32 salt = _salt(msg.sender, nonce);
        EscrowNative escrow = new EscrowNative{salt: salt}(
            msg.sender,
            expectedRecipient,
            expectedAmount,
            0,
            0
        );
        emit EscrowCreated(msg.sender, address(escrow));
        return address(escrow);
    }

    function predictEscrowERC20Address(
        address deployer,
        uint256 nonce,
        address tokenContract,
        address expectedRecipient,
        uint256 expectedAmount
    ) external view returns (address) {
        bytes32 salt = _salt(deployer, nonce);
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(
                    abi.encodePacked(
                        type(EscrowERC20).creationCode,
                        abi.encode(deployer, tokenContract, expectedRecipient, expectedAmount, uint256(0), uint256(0))
                    )
                )
            )
        );
        return address(uint160(uint256(hash)));
    }

    function predictEscrowNativeAddress(
        address deployer,
        uint256 nonce,
        address expectedRecipient,
        uint256 expectedAmount
    ) external view returns (address) {
        bytes32 salt = _salt(deployer, nonce);
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(
                    abi.encodePacked(
                        type(EscrowNative).creationCode,
                        abi.encode(deployer, expectedRecipient, expectedAmount, uint256(0), uint256(0))
                    )
                )
            )
        );
        return address(uint160(uint256(hash)));
    }

    function _salt(address deployer, uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(deployer, nonce));
    }
}
