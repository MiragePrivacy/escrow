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
    error TargetBlockInFuture();
    error TargetBlockTooOld();
    error BlockHashUnavailable();
    error BlockHeaderMismatch();
    error BlockNumberMismatch();
    error AlreadyCollected();
    error SignerNotTxSender();

    // EIP-712 typed-data constants. The struct and domain MUST match the off-chain
    // signer (nomad `crates/types/src/contracts.rs::ExecutionAuth`) byte-for-byte,
    // otherwise the recovered signer differs and the txSender check reverts.
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _EXECUTION_TYPEHASH =
        keccak256("ExecutionAuth(address expectedRecipient,uint256 expectedAmount,address payoutAddress)");
    bytes32 private constant _NAME_HASH = keccak256("MirageEscrow");
    bytes32 private constant _VERSION_HASH = keccak256("1");

    // Cached EIP-712 domain separator, bound to this contract + chain at deploy.
    bytes32 private immutable _domainSeparator;

    // The following variables are set up in the constructor.
    address immutable deployerAddress;
    uint256 public currentRewardAmount;
    uint256 public currentPaymentAmount;
    uint256 public originalRewardAmount;

    // The following variables are for Merkle proof validation
    address public immutable expectedRecipient; // The intended recipient of the transfer
    uint256 public immutable expectedAmount; // The expected transfer amount
    uint256 public constant MAX_BLOCK_LOOKBACK = 256; // Maximum blocks to look back for validation

    // marks if the contract has funds to pay out the executor (if unfunded, collect is rejected)
    bool public funded;
    // single-shot guard: set once a valid collect pays out, blocking double-collect and
    // post-collect withdraw. Replaces the bond lifecycle's exclusivity.
    bool public collected;

    constructor(address _expectedRecipient, uint256 _expectedAmount) {
        expectedRecipient = _expectedRecipient;
        expectedAmount = _expectedAmount;
        deployerAddress = msg.sender;
        _domainSeparator =
            keccak256(abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this)));
    }

    // Returns the EIP-712 domain separator for this escrow.
    function domainSeparator() public view returns (bytes32) {
        return _domainSeparator;
    }

    // EIP-712 digest for an ExecutionAuth over the given payoutAddress, bound to this
    // escrow's expectedRecipient/expectedAmount commitments.
    function _hashExecutionAuth(address payoutAddress) internal view returns (bytes32) {
        bytes32 structHash =
            keccak256(abi.encode(_EXECUTION_TYPEHASH, expectedRecipient, expectedAmount, payoutAddress));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator, structHash));
    }

    // Recovers the signer of an ExecutionAuth authorizing payoutAddress.
    function _recoverExecutionSigner(address payoutAddress, bytes calldata sig) internal view returns (address) {
        return ECDSA.recover(_hashExecutionAuth(payoutAddress), sig);
    }

    // Internal helper to validate block header for proof verification.
    // No bonded-executor gate: any caller may submit a valid proof; exclusivity is
    // enforced by the execution signature binding the payout to the transfer sender.
    function _validateBlockHeader(bytes calldata blockHeader, uint256 targetBlockNumber) internal view {
        if (!funded) revert NotFunded();
        if (targetBlockNumber > block.number) revert TargetBlockInFuture();
        if (block.number - targetBlockNumber > MAX_BLOCK_LOOKBACK) revert TargetBlockTooOld();

        bytes32 targetBlockHash = blockhash(targetBlockNumber);
        if (targetBlockHash == bytes32(0)) revert BlockHashUnavailable();
        if (keccak256(blockHeader) != targetBlockHash) revert BlockHeaderMismatch();
        if (BlockHeaderParser.extractBlockNumber(blockHeader) != targetBlockNumber) revert BlockNumberMismatch();
    }

    // Enforces the execution signature: the signer of the ExecutionAuth authorizing
    // payoutAddress must equal the recovered sender of the proven transfer tx.
    function _validateExecutionSig(address payoutAddress, address txSender, bytes calldata executionSig) internal view {
        if (_recoverExecutionSigner(payoutAddress, executionSig) != txSender) revert SignerNotTxSender();
    }

    // Internal helper to clear payout state
    function _clearPayoutState() internal {
        collected = true;
        funded = false;
        currentPaymentAmount = 0;
        currentRewardAmount = 0;
    }

    // Internal helper to calculate payout amount
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
