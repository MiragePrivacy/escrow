// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import "./BlockHeaderParser.sol";
import "./MPTVerifier.sol";
import "./ReceiptValidator.sol";

interface IERC20 {
    function send(address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract Escrow {
    // The following variables are set up in the constructor.
    address immutable deployerAddress;
    address immutable tokenContract; // The tokens used in the escrow
    // address immutable paymentTokenContract; // The tokens used in the payment to the recipient
    uint256 public currentRewardAmount;
    uint256 public currentPaymentAmount;
    uint256 public originalRewardAmount;

    // The following variables are for Merkle proof validation
    address public immutable expectedRecipient; // The intended recipient of the transfer
    uint256 public immutable expectedAmount; // The expected transfer amount
    uint256 public immutable maxBlockLookback; // Maximum blocks to look back for validation

    // The following variables are dynamically adjusted by the contract when a bond or cancellation request is submitted.
    address public bondedExecutor;
    uint256 public executionDeadline;
    uint256 public bondAmount;
    uint256 public totalBondsDeposited;
    bool public cancellationRequest;
    bool public funded; // marks if the contract has funds to pay out the executors or not (if it doesn't have funds, no executor should be accepted)

    // Based on Nomad's proof structure
    struct ReceiptProof {
        bytes blockHeader; // RLP-encoded block header
        bytes receiptRlp; // RLP-encoded target receipt
        bytes proofNodes; // RLP-encoded array of MPT proof nodes
        bytes receiptPath; // RLP-encoded receipt index
        uint256 logIndex; // Index of target log in receipt
    }

    // Proof structure for native ETH transfers
    struct TransactionProof {
        bytes blockHeader; // RLP-encoded block header
        bytes transactionRlp; // RLP-encoded target transaction
        bytes proofNodes; // RLP-encoded array of MPT proof nodes
        bytes transactionPath; // RLP-encoded transaction index
    }

    constructor(
        address _tokenContract,
        address _expectedRecipient,
        uint256 _expectedAmount,
        uint256 _currentRewardAmount,
        uint256 _currentPaymentAmount
    ) {
        tokenContract = _tokenContract;
        expectedRecipient = _expectedRecipient;
        expectedAmount = _expectedAmount;
        deployerAddress = msg.sender;
        maxBlockLookback = 256;

        if (_currentRewardAmount > 0 && _currentPaymentAmount > 0) {
            fund(_currentRewardAmount, _currentPaymentAmount);
        }
    }

    // takes currentRewardAmount + currentPaymentAmount from the deployer's balance from the tokenContract.
    function fund(uint256 _currentRewardAmount, uint256 _currentPaymentAmount) public {
        require(msg.sender == deployerAddress, "Only callable by the deployer");
        require(!funded, "Contract already funded");
        require(tokenContract != address(0), "Use fundNative for native ETH");
        require(_currentRewardAmount > 0, "Reward amount must be non-zero");
        require(_currentPaymentAmount > 0, "Payment amount must be non-zero");

        currentRewardAmount = _currentRewardAmount;
        originalRewardAmount = _currentRewardAmount;
        currentPaymentAmount = _currentPaymentAmount;
        IERC20(tokenContract).transferFrom(msg.sender, address(this), originalRewardAmount + currentPaymentAmount);
        funded = true;
    }

    function fundNative(uint256 _currentRewardAmount, uint256 _currentPaymentAmount) public payable {
        require(msg.sender == deployerAddress, "Only callable by the deployer");
        require(!funded, "Contract already funded");
        require(tokenContract == address(0), "Use fund for ERC20");
        require(_currentRewardAmount > 0, "Reward amount must be non-zero");
        require(_currentPaymentAmount > 0, "Payment amount must be non-zero");
        require(msg.value == _currentRewardAmount + _currentPaymentAmount, "Incorrect ETH amount");

        currentRewardAmount = _currentRewardAmount;
        originalRewardAmount = _currentRewardAmount;
        currentPaymentAmount = _currentPaymentAmount;
        funded = true;
    }

    // takes _bondAmount from the caller's balance of the tokenContract. The bondstatus is now bonded, execution deadline is current block timestamp + 5 minutes. Sets bondedexecutor to the caller. Will only accept a bond if the cancellationrequest is set to false, and no one is bonded.
    function bond(uint256 _bondAmount) public {
        require(funded, "Contract not funded");
        require(tokenContract != address(0), "Use bondNative for native ETH");
        require(!cancellationRequest, "Cancellation requested");

        // If deadline passed and someone is bonded, add their bond to reward
        if (executionDeadline > 0 && block.timestamp > executionDeadline) {
            currentRewardAmount += bondAmount;
            totalBondsDeposited += bondAmount;
            tryResetBondData();
        }

        // Prevent double bonding - no one can bond while another executor is actively bonded
        require(!is_bonded(), "Another executor is already bonded");
        require(_bondAmount >= currentRewardAmount / 2, "Bond must be at least half of reward amount");

        IERC20(tokenContract).transferFrom(msg.sender, address(this), _bondAmount);

        bondedExecutor = msg.sender;
        executionDeadline = block.timestamp + 5 minutes;
        bondAmount = _bondAmount;
    }

    function bondNative() public payable {
        require(funded, "Contract not funded");
        require(tokenContract == address(0), "Use bond for ERC20");
        require(!cancellationRequest, "Cancellation requested");

        if (executionDeadline > 0 && block.timestamp > executionDeadline) {
            currentRewardAmount += bondAmount;
            totalBondsDeposited += bondAmount;
            tryResetBondData();
        }

        require(!is_bonded(), "Another executor is already bonded");
        require(msg.value >= currentRewardAmount / 2, "Bond must be at least half of reward amount");

        bondedExecutor = msg.sender;
        executionDeadline = block.timestamp + 5 minutes;
        bondAmount = msg.value;
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

    // Validates a given merkle proof against a recent block hash and checks the Transfer event's contents
    function collect(ReceiptProof calldata proof, uint256 targetBlockNumber) public {
        require(tokenContract != address(0), "Use collectNative for native ETH");
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

    // Validates a given merkle proof for native ETH transfer by checking transaction fields directly
    function collectNative(TransactionProof calldata proof, uint256 targetBlockNumber) public {
        require(tokenContract == address(0), "Use collect for ERC20");
        _validateBlockHeader(proof.blockHeader, targetBlockNumber);

        // Extract transactions root and verify transaction inclusion
        bytes32 transactionsRoot = BlockHeaderParser.extractTransactionsRoot(proof.blockHeader);
        require(
            MPTVerifier.verifyReceiptProof(proof.transactionRlp, proof.proofNodes, proof.transactionPath, transactionsRoot),
            "Invalid transaction MPT proof"
        );

        // Validate the native ETH transfer (to and value fields)
        require(
            ReceiptValidator.validateNativeTransfer(proof.transactionRlp, expectedRecipient, expectedAmount),
            "Invalid native transfer"
        );

        _payoutNative();
    }

    function _validateBlockHeader(bytes calldata blockHeader, uint256 targetBlockNumber) internal view {
        require(funded, "Contract not funded");
        require(msg.sender == bondedExecutor && is_bonded(), "Only bonded executor can collect");
        require(targetBlockNumber <= block.number, "Target block is in the future");
        require(block.number - targetBlockNumber <= maxBlockLookback, "Target block too old");

        bytes32 targetBlockHash = blockhash(targetBlockNumber);
        require(targetBlockHash != bytes32(0), "Unable to retrieve block hash");
        require(keccak256(blockHeader) == targetBlockHash, "Block header hash mismatch");
        require(
            BlockHeaderParser.extractBlockNumber(blockHeader) == targetBlockNumber, "Header block number mismatch"
        );
    }

    function _payout() internal {
        uint256 payout = bondAmount + currentRewardAmount + currentPaymentAmount;
        address executor = bondedExecutor;

        bondedExecutor = address(0);
        bondAmount = 0;
        executionDeadline = 0;
        funded = false;
        currentPaymentAmount = 0;
        currentRewardAmount = 0;

        if (block.chainid == 1 || block.chainid == 42429) {
            IERC20(tokenContract).transfer(executor, payout);
        } else {
            IERC20(tokenContract).send(executor, payout);
        }
    }

    function _payoutNative() internal {
        uint256 payout = bondAmount + currentRewardAmount + currentPaymentAmount;
        address executor = bondedExecutor;

        bondedExecutor = address(0);
        bondAmount = 0;
        executionDeadline = 0;
        funded = false;
        currentPaymentAmount = 0;
        currentRewardAmount = 0;

        (bool success,) = executor.call{value: payout}("");
        require(success, "ETH transfer failed");
    }

    // checks if contract is currently bonded by verifying deadline
    function is_bonded() public view returns (bool) {
        return executionDeadline > 0 && block.timestamp <= executionDeadline;
    }

    // allows deployer to withdraw all assets except the seized bonds (so the deployer can withdraw only and only what was deposited by deployer in the start function)
    // only if the contract is not currently bonded (or the execution deadline has passed)
    function withdraw() public {
        require(funded, "Contract not funded");
        require(tokenContract != address(0), "Use withdrawNative for native ETH");
        require(msg.sender == deployerAddress, "Only callable by the deployer");
        tryResetBondData();

        uint256 withdrawableAmount = currentPaymentAmount + originalRewardAmount;

        funded = false;
        currentPaymentAmount = 0;
        currentRewardAmount = 0;

        require(withdrawableAmount > 0, "No withdrawable funds");

        IERC20(tokenContract).transfer(msg.sender, withdrawableAmount);
    }

    function withdrawNative() public {
        require(funded, "Contract not funded");
        require(tokenContract == address(0), "Use withdraw for ERC20");
        require(msg.sender == deployerAddress, "Only callable by the deployer");
        tryResetBondData();

        uint256 withdrawableAmount = currentPaymentAmount + originalRewardAmount;

        funded = false;
        currentPaymentAmount = 0;
        currentRewardAmount = 0;

        require(withdrawableAmount > 0, "No withdrawable funds");

        (bool success,) = msg.sender.call{value: withdrawableAmount}("");
        require(success, "ETH transfer failed");
    }

    function tryResetBondData() internal {
        require(!is_bonded(), "Cannot reset while bond is active");

        bondedExecutor = address(0);
        bondAmount = 0;
        executionDeadline = 0;
    }
}
