// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import "./BlockHeaderParser.sol";
import "./MPTVerifier.sol";
import "./ReceiptValidator.sol";

abstract contract EscrowBase {
    // The following variables are set up in the constructor.
    address immutable deployerAddress;
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

    constructor(address _expectedRecipient, uint256 _expectedAmount) {
        expectedRecipient = _expectedRecipient;
        expectedAmount = _expectedAmount;
        deployerAddress = msg.sender;
        maxBlockLookback = 256;
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

    // checks if contract is currently bonded by verifying deadline
    function is_bonded() public view returns (bool) {
        return executionDeadline > 0 && block.timestamp <= executionDeadline;
    }

    // Internal helper to validate block header for proof verification
    function _validateBlockHeader(bytes calldata blockHeader, uint256 targetBlockNumber) internal view {
        require(funded, "Contract not funded");
        require(msg.sender == bondedExecutor && is_bonded(), "Only bonded executor can collect");
        require(targetBlockNumber <= block.number, "Target block is in the future");
        require(block.number - targetBlockNumber <= maxBlockLookback, "Target block too old");

        bytes32 targetBlockHash = blockhash(targetBlockNumber);
        require(targetBlockHash != bytes32(0), "Unable to retrieve block hash");
        require(keccak256(blockHeader) == targetBlockHash, "Block header hash mismatch");
        require(BlockHeaderParser.extractBlockNumber(blockHeader) == targetBlockNumber, "Header block number mismatch");
    }

    // Internal helper to reset bond data when expired
    function _tryResetBondData() internal {
        require(!is_bonded(), "Cannot reset while bond is active");

        bondedExecutor = address(0);
        bondAmount = 0;
        executionDeadline = 0;
    }

    // Internal helper to handle expired bonds (adds bond to reward pool)
    function _handleExpiredBond() internal {
        if (executionDeadline > 0 && block.timestamp > executionDeadline) {
            currentRewardAmount += bondAmount;
            totalBondsDeposited += bondAmount;
            _tryResetBondData();
        }
    }

    // Internal helper to validate bond requirements
    function _validateBondRequirements(uint256 _bondAmount) internal view {
        require(funded, "Contract not funded");
        require(!cancellationRequest, "Cancellation requested");
        require(!is_bonded(), "Another executor is already bonded");
        require(_bondAmount >= currentRewardAmount / 2, "Bond must be at least half of reward amount");
    }

    // Internal helper to set bond data
    function _setBondData(uint256 _bondAmount) internal {
        bondedExecutor = msg.sender;
        executionDeadline = block.timestamp + 5 minutes;
        bondAmount = _bondAmount;
    }

    // Internal helper to clear payout state
    function _clearPayoutState() internal {
        bondedExecutor = address(0);
        bondAmount = 0;
        executionDeadline = 0;
        funded = false;
        currentPaymentAmount = 0;
        currentRewardAmount = 0;
    }

    // Internal helper to calculate payout amount
    function _calculatePayout() internal view returns (uint256) {
        return bondAmount + currentRewardAmount + currentPaymentAmount;
    }

    // Internal helper to validate withdraw requirements
    function _validateWithdraw() internal view {
        require(funded, "Contract not funded");
        require(msg.sender == deployerAddress, "Only callable by the deployer");
    }

    // Internal helper to calculate withdrawable amount and clear state
    function _calculateWithdrawableAmount() internal view returns (uint256) {
        return currentPaymentAmount + originalRewardAmount;
    }

    // Internal helper to clear state after withdraw
    function _clearWithdrawState() internal {
        funded = false;
        currentPaymentAmount = 0;
        currentRewardAmount = 0;
    }
}
