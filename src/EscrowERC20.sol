// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import "./EscrowBase.sol";

interface IERC20 {
    function send(address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract EscrowERC20 is EscrowBase {
    // Custom errors
    error ZeroAddress();
    error AlreadyFunded();
    error ZeroRewardAmount();
    error ZeroPaymentAmount();
    error TokenTransferFailed();
    error InvalidReceiptProof();
    error InvalidTransferEvent();
    error NoWithdrawableFunds();

    address public immutable tokenContract; // The tokens used in the escrow

    // Based on Nomad's proof structure
    struct ReceiptProof {
        bytes blockHeader; // RLP-encoded block header
        bytes receiptRlp; // RLP-encoded target receipt
        bytes proofNodes; // RLP-encoded array of MPT proof nodes
        bytes receiptPath; // RLP-encoded receipt index
        uint256 logIndex; // Index of target log in receipt
    }

    constructor(
        address _tokenContract,
        address _expectedRecipient,
        uint256 _expectedAmount,
        uint256 _currentRewardAmount,
        uint256 _currentPaymentAmount
    ) EscrowBase(_expectedRecipient, _expectedAmount) {
        if (_tokenContract == address(0)) revert ZeroAddress();
        tokenContract = _tokenContract;

        if (_currentRewardAmount > 0 && _currentPaymentAmount > 0) {
            fund(_currentRewardAmount, _currentPaymentAmount);
        }
    }

    // takes currentRewardAmount + currentPaymentAmount from the deployer's balance from the tokenContract.
    function fund(uint256 _currentRewardAmount, uint256 _currentPaymentAmount) public {
        if (msg.sender != deployerAddress) revert OnlyDeployer();
        if (funded) revert AlreadyFunded();
        if (_currentRewardAmount == 0) revert ZeroRewardAmount();
        if (_currentPaymentAmount == 0) revert ZeroPaymentAmount();

        currentRewardAmount = _currentRewardAmount;
        originalRewardAmount = _currentRewardAmount;
        currentPaymentAmount = _currentPaymentAmount;
        if (!IERC20(tokenContract).transferFrom(msg.sender, address(this), originalRewardAmount + currentPaymentAmount))
        {
            revert TokenTransferFailed();
        }
        funded = true;
    }

    // Validates a Transfer-event proof against a recent block hash, then enforces the
    // execution signature: the executionSig signer must equal the Transfer event's
    // `from` (the token sender). For a direct token.transfer() the event `from` is the
    // EOA that signed the transfer tx, so this binds the payout to the transfer EOA's
    // authorization without needing the tx RLP (which the receipt proof omits).
    function collect(
        ReceiptProof calldata proof,
        uint256 targetBlockNumber,
        address payoutAddress,
        bytes calldata executionSig
    ) external {
        if (collected) revert AlreadyCollected();

        _validateBlockHeader(proof.blockHeader, targetBlockNumber);

        // Extract receipts root and verify receipt inclusion
        bytes32 receiptsRoot = BlockHeaderParser.extractReceiptsRoot(proof.blockHeader);
        if (!MPTVerifier.verifyReceiptProof(proof.receiptRlp, proof.proofNodes, proof.receiptPath, receiptsRoot)) {
            revert InvalidReceiptProof();
        }

        // Validate the Transfer event
        if (!ReceiptValidator.validateTransferInReceipt(
                proof.receiptRlp, proof.logIndex, tokenContract, expectedRecipient, expectedAmount
            )) {
            revert InvalidTransferEvent();
        }

        // Bind the payout to the transfer sender's authorization (Transfer event `from`).
        _validateExecutionSig(
            payoutAddress, ReceiptValidator.extractTransferFrom(proof.receiptRlp, proof.logIndex), executionSig
        );

        _payout(payoutAddress);
    }

    function _payout(address payoutAddress) internal {
        uint256 payout = _calculatePayout();

        _clearPayoutState();

        bool success;
        if (block.chainid == 11155111) {
            // Sepolia testnet uses non-standard send
            success = IERC20(tokenContract).send(payoutAddress, payout);
        } else {
            success = IERC20(tokenContract).transfer(payoutAddress, payout);
        }
        if (!success) revert TokenTransferFailed();
    }

    /// @notice Cancel and withdraw funds in a single transaction. Deployer only,
    /// and only while the escrow has not been collected.
    function cancelAndWithdraw() external {
        if (collected) revert AlreadyCollected();
        _validateWithdraw();

        uint256 withdrawableAmount = _calculateWithdrawableAmount();

        _clearWithdrawState();

        if (withdrawableAmount == 0) revert NoWithdrawableFunds();

        if (!IERC20(tokenContract).transfer(msg.sender, withdrawableAmount)) {
            revert TokenTransferFailed();
        }
    }
}
