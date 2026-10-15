// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {EscrowBatch} from "./EscrowBatch.sol";
import {StatementHash} from "./StatementHash.sol";
import {BatchVerifier} from "./BatchVerifier.sol";
import {BatchNativeVerifier} from "./BatchNativeVerifier.sol";

/// @notice Progressive batch settlement with one Groth16 proof per row.
/// @dev Clients must reject overlapping identical settlement intents.
contract EscrowBatchZK is EscrowBatch {
    struct Row {
        address asset;
        uint256 amount;
        uint256 valueWeight;
        bytes32 intentCommitment;
    }

    struct RowProof {
        uint32 rowIndex;
        uint64 witnessBlockNumber;
        uint256[8] proof;
        uint256[2] signals;
    }

    error ZeroCommitment();
    error StatementMismatch();
    error PlaintextProofDisabled();
    error BondBlockDeadlineExpired();

    bytes32 public immutable instanceDomain;
    bytes32 public immutable requestHash;
    mapping(uint256 => bytes32) public intentCommitments;
    mapping(address => uint32) public bondAttempts;
    mapping(address => uint64) public bondBlockDeadlines;
    uint256 public constant MAX_WITNESS_LOOKBACK = 128;
    uint64 public constant BOND_BLOCKS = 75;

    constructor(
        address rewardAsset_,
        Row[] memory rows,
        uint256 rewardAmount,
        uint256 gasAdvance,
        address[] memory signers,
        bytes32 domain,
        bytes32 requestId
    ) payable EscrowBatch(rewardAsset_, _payoutRows(rows), rewardAmount, gasAdvance, signers) {
        instanceDomain = domain;
        requestHash = requestId;
        for (uint256 i; i < rows.length; ++i) {
            if (rows[i].intentCommitment == bytes32(0)) revert ZeroCommitment();
            intentCommitments[i] = rows[i].intentCommitment;
        }
    }

    function _payoutRows(Row[] memory rows) private pure returns (BatchTransfer[] memory payouts) {
        payouts = new BatchTransfer[](rows.length);
        for (uint256 i; i < rows.length; ++i) {
            payouts[i] = BatchTransfer(rows[i].asset, address(1), rows[i].amount, rows[i].valueWeight);
        }
    }

    function _bidExpiry() internal view override returns (uint256) {
        return block.timestamp + 15 minutes;
    }

    function _onBid(address bidder) internal override {
        bondAttempts[bidder] += 1;
        bondBlockDeadlines[bidder] = uint64(block.number) + BOND_BLOCKS;
    }

    function collect(BatchProof[] calldata) external pure override {
        revert PlaintextProofDisabled();
    }

    function collectRows(RowProof[] calldata proofs) external nonReentrant {
        _handleExpiredBids();
        if (!funded) revert NotFunded();
        Bid storage activeBid = bids[msg.sender];
        if (activeBid.expiresAt == 0 || block.timestamp > activeBid.expiresAt) revert OnlyActiveBidder();
        if (block.number > bondBlockDeadlines[msg.sender]) revert BondBlockDeadlineExpired();
        if (proofs.length == 0 || proofs.length > expectedTransfers.length) revert MalformedProof();
        uint256[] memory indexes = new uint256[](proofs.length);
        for (uint256 i; i < proofs.length; ++i) {
            RowProof calldata row = proofs[i];
            indexes[i] = _validateCollectTransfer(row.rowIndex, indexes, i);
            if (row.witnessBlockNumber >= block.number) revert TargetBlockInFuture();
            if (block.number - row.witnessBlockNumber > MAX_WITNESS_LOOKBACK) revert TargetBlockTooOld();
            if (row.witnessBlockNumber <= activeBid.startBlock) revert ProofBeforeBid();
            bytes32 witnessHash = blockhash(row.witnessBlockNumber);
            if (witnessHash == bytes32(0)) revert BlockHashUnavailable();
            uint256[2] memory expected =
                StatementHash.signals(_statement(row.rowIndex, row.witnessBlockNumber, witnessHash));
            if (row.signals[0] != expected[0] || row.signals[1] != expected[1]) revert StatementMismatch();
            _verifyRow(row, expectedTransfers[row.rowIndex].asset == address(0));
        }
        _settleProvedRows(msg.sender, indexes, proofs.length);
    }

    function _verifyRow(RowProof calldata row, bool nativeAsset) internal view virtual {
        if (nativeAsset) BatchNativeVerifier.verifyProof(row.proof, row.signals);
        else BatchVerifier.verifyProof(row.proof, row.signals);
    }

    function rowStatement(uint32 rowIndex, uint64 witnessBlockNumber)
        external
        view
        returns (StatementHash.Context memory)
    {
        return _statement(rowIndex, witnessBlockNumber, blockhash(witnessBlockNumber));
    }

    function rowStatementSignals(uint32 rowIndex, uint64 witnessBlockNumber) external view returns (uint256[2] memory) {
        return StatementHash.signals(_statement(rowIndex, witnessBlockNumber, blockhash(witnessBlockNumber)));
    }

    function _statement(uint32 rowIndex, uint64 witnessBlockNumber, bytes32 witnessHash)
        internal
        view
        returns (StatementHash.Context memory)
    {
        if (rowIndex >= expectedTransfers.length) revert InvalidTransferIndex();
        address bidder = transferBidder[rowIndex];
        Bid storage lease = bids[bidder];
        BatchTransfer storage row = expectedTransfers[rowIndex];
        return StatementHash.Context({
            instanceDomain: instanceDomain,
            chainId: block.chainid,
            escrow: address(this),
            requestId: requestHash,
            rowIndex: rowIndex,
            intentCommitment: intentCommitments[rowIndex],
            bondAttempt: bondAttempts[bidder],
            bondStartBlock: uint64(lease.startBlock),
            bondDeadline: bondBlockDeadlines[bidder],
            bondedCollector: bidder,
            rowPayoutAsset: row.asset,
            rowPayoutAmount: row.amount,
            witnessBlockNumber: witnessBlockNumber,
            witnessBlockHash: witnessHash
        });
    }
}
