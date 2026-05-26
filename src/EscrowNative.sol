// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import "./EscrowBase.sol";

contract EscrowNative is EscrowBase {
    // Custom errors
    error AlreadyFunded();
    error ZeroAmount();
    error InvalidTxProof();
    error InvalidReceiptProof();
    error TxFailed();
    error ETHTransferFailed();
    error NoWithdrawableFunds();

    // Proof structure for native ETH transfers (requires both tx and receipt)
    struct NativeTransferProof {
        bytes blockHeader; // RLP-encoded block header
        bytes transactionRlp; // RLP-encoded target transaction (for to/value validation)
        bytes txProofNodes; // MPT proof nodes for transaction inclusion
        bytes receiptRlp; // RLP-encoded receipt (for status validation)
        bytes receiptProofNodes; // MPT proof nodes for receipt inclusion
        bytes path; // RLP-encoded index (same for both tx and receipt)
    }

    constructor(bytes32 _commitment) payable EscrowBase() {
        if (msg.value > 0) {
            deposit = msg.value;
            commitment = _commitment;
            funded = true;
        }
    }

    function fund(bytes32 _commitment) external payable {
        if (msg.sender != deployerAddress) revert OnlyDeployer();
        if (funded) revert AlreadyFunded();
        if (msg.value == 0) revert ZeroAmount();

        deposit = msg.value;
        commitment = _commitment;
        funded = true;
    }

    function bond() external payable {
        // If deadline passed and someone is bonded, add their bond to reward
        _handleExpiredBond();

        _validateBondRequirements(msg.value);

        _setBondData(msg.value);
    }

    // Validates native ETH transfer by proving both transaction inclusion (for to/value)
    // and receipt inclusion (for status == 1, i.e., successful execution)
    function collect(NativeTransferProof calldata proof, uint256 targetBlockNumber, bytes32 salt) external {
        _validateBlockHeader(proof.blockHeader, targetBlockNumber);

        // Verify transaction inclusion in transactions trie
        bytes32 transactionsRoot = BlockHeaderParser.extractTransactionsRoot(proof.blockHeader);
        if (!MPTVerifier.verifyReceiptProof(proof.transactionRlp, proof.txProofNodes, proof.path, transactionsRoot)) {
            revert InvalidTxProof();
        }

        // Verify receipt inclusion in receipts trie
        bytes32 receiptsRoot = BlockHeaderParser.extractReceiptsRoot(proof.blockHeader);
        if (!MPTVerifier.verifyReceiptProof(proof.receiptRlp, proof.receiptProofNodes, proof.path, receiptsRoot)) {
            revert InvalidReceiptProof();
        }

        // Validate transaction succeeded (status == 1)
        if (!ReceiptValidator.validateReceiptStatus(proof.receiptRlp)) revert TxFailed();

        // Extract transfer fields from the proven transaction
        (address recipient, uint256 amount) = ReceiptValidator.extractNativeTransfer(proof.transactionRlp);

        // Verify commitment: H(recipient, amount, salt)
        if (keccak256(abi.encodePacked(recipient, amount, salt)) != commitment) {
            revert CommitmentMismatch();
        }

        _payout();
    }

    function _payout() internal {
        uint256 payout = _calculatePayout();
        address executor = bondedExecutor;

        _clearPayoutState();

        (bool success,) = executor.call{value: payout}("");
        if (!success) revert ETHTransferFailed();
    }

    /// @notice Cancel and withdraw all funds in a single transaction.
    /// Reverts if a bond is still active.
    function cancelAndWithdraw() external {
        cancellationRequest = true;
        _validateWithdraw();
        _handleExpiredBond();
        _tryResetBondData();

        uint256 withdrawableAmount = deposit;
        if (withdrawableAmount == 0) revert NoWithdrawableFunds();

        _clearWithdrawState();

        (bool success,) = msg.sender.call{value: withdrawableAmount}("");
        if (!success) revert ETHTransferFailed();
    }
}
