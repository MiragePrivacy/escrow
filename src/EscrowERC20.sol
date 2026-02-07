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
        require(_tokenContract != address(0), "Token contract cannot be zero address");
        tokenContract = _tokenContract;

        if (_currentRewardAmount > 0 && _currentPaymentAmount > 0) {
            fund(_currentRewardAmount, _currentPaymentAmount);
        }
    }

    // takes currentRewardAmount + currentPaymentAmount from the deployer's balance from the tokenContract.
    function fund(uint256 _currentRewardAmount, uint256 _currentPaymentAmount) public {
        require(msg.sender == deployerAddress, "Only callable by the deployer");
        require(!funded, "Contract already funded");
        require(_currentRewardAmount > 0, "Reward amount must be non-zero");
        require(_currentPaymentAmount > 0, "Payment amount must be non-zero");

        currentRewardAmount = _currentRewardAmount;
        originalRewardAmount = _currentRewardAmount;
        currentPaymentAmount = _currentPaymentAmount;
        require(
            IERC20(tokenContract).transferFrom(msg.sender, address(this), originalRewardAmount + currentPaymentAmount),
            "Token transfer failed"
        );
        funded = true;
    }

    // takes _bondAmount from the caller's balance of the tokenContract. The bondstatus is now bonded, execution deadline is current block timestamp + 5 minutes. Sets bondedexecutor to the caller. Will only accept a bond if the cancellationrequest is set to false, and no one is bonded.
    function bond(uint256 _bondAmount) public {
        // If deadline passed and someone is bonded, add their bond to reward
        _handleExpiredBond();

        _validateBondRequirements(_bondAmount);

        require(
            IERC20(tokenContract).transferFrom(msg.sender, address(this), _bondAmount),
            "Token transfer failed"
        );

        _setBondData(_bondAmount);
    }

    // Validates a given merkle proof against a recent block hash and checks the Transfer event's contents
    function collect(ReceiptProof calldata proof, uint256 targetBlockNumber) public {
        _validateBlockHeader(proof.blockHeader, targetBlockNumber);

        // Extract receipts root and verify receipt inclusion
        bytes32 receiptsRoot = BlockHeaderParser.extractReceiptsRoot(proof.blockHeader);
        require(
            MPTVerifier.verifyReceiptProof(proof.receiptRlp, proof.proofNodes, proof.receiptPath, receiptsRoot),
            "Invalid receipt MPT proof"
        );

        // Validate the Transfer event
        require(
            ReceiptValidator.validateTransferInReceipt(
                proof.receiptRlp, proof.logIndex, tokenContract, expectedRecipient, expectedAmount
            ),
            "Invalid Transfer event"
        );

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
        require(success, "Token transfer failed");
    }

    // allows deployer to withdraw all assets except the seized bonds (so the deployer can withdraw only and only what was deposited by deployer in the start function)
    // only if the contract is not currently bonded (or the execution deadline has passed)
    function withdraw() public {
        _validateWithdraw();
        _tryResetBondData();

        uint256 withdrawableAmount = _calculateWithdrawableAmount();

        _clearWithdrawState();

        require(withdrawableAmount > 0, "No withdrawable funds");

        require(
            IERC20(tokenContract).transfer(msg.sender, withdrawableAmount),
            "Token transfer failed"
        );
    }
}
