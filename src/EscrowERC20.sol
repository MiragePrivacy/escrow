// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import "./EscrowBase.sol";

interface IERC20 {
    function send(address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract EscrowERC20 is EscrowBase {
    // Custom errors
    error ZeroAddress();
    error AlreadyFunded();
    error ZeroRewardAmount();
    error ZeroPaymentAmount();
    error ZeroBondAmount();
    error TokenTransferFailed();
    error BondTransferFailed();
    error InvalidReceiptProof();
    error InvalidTransferEvent();
    error NoWithdrawableFunds();

    address public immutable tokenContract; // The tokens used in the escrow

    // Based on Nomad's proof structure
    struct ReceiptProof {
        bytes blockHeader; // RLP-encoded block header
        bytes receiptRlp; // RLP-encoded target receipt
        bytes proofNodes; // RLP-encoded array of MPT proof nodes
        bytes receiptPath; // RLP-encoded receipt index
        uint256 logIndex; // Index of target log in receipt
    }

    constructor(
        address _tokenContract,
        address _expectedRecipient,
        uint256 _expectedAmount,
        address _blindedSigner,
        uint256 _currentRewardAmount,
        uint256 _currentPaymentAmount
    ) payable EscrowBase(_expectedRecipient, _expectedAmount, _blindedSigner) {
        if (_tokenContract == address(0)) revert ZeroAddress();
        tokenContract = _tokenContract;

        if (_currentRewardAmount > 0 && _currentPaymentAmount > 0) {
            fund(_currentRewardAmount, _currentPaymentAmount);
        }
    }

    // takes currentRewardAmount + currentPaymentAmount from the deployer's balance from the
    // tokenContract, and the ETH bond pot (msg.value) that bootstraps the fresh EOA's gas.
    function fund(uint256 _currentRewardAmount, uint256 _currentPaymentAmount) public payable {
        if (msg.sender != deployerAddress) revert OnlyDeployer();
        if (funded) revert AlreadyFunded();
        if (_currentRewardAmount == 0) revert ZeroRewardAmount();
        if (_currentPaymentAmount == 0) revert ZeroPaymentAmount();
        if (msg.value == 0) revert ZeroBondAmount();

        currentRewardAmount = _currentRewardAmount;
        originalRewardAmount = _currentRewardAmount;
        currentPaymentAmount = _currentPaymentAmount;
        bondPot = msg.value;
        if (!IERC20(tokenContract).transferFrom(msg.sender, address(this), originalRewardAmount + currentPaymentAmount))
        {
            revert TokenTransferFailed();
        }
        funded = true;
    }

    // Locks the escrow to the calling fresh EOA and pays it the ETH bond pot to bootstrap
    // its gas. Gated by the ECDH signature: bondSig must recover to blindedSigner. The bond
    // ETH leaving the escrow lets the caller repay the block builder in the same bundle.
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

    // Validates a Transfer-event proof against a recent block hash and checks the Transfer
    // event's contents, then pays the bonded executor. Gated by the OnlyBondedExecutor guard:
    // the ECDH signature was spent at bond(), so the bonded EOA is thereafter the only caller.
    function collect(ReceiptProof calldata proof, uint256 targetBlockNumber) external {
        _validateBlockHeader(proof.blockHeader, targetBlockNumber);

        // Extract receipts root and verify receipt inclusion
        bytes32 receiptsRoot = BlockHeaderParser.extractReceiptsRoot(proof.blockHeader);
        if (!MPTVerifier.verifyReceiptProof(proof.receiptRlp, proof.proofNodes, proof.receiptPath, receiptsRoot)) {
            revert InvalidReceiptProof();
        }

        // Validate the Transfer event
        if (!ReceiptValidator.validateTransferInReceipt(
                proof.receiptRlp, proof.logIndex, tokenContract, expectedRecipient, expectedAmount
            )) {
            revert InvalidTransferEvent();
        }

        _payout();
    }

    function _payout() internal {
        uint256 payout = _calculatePayout();
        address executor = bondedExecutor;

        _clearPayoutState();

        bool success;
        if (block.chainid == 11155111) {
            // Sepolia testnet uses non-standard send
            success = IERC20(tokenContract).send(executor, payout);
        } else {
            success = IERC20(tokenContract).transfer(executor, payout);
        }
        if (!success) revert TokenTransferFailed();
    }

    /// @notice Cancel and withdraw funds in a single transaction.
    /// Reverts if a node has already bonded.
    function cancelAndWithdraw() external {
        cancellationRequest = true;
        _validateWithdraw();
        _tryResetBondData();

        uint256 withdrawableAmount = _calculateWithdrawableAmount();
        uint256 pot = bondPot;

        _clearWithdrawState();
        bondPot = 0;

        if (withdrawableAmount == 0) revert NoWithdrawableFunds();

        if (!IERC20(tokenContract).transfer(msg.sender, withdrawableAmount)) {
            revert TokenTransferFailed();
        }
        // Return the unspent ETH bond pot alongside the token reward.
        if (pot > 0) {
            (bool success,) = msg.sender.call{value: pot}("");
            if (!success) revert BondTransferFailed();
        }
    }
}
