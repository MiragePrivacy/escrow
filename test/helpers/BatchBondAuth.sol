// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Test.sol";

// Shared helper for producing the enclave's ECDH-gate signature in batch escrow tests.
//
// EscrowBatch stores `blindedSigner` = address(P), the blinded enclave key. The enclave
// signs a BatchBondAuth over the bidding EOA and the claimed rows with the matching scalar
// p; ecrecover of a valid signature yields blindedSigner. Here the "enclave" is a foundry
// wallet whose address is used as blindedSigner, so vm.sign reproduces that recovery.
library BatchBondAuth {
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _BOND_TYPEHASH =
        keccak256("BatchBondAuth(address bondingExecutor,uint256[] transferIndexes)");
    bytes32 private constant _NAME_HASH = keccak256("MirageEscrow");
    bytes32 private constant _VERSION_HASH = keccak256("1");

    // Recomputes the EIP-712 BatchBondAuth digest for `bondingExecutor` + `transferIndexes`
    // bound to `escrow`.
    function digest(address escrow, address bondingExecutor, uint256[] memory transferIndexes)
        internal
        view
        returns (bytes32)
    {
        bytes32 domainSeparator =
            keccak256(abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, escrow));
        bytes32 structHash =
            keccak256(abi.encode(_BOND_TYPEHASH, bondingExecutor, keccak256(abi.encodePacked(transferIndexes))));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    // Signs the BatchBondAuth digest with `enclaveKey`, yielding a signature that recovers to
    // vm.addr(enclaveKey) -- the escrow's blindedSigner.
    function sign(Vm vm, uint256 enclaveKey, address escrow, address bondingExecutor, uint256[] memory transferIndexes)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(enclaveKey, digest(escrow, bondingExecutor, transferIndexes));
        return abi.encodePacked(r, s, v);
    }
}
