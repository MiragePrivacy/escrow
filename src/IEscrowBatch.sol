// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

interface IEscrowBatch {
    enum AssetType {
        ERC20,
        NATIVE
    }

    struct BatchTransfer {
        AssetType assetType;
        address asset;
        address recipient;
        uint256 amount;
        uint256 rewardWeight;
    }

    struct BatchReceiptProof {
        bytes blockHeader;
        bytes receiptRlp;
        bytes proofNodes;
        bytes receiptPath;
        uint256 targetBlockNumber;
    }

    struct BatchProof {
        AssetType proofType;
        BatchReceiptProof receiptProof;
        bytes transactionRlp;
        bytes txProofNodes;
        uint256[] transferIndexes;
        uint256[] logIndexes;
    }

    function bond(uint256[] calldata transferIndexes, uint256 bondAmount) external;

    function collect(BatchProof[] calldata proofs) external;
}
