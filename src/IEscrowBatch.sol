// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

interface IEscrowBatch {
    struct BatchTransfer {
        address recipient;
        uint256 amount;
    }

    struct BatchReceiptProof {
        bytes blockHeader;
        bytes receiptRlp;
        bytes proofNodes;
        bytes receiptPath;
        uint256 targetBlockNumber;
    }

    function collect(BatchReceiptProof calldata proof, uint256[] calldata logIndexes) external;
}
