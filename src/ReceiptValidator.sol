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
        require(uint8(receiptRlp[offset]) >= 0xc0, "Invalid receipt RLP");
        if (uint8(receiptRlp[offset]) >= 0xf8) {
            offset += 1 + (uint8(receiptRlp[offset]) - 0xf7);
        } else {
            offset += 1;
        }

        // Skip status, cumulativeGasUsed, bloom to get to logs
        for (uint256 i = 0; i < 3; i++) {
            offset = receiptRlp.skipItem(offset);
        }

        // Now at logs array
        require(uint8(receiptRlp[offset]) >= 0xc0, "Invalid logs RLP");
        if (uint8(receiptRlp[offset]) >= 0xf8) {
            offset += 1 + (uint8(receiptRlp[offset]) - 0xf7);
        } else {
            offset += 1;
        }

        // Navigate to target log
        for (uint256 i = 0; i < logIndex; i++) {
            offset = receiptRlp.skipItem(offset);
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
        require(uint8(receiptRlp[offset]) >= 0xc0, "Invalid log RLP");
        if (uint8(receiptRlp[offset]) >= 0xf8) {
            offset += 1 + (uint8(receiptRlp[offset]) - 0xf7);
        } else {
            offset += 1;
        }

        // Parse emitter address (should be the token contract)
        (bytes memory addrBytes, uint256 addrLen) = parseAddressFromRLP(receiptRlp, offset);
        require(addrBytes.length == 20, "Invalid emitter address length");

        // Extract emitter address
        address emitter;
        assembly {
            emitter := mload(add(addrBytes, 20))
        }
        require(emitter == tokenContract, "Wrong token contract");
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
        require(offset < data.length, "RLP offset out of bounds");

        uint8 prefix = uint8(data[offset]);

        if (prefix == 0x94) {
            // Address is 20 bytes with prefix 0x94
            result = new bytes(20);
            for (uint256 i = 0; i < 20; i++) {
                result[i] = data[offset + 1 + i];
            }
            return (result, 21);
        } else {
            revert("Invalid address RLP encoding");
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
        require(uint8(receiptRlp[offset]) >= 0xc0, "Invalid topics RLP");
        if (uint8(receiptRlp[offset]) >= 0xf8) {
            offset += 1 + (uint8(receiptRlp[offset]) - 0xf7);
        } else {
            offset += 1;
        }

        // Check first topic (event signature)
        bytes32 eventSig = receiptRlp.extractBytes32(offset);
        bytes32 expectedSig = keccak256("Transfer(address,address,uint256)");
        require(eventSig == expectedSig, "Wrong event signature");

        // Check second topic (from address) --skip validation
        offset = receiptRlp.skipItem(offset);

        // Check third topic (to address)
        offset = receiptRlp.skipItem(offset);
        bytes32 logToAddr = receiptRlp.extractBytes32(offset);
        require(address(uint160(uint256(logToAddr))) == toAddress, "To address mismatch");

        // Parse and validate data payload (amount)
        offset = receiptRlp.skipItem(topicsOffset); // Skip entire topics array
        (bytes memory dataBytes,) = parseDataFromRLP(receiptRlp, offset);

        // Convert data bytes to uint256 (amount)
        require(dataBytes.length <= 32, "Amount data too long");
        uint256 logAmount = 0;
        for (uint256 i = 0; i < dataBytes.length; i++) {
            logAmount = (logAmount << 8) | uint8(dataBytes[i]);
        }
        require(logAmount == expectedAmount, "Transfer amount mismatch");

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
        require(offset < data.length, "RLP offset out of bounds");

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
            for (uint256 i = 0; i < dataLength; i++) {
                result[i] = data[offset + 1 + i];
            }
            return (result, 1 + dataLength);
        } else if (prefix < 0xc0) {
            // Long string
            uint256 lengthBytes = prefix - 0xb7;
            uint256 dataLength = 0;
            for (uint256 i = 0; i < lengthBytes; i++) {
                dataLength = (dataLength << 8) | uint8(data[offset + 1 + i]);
            }
            result = new bytes(dataLength);
            for (uint256 i = 0; i < dataLength; i++) {
                result[i] = data[offset + 1 + lengthBytes + i];
            }
            return (result, 1 + lengthBytes + dataLength);
        } else {
            revert("Expected string data, got list");
        }
    }
}
