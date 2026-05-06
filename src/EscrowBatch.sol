// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import "./BlockHeaderParser.sol";
import "./IEscrowBatch.sol";
import "./MPTVerifier.sol";
import "./ReceiptValidator.sol";

interface IBatchERC20 {
    function send(address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract EscrowBatch is IEscrowBatch {
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
    error ZeroAddress();
    error EmptyBatch();
    error ZeroRewardAmount();
    error ZeroPaymentAmount();
    error AlreadyFunded();
    error TokenTransferFailed();
    error InvalidBatchProofLength();
    error DuplicateLogIndex();
    error InvalidReceiptProof();
    error InvalidTransferEvent();
    error NoWithdrawableFunds();

    address immutable deployerAddress;
    address public immutable tokenContract;
    uint256 public immutable totalPaymentAmount;

    uint256 public currentRewardAmount;
    uint256 public currentPaymentAmount;
    uint256 public originalRewardAmount;

    uint256 public constant MAX_BLOCK_LOOKBACK = 256;

    IEscrowBatch.BatchTransfer[] public expectedTransfers;

    address public bondedExecutor;
    uint256 public executionDeadline;
    uint256 public bondAmount;
    uint256 public totalBondsDeposited;
    bool public cancellationRequest;
    bool public funded;

    constructor(
        address _tokenContract,
        IEscrowBatch.BatchTransfer[] memory _expectedTransfers,
        uint256 _currentRewardAmount
    ) {
        if (_tokenContract == address(0)) revert ZeroAddress();
        if (_expectedTransfers.length == 0) revert EmptyBatch();

        tokenContract = _tokenContract;
        deployerAddress = msg.sender;

        uint256 totalAmount;
        for (uint256 i = 0; i < _expectedTransfers.length;) {
            if (_expectedTransfers[i].recipient == address(0)) revert ZeroAddress();
            if (_expectedTransfers[i].amount == 0) revert ZeroPaymentAmount();

            totalAmount += _expectedTransfers[i].amount;
            expectedTransfers.push(_expectedTransfers[i]);

            unchecked {
                ++i;
            }
        }

        totalPaymentAmount = totalAmount;

        if (_currentRewardAmount > 0) {
            _fund(_currentRewardAmount);
        }
    }

    function expectedTransferCount() external view returns (uint256) {
        return expectedTransfers.length;
    }

    function fund(uint256 _currentRewardAmount) external {
        if (msg.sender != deployerAddress) revert OnlyDeployer();
        if (funded) revert AlreadyFunded();

        _fund(_currentRewardAmount);
    }

    function requestCancellation() external {
        if (msg.sender != deployerAddress) revert OnlyDeployer();
        cancellationRequest = true;
    }

    function resume() external {
        if (msg.sender != deployerAddress) revert OnlyDeployer();
        cancellationRequest = false;
    }

    function is_bonded() public view returns (bool) {
        return executionDeadline > 0 && block.timestamp <= executionDeadline;
    }

    function bond(uint256 _bondAmount) external {
        _handleExpiredBond();
        _validateBondRequirements(_bondAmount);

        if (!IBatchERC20(tokenContract).transferFrom(msg.sender, address(this), _bondAmount)) {
            revert TokenTransferFailed();
        }

        bondedExecutor = msg.sender;
        executionDeadline = block.timestamp + 5 minutes;
        bondAmount = _bondAmount;
    }

    function collect(IEscrowBatch.BatchReceiptProof calldata proof, uint256[] calldata logIndexes) external {
        _validateCollectRequirements();

        uint256 expectedCount = expectedTransfers.length;
        if (logIndexes.length != expectedCount) revert InvalidBatchProofLength();
        _validateLogIndexesAreUnique(logIndexes);

        _validateBlockHeader(proof.blockHeader, proof.targetBlockNumber);

        bytes32 receiptsRoot = BlockHeaderParser.extractReceiptsRoot(proof.blockHeader);
        if (!MPTVerifier.verifyReceiptProof(proof.receiptRlp, proof.proofNodes, proof.receiptPath, receiptsRoot)) {
            revert InvalidReceiptProof();
        }

        for (uint256 i = 0; i < expectedCount;) {
            IEscrowBatch.BatchTransfer storage expectedTransfer = expectedTransfers[i];
            if (
                !ReceiptValidator.validateTransferInReceipt(
                    proof.receiptRlp, logIndexes[i], tokenContract, expectedTransfer.recipient, expectedTransfer.amount
                )
            ) revert InvalidTransferEvent();

            unchecked {
                ++i;
            }
        }

        _payout();
    }

    function cancelAndWithdraw() external {
        cancellationRequest = true;
        if (!funded) revert NotFunded();
        if (msg.sender != deployerAddress) revert OnlyDeployer();
        _tryResetBondData();

        uint256 withdrawableAmount = currentPaymentAmount + originalRewardAmount;

        funded = false;
        currentPaymentAmount = 0;
        currentRewardAmount = 0;

        if (withdrawableAmount == 0) revert NoWithdrawableFunds();

        if (!IBatchERC20(tokenContract).transfer(msg.sender, withdrawableAmount)) {
            revert TokenTransferFailed();
        }
    }

    function _fund(uint256 _currentRewardAmount) internal {
        if (_currentRewardAmount == 0) revert ZeroRewardAmount();
        if (totalPaymentAmount == 0) revert ZeroPaymentAmount();

        bool success = IBatchERC20(tokenContract)
            .transferFrom(msg.sender, address(this), _currentRewardAmount + totalPaymentAmount);
        if (!success) {
            revert TokenTransferFailed();
        }

        currentRewardAmount = _currentRewardAmount;
        originalRewardAmount = _currentRewardAmount;
        currentPaymentAmount = totalPaymentAmount;
        funded = true;
    }

    function _validateCollectRequirements() internal view {
        if (!funded) revert NotFunded();
        if (msg.sender != bondedExecutor || !is_bonded()) revert OnlyBondedExecutor();
    }

    function _validateBlockHeader(bytes calldata blockHeader, uint256 targetBlockNumber) internal view {
        if (targetBlockNumber > block.number) revert TargetBlockInFuture();
        if (block.number - targetBlockNumber > MAX_BLOCK_LOOKBACK) revert TargetBlockTooOld();

        bytes32 targetBlockHash = blockhash(targetBlockNumber);
        if (targetBlockHash == bytes32(0)) revert BlockHashUnavailable();
        if (keccak256(blockHeader) != targetBlockHash) revert BlockHeaderMismatch();
        if (BlockHeaderParser.extractBlockNumber(blockHeader) != targetBlockNumber) revert BlockNumberMismatch();
    }

    function _validateLogIndexesAreUnique(uint256[] calldata logIndexes) internal pure {
        uint256 len = logIndexes.length;
        for (uint256 i = 0; i < len;) {
            uint256 current = logIndexes[i];
            for (uint256 j = 0; j < i;) {
                if (current == logIndexes[j]) revert DuplicateLogIndex();
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function _tryResetBondData() internal {
        if (is_bonded()) revert BondActive();

        bondedExecutor = address(0);
        bondAmount = 0;
        executionDeadline = 0;
    }

    function _handleExpiredBond() internal {
        if (executionDeadline > 0 && block.timestamp > executionDeadline) {
            currentRewardAmount += bondAmount;
            totalBondsDeposited += bondAmount;
            _tryResetBondData();
        }
    }

    function _validateBondRequirements(uint256 _bondAmount) internal view {
        if (!funded) revert NotFunded();
        if (cancellationRequest) revert CancellationRequested();
        if (is_bonded()) revert ExecutorAlreadyBonded();
        if (_bondAmount < currentRewardAmount / 2) revert InsufficientBond();
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

        bool success;
        if (block.chainid == 11155111) {
            success = IBatchERC20(tokenContract).send(executor, payout);
        } else {
            success = IBatchERC20(tokenContract).transfer(executor, payout);
        }
        if (!success) revert TokenTransferFailed();
    }
}
