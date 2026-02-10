// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./RLPParser.sol";

/**
 * @title ReceiptValidator
 * @dev Library for validating transaction receipts and event logs
 * Handles EIP-2718 typed receipts and Transfer event validation
 */
library ReceiptValidator {
    using RLPParser for bytes;

    // Custom errors
    error InvalidRLP();
    error InvalidAddress();
    error WrongTokenContract();
    error WrongEventSignature();
    error ToAddressMismatch();
    error AmountMismatch();
    error ReceiptStatusNotSuccess();
    error UnsupportedTxType();
    error RecipientMismatch();

    // Pre-computed Transfer(address,address,uint256) event signature
    bytes32 private constant TRANSFER_EVENT_SIG = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    /**
     * @dev Validate Transfer event in receipt
     * @param receiptRlp RLP-encoded transaction receipt
     * @param logIndex Index of the target log in the receipt
     * @param toAddress Expected recipient address
     * @param expectedAmount Expected transfer amount
     * @return True if validation passes
     */
    function validateTransferInReceipt(
        bytes calldata receiptRlp,
        uint256 logIndex,
        address tokenContract,
        address toAddress,
        uint256 expectedAmount
    ) internal pure returns (bool) {
        uint256 offset = 0;

        // Handle typed receipts (EIP-2718)
        if (receiptRlp.length > 0 && uint8(receiptRlp[0]) < 0x80) {
            offset += 1; // Skip typed receipt prefix
        }

        // Skip RLP list prefix
        if (uint8(receiptRlp[offset]) < 0xc0) revert InvalidRLP();
        if (uint8(receiptRlp[offset]) >= 0xf8) {
            offset += 1 + (uint8(receiptRlp[offset]) - 0xf7);
        } else {
            offset += 1;
        }

        // Skip status, cumulativeGasUsed, bloom to get to logs
        for (uint256 i = 0; i < 3;) {
            offset = receiptRlp.skipItem(offset);
            unchecked {
                ++i;
            }
        }

        // Now at logs array
        if (uint8(receiptRlp[offset]) < 0xc0) revert InvalidRLP();
        if (uint8(receiptRlp[offset]) >= 0xf8) {
            offset += 1 + (uint8(receiptRlp[offset]) - 0xf7);
        } else {
            offset += 1;
        }

        // Navigate to target log
        for (uint256 i = 0; i < logIndex;) {
            offset = receiptRlp.skipItem(offset);
            unchecked {
                ++i;
            }
        }

        // Validate the target log
        return validateTransferLog(receiptRlp, offset, tokenContract, toAddress, expectedAmount);
    }

    /**
     * @dev Validate a Transfer event log
     * @param receiptRlp The receipt data
     * @param logOffset Offset to the target log
     * @param tokenContract Expected token contract address
     * @param toAddress Expected recipient address
     * @param expectedAmount Expected transfer amount
     * @return True if validation passes
     */
    function validateTransferLog(
        bytes calldata receiptRlp,
        uint256 logOffset,
        address tokenContract,
        address toAddress,
        uint256 expectedAmount
    ) private pure returns (bool) {
        uint256 offset = logOffset;

        // Parse target log: [address, topics[], data]
        if (uint8(receiptRlp[offset]) < 0xc0) revert InvalidRLP();
        if (uint8(receiptRlp[offset]) >= 0xf8) {
            offset += 1 + (uint8(receiptRlp[offset]) - 0xf7);
        } else {
            offset += 1;
        }

        // Parse emitter address (should be the token contract)
        if (uint8(receiptRlp[offset]) != 0x94) revert InvalidAddress();
        address emitter;
        assembly {
            emitter := shr(96, calldataload(add(receiptRlp.offset, add(offset, 1))))
        }
        if (emitter != tokenContract) revert WrongTokenContract();
        offset += 21;

        // Parse and validate topics
        return validateTransferTopics(receiptRlp, offset, toAddress, expectedAmount);
    }

    /**
     * @dev Validate event topics for Transfer event
     * @param receiptRlp The receipt data
     * @param topicsOffset Offset to the topics array
     * @param toAddress Expected recipient address
     * @param expectedAmount Expected transfer amount
     * @return True if validation passes
     */
    function validateTransferTopics(
        bytes calldata receiptRlp,
        uint256 topicsOffset,
        address toAddress,
        uint256 expectedAmount
    ) private pure returns (bool) {
        uint256 offset = topicsOffset;

        // Parse topics array
        if (uint8(receiptRlp[offset]) < 0xc0) revert InvalidRLP();
        if (uint8(receiptRlp[offset]) >= 0xf8) {
            offset += 1 + (uint8(receiptRlp[offset]) - 0xf7);
        } else {
            offset += 1;
        }

        // Check first topic (event signature)
        bytes32 eventSig = receiptRlp.extractBytes32(offset);
        if (eventSig != TRANSFER_EVENT_SIG) revert WrongEventSignature();

        // Check second topic (from address) --skip validation
        offset = receiptRlp.skipItem(offset);

        // Check third topic (to address)
        offset = receiptRlp.skipItem(offset);
        bytes32 logToAddr = receiptRlp.extractBytes32(offset);
        if (address(uint160(uint256(logToAddr))) != toAddress) revert ToAddressMismatch();

        // Parse and validate data payload (amount)
        offset = receiptRlp.skipItem(topicsOffset); // Skip entire topics array
        uint256 logAmount;
        {
            uint8 dataPrefix = uint8(receiptRlp[offset]);
            if (dataPrefix < 0x80) {
                logAmount = dataPrefix;
            } else if (dataPrefix == 0x80) {
                logAmount = 0;
            } else if (dataPrefix <= 0xa0) {
                uint256 len = dataPrefix - 0x80;
                for (uint256 i = 0; i < len;) {
                    logAmount = (logAmount << 8) | uint8(receiptRlp[offset + 1 + i]);
                    unchecked {
                        ++i;
                    }
                }
            } else {
                revert InvalidRLP();
            }
        }
        if (logAmount != expectedAmount) revert AmountMismatch();

        return true;
    }

    /**
     * @dev Validate receipt status == 1 (successful execution)
     * Receipt structure: [status, cumulativeGasUsed, logsBloom, logs]
     * Status is 0x01 for success, 0x80 (empty) for failure in post-Byzantium receipts
     */
    function validateReceiptStatus(bytes calldata receiptRlp) internal pure returns (bool) {
        uint256 offset = 0;

        // Handle typed receipts (EIP-2718)
        if (receiptRlp.length > 0 && uint8(receiptRlp[0]) < 0x80) {
            offset += 1; // Skip typed receipt prefix
        }

        // Skip RLP list prefix
        if (uint8(receiptRlp[offset]) < 0xc0) revert InvalidRLP();
        if (uint8(receiptRlp[offset]) >= 0xf8) {
            offset += 1 + (uint8(receiptRlp[offset]) - 0xf7);
        } else {
            offset += 1;
        }

        // Now at status field (first item in receipt)
        // Status encoding: 0x01 = success (1), 0x80 = failure (empty/0)
        uint8 statusByte = uint8(receiptRlp[offset]);

        // Status must be 0x01 (success)
        // 0x80 means empty byte string (status = 0, failed)
        // 0x01 means single byte with value 1 (success)
        if (statusByte != 0x01) revert ReceiptStatusNotSuccess();

        return true;
    }

    /**
     * @dev Validate native ETH transfer by checking tx 'to' and 'value' fields
     */
    function validateNativeTransfer(bytes calldata txRlp, address expectedRecipient, uint256 expectedAmount)
        internal
        pure
        returns (bool)
    {
        uint256 offset = 0;

        // Skip type prefix for typed transactions (EIP-2718)
        uint256 toIndex = 3; // Legacy: [nonce, gasPrice, gasLimit, to, value, ...]
        if (txRlp.length > 0 && uint8(txRlp[0]) < 0x80) {
            uint8 txType = uint8(txRlp[0]);
            offset = 1;
            if (txType == 0x01) {
                toIndex = 4; // EIP-2930: [chainId, nonce, gasPrice, gasLimit, to, value, ...]
            } else if (txType == 0x02) {
                toIndex = 5; // EIP-1559: [chainId, nonce, maxPriorityFee, maxFee, gasLimit, to, value, ...]
            } else {
                revert UnsupportedTxType();
            }
        }

        // Skip list prefix
        if (uint8(txRlp[offset]) < 0xc0) revert InvalidRLP();
        offset += uint8(txRlp[offset]) >= 0xf8 ? 1 + (uint8(txRlp[offset]) - 0xf7) : 1;

        // Skip to 'to' field
        for (uint256 i = 0; i < toIndex;) {
            offset = txRlp.skipItem(offset);
            unchecked {
                ++i;
            }
        }

        // Validate 'to' address (0x94 prefix = 20 byte string)
        if (uint8(txRlp[offset]) != 0x94) revert InvalidAddress();
        address to;
        assembly {
            to := shr(96, calldataload(add(txRlp.offset, add(offset, 1))))
        }
        if (to != expectedRecipient) revert RecipientMismatch();
        offset += 21;

        // Validate 'value'
        uint8 prefix = uint8(txRlp[offset]);
        uint256 value;
        if (prefix < 0x80) {
            value = prefix;
        } else if (prefix == 0x80) {
            value = 0;
        } else {
            uint256 len = prefix - 0x80;
            for (uint256 i = 0; i < len;) {
                value = (value << 8) | uint8(txRlp[offset + 1 + i]);
                unchecked {
                    ++i;
                }
            }
        }
        if (value != expectedAmount) revert AmountMismatch();

        return true;
    }
}
