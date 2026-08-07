// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./EscrowBase.sol";

contract EscrowERC20 is EscrowBase {
    using SafeERC20 for IERC20;

    // Custom errors
    error ZeroAddress();
    error AlreadyFunded();
    error ZeroRewardAmount();
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
        address _blindedSigner,
        uint256 _currentRewardAmount,
        uint256 _maxGasAdvance
    ) EscrowBase(_expectedRecipient, _expectedAmount, _blindedSigner, _maxGasAdvance) {
        if (_tokenContract == address(0)) revert ZeroAddress();
        tokenContract = _tokenContract;

        if (_currentRewardAmount > 0) {
            fund(_currentRewardAmount);
        }
    }

    // Takes currentRewardAmount + expectedAmount from the deployer's token balance. The
    // sender deposits no ETH execution-gas surcharge; Nomad provisions executor gas.
    function fund(uint256 _currentRewardAmount) public {
        if (msg.sender != deployerAddress) revert OnlyDeployer();
        if (funded) revert AlreadyFunded();
        if (_currentRewardAmount == 0) revert ZeroRewardAmount();
        _validateGasAdvanceBudget(_currentRewardAmount);

        currentRewardAmount = _currentRewardAmount;
        originalRewardAmount = _currentRewardAmount;
        currentPaymentAmount = expectedAmount;
        gasAdvanceClaimed = false;
        IERC20(tokenContract).safeTransferFrom(msg.sender, address(this), originalRewardAmount + currentPaymentAmount);
        funded = true;
    }

    function _releaseGasAdvance(address executor, uint256 gasAdvance) internal override {
        IERC20(tokenContract).safeTransfer(executor, gasAdvance);
    }

    // Validates a Transfer-event proof against a recent block hash and checks the Transfer
    // event's contents, then pays the bonded executor. Gated by the OnlyBondedExecutor guard:
    // the ECDH signature was spent at bond(), so the bonded EOA is thereafter the only caller.
    function collect(ReceiptProof calldata proof, uint256 targetBlockNumber) external {
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

        _payout();
    }

    function _payout() internal {
        uint256 payout = _calculatePayout();
        address executor = bondedExecutor;

        _clearPayoutState();

        IERC20(tokenContract).safeTransfer(executor, payout);
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

        IERC20(tokenContract).safeTransfer(msg.sender, withdrawableAmount);
    }
}
