// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import "./BlockHeaderParser.sol";
import "./MPTVerifier.sol";
import "./ReceiptValidator.sol";

interface IBatchERC20 {
    function send(address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title EscrowBatch
/// @notice Multi-transfer escrow with first-come bid-backed execution. Bidders
/// (nodes) commit to executing selected transfer rows by posting a
/// bond. Bidders who prove every committed transfer by `expiresAt` recover
/// their bond plus a pro-rata reward share. Expired bids forfeit their bond
/// into the reward pool.
contract EscrowBatch {
    // ============ Types ============

    /// TODO: reward calculation across mixed assets is not fully solved yet.
    struct BatchTransfer {
        address asset;
        address recipient;
        uint256 amount;
    }

    struct BatchReceiptProof {
        bytes blockHeader;
        bytes receiptRlp;
        bytes proofNodes;
        bytes receiptPath;
        uint256 targetBlockNumber;
    }

    /// @dev Proof type is inferred from the asset of the first claimed transfer:
    /// - if that transfer's `asset == address(0)`, the proof is native and
    ///   `transferIndexes.length` must be 1 and `transactionRlp` / `txProofNodes` populated.
    /// - otherwise it's an ERC-20 receipt-log proof; `logIndexes` must match
    ///   `transferIndexes` in length and order.
    struct BatchProof {
        BatchReceiptProof receiptProof;
        bytes transactionRlp;
        bytes txProofNodes;
        uint256[] transferIndexes;
        uint256[] logIndexes;
    }

    /// @dev A bid is a bidder's commitment to deliver the transfer rows stored in
    /// `bidTransferIndexes[bidder]`, backed by `bondAmount` as security deposit
    /// and valid until `expiresAt`. `startBlock` is the block at which the bid
    /// was placed, used to reject proofs of transfers that happened before the bid existed.
    struct Bid {
        uint256 bondAmount;
        uint256 expiresAt;
        uint256 startBlock;
    }

    // ============ Errors ============

    error OnlyDeployer();
    error NotFunded();
    error OnlyActiveBidder();
    error TargetBlockInFuture();
    error TargetBlockTooOld();
    error BlockHashUnavailable();
    error BlockHeaderMismatch();
    error BlockNumberMismatch();
    error BidActive();
    error CancellationRequested();
    error BidderHasActiveBid();
    error InsufficientBond();
    error ZeroAddress();
    error EmptyBatch();
    error EmptyBid();
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
    error InvalidProofShape();
    error InvalidTxProof();
    error TxFailed();
    error TransferAlreadyCompleted();
    error TransferAlreadyInBid();
    error TransferNotInBid();
    error MissingTransferProof();
    error ProofBeforeBid();
    error InvalidReceiptProof();
    error InvalidTransferEvent();
    error InvalidNativeTransfer();
    error Reentrancy();

    // ============ Storage ============

    address public immutable deployerAddress;
    address public immutable rewardAsset;
    uint256 public immutable totalTransferAmount;

    uint256 public currentRewardAmount;
    uint256 public currentTransferAmount;
    uint256 public originalRewardAmount;
    uint256 public completedTransferCount;
    uint256 public activeBidCount;

    uint256 public constant MAX_BLOCK_LOOKBACK = 256;
    uint256 public constant BID_DURATION = 5 minutes;
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    BatchTransfer[] public expectedTransfers;

    mapping(address => Bid) public bids;
    mapping(address => uint256[]) private bidTransferIndexes;
    mapping(address => uint256) private bidderPositions;
    address[] private bidders;

    mapping(address => uint256) public totalAssetPaymentAmount;
    mapping(address => uint256) public currentAssetPaymentAmount;
    mapping(address => bool) private knownPaymentAsset;
    address[] private paymentAssets;

    mapping(uint256 => address) public transferBidder;
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

    constructor(address _rewardAsset, BatchTransfer[] memory _expectedTransfers, uint256 _currentRewardAmount) payable {
        if (_expectedTransfers.length == 0) revert EmptyBatch();

        rewardAsset = _rewardAsset;
        deployerAddress = msg.sender;

        uint256 totalAmount;
        for (uint256 i = 0; i < _expectedTransfers.length;) {
            BatchTransfer memory expectedTransfer = _expectedTransfers[i];
            _validateExpectedTransfer(expectedTransfer);

            _trackPaymentAsset(expectedTransfer.asset);
            totalAssetPaymentAmount[expectedTransfer.asset] += expectedTransfer.amount;
            totalAmount += expectedTransfer.amount;
            expectedTransfers.push(expectedTransfer);

            unchecked {
                ++i;
            }
        }

        totalTransferAmount = totalAmount;

        if (_currentRewardAmount > 0) {
            _fund(_currentRewardAmount);
        } else if (msg.value != 0) {
            revert IncorrectNativeAmount();
        }
    }

    // ============ View functions ============

    function expectedTransferCount() external view returns (uint256) {
        return expectedTransfers.length;
    }

    function paymentAssetCount() external view returns (uint256) {
        return paymentAssets.length;
    }

    function paymentAssetAt(uint256 index) external view returns (address) {
        return paymentAssets[index];
    }

    function bidTransferCount(address bidder) external view returns (uint256) {
        return bidTransferIndexes[bidder].length;
    }

    function bidTransferIndex(address bidder, uint256 position) external view returns (uint256) {
        return bidTransferIndexes[bidder][position];
    }

    function is_bonded() public view returns (bool) {
        uint256 bidderCount = bidders.length;
        for (uint256 i = 0; i < bidderCount;) {
            Bid storage activeBid = bids[bidders[i]];
            if (activeBid.expiresAt > 0 && block.timestamp <= activeBid.expiresAt) {
                return true;
            }

            unchecked {
                ++i;
            }
        }

        return false;
    }

    // ============ Deployer entrypoints ============

    function fund(uint256 _currentRewardAmount) external payable nonReentrant {
        if (msg.sender != deployerAddress) revert OnlyDeployer();
        if (funded || hasBeenFunded) revert AlreadyFunded();
        if (cancellationRequest) revert CancellationRequested();

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

    function cancelAndWithdraw() external nonReentrant {
        if (msg.sender != deployerAddress) revert OnlyDeployer();
        if (!funded) revert NotFunded();

        cancellationRequest = true;
        _handleExpiredBids();
        if (activeBidCount > 0) revert BidActive();

        uint256 rewardAmount = currentRewardAmount;
        address[] memory assets = paymentAssets;
        uint256[] memory amounts = new uint256[](assets.length);

        funded = false;
        currentRewardAmount = 0;
        currentTransferAmount = 0;

        for (uint256 i = 0; i < assets.length;) {
            amounts[i] = currentAssetPaymentAmount[assets[i]];
            currentAssetPaymentAmount[assets[i]] = 0;

            unchecked {
                ++i;
            }
        }

        if (rewardAmount > 0) {
            _sendAsset(rewardAsset, msg.sender, rewardAmount);
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

    // ============ Bidder entrypoints ============

    /// @notice Place a bid on a subset of expected transfers by posting a bond.
    /// @dev Bids are first-come commitments, not price auctions. `_bondAmount`
    /// is a security deposit; posting more than the required bond does not
    /// give priority and cannot outbid an existing active bid.
    /// `transferIndexes` is a list, so a single bid can reserve many rows in one call.
    function bid(uint256[] calldata transferIndexes, uint256 _bondAmount) external payable nonReentrant {
        _handleExpiredBids();
        _validateBidRequirements(transferIndexes, _bondAmount);

        uint256 transferAmount = _validateBidIndexes(transferIndexes);
        uint256 requiredBond = _calculateRewardShare(transferAmount) / 2;
        if (_bondAmount < requiredBond) revert InsufficientBond();

        _trackBidder(msg.sender);

        Bid storage placedBid = bids[msg.sender];
        placedBid.bondAmount = _bondAmount;
        placedBid.expiresAt = block.timestamp + BID_DURATION;
        placedBid.startBlock = block.number;
        activeBidCount += 1;

        for (uint256 i = 0; i < transferIndexes.length;) {
            uint256 transferIndex = transferIndexes[i];
            transferBidder[transferIndex] = msg.sender;
            bidTransferIndexes[msg.sender].push(transferIndex);

            unchecked {
                ++i;
            }
        }

        if (rewardAsset == address(0)) {
            if (msg.value != _bondAmount) revert IncorrectNativeAmount();
        } else {
            if (msg.value != 0) revert IncorrectNativeAmount();
            if (!IBatchERC20(rewardAsset).transferFrom(msg.sender, address(this), _bondAmount)) {
                revert TokenTransferFailed();
            }
        }
    }

    /// @notice Settle the caller's active bid by submitting proofs of every transfer
    /// they committed to. Pays out the bond + a pro-rata reward share + per-asset
    /// reimbursements on success; reverts if any committed transfer is unproven.
    function collect(BatchProof[] calldata proofs) external nonReentrant {
        _handleExpiredBids();

        Bid storage activeBid = bids[msg.sender];
        if (!funded) revert NotFunded();
        if (activeBid.expiresAt == 0 || block.timestamp > activeBid.expiresAt) revert OnlyActiveBidder();
        if (proofs.length == 0) revert InvalidBatchProofLength();

        bool[] memory seenTransfers = new bool[](expectedTransfers.length);
        bytes32[] memory seenProofItems = new bytes32[](expectedTransfers.length);
        uint256 providedTransferCount;

        for (uint256 proofIndex = 0; proofIndex < proofs.length;) {
            BatchProof calldata batchProof = proofs[proofIndex];
            if (batchProof.transferIndexes.length == 0) revert InvalidBatchProofLength();

            uint256 firstTransferIndex = batchProof.transferIndexes[0];
            if (firstTransferIndex >= expectedTransfers.length) revert InvalidTransferIndex();

            address firstAsset = expectedTransfers[firstTransferIndex].asset;
            if (firstAsset == address(0)) {
                _validateNativeBatchProof(
                    batchProof, seenTransfers, seenProofItems, providedTransferCount, activeBid.startBlock
                );
                providedTransferCount += 1;
            } else {
                uint256 proofTransferCount = _validateERC20BatchProof(
                    batchProof, seenTransfers, seenProofItems, providedTransferCount, activeBid.startBlock
                );
                providedTransferCount += proofTransferCount;
            }

            unchecked {
                ++proofIndex;
            }
        }

        uint256[] storage committedIndexes = bidTransferIndexes[msg.sender];
        if (providedTransferCount != committedIndexes.length) revert MissingTransferProof();

        for (uint256 i = 0; i < committedIndexes.length;) {
            uint256 transferIndex = committedIndexes[i];
            if (!seenTransfers[transferIndex]) revert MissingTransferProof();
            transferCompleted[transferIndex] = true;
            transferBidder[transferIndex] = address(0);

            unchecked {
                ++i;
            }
        }

        _payoutBid(msg.sender, activeBid.bondAmount);
    }

    // ============ Internal: funding ============

    function _fund(uint256 _currentRewardAmount) internal {
        if (_currentRewardAmount == 0) revert ZeroRewardAmount();

        // msg.value must cover any native transfers in the batch plus, if the
        // bond/reward currency is ETH, the reward amount itself.
        uint256 nativeOwed = totalAssetPaymentAmount[address(0)];
        if (rewardAsset == address(0)) {
            nativeOwed += _currentRewardAmount;
        }
        if (msg.value != nativeOwed) revert IncorrectNativeAmount();

        currentRewardAmount = _currentRewardAmount;
        originalRewardAmount = _currentRewardAmount;
        currentTransferAmount = totalTransferAmount;
        completedTransferCount = 0;
        hasBeenFunded = true;
        funded = true;

        if (
            rewardAsset != address(0)
                && !IBatchERC20(rewardAsset).transferFrom(msg.sender, address(this), _currentRewardAmount)
        ) {
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

    // ============ Internal: validation ============

    function _validateExpectedTransfer(BatchTransfer memory expectedTransfer) internal pure {
        if (expectedTransfer.recipient == address(0)) revert ZeroAddress();
        if (expectedTransfer.amount == 0) revert ZeroPaymentAmount();
    }

    function _validateBidRequirements(uint256[] calldata transferIndexes, uint256 _bondAmount) internal view {
        if (!funded) revert NotFunded();
        if (cancellationRequest) revert CancellationRequested();
        if (transferIndexes.length == 0) revert EmptyBid();
        if (bids[msg.sender].expiresAt > 0) revert BidderHasActiveBid();
        if (_bondAmount == 0) revert InsufficientBond();
    }

    function _validateBidIndexes(uint256[] calldata transferIndexes) internal view returns (uint256 transferAmount) {
        bool[] memory seenTransfers = new bool[](expectedTransfers.length);

        for (uint256 i = 0; i < transferIndexes.length;) {
            uint256 transferIndex = transferIndexes[i];
            if (transferIndex >= expectedTransfers.length) revert InvalidTransferIndex();
            if (seenTransfers[transferIndex]) revert DuplicateTransferIndex();
            if (transferCompleted[transferIndex]) revert TransferAlreadyCompleted();
            if (transferBidder[transferIndex] != address(0)) revert TransferAlreadyInBid();

            seenTransfers[transferIndex] = true;
            transferAmount += expectedTransfers[transferIndex].amount;

            unchecked {
                ++i;
            }
        }
    }

    function _validateERC20BatchProof(
        BatchProof calldata batchProof,
        bool[] memory seenTransfers,
        bytes32[] memory seenProofItems,
        uint256 providedTransferCount,
        uint256 bidStartBlock
    ) internal view returns (uint256 proofTransferCount) {
        if (batchProof.transferIndexes.length != batchProof.logIndexes.length) {
            revert InvalidBatchProofLength();
        }
        for (uint256 i = 0; i < batchProof.transferIndexes.length;) {
            uint256 transferIndex = _validateCollectTransfer(batchProof.transferIndexes[i], seenTransfers);
            BatchTransfer storage expectedTransfer = expectedTransfers[transferIndex];
            if (expectedTransfer.asset == address(0)) revert InvalidProofShape();

            bytes32 proofItemId = keccak256(
                abi.encode(
                    uint8(1), // ERC20 proof tag
                    batchProof.receiptProof.targetBlockNumber,
                    batchProof.receiptProof.receiptPath,
                    batchProof.logIndexes[i]
                )
            );
            _validateProofItemIsUnused(seenProofItems, providedTransferCount + proofTransferCount, proofItemId);
            seenProofItems[providedTransferCount + proofTransferCount] = proofItemId;

            seenTransfers[transferIndex] = true;
            proofTransferCount += 1;

            unchecked {
                ++i;
            }
        }

        if (batchProof.receiptProof.targetBlockNumber <= bidStartBlock) revert ProofBeforeBid();
        _validateReceiptProof(batchProof.receiptProof);

        for (uint256 i = 0; i < batchProof.transferIndexes.length;) {
            uint256 transferIndex = batchProof.transferIndexes[i];
            BatchTransfer storage expectedTransfer = expectedTransfers[transferIndex];
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
        BatchProof calldata batchProof,
        bool[] memory seenTransfers,
        bytes32[] memory seenProofItems,
        uint256 providedTransferCount,
        uint256 bidStartBlock
    ) internal view returns (uint256 transferIndex) {
        if (batchProof.transferIndexes.length != 1 || batchProof.logIndexes.length != 0) {
            revert InvalidBatchProofLength();
        }

        transferIndex = _validateCollectTransfer(batchProof.transferIndexes[0], seenTransfers);
        BatchTransfer storage expectedTransfer = expectedTransfers[transferIndex];
        if (expectedTransfer.asset != address(0)) revert InvalidProofShape();

        bytes32 proofItemId = keccak256(
            abi.encode(
                uint8(0), // native proof tag
                batchProof.receiptProof.targetBlockNumber,
                batchProof.receiptProof.receiptPath
            )
        );
        _validateProofItemIsUnused(seenProofItems, providedTransferCount, proofItemId);
        seenProofItems[providedTransferCount] = proofItemId;
        seenTransfers[transferIndex] = true;

        if (batchProof.receiptProof.targetBlockNumber <= bidStartBlock) revert ProofBeforeBid();
        _validateNativeProof(batchProof, expectedTransfer.recipient, expectedTransfer.amount);
    }

    function _validateCollectTransfer(uint256 transferIndex, bool[] memory seenTransfers)
        internal
        view
        returns (uint256)
    {
        if (transferIndex >= expectedTransfers.length) revert InvalidTransferIndex();
        if (seenTransfers[transferIndex]) revert DuplicateTransferIndex();
        if (transferBidder[transferIndex] != msg.sender) revert TransferNotInBid();
        return transferIndex;
    }

    function _validateReceiptProof(BatchReceiptProof calldata proof) internal view {
        _validateBlockHeader(proof.blockHeader, proof.targetBlockNumber);

        bytes32 receiptsRoot = BlockHeaderParser.extractReceiptsRoot(proof.blockHeader);
        if (!MPTVerifier.verifyReceiptProof(proof.receiptRlp, proof.proofNodes, proof.receiptPath, receiptsRoot)) {
            revert InvalidReceiptProof();
        }
    }

    function _validateNativeProof(BatchProof calldata batchProof, address expectedRecipient, uint256 expectedAmount)
        internal
        view
    {
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
        if (!ReceiptValidator.validateNativeTransfer(batchProof.transactionRlp, expectedRecipient, expectedAmount)) {
            revert InvalidNativeTransfer();
        }
    }

    function _validateBlockHeader(bytes calldata blockHeader, uint256 targetBlockNumber) internal view {
        if (targetBlockNumber > block.number) revert TargetBlockInFuture();
        if (block.number - targetBlockNumber > MAX_BLOCK_LOOKBACK) revert TargetBlockTooOld();

        bytes32 targetBlockHash = blockhash(targetBlockNumber);
        if (targetBlockHash == bytes32(0)) revert BlockHashUnavailable();
        if (keccak256(blockHeader) != targetBlockHash) revert BlockHeaderMismatch();
        if (BlockHeaderParser.extractBlockNumber(blockHeader) != targetBlockNumber) revert BlockNumberMismatch();
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

    // ============ Internal: bid lifecycle ============

    function _handleExpiredBids() internal {
        uint256 i;
        while (i < bidders.length) {
            if (!_releaseExpiredBid(bidders[i])) {
                unchecked {
                    ++i;
                }
            }
        }
    }

    function _releaseExpiredBid(address bidder) internal returns (bool released) {
        Bid storage activeBid = bids[bidder];
        if (activeBid.expiresAt == 0 || block.timestamp <= activeBid.expiresAt) {
            return false;
        }

        uint256 forfeitedBond = activeBid.bondAmount;
        _clearBid(bidder);

        if (forfeitedBond > 0) {
            currentRewardAmount += forfeitedBond;
        }

        return true;
    }

    function _clearBid(address bidder) internal {
        Bid storage activeBid = bids[bidder];
        if (activeBid.expiresAt == 0) {
            return;
        }

        uint256[] storage indexes = bidTransferIndexes[bidder];
        for (uint256 i = 0; i < indexes.length;) {
            uint256 transferIndex = indexes[i];
            if (transferBidder[transferIndex] == bidder) {
                transferBidder[transferIndex] = address(0);
            }

            unchecked {
                ++i;
            }
        }

        delete bidTransferIndexes[bidder];
        delete bids[bidder];
        _untrackBidder(bidder);
        activeBidCount -= 1;
    }

    function _trackBidder(address bidder) internal {
        if (bidderPositions[bidder] != 0) {
            return;
        }

        bidders.push(bidder);
        bidderPositions[bidder] = bidders.length;
    }

    function _untrackBidder(address bidder) internal {
        uint256 position = bidderPositions[bidder];
        if (position == 0) {
            return;
        }

        uint256 index = position - 1;
        uint256 lastIndex = bidders.length - 1;

        if (index != lastIndex) {
            address lastBidder = bidders[lastIndex];
            bidders[index] = lastBidder;
            bidderPositions[lastBidder] = position;
        }

        bidders.pop();
        delete bidderPositions[bidder];
    }

    function _trackPaymentAsset(address asset) internal {
        if (knownPaymentAsset[asset]) {
            return;
        }

        knownPaymentAsset[asset] = true;
        paymentAssets.push(asset);
    }

    // ============ Internal: reward math + payout ============

    /// @dev `currentReward × completedAmount / currentTransferAmount`.
    function _calculateRewardShare(uint256 amount) internal view returns (uint256) {
        if (amount == 0 || currentRewardAmount == 0) {
            return 0;
        }
        if (amount >= currentTransferAmount) {
            return currentRewardAmount;
        }

        return (currentRewardAmount * amount) / currentTransferAmount;
    }

    function _payoutBid(address bidder, uint256 bidderBondAmount) internal {
        uint256[] storage indexes = bidTransferIndexes[bidder];
        uint256 completedCount = indexes.length;
        bool isFinalCollection = completedTransferCount + completedCount == expectedTransfers.length;

        address[] memory assets = new address[](indexes.length);
        uint256[] memory amounts = new uint256[](indexes.length);
        uint256 completedAmount;
        for (uint256 i = 0; i < indexes.length;) {
            BatchTransfer storage expectedTransfer = expectedTransfers[indexes[i]];
            assets[i] = expectedTransfer.asset;
            amounts[i] = expectedTransfer.amount;
            completedAmount += expectedTransfer.amount;
            currentAssetPaymentAmount[expectedTransfer.asset] -= expectedTransfer.amount;

            unchecked {
                ++i;
            }
        }

        uint256 transferAmountShare = isFinalCollection ? currentTransferAmount : completedAmount;
        uint256 rewardShare = isFinalCollection ? currentRewardAmount : _calculateRewardShare(completedAmount);
        uint256 rewardPayout = bidderBondAmount + rewardShare;
        completedTransferCount += completedCount;
        currentTransferAmount -= transferAmountShare;
        currentRewardAmount -= rewardShare;
        _clearBid(bidder);

        if (isFinalCollection) {
            funded = false;
            currentTransferAmount = 0;
            currentRewardAmount = 0;
        }

        if (rewardPayout > 0) {
            _sendAsset(rewardAsset, bidder, rewardPayout);
        }
        for (uint256 i = 0; i < assets.length;) {
            _sendAsset(assets[i], bidder, amounts[i]);

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
