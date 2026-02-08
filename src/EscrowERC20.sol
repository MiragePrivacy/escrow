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
        if (!IERC20(tokenContract).transferFrom(msg.sender, address(this), originalRewardAmount + currentPaymentAmount)) {
            revert TokenTransferFailed();
        }
        funded = true;
    }

    // takes _bondAmount from the caller's balance of the tokenContract. The bondstatus is now bonded, execution deadline is current block timestamp + 5 minutes. Sets bondedexecutor to the caller. Will only accept a bond if the cancellationrequest is set to false, and no one is bonded.
    function bond(uint256 _bondAmount) public {
        // If deadline passed and someone is bonded, add their bond to reward
        _handleExpiredBond();

        _validateBondRequirements(_bondAmount);

        if (!IERC20(tokenContract).transferFrom(msg.sender, address(this), _bondAmount)) {
            revert TokenTransferFailed();
        }

        _setBondData(_bondAmount);
    }

    // Validates a given merkle proof against a recent block hash and checks the Transfer event's contents
    function collect(ReceiptProof calldata proof, uint256 targetBlockNumber) public {
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

        bool success;
        if (block.chainid == 11155111) {
            // Sepolia testnet uses non-standard send
            success = IERC20(tokenContract).send(executor, payout);
        } else {
            success = IERC20(tokenContract).transfer(executor, payout);
        }
        if (!success) revert TokenTransferFailed();
    }

    // allows deployer to withdraw all assets except the seized bonds (so the deployer can withdraw only and only what was deposited by deployer in the start function)
    // only if the contract is not currently bonded (or the execution deadline has passed)
    function withdraw() public {
        _validateWithdraw();
        _tryResetBondData();

        uint256 withdrawableAmount = _calculateWithdrawableAmount();

        _clearWithdrawState();

        if (withdrawableAmount == 0) revert NoWithdrawableFunds();

        if (!IERC20(tokenContract).transfer(msg.sender, withdrawableAmount)) {
            revert TokenTransferFailed();
        }
    }
}
