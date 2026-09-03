// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./EscrowBase.sol";
import {StatementHash} from "./StatementHash.sol";
import {Verifier} from "./Verifier.sol";

/// @title Single-row ERC-20 escrow settled by a zero-knowledge receipt proof
/// @notice The settlement is hidden behind `intentCommitment`. Where this
/// contract previously took an RLP receipt, an MPT proof and a block header as
/// calldata and parsed them on-chain, it now takes a Groth16 proof and checks
/// it against a statement it builds from its own storage.
///
/// The escrow never sees the token, recipient or amount that settled. It knows
/// only that some settlement matching its commitment was included in a block
/// descending from a hash the EVM handed it.
///
/// Spec 15.1 requires the verifier be embedded rather than called, so escrows
/// share no deployed contract; hence the inheritance.
contract EscrowERC20 is EscrowBase, Verifier {
    using SafeERC20 for IERC20;

    // Custom errors
    error ZeroAddress();
    error ZeroCommitment();
    error AlreadyFunded();
    error ZeroRewardAmount();
    error NoWithdrawableFunds();
    error WitnessBlockInFuture();
    error WitnessBlockTooOld();
    error WitnessBlockUnavailable();
    error StatementMismatch();

    /// @notice Blocks of witness-block history the escrow will accept.
    ///
    /// Spec 12.10 uses 128 rather than the 256 Solidity documents for
    /// `blockhash`, as a reorg safety margin.
    uint256 public constant MAX_WITNESS_LOOKBACK = 128;

    /// @notice The asset this escrow pays the collector in.
    ///
    /// Distinct from the settlement asset, which is hidden in the commitment.
    /// Spec 7.3 keeps them separate: the payout asset must be public because
    /// the escrow transfers it, and they are not required to match.
    address public immutable payoutAsset;

    /// @notice keccak-256 over the settlement details and a salt, spec 8.3.
    ///
    /// Binds token, recipient, amount, chain, escrow, request and row. The
    /// enclave holds the opening; the chain sees only the digest.
    bytes32 public immutable intentCommitment;

    /// @notice Per-deployment domain separator, spec 16.
    bytes32 public immutable instanceDomain;

    /// @notice Identifies the settlement request this escrow serves.
    ///
    /// Named `requestHash` rather than `requestId` so its selector carries no
    /// leading zero byte: solc emits such a selector as a truncated PUSH, which
    /// the bytecode obfuscator does not recognise as a dispatcher entry.
    bytes32 public immutable requestHash;

    /// @notice Row index within the request. Always zero: this escrow is
    /// single-row, but the statement binds it because batch escrows are not.
    uint32 public constant ROW_INDEX = 0;

    /// @notice What the collector is paid on settlement, in `payoutAsset`.
    ///
    /// Public, and deliberately not the settled amount: the escrow must know
    /// what it owes, and spec 7.3 keeps the settled amount inside the
    /// commitment. Equal values are common but not required.
    uint256 public immutable payoutAmount;

    /// @param _payoutAsset Asset the collector is paid in, public.
    /// @param _payoutAmount Amount the collector is paid, public.
    /// @param _intentCommitment Spec 8.3 digest hiding the settlement details.
    /// @param _instanceDomain Per-deployment domain separator, spec 16.
    /// @param _requestId Settlement request this escrow serves.
    ///
    /// `expectedRecipient` and `expectedAmount` in the base are set to zero:
    /// the settlement recipient and amount live in the commitment, and writing
    /// them here would publish exactly what the commitment hides.
    constructor(
        address _payoutAsset,
        uint256 _payoutAmount,
        bytes32 _intentCommitment,
        bytes32 _instanceDomain,
        bytes32 _requestId,
        address _blindedSigner,
        uint256 _currentRewardAmount,
        uint256 _maxGasAdvance
    ) EscrowBase(address(0), 0, _blindedSigner, _maxGasAdvance) {
        if (_payoutAsset == address(0)) revert ZeroAddress();
        // A zero commitment would be openable by anyone who guesses the empty
        // preimage, and cannot arise from a correct derivation.
        if (_intentCommitment == bytes32(0)) revert ZeroCommitment();

        payoutAsset = _payoutAsset;
        payoutAmount = _payoutAmount;
        intentCommitment = _intentCommitment;
        instanceDomain = _instanceDomain;
        requestHash = _requestId;

        if (_currentRewardAmount > 0) {
            fund(_currentRewardAmount);
        }
    }

    // Takes currentRewardAmount + the payout from the deployer's token balance. The
    // sender deposits no ETH execution-gas surcharge; Nomad provisions executor gas.
    function fund(uint256 _currentRewardAmount) public {
        if (msg.sender != deployerAddress) revert OnlyDeployer();
        if (funded) revert AlreadyFunded();
        if (_currentRewardAmount == 0) revert ZeroRewardAmount();
        _validateGasAdvanceBudget(_currentRewardAmount);

        currentRewardAmount = _currentRewardAmount;
        originalRewardAmount = _currentRewardAmount;
        currentPaymentAmount = payoutAmount;
        gasAdvanceClaimed = false;
        IERC20(payoutAsset).safeTransferFrom(msg.sender, address(this), originalRewardAmount + currentPaymentAmount);
        funded = true;
    }

    function _releaseGasAdvance(address executor, uint256 gasAdvance) internal override {
        IERC20(payoutAsset).safeTransfer(executor, gasAdvance);
    }

    /// @notice Verify a settlement proof and pay the bonded collector.
    /// @param proof Groth16 proof points, EIP-197 order.
    /// @param witnessBlockNumber A recent block whose hash anchors the proof.
    ///
    /// The caller supplies the proof and one block number. Every other input to
    /// the verified statement comes from storage or the EVM, which is what
    /// spec 12.8 requires: no caller-controlled value may bypass the statement
    /// hash.
    ///
    /// The escrow does not parse the header. It reads `blockhash` — unforgeable,
    /// EVM-supplied — and hashes it into the statement. The circuit holds the
    /// header privately and proves it hashes to that value, that its
    /// `receiptsRoot` contains the receipt, and that the receipt carries a
    /// Transfer matching `intentCommitment`.
    ///
    /// Gated by the OnlyBondedExecutor guard: the ECDH signature was spent at
    /// bond(), so the bonded EOA is thereafter the only caller.
    /// @param signals The statement's two public signals. Checked against the
    /// escrow's own computation before use, so supplying them is a calldata
    /// convenience and not a trust concession: a caller who alters them fails
    /// the equality check, and one who does not has changed nothing.
    ///
    /// They are a parameter because the generated verifier reads its public
    /// input with `calldataload`, so the array must come from calldata rather
    /// than being built in memory.
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
    ///
    /// This is the whole of the escrow's block validation. The three checks the
    /// plaintext path also needed — that the header hashes to this value, that
    /// its encoded number matches, and that the settlement came after the bond
    /// — are now circuit assertions.
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
                requestId: requestHash,
                rowIndex: ROW_INDEX,
                intentCommitment: intentCommitment,
                bondAttempt: bondAttempt,
                bondStartBlock: uint64(bondStartBlock),
                bondDeadline: uint64(executionDeadline),
                bondedCollector: bondedExecutor,
                rowPayoutAsset: payoutAsset,
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

        IERC20(payoutAsset).safeTransfer(executor, payout);
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

        IERC20(payoutAsset).safeTransfer(msg.sender, withdrawableAmount);
    }
}
