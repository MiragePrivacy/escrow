// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {EscrowBase} from "../src/EscrowBase.sol";

// Concrete EscrowBase subclass exposing the internal EIP-712 helpers for testing,
// without adding test-only surface to the production flavors.
contract BaseHarness is EscrowBase {
    constructor(address recipient, uint256 amount) EscrowBase(recipient, amount) {}

    function hashExecutionAuth(address payoutAddress) external view returns (bytes32) {
        return _hashExecutionAuth(payoutAddress);
    }

    function recoverExecutionSigner(address payoutAddress, bytes calldata sig) external view returns (address) {
        return _recoverExecutionSigner(payoutAddress, sig);
    }
}

// Verifies the EIP-712 ExecutionAuth digest matches the canonical definition shared
// with the off-chain signer (nomad crates/types/src/contracts.rs): domain
// "MirageEscrow"/"1"/chainId/escrow, struct
// ExecutionAuth(address expectedRecipient,uint256 expectedAmount,address payoutAddress).
contract ExecutionAuthTest is Test {
    BaseHarness escrow;
    address recipient = address(0xBEEF);
    uint256 amount = 1_000_000_000_000_000;

    function setUp() public {
        escrow = new BaseHarness(recipient, amount);
    }

    function testDomainSeparatorMatchesCanonical() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("MirageEscrow"),
                keccak256("1"),
                block.chainid,
                address(escrow)
            )
        );
        assertEq(escrow.domainSeparator(), expected);
    }

    function testExecutionAuthDigestMatchesCanonical() public view {
        address payout = address(0xCAFE);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("ExecutionAuth(address expectedRecipient,uint256 expectedAmount,address payoutAddress)"),
                recipient,
                amount,
                payout
            )
        );
        bytes32 expected = keccak256(abi.encodePacked("\x19\x01", escrow.domainSeparator(), structHash));
        assertEq(escrow.hashExecutionAuth(payout), expected);
    }

    // A signature from a known wallet over the digest must recover to that wallet.
    function testRecoverRoundTrip() public {
        Vm.Wallet memory w = vm.createWallet("transferEOA");
        address payout = address(0xCAFE);
        bytes32 digest = escrow.hashExecutionAuth(payout);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(w.privateKey, digest);
        assertEq(escrow.recoverExecutionSigner(payout, abi.encodePacked(r, s, v)), w.addr);
    }
}
