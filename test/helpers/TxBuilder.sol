// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {ProofFixture} from "./ProofFixture.sol";

// Builds a signed EIP-1559 (type 0x02) native-transfer transaction from a controlled
// key, so recoverTxSender recovers a known address and the same key can sign the
// ExecutionAuth. Mirrors nomad's build_signed_eip1559_tx (chainId/nonce/.../accessList).
library TxBuilder {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // Returns the raw signed tx RLP (0x02 ++ rlp([...fields, yParity, r, s])).
    function signedNativeTransfer(uint256 privateKey, uint256 chainId, uint64 nonce, address to, uint256 value)
        internal
        pure
        returns (bytes memory)
    {
        // Signing payload fields: [chainId, nonce, maxPrio, maxFee, gas, to, value, data, accessList]
        bytes memory fields = bytes.concat(
            ProofFixture.rlpUint(chainId),
            ProofFixture.rlpUint(nonce),
            ProofFixture.rlpUint(1_000_000), // maxPriorityFeePerGas
            ProofFixture.rlpUint(2_000_000_000), // maxFeePerGas
            ProofFixture.rlpUint(21_000), // gasLimit
            _rlpAddress(to),
            ProofFixture.rlpUint(value),
            hex"80", // empty data
            hex"c0" // empty access list
        );
        bytes memory signingPayload = bytes.concat(hex"02", ProofFixture.rlpList(fields));
        bytes32 sigHash = keccak256(signingPayload);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, sigHash);
        uint8 yParity = v - 27;

        bytes memory signed = bytes.concat(fields, ProofFixture.rlpUint(yParity), _rlpScalar(r), _rlpScalar(s));
        return bytes.concat(hex"02", ProofFixture.rlpList(signed));
    }

    function _rlpAddress(address a) private pure returns (bytes memory) {
        return bytes.concat(hex"94", bytes20(a));
    }

    // RLP-encode a 32-byte scalar (r/s are full 32 bytes, high bit typically set).
    function _rlpScalar(bytes32 x) private pure returns (bytes memory) {
        return bytes.concat(hex"a0", x);
    }
}
