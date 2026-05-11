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
    error EmptyReservation();
    error ZeroRewardAmount();
    error ZeroPaymentAmount();
    error AlreadyFunded();
    error TokenTransferFailed();
    error ETHTransferFailed();
    error IncorrectNativeAmount();
    error InvalidBatchProofLength();
    error DuplicateLogIndex();
    error DuplicateTransferIndex();
    error InvalidTransferIndex();
    error InvalidProofType();
    error InvalidTxProof();
    error TxFailed();
    error TransferAlreadyCompleted();
    error TransferAlreadyReserved();
    error TransferNotReserved();
    error MissingTransferProof();
    error ProofBeforeReservation();
    error InvalidReceiptProof();
    error InvalidTransferEvent();
    error InvalidNativeTransfer();
    error NoWithdrawableFunds();
    error Reentrancy();

    struct Reservation {
        uint256 bondAmount;
        uint256 deadline;
        uint256 startBlock;
        uint256 reservedRewardWeight;
        uint256 reservedCount;
    }

    address immutable deployerAddress;
    address public immutable tokenContract;
    uint256 public immutable totalPaymentAmount;
    uint256 public immutable totalRewardWeight;

    uint256 public currentRewardAmount;
    uint256 public currentPaymentAmount;
    uint256 public originalRewardAmount;
    uint256 public completedTransferCount;
    uint256 public activeReservationCount;
    uint256 public totalBondsDeposited;

    uint256 public constant MAX_BLOCK_LOOKBACK = 256;
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    IEscrowBatch.BatchTransfer[] public expectedTransfers;

    mapping(address => Reservation) public reservations;
    mapping(address => uint256[]) private reservedTransferIndexes;
    mapping(address => uint256) private reservationExecutorPositions;
    address[] private reservationExecutors;

    mapping(address => uint256) public totalAssetPaymentAmount;
    mapping(address => uint256) public currentAssetPaymentAmount;
    mapping(address => bool) private knownPaymentAsset;
    address[] private paymentAssets;

    mapping(uint256 => address) public transferExecutor;
    mapping(uint256 => bool) public transferCompleted;

    bool public cancellationRequest;
    bool public funded;
    bool public hasBeenFunded;
    uint256 private reentrancyStatus = NOT_ENTERED;

    modifier nonReentrant() {
        if (reentrancyStatus == ENTERED) revert Reentrancy();
        reentrancyStatus = ENTERED;
        _;
        reentrancyStatus = NOT_ENTERED;
    }

    constructor(
        address _tokenContract,
        IEscrowBatch.BatchTransfer[] memory _expectedTransfers,
        uint256 _currentRewardAmount
    ) payable {
        if (_tokenContract == address(0)) revert ZeroAddress();
        if (_expectedTransfers.length == 0) revert EmptyBatch();

        tokenContract = _tokenContract;
        deployerAddress = msg.sender;

        uint256 totalWeight;
        for (uint256 i = 0; i < _expectedTransfers.length;) {
            IEscrowBatch.BatchTransfer memory expectedTransfer = _expectedTransfers[i];
            _validateExpectedTransfer(expectedTransfer);

            address asset = _assetKey(expectedTransfer);
            _trackPaymentAsset(asset);
            totalAssetPaymentAmount[asset] += expectedTransfer.amount;
            totalWeight += expectedTransfer.rewardWeight;
            expectedTransfers.push(expectedTransfer);

            unchecked {
                ++i;
            }
        }

        totalPaymentAmount = totalWeight;
        totalRewardWeight = totalWeight;

        if (_currentRewardAmount > 0) {
            _fund(_currentRewardAmount);
        } else if (msg.value != 0) {
            revert IncorrectNativeAmount();
        }
    }

    function expectedTransferCount() external view returns (uint256) {
        return expectedTransfers.length;
    }

    function paymentAssetCount() external view returns (uint256) {
        return paymentAssets.length;
    }

    function paymentAssetAt(uint256 index) external view returns (address) {
        return paymentAssets[index];
    }

    function reservedTransferCount(address executor) external view returns (uint256) {
        return reservedTransferIndexes[executor].length;
    }

    function reservedTransferIndex(address executor, uint256 position) external view returns (uint256) {
        return reservedTransferIndexes[executor][position];
    }

    function fund(uint256 _currentRewardAmount) external payable nonReentrant {
        if (msg.sender != deployerAddress) revert OnlyDeployer();
        if (funded || hasBeenFunded) revert AlreadyFunded();

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
        uint256 executorCount = reservationExecutors.length;
        for (uint256 i = 0; i < executorCount;) {
            Reservation storage reservation = reservations[reservationExecutors[i]];
            if (reservation.deadline > 0 && block.timestamp <= reservation.deadline) {
                return true;
            }

            unchecked {
                ++i;
            }
        }

        return false;
    }

    function bond(uint256[] calldata transferIndexes, uint256 _bondAmount) external nonReentrant {
        _handleExpiredReservations(true);
        _validateBondRequirements(transferIndexes, _bondAmount);

        (uint256 reservedRewardWeight, uint256 reservedCount) = _validateReservationIndexes(transferIndexes);
        uint256 requiredBond = _calculateRewardShare(reservedRewardWeight) / 2;
        if (_bondAmount < requiredBond) revert InsufficientBond();

        _trackReservationExecutor(msg.sender);

        Reservation storage reservation = reservations[msg.sender];
        reservation.bondAmount = _bondAmount;
        reservation.deadline = block.timestamp + 5 minutes;
        reservation.startBlock = block.number;
        reservation.reservedRewardWeight = reservedRewardWeight;
        reservation.reservedCount = reservedCount;
        activeReservationCount += 1;

        for (uint256 i = 0; i < transferIndexes.length;) {
            uint256 transferIndex = transferIndexes[i];
            transferExecutor[transferIndex] = msg.sender;
            reservedTransferIndexes[msg.sender].push(transferIndex);

            unchecked {
                ++i;
            }
        }

        if (!IBatchERC20(tokenContract).transferFrom(msg.sender, address(this), _bondAmount)) {
            revert TokenTransferFailed();
        }
    }

    function collect(IEscrowBatch.BatchProof[] calldata proofs) external nonReentrant {
        _handleExpiredReservations(true);

        Reservation storage reservation = reservations[msg.sender];
        if (!funded) revert NotFunded();
        if (reservation.deadline == 0 || block.timestamp > reservation.deadline) revert OnlyBondedExecutor();
        if (proofs.length == 0) revert InvalidBatchProofLength();

        bool[] memory seenTransfers = new bool[](expectedTransfers.length);
        bytes32[] memory seenProofItems = new bytes32[](expectedTransfers.length);
        uint256 completedRewardWeight;
        uint256 providedTransferCount;

        for (uint256 proofIndex = 0; proofIndex < proofs.length;) {
            IEscrowBatch.BatchProof calldata batchProof = proofs[proofIndex];

            if (batchProof.proofType == IEscrowBatch.AssetType.ERC20) {
                (uint256 proofRewardWeight, uint256 proofTransferCount) = _validateERC20BatchProof(
                    batchProof, seenTransfers, seenProofItems, providedTransferCount, reservation.startBlock
                );
                completedRewardWeight += proofRewardWeight;
                providedTransferCount += proofTransferCount;
            } else if (batchProof.proofType == IEscrowBatch.AssetType.NATIVE) {
                uint256 transferIndex = _validateNativeBatchProof(
                    batchProof, seenTransfers, seenProofItems, providedTransferCount, reservation.startBlock
                );
                completedRewardWeight += expectedTransfers[transferIndex].rewardWeight;
                providedTransferCount += 1;
            } else {
                revert InvalidProofType();
            }

            unchecked {
                ++proofIndex;
            }
        }

        if (providedTransferCount != reservation.reservedCount) revert MissingTransferProof();
        if (completedRewardWeight != reservation.reservedRewardWeight) revert MissingTransferProof();

        uint256[] storage reservedIndexes = reservedTransferIndexes[msg.sender];
        for (uint256 i = 0; i < reservedIndexes.length;) {
            uint256 transferIndex = reservedIndexes[i];
            if (!seenTransfers[transferIndex]) revert MissingTransferProof();
            transferCompleted[transferIndex] = true;
            transferExecutor[transferIndex] = address(0);

            unchecked {
                ++i;
            }
        }

        _payoutReservation(msg.sender, reservation.bondAmount, completedRewardWeight, reservation.reservedCount);
    }

    function cancelAndWithdraw() external nonReentrant {
        if (msg.sender != deployerAddress) revert OnlyDeployer();
        if (!funded) revert NotFunded();

        cancellationRequest = true;
        _handleExpiredReservations(true);
        if (activeReservationCount > 0) revert BondActive();

        uint256 rewardAmount = currentRewardAmount;
        address[] memory assets = paymentAssets;
        uint256[] memory amounts = new uint256[](assets.length);
        uint256 withdrawableAmount = rewardAmount;

        funded = false;
        currentRewardAmount = 0;
        currentPaymentAmount = 0;

        for (uint256 i = 0; i < assets.length;) {
            amounts[i] = currentAssetPaymentAmount[assets[i]];
            withdrawableAmount += amounts[i];
            currentAssetPaymentAmount[assets[i]] = 0;

            unchecked {
                ++i;
            }
        }

        if (withdrawableAmount == 0) revert NoWithdrawableFunds();

        if (rewardAmount > 0) {
            _sendERC20(tokenContract, msg.sender, rewardAmount);
        }
        for (uint256 i = 0; i < assets.length;) {
            if (amounts[i] > 0) {
                _sendAsset(assets[i], msg.sender, amounts[i]);
            }

            unchecked {
                ++i;
            }
        }
    }

    function _fund(uint256 _currentRewardAmount) internal {
        if (_currentRewardAmount == 0) revert ZeroRewardAmount();
        if (totalRewardWeight == 0) revert ZeroPaymentAmount();
        if (msg.value != totalAssetPaymentAmount[address(0)]) revert IncorrectNativeAmount();

        currentRewardAmount = _currentRewardAmount;
        originalRewardAmount = _currentRewardAmount;
        currentPaymentAmount = totalRewardWeight;
        completedTransferCount = 0;
        hasBeenFunded = true;
        funded = true;

        if (!IBatchERC20(tokenContract).transferFrom(msg.sender, address(this), _currentRewardAmount)) {
            revert TokenTransferFailed();
        }

        for (uint256 i = 0; i < paymentAssets.length;) {
            address asset = paymentAssets[i];
            uint256 amount = totalAssetPaymentAmount[asset];
            currentAssetPaymentAmount[asset] = amount;

            if (asset != address(0) && !IBatchERC20(asset).transferFrom(msg.sender, address(this), amount)) {
                revert TokenTransferFailed();
            }

            unchecked {
                ++i;
            }
        }
    }

    function _validateExpectedTransfer(IEscrowBatch.BatchTransfer memory expectedTransfer) internal pure {
        if (expectedTransfer.recipient == address(0)) revert ZeroAddress();
        if (expectedTransfer.amount == 0) revert ZeroPaymentAmount();
        if (expectedTransfer.rewardWeight == 0) revert ZeroPaymentAmount();

        if (expectedTransfer.assetType == IEscrowBatch.AssetType.ERC20) {
            if (expectedTransfer.asset == address(0)) revert ZeroAddress();
        } else if (expectedTransfer.assetType == IEscrowBatch.AssetType.NATIVE) {
            if (expectedTransfer.asset != address(0)) revert ZeroAddress();
        } else {
            revert InvalidProofType();
        }
    }

    function _validateBondRequirements(uint256[] calldata transferIndexes, uint256 _bondAmount) internal view {
        if (!funded) revert NotFunded();
        if (cancellationRequest) revert CancellationRequested();
        if (transferIndexes.length == 0) revert EmptyReservation();
        if (reservations[msg.sender].deadline > 0) revert ExecutorAlreadyBonded();
        if (_bondAmount == 0) revert InsufficientBond();
    }

    function _validateReservationIndexes(uint256[] calldata transferIndexes)
        internal
        view
        returns (uint256 reservedRewardWeight, uint256 reservedCount)
    {
        bool[] memory seenTransfers = new bool[](expectedTransfers.length);

        for (uint256 i = 0; i < transferIndexes.length;) {
            uint256 transferIndex = transferIndexes[i];
            if (transferIndex >= expectedTransfers.length) revert InvalidTransferIndex();
            if (seenTransfers[transferIndex]) revert DuplicateTransferIndex();
            if (transferCompleted[transferIndex]) revert TransferAlreadyCompleted();
            if (transferExecutor[transferIndex] != address(0)) revert TransferAlreadyReserved();

            seenTransfers[transferIndex] = true;
            reservedRewardWeight += expectedTransfers[transferIndex].rewardWeight;
            reservedCount += 1;

            unchecked {
                ++i;
            }
        }
    }

    function _validateERC20BatchProof(
        IEscrowBatch.BatchProof calldata batchProof,
        bool[] memory seenTransfers,
        bytes32[] memory seenProofItems,
        uint256 providedTransferCount,
        uint256 reservationStartBlock
    ) internal view returns (uint256 proofRewardWeight, uint256 proofTransferCount) {
        if (batchProof.transferIndexes.length == 0) revert InvalidBatchProofLength();
        if (batchProof.transferIndexes.length != batchProof.logIndexes.length) revert InvalidBatchProofLength();
        _validateLogIndexesAreUnique(batchProof.logIndexes);

        for (uint256 i = 0; i < batchProof.transferIndexes.length;) {
            uint256 transferIndex = _validateCollectTransfer(batchProof.transferIndexes[i], seenTransfers);
            IEscrowBatch.BatchTransfer storage expectedTransfer = expectedTransfers[transferIndex];
            if (expectedTransfer.assetType != IEscrowBatch.AssetType.ERC20) revert InvalidProofType();

            bytes32 proofItemId = keccak256(
                abi.encode(
                    batchProof.proofType,
                    batchProof.receiptProof.targetBlockNumber,
                    batchProof.receiptProof.receiptPath,
                    batchProof.logIndexes[i]
                )
            );
            _validateProofItemIsUnused(seenProofItems, providedTransferCount + proofTransferCount, proofItemId);
            seenProofItems[providedTransferCount + proofTransferCount] = proofItemId;

            seenTransfers[transferIndex] = true;
            proofRewardWeight += expectedTransfer.rewardWeight;
            proofTransferCount += 1;

            unchecked {
                ++i;
            }
        }

        if (batchProof.receiptProof.targetBlockNumber <= reservationStartBlock) revert ProofBeforeReservation();
        _validateReceiptProof(batchProof.receiptProof);

        for (uint256 i = 0; i < batchProof.transferIndexes.length;) {
            uint256 transferIndex = batchProof.transferIndexes[i];
            IEscrowBatch.BatchTransfer storage expectedTransfer = expectedTransfers[transferIndex];
            if (!ReceiptValidator.validateTransferInReceipt(
                    batchProof.receiptProof.receiptRlp,
                    batchProof.logIndexes[i],
                    expectedTransfer.asset,
                    expectedTransfer.recipient,
                    expectedTransfer.amount
                )) revert InvalidTransferEvent();

            unchecked {
                ++i;
            }
        }
    }

    function _validateNativeBatchProof(
        IEscrowBatch.BatchProof calldata batchProof,
        bool[] memory seenTransfers,
        bytes32[] memory seenProofItems,
        uint256 providedTransferCount,
        uint256 reservationStartBlock
    ) internal view returns (uint256 transferIndex) {
        if (batchProof.transferIndexes.length != 1 || batchProof.logIndexes.length != 0) {
            revert InvalidBatchProofLength();
        }

        transferIndex = _validateCollectTransfer(batchProof.transferIndexes[0], seenTransfers);
        IEscrowBatch.BatchTransfer storage expectedTransfer = expectedTransfers[transferIndex];
        if (expectedTransfer.assetType != IEscrowBatch.AssetType.NATIVE) revert InvalidProofType();

        bytes32 proofItemId = keccak256(
            abi.encode(
                batchProof.proofType, batchProof.receiptProof.targetBlockNumber, batchProof.receiptProof.receiptPath
            )
        );
        _validateProofItemIsUnused(seenProofItems, providedTransferCount, proofItemId);
        seenProofItems[providedTransferCount] = proofItemId;
        seenTransfers[transferIndex] = true;

        if (batchProof.receiptProof.targetBlockNumber <= reservationStartBlock) revert ProofBeforeReservation();
        _validateNativeProof(batchProof, expectedTransfer.recipient, expectedTransfer.amount);
    }

    function _validateCollectTransfer(uint256 transferIndex, bool[] memory seenTransfers)
        internal
        view
        returns (uint256)
    {
        if (transferIndex >= expectedTransfers.length) revert InvalidTransferIndex();
        if (seenTransfers[transferIndex]) revert DuplicateTransferIndex();
        if (transferExecutor[transferIndex] != msg.sender) revert TransferNotReserved();
        if (transferCompleted[transferIndex]) revert TransferAlreadyCompleted();
        return transferIndex;
    }

    function _validateReceiptProof(IEscrowBatch.BatchReceiptProof calldata proof) internal view {
        _validateBlockHeader(proof.blockHeader, proof.targetBlockNumber);

        bytes32 receiptsRoot = BlockHeaderParser.extractReceiptsRoot(proof.blockHeader);
        if (!MPTVerifier.verifyReceiptProof(proof.receiptRlp, proof.proofNodes, proof.receiptPath, receiptsRoot)) {
            revert InvalidReceiptProof();
        }
    }

    function _validateNativeProof(
        IEscrowBatch.BatchProof calldata batchProof,
        address expectedRecipient,
        uint256 expectedAmount
    ) internal view {
        _validateBlockHeader(batchProof.receiptProof.blockHeader, batchProof.receiptProof.targetBlockNumber);

        bytes32 transactionsRoot = BlockHeaderParser.extractTransactionsRoot(batchProof.receiptProof.blockHeader);
        if (!MPTVerifier.verifyReceiptProof(
                batchProof.transactionRlp,
                batchProof.txProofNodes,
                batchProof.receiptProof.receiptPath,
                transactionsRoot
            )) revert InvalidTxProof();

        bytes32 receiptsRoot = BlockHeaderParser.extractReceiptsRoot(batchProof.receiptProof.blockHeader);
        if (!MPTVerifier.verifyReceiptProof(
                batchProof.receiptProof.receiptRlp,
                batchProof.receiptProof.proofNodes,
                batchProof.receiptProof.receiptPath,
                receiptsRoot
            )) revert InvalidReceiptProof();

        if (!ReceiptValidator.validateReceiptStatus(batchProof.receiptProof.receiptRlp)) revert TxFailed();
        if (!ReceiptValidator.validateNativeTransfer(
                batchProof.transactionRlp, expectedRecipient, expectedAmount
            )) revert InvalidNativeTransfer();
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

    function _validateProofItemIsUnused(bytes32[] memory seenProofItems, uint256 seenCount, bytes32 proofItemId)
        internal
        pure
    {
        for (uint256 i = 0; i < seenCount;) {
            if (seenProofItems[i] == proofItemId) revert DuplicateLogIndex();

            unchecked {
                ++i;
            }
        }
    }

    function _handleExpiredReservations(bool addToReward) internal {
        uint256 i;
        while (i < reservationExecutors.length) {
            if (!_releaseExpiredReservation(reservationExecutors[i], addToReward)) {
                unchecked {
                    ++i;
                }
            }
        }
    }

    function _releaseExpiredReservation(address executor, bool addToReward) internal returns (bool released) {
        Reservation storage reservation = reservations[executor];
        if (reservation.deadline == 0 || block.timestamp <= reservation.deadline) {
            return false;
        }

        uint256 forfeitedBond = reservation.bondAmount;
        _clearReservation(executor);

        if (addToReward && forfeitedBond > 0) {
            currentRewardAmount += forfeitedBond;
            totalBondsDeposited += forfeitedBond;
        }

        return true;
    }

    function _clearReservation(address executor) internal {
        Reservation storage reservation = reservations[executor];
        if (reservation.deadline == 0) {
            return;
        }

        uint256[] storage indexes = reservedTransferIndexes[executor];
        for (uint256 i = 0; i < indexes.length;) {
            uint256 transferIndex = indexes[i];
            if (transferExecutor[transferIndex] == executor) {
                transferExecutor[transferIndex] = address(0);
            }

            unchecked {
                ++i;
            }
        }

        delete reservedTransferIndexes[executor];
        delete reservations[executor];
        _untrackReservationExecutor(executor);
        activeReservationCount -= 1;
    }

    function _trackReservationExecutor(address executor) internal {
        if (reservationExecutorPositions[executor] != 0) {
            return;
        }

        reservationExecutors.push(executor);
        reservationExecutorPositions[executor] = reservationExecutors.length;
    }

    function _untrackReservationExecutor(address executor) internal {
        uint256 position = reservationExecutorPositions[executor];
        if (position == 0) {
            return;
        }

        uint256 index = position - 1;
        uint256 lastIndex = reservationExecutors.length - 1;

        if (index != lastIndex) {
            address lastExecutor = reservationExecutors[lastIndex];
            reservationExecutors[index] = lastExecutor;
            reservationExecutorPositions[lastExecutor] = position;
        }

        reservationExecutors.pop();
        delete reservationExecutorPositions[executor];
    }

    function _trackPaymentAsset(address asset) internal {
        if (knownPaymentAsset[asset]) {
            return;
        }

        knownPaymentAsset[asset] = true;
        paymentAssets.push(asset);
    }

    function _assetKey(IEscrowBatch.BatchTransfer memory expectedTransfer) internal pure returns (address) {
        return expectedTransfer.assetType == IEscrowBatch.AssetType.NATIVE ? address(0) : expectedTransfer.asset;
    }

    function _calculateRewardShare(uint256 rewardWeight) internal view returns (uint256) {
        if (rewardWeight == 0 || currentRewardAmount == 0) {
            return 0;
        }
        if (rewardWeight >= currentPaymentAmount) {
            return currentRewardAmount;
        }

        return (currentRewardAmount * rewardWeight) / currentPaymentAmount;
    }

    function _payoutReservation(
        address executor,
        uint256 executorBondAmount,
        uint256 completedRewardWeight,
        uint256 completedCount
    ) internal {
        bool isFinalCollection =
            completedTransferCount + completedCount == expectedTransfers.length;
        uint256 rewardWeightShare = isFinalCollection ? currentPaymentAmount : completedRewardWeight;
        uint256 rewardShare = isFinalCollection ? currentRewardAmount : _calculateRewardShare(completedRewardWeight);

        uint256[] storage indexes = reservedTransferIndexes[executor];
        address[] memory assets = new address[](indexes.length);
        uint256[] memory amounts = new uint256[](indexes.length);
        for (uint256 i = 0; i < indexes.length;) {
            IEscrowBatch.BatchTransfer storage expectedTransfer = expectedTransfers[indexes[i]];
            address asset = _assetKey(expectedTransfer);
            assets[i] = asset;
            amounts[i] = expectedTransfer.amount;
            currentAssetPaymentAmount[asset] -= expectedTransfer.amount;

            unchecked {
                ++i;
            }
        }

        uint256 rewardPayout = executorBondAmount + rewardShare;
        completedTransferCount += completedCount;
        currentPaymentAmount -= rewardWeightShare;
        currentRewardAmount -= rewardShare;
        _clearReservation(executor);

        if (isFinalCollection) {
            funded = false;
            currentPaymentAmount = 0;
            currentRewardAmount = 0;
        }

        if (rewardPayout > 0) {
            _sendERC20(tokenContract, executor, rewardPayout);
        }
        for (uint256 i = 0; i < assets.length;) {
            _sendAsset(assets[i], executor, amounts[i]);

            unchecked {
                ++i;
            }
        }
    }

    function _sendAsset(address asset, address to, uint256 amount) internal {
        if (asset == address(0)) {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert ETHTransferFailed();
        } else {
            _sendERC20(asset, to, amount);
        }
    }

    function _sendERC20(address asset, address to, uint256 amount) internal {
        bool success;
        if (block.chainid == 11155111) {
            success = IBatchERC20(asset).send(to, amount);
        } else {
            success = IBatchERC20(asset).transfer(to, amount);
        }
        if (!success) revert TokenTransferFailed();
    }
}
