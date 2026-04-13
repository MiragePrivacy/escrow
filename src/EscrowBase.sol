// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import "./BlockHeaderParser.sol";
import "./MPTVerifier.sol";
import "./ReceiptValidator.sol";

abstract contract EscrowBase {
    // Custom errors
    error OnlyDeployer();
    error NotFunded();
    error OnlyBondedExecutor();
    error TargetBlockInFuture();
    error TargetBlockTooOld();
    error BlockHashUnavailable();
    error BlockHeaderMismatch();
    error BlockNumberMismatch();
    error BondActive();
    error CancellationRequested();
    error ExecutorAlreadyBonded();
    error InsufficientBond();
    error CommitmentMismatch();

    address immutable deployerAddress;
    uint256 public deposit; // Total deposited (original + seized bonds)
    bytes32 public commitment; // H(recipient, [token,] amount, salt)

    uint256 public constant MAX_BLOCK_LOOKBACK = 256;

    address public bondedExecutor;
    uint256 public executionDeadline;
    uint256 public bondAmount;
    bool public cancellationRequest;
    bool public funded;

    constructor() {
        deployerAddress = msg.sender;
    }

    // only deployer can call this. will set the cancellation request to true.
    // when the cancellation is requested, the bonded executor may still finish their job and collect, but no new executor is accepted after the current bonded one.
    function requestCancellation() external {
        if (msg.sender != deployerAddress) revert OnlyDeployer();
        cancellationRequest = true;
    }

    // sets cancellation request to false, if the caller is deployer.
    // starts accepting new executors
    function resume() external {
        if (msg.sender != deployerAddress) revert OnlyDeployer();
        cancellationRequest = false;
    }

    // checks if contract is currently bonded by verifying deadline
    function is_bonded() public view returns (bool) {
        return executionDeadline > 0 && block.timestamp <= executionDeadline;
    }

    // Internal helper to validate block header for proof verification
    function _validateBlockHeader(bytes calldata blockHeader, uint256 targetBlockNumber) internal view {
        if (!funded) revert NotFunded();
        if (msg.sender != bondedExecutor || !is_bonded()) revert OnlyBondedExecutor();
        if (targetBlockNumber > block.number) revert TargetBlockInFuture();
        if (block.number - targetBlockNumber > MAX_BLOCK_LOOKBACK) revert TargetBlockTooOld();

        bytes32 targetBlockHash = blockhash(targetBlockNumber);
        if (targetBlockHash == bytes32(0)) revert BlockHashUnavailable();
        if (keccak256(blockHeader) != targetBlockHash) revert BlockHeaderMismatch();
        if (BlockHeaderParser.extractBlockNumber(blockHeader) != targetBlockNumber) revert BlockNumberMismatch();
    }

    // Internal helper to reset bond data when expired
    function _tryResetBondData() internal {
        if (is_bonded()) revert BondActive();

        bondedExecutor = address(0);
        bondAmount = 0;
        executionDeadline = 0;
    }

    // Internal helper to handle expired bonds (adds bond to deposit pool)
    function _handleExpiredBond() internal {
        if (executionDeadline > 0 && block.timestamp > executionDeadline) {
            deposit += bondAmount;
            _tryResetBondData();
        }
    }

    // Internal helper to validate bond requirements
    function _validateBondRequirements(uint256 _bondAmount) internal view {
        if (!funded) revert NotFunded();
        if (cancellationRequest) revert CancellationRequested();
        if (is_bonded()) revert ExecutorAlreadyBonded();
        if (_bondAmount < deposit / 400) revert InsufficientBond();
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
        deposit = 0;
        commitment = bytes32(0);
    }

    // Internal helper to calculate payout amount
    function _calculatePayout() internal view returns (uint256) {
        return bondAmount + deposit;
    }

    // Internal helper to validate withdraw requirements
    function _validateWithdraw() internal view {
        if (!funded) revert NotFunded();
        if (msg.sender != deployerAddress) revert OnlyDeployer();
    }

    // Internal helper to clear state after withdraw
    function _clearWithdrawState() internal {
        funded = false;
        deposit = 0;
        commitment = bytes32(0);
    }
}
