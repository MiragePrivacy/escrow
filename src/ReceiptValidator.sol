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
    error ExpectedStringData();
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
            unchecked { ++i; }
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
            unchecked { ++i; }
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
        (bytes memory addrBytes, uint256 addrLen) = parseAddressFromRLP(receiptRlp, offset);
        if (addrBytes.length != 20) revert InvalidAddress();

        // Extract emitter address
        address emitter;
        assembly {
            emitter := mload(add(addrBytes, 20))
        }
        if (emitter != tokenContract) revert WrongTokenContract();
        offset += addrLen;

        // Parse and validate topics
        return validateTransferTopics(receiptRlp, offset, toAddress, expectedAmount);
    }

    /**
     * @dev Parse address from RLP data
     * @param data RLP encoded data
     * @param offset Current offset
     * @return result Parsed address bytes
     * @return length Length consumed
     */
    function parseAddressFromRLP(bytes calldata data, uint256 offset)
        private
        pure
        returns (bytes memory result, uint256 length)
    {
        if (offset >= data.length) revert InvalidRLP();

        uint8 prefix = uint8(data[offset]);

        if (prefix == 0x94) {
            // Address is 20 bytes with prefix 0x94
            result = new bytes(20);
            for (uint256 i = 0; i < 20;) {
                result[i] = data[offset + 1 + i];
                unchecked { ++i; }
            }
            return (result, 21);
        } else {
            revert InvalidAddress();
        }
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
        (bytes memory dataBytes,) = parseDataFromRLP(receiptRlp, offset);

        // Convert data bytes to uint256 (amount)
        if (dataBytes.length > 32) revert InvalidRLP();
        uint256 logAmount = 0;
        for (uint256 i = 0; i < dataBytes.length;) {
            logAmount = (logAmount << 8) | uint8(dataBytes[i]);
            unchecked { ++i; }
        }
        if (logAmount != expectedAmount) revert AmountMismatch();

        return true;
    }

    /**
     * @dev Parse data field from RLP
     * @param data RLP encoded data
     * @param offset Current offset
     * @return result Parsed data bytes
     * @return length Length consumed
     */
    function parseDataFromRLP(bytes calldata data, uint256 offset)
        private
        pure
        returns (bytes memory result, uint256 length)
    {
        if (offset >= data.length) revert InvalidRLP();

        uint8 prefix = uint8(data[offset]);

        if (prefix < 0x80) {
            // Single byte
            result = new bytes(1);
            result[0] = bytes1(prefix);
            return (result, 1);
        } else if (prefix < 0xb8) {
            // Short string
            uint256 dataLength = prefix - 0x80;
            result = new bytes(dataLength);
            for (uint256 i = 0; i < dataLength;) {
                result[i] = data[offset + 1 + i];
                unchecked { ++i; }
            }
            return (result, 1 + dataLength);
        } else if (prefix < 0xc0) {
            // Long string
            uint256 lengthBytes = prefix - 0xb7;
            uint256 dataLength = 0;
            for (uint256 i = 0; i < lengthBytes;) {
                dataLength = (dataLength << 8) | uint8(data[offset + 1 + i]);
                unchecked { ++i; }
            }
            result = new bytes(dataLength);
            for (uint256 i = 0; i < dataLength;) {
                result[i] = data[offset + 1 + lengthBytes + i];
                unchecked { ++i; }
            }
            return (result, 1 + lengthBytes + dataLength);
        } else {
            revert ExpectedStringData();
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
            unchecked { ++i; }
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
                unchecked { ++i; }
            }
        }
        if (value != expectedAmount) revert AmountMismatch();

        return true;
    }
}
