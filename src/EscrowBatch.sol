// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "./BlockHeaderParser.sol";
import "./MPTVerifier.sol";
import "./ReceiptValidator.sol";
import "./utils/ECDSA.sol";

/// @title EscrowBatch
/// @notice Multi-transfer escrow with first-come, signature-gated execution.
/// Bidders commit to selected rows using a one-time blinded Nomad signer.
/// Proven rows settle permanently, while unfinished rows remain reserved until
/// the bid expires. Expired bids release only their unfinished rows.
contract EscrowBatch {
    using SafeERC20 for IERC20;

    // ============ Types ============

    struct BatchTransfer {
        address asset;
        address recipient;
        uint256 amount;
        uint256 valueWeight;
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
    /// `bidTransferIndexes[bidder]` and valid until `expiresAt`. Entry requires a
    /// one-time blinded-signer authorization. `startBlock` rejects proofs of
    /// transfers that happened before the bid existed.
    struct Bid {
        uint256 remainingRows;
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
    error BidNotExpired();
    error CancellationRequested();
    error BidderHasActiveBid();
    error EmptyBlindedSigners();
    error ZeroBlindedSigner();
    error DuplicateBlindedSigner();
    error InvalidBidSignature();
    error BlindedSignerAlreadyUsed();
    error TooManyRows();
    error TooManyBlindedSigners();
    error ZeroAddress();
    error EmptyBatch();
    error EmptyBid();
    error ZeroRewardAmount();
    error ZeroPaymentAmount();
    error ZeroValueWeight();
    error AlreadyFunded();
    error ETHTransferFailed();
    error IncorrectNativeAmount();
    error MalformedProof();
    error ProofVerificationFailed();
    error ProofContentMismatch();
    error DuplicateProofItem();
    error ProofBeforeBid();
    error InvalidTransferIndex();
    error TransferStateConflict();
    error Reentrancy();

    // ============ Storage ============

    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _BOND_TYPEHASH =
        keccak256("BatchBondAuth(address bondingExecutor,uint256[] transferIndexes)");
    bytes32 private constant _NAME_HASH = keccak256("MirageEscrow");
    bytes32 private constant _VERSION_HASH = keccak256("1");
    bytes32 private immutable _domainSeparator;

    address public immutable deployerAddress;
    address public immutable rewardAsset;
    uint256 public immutable totalTransferAmount;
    uint256 public immutable totalValueWeight;

    uint256 public currentRewardAmount;
    uint256 public currentTransferAmount;
    uint256 public currentValueWeight;
    uint256 public originalRewardAmount;
    uint256 public completedTransferCount;
    uint256 public activeBidCount;

    uint256 public constant MAX_BLOCK_LOOKBACK = 256;
    uint256 public constant BID_DURATION = 5 minutes;
    uint256 public constant MAX_ROWS = 256;
    uint256 public constant MAX_BLINDED_SIGNERS = 256;
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    BatchTransfer[] public expectedTransfers;
    address[] private blindedSigners;
    mapping(address => bool) public isBlindedSigner;
    mapping(address => bool) public blindedSignerUsed;

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
    mapping(bytes32 => bool) public consumedProofItems;
    mapping(address => mapping(address => uint256)) public claimable;

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

    // Tags used to build a unique ID for each proved ERC-20 log or native
    // transaction. Consumed IDs are stored permanently so one transfer proof
    // cannot settle another row in the same or a later collect() call.
    bytes32 private constant ERC20_PROOF_TAG = keccak256("MIRAGE_ERC20_PROOF_V1");
    bytes32 private constant NATIVE_PROOF_TAG = keccak256("MIRAGE_NATIVE_PROOF_V1");

    constructor(
        address _rewardAsset,
        BatchTransfer[] memory _expectedTransfers,
        uint256 _currentRewardAmount,
        address[] memory _blindedSigners
    ) payable {
        if (_expectedTransfers.length == 0) revert EmptyBatch();
        if (_expectedTransfers.length > MAX_ROWS) revert TooManyRows();
        if (_blindedSigners.length == 0) revert EmptyBlindedSigners();
        if (_blindedSigners.length > MAX_BLINDED_SIGNERS) revert TooManyBlindedSigners();

        rewardAsset = _rewardAsset;
        deployerAddress = msg.sender;
        _domainSeparator =
            keccak256(abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this)));

        for (uint256 i = 0; i < _blindedSigners.length;) {
            address signer = _blindedSigners[i];
            if (signer == address(0)) revert ZeroBlindedSigner();
            if (isBlindedSigner[signer]) revert DuplicateBlindedSigner();
            isBlindedSigner[signer] = true;
            blindedSigners.push(signer);

            unchecked {
                ++i;
            }
        }

        uint256 totalAmount;
        uint256 totalWeight;
        for (uint256 i = 0; i < _expectedTransfers.length;) {
            BatchTransfer memory expectedTransfer = _expectedTransfers[i];
            _validateExpectedTransfer(expectedTransfer);

            _trackPaymentAsset(expectedTransfer.asset);
            totalAssetPaymentAmount[expectedTransfer.asset] += expectedTransfer.amount;
            totalAmount += expectedTransfer.amount;
            totalWeight += expectedTransfer.valueWeight;
            expectedTransfers.push(expectedTransfer);

            unchecked {
                ++i;
            }
        }

        totalTransferAmount = totalAmount;
        totalValueWeight = totalWeight;

        if (_currentRewardAmount > 0) {
            _fund(_currentRewardAmount);
        } else if (msg.value != 0) {
            revert IncorrectNativeAmount();
        }
    }

    // ============ View functions ============

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparator;
    }

    function blindedSignerCount() external view returns (uint256) {
        return blindedSigners.length;
    }

    function blindedSignerAt(uint256 index) external view returns (address signer, bool used) {
        signer = blindedSigners[index];
        used = blindedSignerUsed[signer];
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

    function bidTransferCount(address bidder) external view returns (uint256) {
        return bidTransferIndexes[bidder].length;
    }

    function bidTransferIndex(address bidder, uint256 position) external view returns (uint256) {
        return bidTransferIndexes[bidder][position];
    }

    /// @notice Whether at least one bid is still inside its execution window.
    function is_bonded() public view returns (bool) {
        for (uint256 i = 0; i < bidders.length;) {
            if (bids[bidders[i]].expiresAt >= block.timestamp) return true;

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
        currentValueWeight = 0;

        bool rewardAssetWithdrawn;
        for (uint256 i = 0; i < assets.length;) {
            address asset = assets[i];
            uint256 amount = currentAssetPaymentAmount[asset];
            if (asset == rewardAsset) {
                amount += rewardAmount;
                rewardAssetWithdrawn = true;
            }

            amounts[i] = amount;
            currentAssetPaymentAmount[asset] = 0;

            unchecked {
                ++i;
            }
        }

        for (uint256 i = 0; i < assets.length;) {
            if (amounts[i] > 0) {
                _sendAsset(assets[i], msg.sender, amounts[i]);
            }

            unchecked {
                ++i;
            }
        }
        if (!rewardAssetWithdrawn && rewardAmount > 0) {
            _sendAsset(rewardAsset, msg.sender, rewardAmount);
        }
    }

    // ============ Bidder entrypoints ============

    /// @notice Place a free bid on a subset of expected transfers.
    /// @dev The signature binds this escrow, chain, bidder, and exact row indexes.
    /// Its recovered blinded signer must be constructor-approved and unused.
    function bid(uint256[] calldata transferIndexes, bytes calldata bidSignature) external nonReentrant {
        _handleExpiredBids();
        _validateBidRequirements(transferIndexes);

        address signer = ECDSA.recover(_hashBidAuthorization(msg.sender, transferIndexes), bidSignature);
        if (!isBlindedSigner[signer]) revert InvalidBidSignature();
        if (blindedSignerUsed[signer]) revert BlindedSignerAlreadyUsed();

        _validateBidIndexes(transferIndexes);
        blindedSignerUsed[signer] = true;

        _trackBidder(msg.sender);

        Bid storage placedBid = bids[msg.sender];
        placedBid.remainingRows = transferIndexes.length;
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
    }

    /// @notice Permanently settle a non-empty proved subset of the caller's active bid.
    /// @dev Unproved rows remain reserved under the same bid and deadline. After
    /// completing all state changes, settlement attempts to pay each asset directly.
    /// Only a failed asset payout is retained in `claimable` for later withdrawal.
    function collect(BatchProof[] calldata proofs) external nonReentrant {
        _handleExpiredBids();
        Bid storage activeBid = bids[msg.sender];
        if (!funded) revert NotFunded();
        if (activeBid.expiresAt == 0 || block.timestamp > activeBid.expiresAt) revert OnlyActiveBidder();
        if (proofs.length == 0) revert MalformedProof();

        uint256 provedTransferCapacity;
        for (uint256 i = 0; i < proofs.length;) {
            uint256 proofTransferCount = proofs[i].transferIndexes.length;
            if (proofTransferCount == 0) revert MalformedProof();
            provedTransferCapacity += proofTransferCount;
            if (provedTransferCapacity > expectedTransfers.length) revert MalformedProof();

            unchecked {
                ++i;
            }
        }

        bytes32[] memory seenProofItems = new bytes32[](provedTransferCapacity);
        uint256[] memory provedTransferIndexes = new uint256[](provedTransferCapacity);
        uint256 providedTransferCount;

        for (uint256 proofIndex = 0; proofIndex < proofs.length;) {
            BatchProof calldata batchProof = proofs[proofIndex];

            uint256 firstTransferIndex = batchProof.transferIndexes[0];
            if (firstTransferIndex >= expectedTransfers.length) revert InvalidTransferIndex();

            address firstAsset = expectedTransfers[firstTransferIndex].asset;
            uint256 proofTransferCount;
            if (firstAsset == address(0)) {
                _validateNativeBatchProof(
                    batchProof, provedTransferIndexes, seenProofItems, providedTransferCount, activeBid.startBlock
                );
                proofTransferCount = 1;
            } else {
                proofTransferCount = _validateERC20BatchProof(
                    batchProof, provedTransferIndexes, seenProofItems, providedTransferCount, activeBid.startBlock
                );
            }

            providedTransferCount += proofTransferCount;

            unchecked {
                ++proofIndex;
            }
        }

        for (uint256 i = 0; i < providedTransferCount;) {
            consumedProofItems[seenProofItems[i]] = true;

            unchecked {
                ++i;
            }
        }

        _settleProvedRows(msg.sender, provedTransferIndexes, providedTransferCount);
    }

    /// @notice Withdraw the caller's accrued settlement claim for one asset.
    /// @dev State is cleared before the external transfer. A failed transfer
    /// reverts and restores the claim, without affecting already-settled rows.
    function withdrawClaim(address asset) external nonReentrant {
        uint256 amount = claimable[msg.sender][asset];
        if (amount == 0) revert ZeroPaymentAmount();

        claimable[msg.sender][asset] = 0;
        _sendAsset(asset, msg.sender, amount);
    }

    /// @notice Release one expired bid's unfinished rows.
    /// @dev This permissionless entrypoint allows proactive cleanup even though
    /// normal bid, collect, and cancellation calls also clear expired bids.
    function expireBid(address bidder) external nonReentrant {
        if (!_releaseExpiredBid(bidder)) revert BidNotExpired();
    }

    /// @notice Release any expired bids in a caller-supplied bounded list.
    /// @dev Active, missing, and duplicate entries are skipped so one stale
    /// input cannot prevent other expired bids from being cleaned up.
    function expireBids(address[] calldata expiredBidders) external nonReentrant returns (uint256 expiredBidCount) {
        for (uint256 i = 0; i < expiredBidders.length;) {
            if (_releaseExpiredBid(expiredBidders[i])) {
                expiredBidCount += 1;
            }

            unchecked {
                ++i;
            }
        }
    }

    // ============ Internal: bid authorization ============

    function _hashBidAuthorization(address bondingExecutor, uint256[] calldata transferIndexes)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash =
            keccak256(abi.encode(_BOND_TYPEHASH, bondingExecutor, keccak256(abi.encodePacked(transferIndexes))));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator, structHash));
    }

    // ============ Internal: funding ============

    function _fund(uint256 _currentRewardAmount) internal {
        if (_currentRewardAmount == 0) revert ZeroRewardAmount();

        // msg.value must cover any native transfers in the batch plus, if the
        // reward currency is ETH, the reward amount itself.
        uint256 nativeOwed = totalAssetPaymentAmount[address(0)];
        if (rewardAsset == address(0)) {
            nativeOwed += _currentRewardAmount;
        }
        if (msg.value != nativeOwed) revert IncorrectNativeAmount();

        currentRewardAmount = _currentRewardAmount;
        originalRewardAmount = _currentRewardAmount;
        currentTransferAmount = totalTransferAmount;
        currentValueWeight = totalValueWeight;
        completedTransferCount = 0;
        hasBeenFunded = true;
        funded = true;

        bool rewardAssetFunded;
        for (uint256 i = 0; i < paymentAssets.length;) {
            address asset = paymentAssets[i];
            uint256 amount = totalAssetPaymentAmount[asset];
            currentAssetPaymentAmount[asset] = amount;

            if (asset == rewardAsset) {
                amount += _currentRewardAmount;
                rewardAssetFunded = true;
            }

            if (asset != address(0)) IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

            unchecked {
                ++i;
            }
        }

        if (!rewardAssetFunded && rewardAsset != address(0)) {
            IERC20(rewardAsset).safeTransferFrom(msg.sender, address(this), _currentRewardAmount);
        }
    }

    // ============ Internal: validation ============

    function _validateExpectedTransfer(BatchTransfer memory expectedTransfer) internal pure {
        if (expectedTransfer.recipient == address(0)) revert ZeroAddress();
        if (expectedTransfer.amount == 0) revert ZeroPaymentAmount();
        if (expectedTransfer.valueWeight == 0) revert ZeroValueWeight();
    }

    function _validateBidRequirements(uint256[] calldata transferIndexes) internal view {
        if (!funded) revert NotFunded();
        if (cancellationRequest) revert CancellationRequested();
        if (transferIndexes.length == 0) revert EmptyBid();
        if (bids[msg.sender].expiresAt > 0) revert BidderHasActiveBid();
    }

    function _validateBidIndexes(uint256[] calldata transferIndexes) internal view {
        bool[] memory seenTransfers = new bool[](expectedTransfers.length);

        for (uint256 i = 0; i < transferIndexes.length;) {
            uint256 transferIndex = transferIndexes[i];
            if (transferIndex >= expectedTransfers.length) revert InvalidTransferIndex();
            if (seenTransfers[transferIndex]) revert DuplicateProofItem();
            if (transferCompleted[transferIndex]) revert TransferStateConflict();
            if (transferBidder[transferIndex] != address(0)) revert TransferStateConflict();

            seenTransfers[transferIndex] = true;

            unchecked {
                ++i;
            }
        }
    }

    function _validateERC20BatchProof(
        BatchProof calldata batchProof,
        uint256[] memory seenTransferIndexes,
        bytes32[] memory seenProofItems,
        uint256 providedTransferCount,
        uint256 bidStartBlock
    ) internal view returns (uint256 proofTransferCount) {
        if (batchProof.transferIndexes.length != batchProof.logIndexes.length) {
            revert MalformedProof();
        }
        for (uint256 i = 0; i < batchProof.transferIndexes.length;) {
            uint256 seenCount = providedTransferCount + proofTransferCount;
            uint256 transferIndex =
                _validateCollectTransfer(batchProof.transferIndexes[i], seenTransferIndexes, seenCount);
            BatchTransfer storage expectedTransfer = expectedTransfers[transferIndex];
            if (expectedTransfer.asset == address(0)) revert MalformedProof();

            bytes32 proofItemId = keccak256(
                abi.encode(
                    ERC20_PROOF_TAG,
                    batchProof.receiptProof.targetBlockNumber,
                    batchProof.receiptProof.receiptPath,
                    batchProof.logIndexes[i]
                )
            );
            _validateProofItemIsUnused(seenProofItems, seenCount, proofItemId);
            seenProofItems[seenCount] = proofItemId;

            seenTransferIndexes[seenCount] = transferIndex;
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
                )) revert ProofContentMismatch();

            unchecked {
                ++i;
            }
        }
    }

    function _validateNativeBatchProof(
        BatchProof calldata batchProof,
        uint256[] memory seenTransferIndexes,
        bytes32[] memory seenProofItems,
        uint256 providedTransferCount,
        uint256 bidStartBlock
    ) internal view returns (uint256 transferIndex) {
        if (batchProof.transferIndexes.length != 1 || batchProof.logIndexes.length != 0) {
            revert MalformedProof();
        }

        transferIndex =
            _validateCollectTransfer(batchProof.transferIndexes[0], seenTransferIndexes, providedTransferCount);
        BatchTransfer storage expectedTransfer = expectedTransfers[transferIndex];
        if (expectedTransfer.asset != address(0)) revert MalformedProof();

        bytes32 proofItemId = keccak256(
            abi.encode(NATIVE_PROOF_TAG, batchProof.receiptProof.targetBlockNumber, batchProof.receiptProof.receiptPath)
        );
        _validateProofItemIsUnused(seenProofItems, providedTransferCount, proofItemId);
        seenProofItems[providedTransferCount] = proofItemId;
        seenTransferIndexes[providedTransferCount] = transferIndex;

        if (batchProof.receiptProof.targetBlockNumber <= bidStartBlock) revert ProofBeforeBid();
        _validateNativeProof(batchProof, expectedTransfer.recipient, expectedTransfer.amount);
    }

    function _validateCollectTransfer(
        uint256 transferIndex,
        uint256[] memory seenTransferIndexes,
        uint256 seenTransferCount
    ) internal view returns (uint256) {
        if (transferIndex >= expectedTransfers.length) {
            revert InvalidTransferIndex();
        }
        if (transferBidder[transferIndex] != msg.sender) revert TransferStateConflict();

        for (uint256 i = 0; i < seenTransferCount;) {
            if (seenTransferIndexes[i] == transferIndex) revert DuplicateProofItem();

            unchecked {
                ++i;
            }
        }

        return transferIndex;
    }

    function _validateReceiptProof(BatchReceiptProof calldata proof) internal view {
        _validateBlockHeader(proof.blockHeader, proof.targetBlockNumber);

        bytes32 receiptsRoot = BlockHeaderParser.extractReceiptsRoot(proof.blockHeader);
        if (!MPTVerifier.verifyReceiptProof(proof.receiptRlp, proof.proofNodes, proof.receiptPath, receiptsRoot)) {
            revert ProofVerificationFailed();
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
            )) revert ProofVerificationFailed();

        bytes32 receiptsRoot = BlockHeaderParser.extractReceiptsRoot(batchProof.receiptProof.blockHeader);
        if (!MPTVerifier.verifyReceiptProof(
                batchProof.receiptProof.receiptRlp,
                batchProof.receiptProof.proofNodes,
                batchProof.receiptProof.receiptPath,
                receiptsRoot
            )) revert ProofVerificationFailed();

        if (!ReceiptValidator.validateReceiptStatus(batchProof.receiptProof.receiptRlp)) {
            revert ProofVerificationFailed();
        }
        if (!ReceiptValidator.validateNativeTransfer(batchProof.transactionRlp, expectedRecipient, expectedAmount)) {
            revert ProofContentMismatch();
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
        view
    {
        if (consumedProofItems[proofItemId]) revert DuplicateProofItem();

        for (uint256 i = 0; i < seenCount;) {
            if (seenProofItems[i] == proofItemId) revert DuplicateProofItem();

            unchecked {
                ++i;
            }
        }
    }

    // ============ Internal: bid lifecycle ============

    /// @dev Automatically release every expired bid. Blinded signers cap who
    /// can create bids, while MAX_ROWS and MAX_BLINDED_SIGNERS bound this scan.
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

        _clearBid(bidder);

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

    // ============ Internal: reward math + settlement ============

    /// @dev `currentReward × completedWeight / currentValueWeight`.
    function _calculateRewardShare(uint256 weight) internal view returns (uint256) {
        if (weight == 0 || currentRewardAmount == 0) {
            return 0;
        }
        if (weight >= currentValueWeight) {
            return currentRewardAmount;
        }

        return Math.mulDiv(currentRewardAmount, weight, currentValueWeight);
    }

    function _settleProvedRows(address bidder, uint256[] memory provedTransferIndexes, uint256 provedTransferCount)
        internal
    {
        Bid storage activeBid = bids[bidder];
        address[] memory assets = new address[](provedTransferCount + 1);
        uint256[] memory amounts = new uint256[](provedTransferCount + 1);
        uint256 assetCount;
        uint256 completedAmount;
        uint256 completedWeight;

        for (uint256 i = 0; i < provedTransferCount;) {
            uint256 transferIndex = provedTransferIndexes[i];
            BatchTransfer storage expectedTransfer = expectedTransfers[transferIndex];
            transferCompleted[transferIndex] = true;
            transferBidder[transferIndex] = address(0);
            currentAssetPaymentAmount[expectedTransfer.asset] -= expectedTransfer.amount;

            assetCount = _addAssetAmount(assets, amounts, assetCount, expectedTransfer.asset, expectedTransfer.amount);
            completedAmount += expectedTransfer.amount;
            completedWeight += expectedTransfer.valueWeight;

            unchecked {
                ++i;
            }
        }

        bool isFinalCollection = completedTransferCount + provedTransferCount == expectedTransfers.length;
        uint256 rewardShare = isFinalCollection ? currentRewardAmount : _calculateRewardShare(completedWeight);

        activeBid.remainingRows -= provedTransferCount;

        completedTransferCount += provedTransferCount;
        currentTransferAmount -= completedAmount;
        currentValueWeight -= completedWeight;
        currentRewardAmount -= rewardShare;

        if (rewardShare > 0) {
            assetCount = _addAssetAmount(assets, amounts, assetCount, rewardAsset, rewardShare);
        }

        if (activeBid.remainingRows == 0) {
            _clearBid(bidder);
        }

        if (isFinalCollection) {
            funded = false;
            currentTransferAmount = 0;
            currentValueWeight = 0;
            currentRewardAmount = 0;
        }

        // Payouts happen only after row, reward, and bid state is terminal. A
        // failing token/native transfer therefore becomes a claim instead of
        // reverting valid proofs and reopening completed rows.
        for (uint256 i = 0; i < assetCount;) {
            if (!_trySendAsset(assets[i], bidder, amounts[i])) {
                claimable[bidder][assets[i]] += amounts[i];
            }

            unchecked {
                ++i;
            }
        }
    }

    function _addAssetAmount(
        address[] memory assets,
        uint256[] memory amounts,
        uint256 assetCount,
        address asset,
        uint256 amount
    ) internal pure returns (uint256) {
        for (uint256 i = 0; i < assetCount;) {
            if (assets[i] == asset) {
                amounts[i] += amount;
                return assetCount;
            }

            unchecked {
                ++i;
            }
        }

        assets[assetCount] = asset;
        amounts[assetCount] = amount;
        return assetCount + 1;
    }

    function _sendAsset(address asset, address to, uint256 amount) internal {
        if (asset == address(0)) {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert ETHTransferFailed();
        } else {
            _sendERC20(asset, to, amount);
        }
    }

    function _trySendAsset(address asset, address to, uint256 amount) internal returns (bool) {
        if (asset == address(0)) {
            (bool success,) = to.call{value: amount}("");
            return success;
        }

        return IERC20(asset).trySafeTransfer(to, amount);
    }

    function _sendERC20(address asset, address to, uint256 amount) internal {
        IERC20(asset).safeTransfer(to, amount);
    }
}
