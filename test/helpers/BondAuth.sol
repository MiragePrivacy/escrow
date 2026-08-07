// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Test.sol";
import {EscrowBase} from "../../src/EscrowBase.sol";

// Shared helper for producing the enclave's ECDH-gate signature in tests.
//
// The escrow stores `blindedSigner` = address(P), the blinded enclave key. The enclave
// signs a BondAuth over the fresh bonding EOA with the matching scalar p; ecrecover of a
// valid signature yields blindedSigner. Here the "enclave" is a foundry wallet whose
// address is used as blindedSigner, so vm.sign reproduces that recovery.
library BondAuth {
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _BOND_TYPEHASH = keccak256("BondAuth(address bondingExecutor,uint256 gasAdvance)");
    bytes32 private constant _NAME_HASH = keccak256("MirageEscrow");
    bytes32 private constant _VERSION_HASH = keccak256("1");

    // Recomputes a zero-advance digest for existing prefunded-EOA tests.
    function digest(address escrow, address bondingExecutor) internal view returns (bytes32) {
        return digest(escrow, bondingExecutor, 0);
    }

    // Recomputes the EIP-712 BondAuth digest for the executor and exact advance.
    function digest(address escrow, address bondingExecutor, uint256 gasAdvance) internal view returns (bytes32) {
        bytes32 domainSeparator =
            keccak256(abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, escrow));
        bytes32 structHash = keccak256(abi.encode(_BOND_TYPEHASH, bondingExecutor, gasAdvance));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    // Signs the BondAuth digest with `enclaveKey`, yielding a signature that recovers to
    // vm.addr(enclaveKey) -- the escrow's blindedSigner.
    function sign(Vm vm, uint256 enclaveKey, address escrow, address bondingExecutor)
        internal
        view
        returns (bytes memory)
    {
        return sign(vm, enclaveKey, escrow, bondingExecutor, 0);
    }

    function sign(Vm vm, uint256 enclaveKey, address escrow, address bondingExecutor, uint256 gasAdvance)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(enclaveKey, digest(escrow, bondingExecutor, gasAdvance));
        return abi.encodePacked(r, s, v);
    }
}
