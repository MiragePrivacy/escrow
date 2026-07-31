// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./BlockHeaderParser.sol";
import "./MPTVerifier.sol";
import "./ReceiptValidator.sol";
import "./utils/ECDSA.sol";

/// @title EscrowERC20Delayed
/// @notice Single-use ERC20 escrow funded asynchronously by a plain token transfer.
/// The user's deposit contains the payment, node reward, and a token-denominated
/// execution pot. For now an already-active node EOA self-funds gas and receives
/// the execution pot when it bonds. A future execution path may swap that pot to
/// ETH before serving the escrow.
contract EscrowERC20Delayed {
    using SafeERC20 for IERC20;

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
    error ZeroAddress();
    error ZeroAmount();
    error ZeroRewardAmount();
    error InvalidReceiptProof();
    error InvalidTransferEvent();
    error NoWithdrawableFunds();
    error ProofBeforeBond();

    uint256 public constant MAX_BLOCK_LOOKBACK = 256;

    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _BOND_TYPEHASH = keccak256("BondAuth(address bondingExecutor)");
    bytes32 private constant _NAME_HASH = keccak256("MirageEscrow");
    bytes32 private constant _VERSION_HASH = keccak256("1");
    bytes32 private immutable _domainSeparator;

    address immutable deployerAddress;
    address public immutable tokenContract;
    address public immutable expectedRecipient;
    uint256 public immutable expectedAmount;
    address public immutable blindedSigner;

    uint256 public currentRewardAmount;
    uint256 public currentPaymentAmount;
    uint256 public originalRewardAmount;
    uint256 public executionPotAmount;

    address public bondedExecutor;
    uint256 public executionDeadline;
    uint256 public bondStartBlock;
    bool public cancellationRequest;

    /// 0 = retired/unfunded, 1 = awaiting transfer, 2 = fully funded.
    uint8 private fundedState;

    struct ReceiptProof {
        bytes blockHeader;
        bytes receiptRlp;
        bytes proofNodes;
        bytes receiptPath;
        uint256 logIndex;
    }

    constructor(
        address _tokenContract,
        address _expectedRecipient,
        uint256 _expectedAmount,
        address _blindedSigner,
        uint256 _currentRewardAmount,
        uint256 _executionPotAmount
    ) {
        if (_tokenContract == address(0) || _expectedRecipient == address(0) || _blindedSigner == address(0)) {
            revert ZeroAddress();
        }
        if (_expectedAmount == 0) revert ZeroAmount();
        if (_currentRewardAmount == 0) revert ZeroRewardAmount();

        deployerAddress = msg.sender;
        tokenContract = _tokenContract;
        expectedRecipient = _expectedRecipient;
        expectedAmount = _expectedAmount;
        blindedSigner = _blindedSigner;
        currentRewardAmount = _currentRewardAmount;
        originalRewardAmount = _currentRewardAmount;
        currentPaymentAmount = _expectedAmount;
        executionPotAmount = _executionPotAmount;
        fundedState = 1;
        _domainSeparator =
            keccak256(abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this)));
    }

    function domainSeparator() public view returns (bytes32) {
        return _domainSeparator;
    }

    /// @notice Compatibility with Nomad's common escrow view. The delayed pot
    /// is token-denominated, so it must not be interpreted as sponsorable ETH.
    function bondPot() external pure returns (uint256) {
        return 0;
    }

    function funded() external view returns (uint8) {
        if (fundedState == 1) {
            return IERC20(tokenContract).balanceOf(address(this)) >= _requiredBalance() ? 2 : 0;
        }
        return fundedState;
    }

    function is_bonded() public view returns (bool) {
        return executionDeadline > 0 && block.timestamp <= executionDeadline;
    }

    function requestCancellation() external {
        if (msg.sender != deployerAddress) revert OnlyDeployer();
        cancellationRequest = true;
    }

    function resume() external {
        if (msg.sender != deployerAddress) revert OnlyDeployer();
        cancellationRequest = false;
    }

    /// @notice Bind this single-use escrow to an enclave-authorized executor.
    /// The token execution pot is paid at bond time. Until token-to-ETH swapping
    /// is implemented, Nomad must select an Active EOA that can self-fund gas.
    function bond(bytes calldata bondSig) external {
        _clearExpiredBond();
        _tryUpgradeFunded();

        if (fundedState != 2) revert NotFunded();
        if (cancellationRequest) revert CancellationRequested();
        if (is_bonded()) revert ExecutorAlreadyBonded();
        if (ECDSA.recover(_hashBondAuth(msg.sender), bondSig) != blindedSigner) {
            revert InvalidBondSignature();
        }

        bondedExecutor = msg.sender;
        executionDeadline = block.timestamp + 5 minutes;
        bondStartBlock = block.number;

        uint256 pot = executionPotAmount;
        executionPotAmount = 0;
        if (pot > 0) IERC20(tokenContract).safeTransfer(msg.sender, pot);
    }

    function collect(ReceiptProof calldata proof, uint256 targetBlockNumber) external {
        if (fundedState != 2) revert NotFunded();
        if (msg.sender != bondedExecutor || !is_bonded()) revert OnlyBondedExecutor();
        if (targetBlockNumber > block.number) revert TargetBlockInFuture();
        if (block.number - targetBlockNumber > MAX_BLOCK_LOOKBACK) revert TargetBlockTooOld();
        if (targetBlockNumber <= bondStartBlock) revert ProofBeforeBond();

        bytes32 targetBlockHash = blockhash(targetBlockNumber);
        if (targetBlockHash == bytes32(0)) revert BlockHashUnavailable();
        if (keccak256(proof.blockHeader) != targetBlockHash) revert BlockHeaderMismatch();
        if (BlockHeaderParser.extractBlockNumber(proof.blockHeader) != targetBlockNumber) {
            revert BlockNumberMismatch();
        }

        bytes32 receiptsRoot = BlockHeaderParser.extractReceiptsRoot(proof.blockHeader);
        if (!MPTVerifier.verifyReceiptProof(proof.receiptRlp, proof.proofNodes, proof.receiptPath, receiptsRoot)) {
            revert InvalidReceiptProof();
        }
        if (!ReceiptValidator.validateTransferInReceipt(
                proof.receiptRlp, proof.logIndex, tokenContract, expectedRecipient, expectedAmount
            )) {
            revert InvalidTransferEvent();
        }

        uint256 payout = currentPaymentAmount + currentRewardAmount;
        address executor = bondedExecutor;
        _retire();
        IERC20(tokenContract).safeTransfer(executor, payout);
    }

    /// @notice Retire an unexecuted escrow and return its live token balance.
    /// The contract cannot be rearmed after cancellation.
    function cancelAndWithdraw() external {
        if (msg.sender != deployerAddress) revert OnlyDeployer();
        _clearExpiredBond();
        if (is_bonded()) revert BondActive();

        uint256 withdrawable = IERC20(tokenContract).balanceOf(address(this));
        if (withdrawable == 0) revert NoWithdrawableFunds();
        _retire();
        IERC20(tokenContract).safeTransfer(msg.sender, withdrawable);
    }

    function _requiredBalance() internal view returns (uint256) {
        return currentPaymentAmount + currentRewardAmount + executionPotAmount;
    }

    function _tryUpgradeFunded() internal {
        if (fundedState == 1 && IERC20(tokenContract).balanceOf(address(this)) >= _requiredBalance()) {
            fundedState = 2;
        }
    }

    function _clearExpiredBond() internal {
        if (executionDeadline > 0 && block.timestamp > executionDeadline) {
            bondedExecutor = address(0);
            executionDeadline = 0;
            bondStartBlock = 0;
        }
    }

    function _hashBondAuth(address bondingExecutor) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(_BOND_TYPEHASH, bondingExecutor));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator, structHash));
    }

    function _retire() internal {
        bondedExecutor = address(0);
        executionDeadline = 0;
        bondStartBlock = 0;
        fundedState = 0;
        currentPaymentAmount = 0;
        currentRewardAmount = 0;
        executionPotAmount = 0;
        cancellationRequest = false;
    }
}
