// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {EscrowBatch} from "../src/EscrowBatch.sol";
import {EscrowBatchZK} from "../src/EscrowBatchZK.sol";
import {BatchBondAuth} from "./helpers/BatchBondAuth.sol";
import {BatchMockERC20} from "./EscrowBatch.t.sol";

contract EscrowBatchZKTest is Test {
    uint256 constant SIGNER_KEY = 123;
    EscrowBatchZK escrow;
    EscrowBatchZK.RowProof rowProof;
    address collector;
    address asset;
    uint256 amount;
    uint64 start;

    function _setup(string memory path, bool nativeAsset) internal {
        string memory json = vm.readFile(path);
        vm.chainId(vm.parseJsonUint(json, ".statement.chainId"));
        address target = vm.parseJsonAddress(json, ".statement.escrow");
        collector = vm.parseJsonAddress(json, ".statement.bondedCollector");
        asset = vm.parseJsonAddress(json, ".statement.rowPayoutAsset");
        amount = vm.parseJsonUint(json, ".statement.rowPayoutAmount");
        start = uint64(vm.parseJsonUint(json, ".statement.bondStartBlock"));
        rowProof.rowIndex = uint32(vm.parseJsonUint(json, ".statement.rowIndex"));
        rowProof.witnessBlockNumber = uint64(vm.parseJsonUint(json, ".statement.witnessBlockNumber"));
        uint256[] memory proof = vm.parseJsonUintArray(json, ".proof");
        uint256[] memory signals = vm.parseJsonUintArray(json, ".publicSignals");
        for (uint256 i; i < 8; ++i) {
            rowProof.proof[i] = proof[i];
        }
        rowProof.signals = [signals[0], signals[1]];
        EscrowBatchZK.Row[] memory rows = new EscrowBatchZK.Row[](rowProof.rowIndex + 1);
        for (uint256 i; i < rows.length; ++i) {
            rows[i] = EscrowBatchZK.Row(asset, amount, 1, bytes32(uint256(1)));
        }
        if (!nativeAsset) {
            string memory nativeJson = vm.readFile("test/fixtures/native_proof.json");
            rows[0] = EscrowBatchZK.Row(
                address(0), amount, 1, vm.parseJsonBytes32(nativeJson, ".statement.intentCommitment")
            );
        }
        rows[rowProof.rowIndex].intentCommitment = vm.parseJsonBytes32(json, ".statement.intentCommitment");
        address[] memory signers = new address[](2);
        signers[0] = vm.addr(SIGNER_KEY);
        signers[1] = vm.addr(SIGNER_KEY + 1);
        deployCodeTo(
            "EscrowBatchZK.sol:EscrowBatchZK",
            abi.encode(
                asset,
                rows,
                0,
                0,
                signers,
                vm.parseJsonBytes32(json, ".statement.instanceDomain"),
                vm.parseJsonBytes32(json, ".statement.requestId")
            ),
            target
        );
        escrow = EscrowBatchZK(target);
        if (nativeAsset) {
            vm.deal(address(this), amount * (rows.length + 1));
            escrow.fund{value: amount * (rows.length + 1)}(amount);
        } else {
            BatchMockERC20 token = new BatchMockERC20();
            vm.etch(asset, address(token).code);
            BatchMockERC20(asset).mint(address(this), amount * (rows.length + 1));
            BatchMockERC20(asset).approve(target, type(uint256).max);
            vm.deal(address(this), amount);
            escrow.fund{value: amount}(amount);
        }
        vm.roll(start);
        uint256[] memory indexes = new uint256[](rows.length);
        for (uint256 i; i < rows.length; ++i) {
            indexes[i] = i;
        }
        bytes memory signature = BatchBondAuth.sign(vm, SIGNER_KEY, target, collector, indexes);
        vm.prank(collector);
        escrow.bid(indexes, 0, signature);
        vm.roll(rowProof.witnessBlockNumber + 1);
        vm.setBlockhash(rowProof.witnessBlockNumber, vm.parseJsonBytes32(json, ".statement.witnessBlockHash"));
    }

    function _collect() internal {
        EscrowBatchZK.RowProof[] memory proofs = new EscrowBatchZK.RowProof[](1);
        proofs[0] = rowProof;
        vm.prank(collector);
        escrow.collectRows(proofs);
    }

    function testRealNonzeroRowProofSettlesPartially() public {
        _setup("test/fixtures/batch_row_proof.json", false);
        uint256[2] memory signals = escrow.rowStatementSignals(1, rowProof.witnessBlockNumber);
        assertEq(signals[0], rowProof.signals[0]);
        assertEq(signals[1], rowProof.signals[1]);
        _collect();
        assertTrue(escrow.transferCompleted(1));
        assertFalse(escrow.transferCompleted(0));
        assertTrue(escrow.funded());
        assertEq(escrow.transferBidder(0), collector);
        assertEq(BatchMockERC20(asset).balanceOf(collector), amount + amount / 2);
        vm.expectRevert(EscrowBatch.TransferStateConflict.selector);
        _collect();
    }

    function testRealNativeProofSettlesFinalRow() public {
        _setup("test/fixtures/native_proof.json", true);
        uint256 before = collector.balance;
        _collect();
        assertFalse(escrow.funded());
        assertEq(collector.balance - before, amount * 2);
    }

    function testRealMixedProofsSettleAtomically() public {
        _setup("test/fixtures/batch_row_proof.json", false);
        string memory json = vm.readFile("test/fixtures/native_proof.json");
        EscrowBatchZK.RowProof[] memory proofs = new EscrowBatchZK.RowProof[](2);
        proofs[1] = rowProof;
        proofs[0].rowIndex = 0;
        proofs[0].witnessBlockNumber = uint64(vm.parseJsonUint(json, ".statement.witnessBlockNumber"));
        uint256[] memory points = vm.parseJsonUintArray(json, ".proof");
        uint256[] memory signals = vm.parseJsonUintArray(json, ".publicSignals");
        for (uint256 i; i < 8; ++i) {
            proofs[0].proof[i] = points[i];
        }
        proofs[0].signals = [signals[0], signals[1]];
        vm.roll(proofs[0].witnessBlockNumber + 1);
        vm.setBlockhash(proofs[0].witnessBlockNumber, vm.parseJsonBytes32(json, ".statement.witnessBlockHash"));
        uint256 before = collector.balance;
        vm.prank(collector);
        escrow.collectRows(proofs);
        assertFalse(escrow.funded());
        assertTrue(escrow.transferCompleted(0));
        assertTrue(escrow.transferCompleted(1));
        assertEq(collector.balance - before, amount);
        assertEq(BatchMockERC20(asset).balanceOf(collector), amount * 2);
    }

    function testWrongRowRejected() public {
        _setup("test/fixtures/batch_row_proof.json", false);
        rowProof.rowIndex = 0;
        vm.expectRevert(EscrowBatchZK.StatementMismatch.selector);
        _collect();
        assertFalse(escrow.transferCompleted(0));
    }

    function testBadProofLeavesRowsUnsettled() public {
        _setup("test/fixtures/batch_row_proof.json", false);
        rowProof.proof[0] ^= 1;
        vm.expectRevert();
        _collect();
        assertFalse(escrow.transferCompleted(1));
    }

    function testDuplicateRowRevertsAtomically() public {
        _setup("test/fixtures/batch_row_proof.json", false);
        EscrowBatchZK.RowProof[] memory proofs = new EscrowBatchZK.RowProof[](2);
        proofs[0] = rowProof;
        proofs[1] = rowProof;
        vm.prank(collector);
        vm.expectRevert(EscrowBatch.DuplicateProofItem.selector);
        escrow.collectRows(proofs);
        assertFalse(escrow.transferCompleted(1));
    }

    function testPayoutFailureAccruesClaim() public {
        _setup("test/fixtures/batch_row_proof.json", false);
        BatchMockERC20(asset).setTransfersDisabled(true);
        _collect();
        assertTrue(escrow.transferCompleted(1));
        assertEq(escrow.claimable(collector, asset), amount + amount / 2);
    }

    function testExpiredLeaseCannotCollect() public {
        _setup("test/fixtures/batch_row_proof.json", false);
        vm.roll(start + 76);
        vm.expectRevert(EscrowBatchZK.BondBlockDeadlineExpired.selector);
        _collect();
    }

    function testPlaintextCollectDisabled() public {
        _setup("test/fixtures/batch_row_proof.json", false);
        EscrowBatch.BatchProof[] memory proofs = new EscrowBatch.BatchProof[](0);
        vm.expectRevert(EscrowBatchZK.PlaintextProofDisabled.selector);
        escrow.collect(proofs);
    }
}
