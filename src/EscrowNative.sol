// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import "./EscrowBase.sol";

contract EscrowNative is EscrowBase {
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
        uint256 _currentRewardAmount,
        uint256 _currentPaymentAmount
    ) payable EscrowBase(_expectedRecipient, _expectedAmount) {
        if (_currentRewardAmount > 0 && _currentPaymentAmount > 0) {
            require(msg.value == _currentRewardAmount + _currentPaymentAmount, "Incorrect ETH amount");
            currentRewardAmount = _currentRewardAmount;
            originalRewardAmount = _currentRewardAmount;
            currentPaymentAmount = _currentPaymentAmount;
            funded = true;
        }
    }

    function fund(uint256 _currentRewardAmount, uint256 _currentPaymentAmount) public payable {
        require(msg.sender == deployerAddress, "Only callable by the deployer");
        require(!funded, "Contract already funded");
        require(_currentRewardAmount > 0, "Reward amount must be non-zero");
        require(_currentPaymentAmount > 0, "Payment amount must be non-zero");
        require(msg.value == _currentRewardAmount + _currentPaymentAmount, "Incorrect ETH amount");

        currentRewardAmount = _currentRewardAmount;
        originalRewardAmount = _currentRewardAmount;
        currentPaymentAmount = _currentPaymentAmount;
        funded = true;
    }

    function bond() public payable {
        // If deadline passed and someone is bonded, add their bond to reward
        _handleExpiredBond();

        _validateBondRequirements(msg.value);

        _setBondData(msg.value);
    }

    // Validates native ETH transfer by proving both transaction inclusion (for to/value)
    // and receipt inclusion (for status == 1, i.e., successful execution)
    function collect(NativeTransferProof calldata proof, uint256 targetBlockNumber) public {
        _validateBlockHeader(proof.blockHeader, targetBlockNumber);

        // Verify transaction inclusion in transactions trie
        bytes32 transactionsRoot = BlockHeaderParser.extractTransactionsRoot(proof.blockHeader);
        require(
            MPTVerifier.verifyReceiptProof(proof.transactionRlp, proof.txProofNodes, proof.path, transactionsRoot),
            "Invalid transaction MPT proof"
        );

        // Verify receipt inclusion in receipts trie
        bytes32 receiptsRoot = BlockHeaderParser.extractReceiptsRoot(proof.blockHeader);
        require(
            MPTVerifier.verifyReceiptProof(proof.receiptRlp, proof.receiptProofNodes, proof.path, receiptsRoot),
            "Invalid receipt MPT proof"
        );

        // Validate transaction succeeded (status == 1)
        require(ReceiptValidator.validateReceiptStatus(proof.receiptRlp), "Transaction failed (status != 1)");

        // Validate the native ETH transfer (to and value fields)
        require(
            ReceiptValidator.validateNativeTransfer(proof.transactionRlp, expectedRecipient, expectedAmount),
            "Invalid native transfer"
        );

        _payout();
    }

    function _payout() internal {
        uint256 payout = _calculatePayout();
        address executor = bondedExecutor;

        _clearPayoutState();

        (bool success,) = executor.call{value: payout}("");
        require(success, "ETH transfer failed");
    }

    // allows deployer to withdraw all assets except the seized bonds (so the deployer can withdraw only and only what was deposited by deployer in the start function)
    // only if the contract is not currently bonded (or the execution deadline has passed)
    function withdraw() public {
        _validateWithdraw();
        _tryResetBondData();

        uint256 withdrawableAmount = _calculateWithdrawableAmount();

        _clearWithdrawState();

        require(withdrawableAmount > 0, "No withdrawable funds");

        (bool success,) = msg.sender.call{value: withdrawableAmount}("");
        require(success, "ETH transfer failed");
    }
}
