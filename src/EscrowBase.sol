// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import "./BlockHeaderParser.sol";
import "./MPTVerifier.sol";
import "./ReceiptValidator.sol";
import "./utils/ECDSA.sol";

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
    error InvalidBondSignature();
    error ZeroBlindedSigner();
    error ProofBeforeBond();
    error GasAdvanceAlreadyClaimed();
    error GasAdvanceTooLarge();
    error GasAdvanceBudgetExceedsReward();
    error GasAdvanceTransferFailed();

    // EIP-712 typed-data constants. The domain MUST match the off-chain signer
    // (nomad `crates/types/src/contracts.rs`) byte-for-byte, otherwise the recovered
    // signer differs and the bond signature check reverts.
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    // BondAuth binds the enclave's authorization to the specific fresh EOA that bonds,
    // so a signature cannot be replayed to bond a different executor.
    bytes32 private constant _BOND_TYPEHASH = keccak256("BondAuth(address bondingExecutor,uint256 gasAdvance)");
    bytes32 private constant _NAME_HASH = keccak256("MirageEscrow");
    bytes32 private constant _VERSION_HASH = keccak256("1");
    // Cached EIP-712 domain separator, bound to this contract + chain at deploy.
    bytes32 private immutable _domainSeparator;

    // The following variables are set up in the constructor.
    address public immutable deployerAddress;
    uint256 public currentRewardAmount;
    uint256 public currentPaymentAmount;
    uint256 public originalRewardAmount;
    /// @notice Quote-time reward budget reserved for fresh-EOA gas provisioning.
    uint256 public immutable maxGasAdvance;

    // Blinded enclave key P = G + s.B, stored as address(P). The enclave signs a BondAuth
    // with the matching scalar p = g + s; ecrecover of a valid signature yields this address.
    // Unlinkable to the global key G: with only P on-chain, an observer cannot tie this
    // escrow to any enclave. Only the enclave can produce a signature that recovers to it.
    address public immutable blindedSigner;

    // The following variables are for Merkle proof validation
    address public immutable expectedRecipient; // The intended recipient of the transfer
    uint256 public immutable expectedAmount; // The expected transfer amount
    uint256 public constant MAX_BLOCK_LOOKBACK = 256; // Maximum blocks to look back for validation

    // The following variables are dynamically adjusted when a bond or cancellation request is submitted.
    address public bondedExecutor;
    /// @notice Last block at which the bonded executor may collect.
    ///
    /// A block number rather than a timestamp. Spec 12.7 requires it: the
    /// circuit reads the settlement block number from an authenticated header
    /// and asserts `bondStartBlock < txBlockNumber <= bondDeadline`, and it
    /// cannot compare an authenticated block number against a timestamp.
    uint256 public executionDeadline;
    uint256 public bondStartBlock;
    /// @notice Bond attempts made against this escrow, starting at 1.
    ///
    /// A replay tag, spec 10.2. It enters the statement hash, so a proof
    /// generated under one lease cannot be presented under a later one. Unlike
    /// the rest of the bond state it survives expiry, which is what makes an
    /// expired lease's proofs permanently unusable.
    uint32 public bondAttempt;
    /// @notice Whether this funding cycle has already advanced reward funds.
    bool public gasAdvanceClaimed;
    bool public cancellationRequest;
    bool public funded; // marks if the contract has funds to pay out the executors (if unfunded, no executor is accepted)

    constructor(address _expectedRecipient, uint256 _expectedAmount, address _blindedSigner, uint256 _maxGasAdvance) {
        // Zero can't arise from a correct P = G + s.B derivation, so it signals an
        // upstream derivation/encoding bug; reject it like a zero token address.
        if (_blindedSigner == address(0)) revert ZeroBlindedSigner();
        expectedRecipient = _expectedRecipient;
        expectedAmount = _expectedAmount;
        blindedSigner = _blindedSigner;
        maxGasAdvance = _maxGasAdvance;
        deployerAddress = msg.sender;
        _domainSeparator =
            keccak256(abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this)));
    }

    // Returns the EIP-712 domain separator for this escrow.
    function domainSeparator() public view returns (bytes32) {
        return _domainSeparator;
    }

    // EIP-712 digest for a BondAuth authorizing the executor and exact advance.
    function _hashBondAuth(address bondingExecutor, uint256 gasAdvance) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(_BOND_TYPEHASH, bondingExecutor, gasAdvance));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator, structHash));
    }

    // Recovers the signer of a BondAuth authorizing the executor and advance.
    function _recoverBondSigner(address bondingExecutor, uint256 gasAdvance, bytes calldata sig)
        internal
        view
        returns (address)
    {
        return ECDSA.recover(_hashBondAuth(bondingExecutor, gasAdvance), sig);
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

    /// @notice Blocks a bond stays live. ~5 minutes at 12s blocks, matching the
    /// previous timestamp-based window.
    uint256 public constant BOND_DURATION_BLOCKS = 25;

    // checks if contract is currently bonded by verifying deadline
    function is_bonded() public view returns (bool) {
        return executionDeadline > 0 && block.number <= executionDeadline;
    }

    // Internal helper to validate block header for proof verification
    function _validateBlockHeader(bytes calldata blockHeader, uint256 targetBlockNumber) internal view {
        if (!funded) revert NotFunded();
        if (msg.sender != bondedExecutor || !is_bonded()) revert OnlyBondedExecutor();
        if (targetBlockNumber > block.number) revert TargetBlockInFuture();
        if (block.number - targetBlockNumber > MAX_BLOCK_LOOKBACK) revert TargetBlockTooOld();
        if (targetBlockNumber <= bondStartBlock) revert ProofBeforeBond();

        bytes32 targetBlockHash = blockhash(targetBlockNumber);
        if (targetBlockHash == bytes32(0)) revert BlockHashUnavailable();
        if (keccak256(blockHeader) != targetBlockHash) revert BlockHeaderMismatch();
        if (BlockHeaderParser.extractBlockNumber(blockHeader) != targetBlockNumber) revert BlockNumberMismatch();
    }

    // Internal helper to reset bond data when expired. An expired bond simply frees the
    // lock for the next enclave; there is no forfeited node deposit to roll into the reward.
    //
    // bondAttempt is deliberately preserved: clearing it would let a proof from
    // an expired lease verify against the next one.
    function _tryResetBondData() internal {
        if (is_bonded()) revert BondActive();

        bondedExecutor = address(0);
        executionDeadline = 0;
        bondStartBlock = 0;
    }

    // Internal helper to clear an expired bond so a fresh enclave can bond.
    function _clearExpiredBond() internal {
        if (executionDeadline > 0 && block.number > executionDeadline) {
            _tryResetBondData();
        }
    }

    // Internal helper to validate bond requirements. The entry check is the ECDH gate:
    // the enclave's BondAuth signature must recover to this escrow's blindedSigner. There
    // is no node deposit; Nomad provisions executor gas outside the escrow.
    function _validateBond(uint256 gasAdvance, bytes calldata bondSig) internal view {
        if (!funded) revert NotFunded();
        if (cancellationRequest) revert CancellationRequested();
        if (is_bonded()) revert ExecutorAlreadyBonded();
        if (gasAdvance > 0 && gasAdvanceClaimed) revert GasAdvanceAlreadyClaimed();
        if (gasAdvance > remainingGasAdvance()) revert GasAdvanceTooLarge();
        if (_recoverBondSigner(msg.sender, gasAdvance, bondSig) != blindedSigner) revert InvalidBondSignature();
    }

    // Internal helper to set bond data. bondedExecutor is the fresh EOA that produced a
    // valid signature, not a depositor.
    //
    // bondAttempt increments here rather than resetting with the rest of the
    // bond state, so each lease gets a distinct statement hash.
    function _setBondData() internal {
        bondedExecutor = msg.sender;
        executionDeadline = block.number + BOND_DURATION_BLOCKS;
        bondStartBlock = block.number;
        bondAttempt += 1;
    }

    /// @notice Remaining one-time advance available from the existing reward.
    function remainingGasAdvance() public view returns (uint256) {
        if (gasAdvanceClaimed) return 0;
        return maxGasAdvance < currentRewardAmount ? maxGasAdvance : currentRewardAmount;
    }

    function _validateGasAdvanceBudget(uint256 rewardAmount) internal view {
        if (maxGasAdvance > rewardAmount) revert GasAdvanceBudgetExceedsReward();
    }

    // Locks the escrow to the calling EOA for five minutes and optionally releases
    // a capped part of the existing reward. Titan fronts the bundle; the EOA swaps
    // this advance when necessary, repays the builder, and retains collect() gas.
    // No separate ETH bond pot is funded by the sender.
    function bond(uint256 gasAdvance, bytes calldata bondSig) external {
        // A prior expired bond frees the lock for this fresh enclave.
        _clearExpiredBond();

        _validateBond(gasAdvance, bondSig);

        _setBondData();

        if (gasAdvance > 0) {
            gasAdvanceClaimed = true;
            currentRewardAmount -= gasAdvance;
            _releaseGasAdvance(msg.sender, gasAdvance);
        }
    }

    /// Transfers an advance in this single escrow's reward asset.
    function _releaseGasAdvance(address executor, uint256 gasAdvance) internal virtual;

    // Internal helper to clear payout state
    function _clearPayoutState() internal {
        bondedExecutor = address(0);
        executionDeadline = 0;
        bondStartBlock = 0;
        funded = false;
        currentPaymentAmount = 0;
        currentRewardAmount = 0;
    }

    // Internal helper to calculate the principal reimbursement and reward payout.
    function _calculatePayout() internal view returns (uint256) {
        return currentRewardAmount + currentPaymentAmount;
    }

    // Internal helper to validate withdraw requirements
    function _validateWithdraw() internal view {
        if (!funded) revert NotFunded();
        if (msg.sender != deployerAddress) revert OnlyDeployer();
    }

    // An advance has already left the escrow, so cancellation returns only the
    // remaining reward. originalRewardAmount remains an immutable-cycle audit value.
    function _calculateWithdrawableAmount() internal view returns (uint256) {
        return currentPaymentAmount + currentRewardAmount;
    }

    // Internal helper to clear state after withdraw
    function _clearWithdrawState() internal {
        funded = false;
        currentPaymentAmount = 0;
        currentRewardAmount = 0;
        bondStartBlock = 0;
    }
}
