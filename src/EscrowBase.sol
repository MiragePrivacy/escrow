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
    error BondTransferFailed();
    error ZeroBlindedSigner();

    // EIP-712 typed-data constants. The domain MUST match the off-chain signer
    // (nomad `crates/types/src/contracts.rs`) byte-for-byte, otherwise the recovered
    // signer differs and the bond signature check reverts.
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    // BondAuth binds the enclave's authorization to the specific fresh EOA that bonds,
    // so a signature cannot be replayed to bond a different executor.
    bytes32 private constant _BOND_TYPEHASH = keccak256("BondAuth(address bondingExecutor)");
    bytes32 private constant _NAME_HASH = keccak256("MirageEscrow");
    bytes32 private constant _VERSION_HASH = keccak256("1");

    // Cached EIP-712 domain separator, bound to this contract + chain at deploy.
    bytes32 private immutable _domainSeparator;

    // The following variables are set up in the constructor.
    address immutable deployerAddress;
    uint256 public currentRewardAmount;
    uint256 public currentPaymentAmount;
    uint256 public originalRewardAmount;

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
    uint256 public executionDeadline;
    // ETH bond pot. Sourced at fund time; paid out to the fresh EOA at bond() to bootstrap
    // its gas. A one-shot faucet: once spent it does not refill, so a retry after a failed
    // serve must use an already-funded EOA.
    uint256 public bondPot;
    bool public cancellationRequest;
    bool public funded; // marks if the contract has funds to pay out the executors (if unfunded, no executor is accepted)

    constructor(address _expectedRecipient, uint256 _expectedAmount, address _blindedSigner) {
        // Zero can't arise from a correct P = G + s.B derivation, so it signals an
        // upstream derivation/encoding bug; reject it like a zero token address.
        if (_blindedSigner == address(0)) revert ZeroBlindedSigner();
        expectedRecipient = _expectedRecipient;
        expectedAmount = _expectedAmount;
        blindedSigner = _blindedSigner;
        deployerAddress = msg.sender;
        _domainSeparator =
            keccak256(abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this)));
    }

    // Returns the EIP-712 domain separator for this escrow.
    function domainSeparator() public view returns (bytes32) {
        return _domainSeparator;
    }

    // EIP-712 digest for a BondAuth authorizing bondingExecutor to bond this escrow.
    function _hashBondAuth(address bondingExecutor) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(_BOND_TYPEHASH, bondingExecutor));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator, structHash));
    }

    // Recovers the signer of a BondAuth authorizing bondingExecutor.
    function _recoverBondSigner(address bondingExecutor, bytes calldata sig) internal view returns (address) {
        return ECDSA.recover(_hashBondAuth(bondingExecutor), sig);
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

    // Internal helper to reset bond data when expired. An expired bond simply frees the
    // lock for the next enclave; there is no forfeited node deposit to roll into the reward.
    function _tryResetBondData() internal {
        if (is_bonded()) revert BondActive();

        bondedExecutor = address(0);
        executionDeadline = 0;
    }

    // Internal helper to clear an expired bond so a fresh enclave can bond.
    function _clearExpiredBond() internal {
        if (executionDeadline > 0 && block.timestamp > executionDeadline) {
            _tryResetBondData();
        }
    }

    // Internal helper to validate bond requirements. The entry check is the ECDH gate:
    // the enclave's BondAuth signature must recover to this escrow's blindedSigner. There
    // is no node deposit; the escrow pays out its bond pot instead of receiving one.
    function _validateBond(bytes calldata bondSig) internal view {
        if (!funded) revert NotFunded();
        if (cancellationRequest) revert CancellationRequested();
        if (is_bonded()) revert ExecutorAlreadyBonded();
        if (_recoverBondSigner(msg.sender, bondSig) != blindedSigner) revert InvalidBondSignature();
    }

    // Internal helper to set bond data. bondedExecutor is the fresh EOA that produced a
    // valid signature, not a depositor.
    function _setBondData() internal {
        bondedExecutor = msg.sender;
        executionDeadline = block.timestamp + 5 minutes;
    }

    // Locks the escrow to the calling fresh EOA and pays it the ETH bond pot to bootstrap
    // its gas. Gated by the ECDH signature: bondSig must recover to blindedSigner. The bond
    // ETH leaving the escrow lets the caller repay the block builder in the same bundle.
    // Asset-agnostic (the pot is always ETH), so it lives in the base for both flavors.
    function bond(bytes calldata bondSig) external {
        // A prior expired bond frees the lock for this fresh enclave.
        _clearExpiredBond();

        _validateBond(bondSig);

        _setBondData();

        uint256 pot = bondPot;
        bondPot = 0;
        (bool success,) = msg.sender.call{value: pot}("");
        if (!success) revert BondTransferFailed();
    }

    // Internal helper to clear payout state
    function _clearPayoutState() internal {
        bondedExecutor = address(0);
        executionDeadline = 0;
        funded = false;
        currentPaymentAmount = 0;
        currentRewardAmount = 0;
    }

    // Internal helper to calculate payout amount. The bond pot is spent bootstrapping the
    // serve at bond() and is not part of the collect payout.
    function _calculatePayout() internal view returns (uint256) {
        return currentRewardAmount + currentPaymentAmount;
    }

    // Internal helper to validate withdraw requirements
    function _validateWithdraw() internal view {
        if (!funded) revert NotFunded();
        if (msg.sender != deployerAddress) revert OnlyDeployer();
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
