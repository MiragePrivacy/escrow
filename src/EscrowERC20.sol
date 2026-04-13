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
    error ZeroAmount();
    error TokenTransferFailed();
    error InvalidReceiptProof();
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

    constructor(address _tokenContract, uint256 _amount, bytes32 _commitment) EscrowBase() {
        if (_tokenContract == address(0)) revert ZeroAddress();
        tokenContract = _tokenContract;

        if (_amount > 0) {
            _fund(_amount, _commitment);
        }
    }

    function fund(uint256 _amount, bytes32 _commitment) external {
        if (msg.sender != deployerAddress) revert OnlyDeployer();
        if (funded) revert AlreadyFunded();
        _fund(_amount, _commitment);
    }

    function _fund(uint256 _amount, bytes32 _commitment) internal {
        if (_amount == 0) revert ZeroAmount();

        deposit = _amount;
        originalDeposit = _amount;
        commitment = _commitment;
        if (!IERC20(tokenContract).transferFrom(msg.sender, address(this), _amount)) {
            revert TokenTransferFailed();
        }
        funded = true;
    }

    // takes _bondAmount from the caller's balance of the tokenContract. The bondstatus is now bonded, execution deadline is current block timestamp + 5 minutes. Sets bondedexecutor to the caller. Will only accept a bond if the cancellationrequest is set to false, and no one is bonded.
    function bond(uint256 _bondAmount) external {
        // If deadline passed and someone is bonded, add their bond to reward
        _handleExpiredBond();

        _validateBondRequirements(_bondAmount);

        if (!IERC20(tokenContract).transferFrom(msg.sender, address(this), _bondAmount)) {
            revert TokenTransferFailed();
        }

        _setBondData(_bondAmount);
    }

    // Validates a given merkle proof against a recent block hash and verifies the commitment
    function collect(ReceiptProof calldata proof, uint256 targetBlockNumber, bytes32 salt) external {
        _validateBlockHeader(proof.blockHeader, targetBlockNumber);

        // Extract receipts root and verify receipt inclusion
        bytes32 receiptsRoot = BlockHeaderParser.extractReceiptsRoot(proof.blockHeader);
        if (!MPTVerifier.verifyReceiptProof(proof.receiptRlp, proof.proofNodes, proof.receiptPath, receiptsRoot)) {
            revert InvalidReceiptProof();
        }

        // Extract transfer fields from the proven receipt
        (address token, address recipient, uint256 amount) =
            ReceiptValidator.extractTransferFromReceipt(proof.receiptRlp, proof.logIndex);

        // Verify commitment: H(recipient, token, amount, salt)
        if (keccak256(abi.encodePacked(recipient, token, amount, salt)) != commitment) {
            revert CommitmentMismatch();
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

    /// @notice Cancel and withdraw original deposit in a single transaction.
    /// Reverts if a node has already bonded. Seized bonds remain in the contract.
    function cancelAndWithdraw() external {
        cancellationRequest = true;
        _validateWithdraw();
        _tryResetBondData();

        uint256 withdrawableAmount = originalDeposit;
        if (withdrawableAmount == 0) revert NoWithdrawableFunds();

        _clearWithdrawState();

        if (!IERC20(tokenContract).transfer(msg.sender, withdrawableAmount)) {
            revert TokenTransferFailed();
        }
    }
}
