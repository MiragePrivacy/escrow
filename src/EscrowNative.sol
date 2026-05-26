// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import "./EscrowBase.sol";

contract EscrowNative is EscrowBase {
    // Custom errors
    error IncorrectETHAmount();
    error AlreadyFunded();
    error ZeroRewardAmount();
    error ZeroPaymentAmount();
    error InvalidTxProof();
    error InvalidReceiptProof();
    error TxFailed();
    error InvalidNativeTransfer();
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

    constructor(
        address _deployer,
        address _expectedRecipient,
        uint256 _expectedAmount,
        uint256 _currentRewardAmount,
        uint256 _currentPaymentAmount
    ) payable EscrowBase(_deployer, _expectedRecipient, _expectedAmount) {
        if (_currentRewardAmount > 0 && _currentPaymentAmount > 0) {
            if (msg.value != _currentRewardAmount + _currentPaymentAmount) revert IncorrectETHAmount();
            currentRewardAmount = _currentRewardAmount;
            originalRewardAmount = _currentRewardAmount;
            currentPaymentAmount = _currentPaymentAmount;
            funded = true;
        }
    }

    function fund(uint256 _currentRewardAmount, uint256 _currentPaymentAmount) external payable {
        if (msg.sender != deployerAddress) revert OnlyDeployer();
        if (funded) revert AlreadyFunded();
        if (_currentRewardAmount == 0) revert ZeroRewardAmount();
        if (_currentPaymentAmount == 0) revert ZeroPaymentAmount();
        if (msg.value != _currentRewardAmount + _currentPaymentAmount) revert IncorrectETHAmount();

        currentRewardAmount = _currentRewardAmount;
        originalRewardAmount = _currentRewardAmount;
        currentPaymentAmount = _currentPaymentAmount;
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
    function collect(NativeTransferProof calldata proof, uint256 targetBlockNumber) external {
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

        // Validate the native ETH transfer (to and value fields)
        if (!ReceiptValidator.validateNativeTransfer(proof.transactionRlp, expectedRecipient, expectedAmount)) {
            revert InvalidNativeTransfer();
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

    /// @notice Cancel and withdraw funds in a single transaction.
    /// Reverts if a node has already bonded.
    function cancelAndWithdraw() external {
        cancellationRequest = true;
        _validateWithdraw();
        _tryResetBondData();

        uint256 withdrawableAmount = _calculateWithdrawableAmount();

        _clearWithdrawState();

        if (withdrawableAmount == 0) revert NoWithdrawableFunds();

        (bool success,) = msg.sender.call{value: withdrawableAmount}("");
        if (!success) revert ETHTransferFailed();
    }
}
