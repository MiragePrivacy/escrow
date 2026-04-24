// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import "./BlockHeaderParser.sol";
import "./MPTVerifier.sol";
import "./ReceiptValidator.sol";

interface IERC20 {
    function send(address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title EscrowERC20Delayed
/// @notice Pre-deployable ERC20 escrow. The deployer (typically a node EOA)
/// deploys the contract with (recipient, expectedAmount, reward) committed
/// in storage but does NOT seed it with tokens at construction. The user
/// funds the escrow asynchronously by issuing a plain ERC20 `transfer`
/// directly to the escrow address. Once the escrow's token balance covers
/// `currentRewardAmount + expectedAmount`, `funded()` reports state 2
/// and the escrow is ready for bond/collect.
///
/// Stored `funded` is a uint8 state machine:
///   0 = not funded (no active signal)
///   1 = delayed: args set, waiting for the bare transfer
///   2 = fully funded: balance observed, bondable
///
/// The escrow is reusable: after a signal closes out (collect or
/// cancelAndWithdraw) OR when the deployer abandons an unfunded one, the
/// deployer can `reinit(...)` to arm it for a new signal.
///
/// Reuse risk: `reinit` is permitted even when the escrow still holds a
/// partial balance from a prior user's bare-transfer funding. Those tokens
/// then count toward the new signal's deposit. This can cross-contaminate
/// funds across users if the deployer is careless. The deployer is
/// responsible for out-of-band refunds. A timeout window governing when the
/// deployer is allowed to reinit is expected to live in node orchestration
/// code, not in this contract.
contract EscrowERC20Delayed {
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
    error ZeroAmount();
    error ZeroRewardAmount();
    error AlreadyArmed();
    error TokenTransferFailed();
    error InvalidReceiptProof();
    error InvalidTransferEvent();
    error NoWithdrawableFunds();

    uint256 public constant MAX_BLOCK_LOOKBACK = 256;

    address immutable deployerAddress;
    address public immutable tokenContract;

    address public expectedRecipient;
    uint256 public expectedAmount;
    uint256 public currentRewardAmount;
    uint256 public originalRewardAmount;

    address public bondedExecutor;
    uint256 public executionDeadline;
    uint256 public bondAmount;
    uint256 public totalBondsDeposited;
    bool public cancellationRequest;

    /// Stored funded state. See contract-level docs for meaning.
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
        uint256 _currentRewardAmount
    ) {
        if (_tokenContract == address(0)) revert ZeroAddress();
        if (_expectedRecipient == address(0)) revert ZeroAddress();
        if (_expectedAmount == 0) revert ZeroAmount();
        if (_currentRewardAmount == 0) revert ZeroRewardAmount();

        deployerAddress = msg.sender;
        tokenContract = _tokenContract;

        expectedRecipient = _expectedRecipient;
        expectedAmount = _expectedAmount;
        currentRewardAmount = _currentRewardAmount;
        originalRewardAmount = _currentRewardAmount;
        fundedState = 1;
    }

    /// @notice Arm a previously-cleared escrow with new signal args.
    /// Deployer-only. Reverts if a bond is currently active (settle or
    /// expire it first via cancelAndWithdraw) or if the escrow is already
    /// fully funded (stored state == 2). State 1 (delayed waiting for
    /// transfer) is permitted so the deployer can re-arm a slot that the
    /// previous user abandoned without funding. Partial balances from
    /// prior activity are intentionally retained and count toward the new
    /// deposit. See the reuse-risk note at the top of the contract.
    function reinit(address _expectedRecipient, uint256 _expectedAmount, uint256 _currentRewardAmount) external {
        if (msg.sender != deployerAddress) revert OnlyDeployer();
        if (fundedState == 2) revert AlreadyArmed();
        if (is_bonded()) revert BondActive();
        if (_expectedRecipient == address(0)) revert ZeroAddress();
        if (_expectedAmount == 0) revert ZeroAmount();
        if (_currentRewardAmount == 0) revert ZeroRewardAmount();

        expectedRecipient = _expectedRecipient;
        expectedAmount = _expectedAmount;
        currentRewardAmount = _currentRewardAmount;
        originalRewardAmount = _currentRewardAmount;
        cancellationRequest = false;
        fundedState = 1;
    }

    /// @notice Dynamic funded view. When stored state is 1 (delayed), this
    /// reports 2 iff the escrow's token balance is at least
    /// `currentRewardAmount + expectedAmount`, else 0. Stored 0 and 2
    /// pass through unchanged.
    function funded() external view returns (uint8) {
        uint8 s = fundedState;
        if (s == 1) {
            uint256 required = currentRewardAmount + expectedAmount;
            return IERC20(tokenContract).balanceOf(address(this)) >= required ? 2 : 0;
        }
        return s;
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

    /// @notice Bond to become the executor. Performs an inline balance
    /// check that upgrades stored state 1 -> 2 when the escrow has been
    /// funded via plain transfer.
    function bond(uint256 _bondAmount) external {
        _handleExpiredBond();
        _tryUpgradeFunded();

        if (fundedState != 2) revert NotFunded();
        if (cancellationRequest) revert CancellationRequested();
        if (is_bonded()) revert ExecutorAlreadyBonded();
        if (_bondAmount < currentRewardAmount / 2) revert InsufficientBond();

        if (!_pullTokens(msg.sender, _bondAmount)) revert TokenTransferFailed();

        bondedExecutor = msg.sender;
        executionDeadline = block.timestamp + 5 minutes;
        bondAmount = _bondAmount;
    }

    function collect(ReceiptProof calldata proof, uint256 targetBlockNumber) external {
        if (fundedState != 2) revert NotFunded();
        if (msg.sender != bondedExecutor || !is_bonded()) revert OnlyBondedExecutor();
        if (targetBlockNumber > block.number) revert TargetBlockInFuture();
        if (block.number - targetBlockNumber > MAX_BLOCK_LOOKBACK) revert TargetBlockTooOld();

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

        uint256 payout = bondAmount + currentRewardAmount + expectedAmount;
        address executor = bondedExecutor;

        bondedExecutor = address(0);
        bondAmount = 0;
        executionDeadline = 0;
        fundedState = 0;
        currentRewardAmount = 0;

        bool success;
        if (block.chainid == 11155111) {
            success = IERC20(tokenContract).send(executor, payout);
        } else {
            success = IERC20(tokenContract).transfer(executor, payout);
        }
        if (!success) revert TokenTransferFailed();
    }

    /// @notice Cancel the active arming and sweep the live token balance to
    /// the deployer. Works across delayed and fully funded states. Reverts
    /// if a bond is active (wait for it to expire first).
    function cancelAndWithdraw() external {
        if (msg.sender != deployerAddress) revert OnlyDeployer();
        if (fundedState == 0) revert NotFunded();
        _handleExpiredBond();
        if (is_bonded()) revert BondActive();

        cancellationRequest = true;
        bondedExecutor = address(0);
        bondAmount = 0;
        executionDeadline = 0;

        uint256 withdrawable = IERC20(tokenContract).balanceOf(address(this));
        if (withdrawable == 0) revert NoWithdrawableFunds();

        fundedState = 0;
        currentRewardAmount = 0;
        cancellationRequest = false;

        if (!IERC20(tokenContract).transfer(msg.sender, withdrawable)) revert TokenTransferFailed();
    }

    function _tryUpgradeFunded() internal {
        if (fundedState == 1) {
            uint256 required = currentRewardAmount + expectedAmount;
            if (IERC20(tokenContract).balanceOf(address(this)) >= required) {
                fundedState = 2;
            }
        }
    }

    function _handleExpiredBond() internal {
        if (executionDeadline > 0 && block.timestamp > executionDeadline) {
            currentRewardAmount += bondAmount;
            totalBondsDeposited += bondAmount;
            bondedExecutor = address(0);
            bondAmount = 0;
            executionDeadline = 0;
        }
    }

    /// Pull `_amount` of the escrow token from `from` using a raw transferFrom.
    /// Funding happens via plain transfer; only the bond path pulls.
    function _pullTokens(address from, uint256 _amount) internal returns (bool) {
        (bool ok, bytes memory ret) = tokenContract.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from, address(this), _amount)
        );
        if (!ok) return false;
        if (ret.length == 0) return true;
        return abi.decode(ret, (bool));
    }
}
