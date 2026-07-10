// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import "./EscrowBase.sol";

contract EscrowNative is EscrowBase {
    // Custom errors
    error IncorrectETHAmount();
    error AlreadyFunded();
    error ZeroRewardAmount();
    error ZeroBondAmount();
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
        address _expectedRecipient,
        uint256 _expectedAmount,
        address _blindedSigner,
        uint256 _currentRewardAmount,
        uint256 _bondAmount
    ) payable EscrowBase(_expectedRecipient, _expectedAmount, _blindedSigner) {
        // The payment reimburses the proven delivery, so it is always the escrow's
        // expectedAmount; it is not an independent deploy parameter.
        if (_currentRewardAmount > 0) {
            if (_bondAmount == 0) revert ZeroBondAmount();
            if (msg.value != _currentRewardAmount + _expectedAmount + _bondAmount) revert IncorrectETHAmount();
            currentRewardAmount = _currentRewardAmount;
            originalRewardAmount = _currentRewardAmount;
            currentPaymentAmount = _expectedAmount;
            bondPot = _bondAmount;
            funded = true;
        }
    }

    function fund(uint256 _currentRewardAmount, uint256 _bondAmount) external payable {
        if (msg.sender != deployerAddress) revert OnlyDeployer();
        if (funded) revert AlreadyFunded();
        if (_currentRewardAmount == 0) revert ZeroRewardAmount();
        if (_bondAmount == 0) revert ZeroBondAmount();
        if (msg.value != _currentRewardAmount + expectedAmount + _bondAmount) revert IncorrectETHAmount();

        currentRewardAmount = _currentRewardAmount;
        originalRewardAmount = _currentRewardAmount;
        currentPaymentAmount = expectedAmount;
        bondPot = _bondAmount;
        funded = true;
    }

    // Validates a native ETH transfer by proving both transaction inclusion (for to/value)
    // and receipt inclusion (status == 1), then pays the bonded executor. Gated by the
    // OnlyBondedExecutor guard: the ECDH signature was spent at bond(), so the bonded EOA
    // is thereafter the only caller.
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

        // The unspent bond pot is returned together with the reward/payment.
        uint256 withdrawableAmount = _calculateWithdrawableAmount() + bondPot;

        _clearWithdrawState();
        bondPot = 0;

        if (withdrawableAmount == 0) revert NoWithdrawableFunds();

        (bool success,) = msg.sender.call{value: withdrawableAmount}("");
        if (!success) revert ETHTransferFailed();
    }
}
