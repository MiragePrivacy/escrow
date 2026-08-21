// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import "./EscrowBase.sol";
import {StatementHash} from "./StatementHash.sol";
import {NativeVerifier} from "./NativeVerifier.sol";

/// @title Single-row native-ETH escrow settled by a zero-knowledge proof
/// @notice The native counterpart to `EscrowERC20`. Where `EscrowNative` takes
/// a transaction, a receipt and two MPT proofs as calldata and parses them
/// on-chain, this takes a Groth16 proof and checks it against a statement it
/// builds from its own storage.
///
/// The settled recipient and amount are hidden in `intentCommitment`, which is
/// the substantive difference from `EscrowNative`: that contract publishes
/// both as `expectedRecipient` and `expectedAmount`, so anyone reading the
/// chain learns who was paid what. Here the escrow never learns either.
///
/// @dev The verifier differs from the ERC-20 escrow's. Groth16's verifying key
/// is derived from the constraint system, and the native relation is a separate
/// circuit (~17.8M constraints against the ERC-20 path's ~10.4M), so a native
/// proof does not verify against the ERC-20 key or vice versa. Spec 15.1
/// requires the verifier be embedded rather than called, hence the inheritance.
///
/// @dev Spec 12.9 requires both asset paths cost the same to prove, because
/// proving time that identifies the asset kind splits the anonymity set. The
/// two relations have different constraint counts, so that does not hold yet.
/// This is a release gate for mainnet, tracked in the circuits repository.
contract EscrowNativeZK is EscrowBase, NativeVerifier {
    // Custom errors
    error ZeroCommitment();
    error IncorrectETHAmount();
    error AlreadyFunded();
    error ZeroRewardAmount();
    error NoWithdrawableFunds();
    error ETHTransferFailed();
    error WitnessBlockInFuture();
    error WitnessBlockTooOld();
    error WitnessBlockUnavailable();
    error StatementMismatch();

    /// @notice Blocks of witness-block history the escrow will accept.
    ///
    /// Spec 12.10 uses 128 rather than the 256 Solidity documents for
    /// `blockhash`, as a reorg safety margin.
    uint256 public constant MAX_WITNESS_LOOKBACK = 128;

    /// @notice keccak-256 over the settlement details and a salt, spec 8.3.
    ///
    /// Binds recipient, amount, chain, escrow, request and row, with the asset
    /// kind marking it native. The enclave holds the opening; the chain sees
    /// only the digest.
    bytes32 public immutable intentCommitment;

    /// @notice Per-deployment domain separator, spec 16.
    bytes32 public immutable instanceDomain;

    /// @notice Identifies the settlement request this escrow serves.
    bytes32 public immutable requestId;

    /// @notice Row index within the request. Always zero: this escrow is
    /// single-row, but the statement binds it because batch escrows are not.
    uint32 public constant ROW_INDEX = 0;

    /// @notice What the collector is paid on settlement, in ETH.
    ///
    /// Public, and deliberately not the settled amount: the escrow must know
    /// what it owes, and spec 7.3 keeps the settled amount inside the
    /// commitment. Equal values are common but not required -- a node may
    /// settle 1 ETH and be paid a different amount for doing so.
    uint256 public immutable payoutAmount;

    /// @notice The payout asset, fixed to ETH.
    ///
    /// Present so the statement this escrow builds matches the ERC-20 escrow's
    /// shape; spec 10.2 encodes the payout asset in every statement, and the
    /// zero address is how a native payout is written.
    address public constant PAYOUT_ASSET = address(0);

    /// @param _payoutAmount Amount the collector is paid, public.
    /// @param _intentCommitment Spec 8.3 digest hiding the settlement details.
    /// @param _instanceDomain Per-deployment domain separator, spec 16.
    /// @param _requestId Settlement request this escrow serves.
    ///
    /// `expectedRecipient` and `expectedAmount` in the base are set to zero:
    /// the settlement recipient and amount live in the commitment, and writing
    /// them here would publish exactly what the commitment hides.
    constructor(
        uint256 _payoutAmount,
        bytes32 _intentCommitment,
        bytes32 _instanceDomain,
        bytes32 _requestId,
        address _blindedSigner,
        uint256 _currentRewardAmount,
        uint256 _maxGasAdvance
    ) payable EscrowBase(address(0), 0, _blindedSigner, _maxGasAdvance) {
        // A zero commitment would be openable by anyone who guesses the empty
        // preimage, and cannot arise from a correct derivation.
        if (_intentCommitment == bytes32(0)) revert ZeroCommitment();

        payoutAmount = _payoutAmount;
        intentCommitment = _intentCommitment;
        instanceDomain = _instanceDomain;
        requestId = _requestId;

        if (_currentRewardAmount > 0) {
            _validateGasAdvanceBudget(_currentRewardAmount);
            if (msg.value != _currentRewardAmount + _payoutAmount) revert IncorrectETHAmount();
            currentRewardAmount = _currentRewardAmount;
            originalRewardAmount = _currentRewardAmount;
            currentPaymentAmount = _payoutAmount;
            funded = true;
        }
    }

    /// Takes currentRewardAmount + the payout as ETH. The sender deposits no
    /// execution-gas surcharge; Nomad provisions executor gas.
    function fund(uint256 _currentRewardAmount) external payable {
        if (msg.sender != deployerAddress) revert OnlyDeployer();
        if (funded) revert AlreadyFunded();
        if (_currentRewardAmount == 0) revert ZeroRewardAmount();
        _validateGasAdvanceBudget(_currentRewardAmount);
        if (msg.value != _currentRewardAmount + payoutAmount) revert IncorrectETHAmount();

        currentRewardAmount = _currentRewardAmount;
        originalRewardAmount = _currentRewardAmount;
        currentPaymentAmount = payoutAmount;
        gasAdvanceClaimed = false;
        funded = true;
    }

    function _releaseGasAdvance(address executor, uint256 gasAdvance) internal override {
        (bool success,) = executor.call{value: gasAdvance}("");
        if (!success) revert GasAdvanceTransferFailed();
    }

    /// @notice Verify a native settlement proof and pay the bonded collector.
    /// @param proof Groth16 proof points, EIP-197 order.
    /// @param signals The statement's two public signals, checked against the
    /// escrow's own computation before use.
    /// @param witnessBlockNumber A recent block whose hash anchors the proof.
    ///
    /// The escrow parses neither the transaction nor the receipt. It reads
    /// `blockhash` -- unforgeable, EVM-supplied -- and hashes it into the
    /// statement. The circuit holds both privately and proves the header hashes
    /// to that value, that its `transactionsRoot` admits a transaction paying
    /// the committed recipient the committed amount, and that its
    /// `receiptsRoot` admits that transaction's receipt with status 1.
    ///
    /// Proving both tries is what makes this a settlement rather than an
    /// attempt: a reverted transaction still sits in the transactions trie
    /// carrying a `to` and a `value`.
    ///
    /// Gated by the OnlyBondedExecutor guard: the ECDH signature was spent at
    /// bond(), so the bonded EOA is thereafter the only caller.
    function collect(uint256[8] calldata proof, uint256[2] calldata signals, uint64 witnessBlockNumber) external {
        bytes32 witnessBlockHash = _validateWitnessBlock(witnessBlockNumber);

        uint256[2] memory expected = _statementSignals(witnessBlockNumber, witnessBlockHash);
        if (signals[0] != expected[0] || signals[1] != expected[1]) revert StatementMismatch();

        // Reverts with ProofInvalid or PublicInputNotInField if the proof does
        // not verify, which reverts the whole collection.
        verifyProof(proof, signals);

        _payout();
    }

    /// @notice The two public signals for the statement this escrow will accept.
    /// @dev Exposed so the collector can build a matching statement off-chain
    /// before proving, rather than discovering a mismatch as a bare revert.
    function statementSignals(uint64 witnessBlockNumber) external view returns (uint256[2] memory) {
        return _statementSignals(witnessBlockNumber, blockhash(witnessBlockNumber));
    }

    /// Checks the witness block is recent, real, and after the bond started,
    /// then returns its hash.
    function _validateWitnessBlock(uint64 witnessBlockNumber) internal view returns (bytes32) {
        if (!funded) revert NotFunded();
        if (msg.sender != bondedExecutor || !is_bonded()) revert OnlyBondedExecutor();
        if (witnessBlockNumber >= block.number) revert WitnessBlockInFuture();
        if (block.number - witnessBlockNumber > MAX_WITNESS_LOOKBACK) revert WitnessBlockTooOld();
        if (witnessBlockNumber <= bondStartBlock) revert ProofBeforeBond();

        bytes32 witnessBlockHash = blockhash(witnessBlockNumber);
        if (witnessBlockHash == bytes32(0)) revert WitnessBlockUnavailable();
        return witnessBlockHash;
    }

    /// Builds the spec 10.2 statement from contract state and returns its two
    /// public signals.
    function _statementSignals(uint64 witnessBlockNumber, bytes32 witnessBlockHash)
        internal
        view
        returns (uint256[2] memory)
    {
        return StatementHash.signals(
            StatementHash.Context({
                instanceDomain: instanceDomain,
                chainId: block.chainid,
                escrow: address(this),
                requestId: requestId,
                rowIndex: ROW_INDEX,
                intentCommitment: intentCommitment,
                bondAttempt: bondAttempt,
                bondStartBlock: uint64(bondStartBlock),
                bondDeadline: uint64(executionDeadline),
                bondedCollector: bondedExecutor,
                rowPayoutAsset: PAYOUT_ASSET,
                rowPayoutAmount: _calculatePayout(),
                witnessBlockNumber: witnessBlockNumber,
                witnessBlockHash: witnessBlockHash
            })
        );
    }

    function _payout() internal {
        uint256 payout = _calculatePayout();
        address executor = bondedExecutor;

        _clearPayoutState();

        (bool success,) = executor.call{value: payout}("");
        if (!success) revert ETHTransferFailed();
    }

    /// @notice Cancel and withdraw funds in a single transaction.
    /// Reverts if a node has already bonded.
    function cancelAndWithdraw() external {
        cancellationRequest = true;
        _validateWithdraw();
        _tryResetBondData();

        uint256 withdrawableAmount = _calculateWithdrawableAmount();
        _clearWithdrawState();

        if (withdrawableAmount == 0) revert NoWithdrawableFunds();

        (bool success,) = msg.sender.call{value: withdrawableAmount}("");
        if (!success) revert ETHTransferFailed();
    }
}
