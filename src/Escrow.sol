// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./BlockHeaderParser.sol";
import "./MPTVerifier.sol";
import "./ReceiptValidator.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract Escrow {
    // The following variables are set up in the contructor.
    address immutable deployerAddress;
    address immutable tokenContract; // The tokens used in the escrow
    // address immutable paymentTokenContract; // The tokens used in the payment to the recipient
    uint256 public currentRewardAmount;
    uint256 public currentPaymentAmount;
    uint256 public originalRewardAmount;

    // The following variables are for Merkle proof validation
    bytes32 public immutable taskId; // Unique identifier for this specific task
    uint256 public immutable maxBlockLookback; // Maximum blocks to look back for validation

    // The following variables are dynamically adjusted by the contract when a bond or cancellation request is submitted.
    address public bondedExecutor;
    uint256 public executionDeadline;
    uint256 public bondAmount;
    uint256 public totalBondsDeposited;
    bool public cancellationRequest;
    bool public funded; // marks if the contract ahs funds to pay out the executors or not (if it doesn't have funds, no executor should be accepted)

    // Based on Nomad's ProofBlob structure
    // https://github.com/MiragePrivacy/Nomad/blob/HEAD/crates/ethereum/src/proof.rs#L24-L35
    struct ReceiptProof {
        bytes blockHeader;      // RLP-encoded block header
        bytes receiptRlp;       // RLP-encoded target receipt  
        bytes proofNodes;       // Serialized MPT proof nodes
        bytes receiptPath;      // RLP-encoded receipt index
        uint256 logIndex;       // Index of target log in receipt
    }

    constructor(address _tokenContract, bytes32 _taskId) {
        tokenContract = _tokenContract;
        deployerAddress = msg.sender;
        taskId = _taskId;
        maxBlockLookback = 256;
    }

    // takes currentRewardAmount + currentPaymentAmount from the deployer's balance from the tokenContract.
    function fund(uint256 _currentRewardAmount, uint256 _currentPaymentAmount) public {
        require(msg.sender == deployerAddress, "Only callable by the deployer");
        require(!funded, "Contract already funded");

        currentRewardAmount = _currentRewardAmount;
        originalRewardAmount = _currentRewardAmount;
        currentPaymentAmount = _currentPaymentAmount;
        IERC20(tokenContract).transferFrom(msg.sender, address(this), originalRewardAmount + currentPaymentAmount);
        funded = true;
    }

    // takes _bondAmount from the caller's balance of the tokenContract. The bondstatus is now bonded, execution deadline is current block timestam + 5 minutes. Sets bondedexecutor to the caller. Will only accept a bond if the cancellationrequest is set to false, and no one is bonded.
    function bond(uint256 _bondAmount) public {
        require(funded, "Contract not funded");
        require(!cancellationRequest, "Cancellation requested");
        require(_bondAmount >= currentRewardAmount / 2, "Bond must be at least half of reward amount");

        // If deadline passed and someone is bonded, add their bond to reward
        if (executionDeadline > 0 && block.timestamp > executionDeadline) {
            currentRewardAmount += bondAmount;
            totalBondsDeposited += bondAmount;
            tryResetBondData();
        }

        IERC20(tokenContract).transferFrom(msg.sender, address(this), _bondAmount);

        bondedExecutor = msg.sender;
        executionDeadline = block.timestamp + 5 minutes;
        bondAmount = _bondAmount;
    }

    // only deployer can call this. will set the cancellation request to true.
    // when the cancellation is requested, the bonded executor may still finish their job and collect, but no new executor is accepted after the current bonded one.
    function requestCancellation() public {
        require(msg.sender == deployerAddress, "Only callable by the deployer");
        cancellationRequest = true;
    }

    // sets cancellation request to false, if the caller is deployer.
    // starts accepting new executors
    function resume() public {
        require(msg.sender == deployerAddress, "Only callable by the deployer");
        cancellationRequest = false;
    }

    // Now validates a given merkle proof against a recent block hash and checks the event's contents against the signal's metadata
    function collect(
        ReceiptProof calldata proof,
        uint256 targetBlockNumber
    ) public {
        require(funded, "Contract not funded");
        require(msg.sender == bondedExecutor && is_bonded(), "Only bonded executor can collect");
        
        // Validate target block is recent and accessible
        require(targetBlockNumber <= block.number, "Target block is in the future");
        require(block.number - targetBlockNumber <= maxBlockLookback, "Target block too old");
        
        // Get the target block hash
        bytes32 targetBlockHash = blockhash(targetBlockNumber);
        require(targetBlockHash != bytes32(0), "Unable to retrieve block hash");
        
        // Validate block header hash matches target block
        require(keccak256(proof.blockHeader) == targetBlockHash, "Block header hash mismatch");
        
        // Also verify the block number in header matches target
        require(
            BlockHeaderParser.extractBlockNumber(proof.blockHeader) == targetBlockNumber, 
            "Header block number mismatch"
        );
        
        // Extract receipts root from block header
        bytes32 receiptsRoot = BlockHeaderParser.extractReceiptsRoot(proof.blockHeader);
        
        // Verify receipt proof against receipts root using MPT verification
        require(
            MPTVerifier.verifyReceiptProof(
                proof.receiptRlp,
                proof.proofNodes,
                proof.receiptPath, 
                receiptsRoot
            ),
            "Invalid receipt MPT proof"
        );
        
        // Extract and validate the task completion log
        require(
            ReceiptValidator.validateTaskCompletionInReceipt(
                proof.receiptRlp, 
                proof.logIndex,
                taskId,
                bondedExecutor
            ),
            "Invalid task completion log"
        );

        uint256 payout = bondAmount + currentRewardAmount + currentPaymentAmount;
        address executor = bondedExecutor;

        bondedExecutor = address(0);
        bondAmount = 0;
        executionDeadline = 0;
        funded = false;
        currentPaymentAmount = 0;
        currentRewardAmount = 0;
        IERC20(tokenContract).transfer(executor, payout);
    }

    // checks if contract is currently bonded by verifying deadline
    function is_bonded() public view returns (bool) {
        return executionDeadline > 0 && block.timestamp <= executionDeadline;
    }

    // allows deployer to withdraw all assets except the seized bonds (so the deployer can withdraw only and only what was deposited by deployer in the start function)
    // only if the contract is not currently bonded (or the execution deadline has passed)
    function withdraw() public {
        require(funded, "Contract not funded");
        require(msg.sender == deployerAddress, "Only callable by the deployer");
        require(funded == true, "The contract was not funded or has been drained already");
        tryResetBondData();

        uint256 withdrawableAmount = currentPaymentAmount + originalRewardAmount;

        funded = false;
        currentPaymentAmount = 0;
        currentRewardAmount = 0;

        require(withdrawableAmount > 0, "No withdrawable funds");

        IERC20(tokenContract).transfer(msg.sender, withdrawableAmount);
    }

    function tryResetBondData() internal {
        require(!is_bonded(), "Cannot reset while bond is active");

        bondedExecutor = address(0);
        bondAmount = 0;
        executionDeadline = 0;
    }
}
