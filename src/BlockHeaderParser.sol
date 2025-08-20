// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./RLPParser.sol";

/**
 * @title BlockHeaderParser
 * @dev Library for parsing Ethereum block headers
 * Extracts receipts root, block number, and other header fields
 */
library BlockHeaderParser {
    using RLPParser for bytes;

    /**
     * @dev Extract block number from RLP-encoded block header
     * @param blockHeader RLP-encoded block header
     * @return Block number
     */
    function extractBlockNumber(bytes calldata blockHeader) internal pure returns (uint256) {
        uint256 offset = 0;

        // Skip RLP list prefix
        require(blockHeader[offset] >= 0xc0, "Invalid RLP list");
        if (blockHeader[offset] >= 0xf8) {
            offset += 1 + (uint8(blockHeader[offset]) - 0xf7);
        } else {
            offset += 1;
        }

        // Skip first 8 fields to get to block number (index 8)
        // [parentHash, sha3Uncles, miner, stateRoot, transactionsRoot, receiptsRoot, logsBloom, difficulty, number, ...]
        for (uint256 i = 0; i < 8; i++) {
            offset = blockHeader.skipItem(offset);
        }

        // Extract block number
        (bytes memory numBytes,) = parseItemFromCalldata(blockHeader, offset);

        // Decode big-endian number
        uint256 blockNumber = 0;
        for (uint256 i = 0; i < numBytes.length; i++) {
            blockNumber = (blockNumber << 8) | uint8(numBytes[i]);
        }

        return blockNumber;
    }

    /**
     * @dev Extract receipts root from RLP-encoded block header
     * @param blockHeader RLP-encoded block header
     * @return Receipts root hash
     */
    function extractReceiptsRoot(bytes calldata blockHeader) internal pure returns (bytes32) {
        // Block header structure:
        // [parentHash, sha3Uncles, miner, stateRoot, transactionsRoot, receiptsRoot, ...]
        // receiptsRoot is at index 5

        uint256 offset = 0;

        // Skip RLP list prefix
        require(blockHeader[offset] >= 0xc0, "Invalid RLP list");
        if (blockHeader[offset] >= 0xf8) {
            offset += 1 + (uint8(blockHeader[offset]) - 0xf7);
        } else {
            offset += 1;
        }

        // Skip first 5 fields to get to receiptsRoot
        for (uint256 i = 0; i < 5; i++) {
            offset = blockHeader.skipItem(offset);
        }

        // Extract receiptsRoot (32 bytes)
        require(blockHeader[offset] == 0xa0, "Invalid receiptsRoot RLP encoding");
        offset += 1;

        bytes32 receiptsRoot;
        assembly {
            receiptsRoot := calldataload(add(blockHeader.offset, offset))
        }

        return receiptsRoot;
    }

    /**
     * @dev Parse RLP item from calldata (helper function)
     * @param data Calldata containing RLP item
     * @param offset Current offset in the data
     * @return result Parsed item content
     * @return length Total length consumed
     */
    function parseItemFromCalldata(bytes calldata data, uint256 offset)
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
            uint256 itemLength = prefix - 0x80;
            result = new bytes(itemLength);
            for (uint256 i = 0; i < itemLength; i++) {
                result[i] = data[offset + 1 + i];
            }
            return (result, 1 + itemLength);
        } else if (prefix < 0xc0) {
            // Long string
            uint256 lengthBytes = prefix - 0xb7;
            uint256 itemLength = 0;
            for (uint256 i = 0; i < lengthBytes; i++) {
                itemLength = (itemLength << 8) | uint8(data[offset + 1 + i]);
            }
            result = new bytes(itemLength);
            for (uint256 i = 0; i < itemLength; i++) {
                result[i] = data[offset + 1 + lengthBytes + i];
            }
            return (result, 1 + lengthBytes + itemLength);
        } else {
            revert("Expected string item, got list");
        }
    }

    /**
     * @dev Extract state root from block header
     * @param blockHeader RLP-encoded block header
     * @return State root hash
     */
    function extractStateRoot(bytes calldata blockHeader) internal pure returns (bytes32) {
        uint256 offset = 0;

        // Skip RLP list prefix
        require(blockHeader[offset] >= 0xc0, "Invalid RLP list");
        if (blockHeader[offset] >= 0xf8) {
            offset += 1 + (uint8(blockHeader[offset]) - 0xf7);
        } else {
            offset += 1;
        }

        // Skip first 3 fields to get to stateRoot (index 3)
        for (uint256 i = 0; i < 3; i++) {
            offset = blockHeader.skipItem(offset);
        }

        // Extract stateRoot (32 bytes)
        require(blockHeader[offset] == 0xa0, "Invalid stateRoot RLP encoding");
        offset += 1;

        bytes32 stateRoot;
        assembly {
            stateRoot := calldataload(add(blockHeader.offset, offset))
        }

        return stateRoot;
    }

    /**
     * @dev Extract transactions root from block header
     * @param blockHeader RLP-encoded block header
     * @return Transactions root hash
     */
    function extractTransactionsRoot(bytes calldata blockHeader) internal pure returns (bytes32) {
        uint256 offset = 0;

        // Skip RLP list prefix
        require(blockHeader[offset] >= 0xc0, "Invalid RLP list");
        if (blockHeader[offset] >= 0xf8) {
            offset += 1 + (uint8(blockHeader[offset]) - 0xf7);
        } else {
            offset += 1;
        }

        // Skip first 4 fields to get to transactionsRoot (index 4)
        for (uint256 i = 0; i < 4; i++) {
            offset = blockHeader.skipItem(offset);
        }

        // Extract transactionsRoot (32 bytes)
        require(blockHeader[offset] == 0xa0, "Invalid transactionsRoot RLP encoding");
        offset += 1;

        bytes32 transactionsRoot;
        assembly {
            transactionsRoot := calldataload(add(blockHeader.offset, offset))
        }

        return transactionsRoot;
    }
}
