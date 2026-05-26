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
    error WrongEventSignature();
    error ReceiptStatusNotSuccess();
    error UnsupportedTxType();

    // Pre-computed Transfer(address,address,uint256) event signature
    bytes32 private constant TRANSFER_EVENT_SIG = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    /**
     * @dev Extract Transfer event fields from receipt
     * @param receiptRlp RLP-encoded transaction receipt
     * @param logIndex Index of the target log in the receipt
     * @return token The emitting token contract address
     * @return recipient The transfer recipient
     * @return amount The transfer amount
     */
    function extractTransferFromReceipt(bytes calldata receiptRlp, uint256 logIndex)
        internal
        pure
        returns (address token, address recipient, uint256 amount)
    {
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

        // Extract fields from the target log
        return extractTransferLog(receiptRlp, offset);
    }

    /**
     * @dev Extract Transfer event fields from a log entry
     * @param receiptRlp The receipt data
     * @param logOffset Offset to the target log
     * @return token The emitting token contract address
     * @return recipient The transfer recipient
     * @return amount The transfer amount
     */
    function extractTransferLog(bytes calldata receiptRlp, uint256 logOffset)
        private
        pure
        returns (address token, address recipient, uint256 amount)
    {
        uint256 offset = logOffset;

        // Parse target log: [address, topics[], data]
        if (uint8(receiptRlp[offset]) < 0xc0) revert InvalidRLP();
        if (uint8(receiptRlp[offset]) >= 0xf8) {
            offset += 1 + (uint8(receiptRlp[offset]) - 0xf7);
        } else {
            offset += 1;
        }

        // Parse emitter address (token contract)
        if (uint8(receiptRlp[offset]) != 0x94) revert InvalidAddress();
        assembly {
            token := shr(96, calldataload(add(receiptRlp.offset, add(offset, 1))))
        }
        offset += 21;

        // Extract topics and data
        (recipient, amount) = extractTransferTopics(receiptRlp, offset);
    }

    /**
     * @dev Extract recipient and amount from Transfer event topics and data
     * @param receiptRlp The receipt data
     * @param topicsOffset Offset to the topics array
     * @return recipient The transfer recipient
     * @return amount The transfer amount
     */
    function extractTransferTopics(bytes calldata receiptRlp, uint256 topicsOffset)
        private
        pure
        returns (address recipient, uint256 amount)
    {
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

        // Skip event signature topic
        offset = receiptRlp.skipItem(offset);

        // Skip second topic (from address)
        offset = receiptRlp.skipItem(offset);

        // Third topic (to address)
        bytes32 logToAddr = receiptRlp.extractBytes32(offset);
        recipient = address(uint160(uint256(logToAddr)));

        // Parse data payload (amount)
        offset = receiptRlp.skipItem(topicsOffset); // Skip entire topics array
        {
            uint8 dataPrefix = uint8(receiptRlp[offset]);
            if (dataPrefix < 0x80) {
                amount = dataPrefix;
            } else if (dataPrefix == 0x80) {
                amount = 0;
            } else if (dataPrefix <= 0xa0) {
                uint256 len = dataPrefix - 0x80;
                for (uint256 i = 0; i < len;) {
                    amount = (amount << 8) | uint8(receiptRlp[offset + 1 + i]);
                    unchecked {
                        ++i;
                    }
                }
            } else {
                revert InvalidRLP();
            }
        }
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
     * @dev Extract recipient and amount from native ETH transfer tx fields
     * @param txRlp RLP-encoded transaction
     * @return recipient The transfer recipient
     * @return amount The transfer value
     */
    function extractNativeTransfer(bytes calldata txRlp) internal pure returns (address recipient, uint256 amount) {
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

        // Extract 'to' address (0x94 prefix = 20 byte string)
        if (uint8(txRlp[offset]) != 0x94) revert InvalidAddress();
        assembly {
            recipient := shr(96, calldataload(add(txRlp.offset, add(offset, 1))))
        }
        offset += 21;

        // Extract 'value'
        uint8 prefix = uint8(txRlp[offset]);
        if (prefix < 0x80) {
            amount = prefix;
        } else if (prefix == 0x80) {
            amount = 0;
        } else {
            uint256 len = prefix - 0x80;
            for (uint256 i = 0; i < len;) {
                amount = (amount << 8) | uint8(txRlp[offset + 1 + i]);
                unchecked {
                    ++i;
                }
            }
        }
    }
}
