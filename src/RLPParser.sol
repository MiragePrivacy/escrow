// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/**
 * @title RLPParser
 * @dev Library for parsing Recursive Length Prefix (RLP) encoded data
 * Used for decoding Ethereum block headers, transaction receipts, and event logs
 */
library RLPParser {
    /**
     * @dev Skip an RLP item and return new offset
     * @param data The RLP encoded data
     * @param offset Current position in the data
     * @return New offset after skipping the item
     */
    function skipItem(bytes calldata data, uint256 offset) internal pure returns (uint256) {
        require(offset < data.length, "RLP offset out of bounds");
        
        uint8 prefix = uint8(data[offset]);
        
        if (prefix < 0x80) {
            // Single byte
            return offset + 1;
        } else if (prefix < 0xb8) {
            // Short string
            return offset + 1 + (prefix - 0x80);
        } else if (prefix < 0xc0) {
            // Long string
            uint256 lengthBytes = prefix - 0xb7;
            uint256 length = 0;
            for (uint256 i = 0; i < lengthBytes; i++) {
                length = (length << 8) | uint8(data[offset + 1 + i]);
            }
            return offset + 1 + lengthBytes + length;
        } else if (prefix < 0xf8) {
            // Short list
            return offset + 1 + (prefix - 0xc0);
        } else {
            // Long list
            uint256 lengthBytes = prefix - 0xf7;
            uint256 length = 0;
            for (uint256 i = 0; i < lengthBytes; i++) {
                length = (length << 8) | uint8(data[offset + 1 + i]);
            }
            return offset + 1 + lengthBytes + length;
        }
    }

    /**
     * @dev Parse an RLP item and return its content and length
     * @param data The RLP encoded data
     * @param offset Current position in the data
     * @return result The decoded content
     * @return length Total length of the RLP item including prefix
     */
    function parseItem(bytes memory data, uint256 offset) internal pure returns (bytes memory, uint256) {
        require(offset < data.length, "RLP offset out of bounds");
        
        uint8 prefix = uint8(data[offset]);
        
        if (prefix < 0x80) {
            // Single byte
            bytes memory result = new bytes(1);
            result[0] = bytes1(prefix);
            return (result, 1);
        } else if (prefix < 0xb8) {
            // Short string
            uint256 length = prefix - 0x80;
            bytes memory result = new bytes(length);
            for (uint256 i = 0; i < length; i++) {
                result[i] = data[offset + 1 + i];
            }
            return (result, 1 + length);
        } else if (prefix < 0xc0) {
            // Long string
            uint256 lengthBytes = prefix - 0xb7;
            uint256 length = 0;
            for (uint256 i = 0; i < lengthBytes; i++) {
                length = (length << 8) | uint8(data[offset + 1 + i]);
            }
            bytes memory result = new bytes(length);
            for (uint256 i = 0; i < length; i++) {
                result[i] = data[offset + 1 + lengthBytes + i];
            }
            return (result, 1 + lengthBytes + length);
        } else {
            // List - return the entire list content
            uint256 totalLength = getItemLength(data, offset);
            bytes memory result = new bytes(totalLength);
            for (uint256 i = 0; i < totalLength; i++) {
                result[i] = data[offset + i];
            }
            return (result, totalLength);
        }
    }

    /**
     * @dev Get total length of RLP item including prefix
     * @param data The RLP encoded data
     * @param offset Current position in the data
     * @return Total length of the RLP item
     */
    function getItemLength(bytes memory data, uint256 offset) internal pure returns (uint256) {
        require(offset < data.length, "RLP offset out of bounds");
        
        uint8 prefix = uint8(data[offset]);
        
        if (prefix < 0x80) {
            return 1;
        } else if (prefix < 0xb8) {
            return 1 + (prefix - 0x80);
        } else if (prefix < 0xc0) {
            uint256 lengthBytes = prefix - 0xb7;
            uint256 length = 0;
            for (uint256 i = 0; i < lengthBytes; i++) {
                length = (length << 8) | uint8(data[offset + 1 + i]);
            }
            return 1 + lengthBytes + length;
        } else if (prefix < 0xf8) {
            return 1 + (prefix - 0xc0);
        } else {
            uint256 lengthBytes = prefix - 0xf7;
            uint256 length = 0;
            for (uint256 i = 0; i < lengthBytes; i++) {
                length = (length << 8) | uint8(data[offset + 1 + i]);
            }
            return 1 + lengthBytes + length;
        }
    }

    /**
     * @dev Extract bytes32 from RLP-encoded data
     * @param data The RLP encoded data
     * @param offset Current position in the data
     * @return The extracted bytes32 value
     */
    function extractBytes32(bytes calldata data, uint256 offset) internal pure returns (bytes32) {
        require(data[offset] == 0xa0, "Expected 32-byte string");
        bytes32 result;
        assembly {
            result := calldataload(add(data.offset, add(offset, 1)))
        }
        return result;
    }
}
