// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./RLPParser.sol";

/**
 * @title BlockHeaderParser
 * @dev Library for parsing Ethereum and Tempo block headers
 * Extracts receipts root, block number, and other header fields
 *
 * Tempo block headers have a wrapper structure:
 * [slot, parent_slot, extra, inner_header]
 * where inner_header follows standard Ethereum format
 */
library BlockHeaderParser {
    using RLPParser for bytes;

    error InvalidRLPList();
    error InvalidRLPEncoding();

    /**
     * @dev Get offset to inner header (skips Tempo wrapper if present)
     * Tempo: [slot, parent_slot, extra, inner_header] -> skip to inner_header
     * Ethereum: header is at root level
     */
    function getInnerHeaderOffset(bytes calldata blockHeader) private view returns (uint256) {
        uint256 offset = 0;

        // Skip outer RLP list prefix
        if (blockHeader[offset] < 0xc0) revert InvalidRLPList();
        if (blockHeader[offset] >= 0xf8) {
            offset += 1 + (uint8(blockHeader[offset]) - 0xf7);
        } else {
            offset += 1;
        }

        // Tempo networks: 42429 (local/test), 42431 (Moderato testnet)
        if (block.chainid == 42429 || block.chainid == 42431) {
            // Tempo: skip first 3 fields (slot, parent_slot, extra) to get to inner header
            for (uint256 i = 0; i < 3;) {
                offset = blockHeader.skipItem(offset);
                unchecked {
                    ++i;
                }
            }

            // Now skip the inner header's list prefix
            if (blockHeader[offset] < 0xc0) revert InvalidRLPList();
            if (blockHeader[offset] >= 0xf8) {
                offset += 1 + (uint8(blockHeader[offset]) - 0xf7);
            } else {
                offset += 1;
            }
        }

        return offset;
    }

    /**
     * @dev Extract block number from RLP-encoded block header
     * @param blockHeader RLP-encoded block header
     * @return Block number
     */
    function extractBlockNumber(bytes calldata blockHeader) internal view returns (uint256) {
        uint256 offset = getInnerHeaderOffset(blockHeader);

        // Skip first 8 fields to get to block number (index 8)
        // [parentHash, sha3Uncles, miner, stateRoot, transactionsRoot, receiptsRoot, logsBloom, difficulty, number, ...]
        for (uint256 i = 0; i < 8;) {
            offset = blockHeader.skipItem(offset);
            unchecked {
                ++i;
            }
        }

        // Extract block number directly from calldata
        uint8 prefix = uint8(blockHeader[offset]);
        uint256 blockNumber;
        if (prefix < 0x80) {
            blockNumber = prefix;
        } else {
            uint256 len = prefix - 0x80;
            for (uint256 i = 0; i < len;) {
                blockNumber = (blockNumber << 8) | uint8(blockHeader[offset + 1 + i]);
                unchecked {
                    ++i;
                }
            }
        }

        return blockNumber;
    }

    /**
     * @dev Extract receipts root from RLP-encoded block header
     * @param blockHeader RLP-encoded block header
     * @return Receipts root hash
     */
    function extractReceiptsRoot(bytes calldata blockHeader) internal view returns (bytes32) {
        uint256 offset = getInnerHeaderOffset(blockHeader);

        // Skip first 5 fields to get to receiptsRoot (index 5)
        // [parentHash, sha3Uncles, miner, stateRoot, transactionsRoot, receiptsRoot, ...]
        for (uint256 i = 0; i < 5;) {
            offset = blockHeader.skipItem(offset);
            unchecked {
                ++i;
            }
        }

        // Extract receiptsRoot (32 bytes)
        if (blockHeader[offset] != 0xa0) revert InvalidRLPEncoding();
        offset += 1;

        bytes32 receiptsRoot;
        assembly {
            receiptsRoot := calldataload(add(blockHeader.offset, offset))
        }

        return receiptsRoot;
    }

    /**
     * @dev Extract transactions root from block header
     * @param blockHeader RLP-encoded block header
     * @return Transactions root hash
     */
    function extractTransactionsRoot(bytes calldata blockHeader) internal pure returns (bytes32) {
        uint256 offset = 0;

        // Skip RLP list prefix
        if (blockHeader[offset] < 0xc0) revert InvalidRLPList();
        if (blockHeader[offset] >= 0xf8) {
            offset += 1 + (uint8(blockHeader[offset]) - 0xf7);
        } else {
            offset += 1;
        }

        // Skip first 4 fields to get to transactionsRoot (index 4)
        for (uint256 i = 0; i < 4;) {
            offset = blockHeader.skipItem(offset);
            unchecked {
                ++i;
            }
        }

        // Extract transactionsRoot (32 bytes)
        if (blockHeader[offset] != 0xa0) revert InvalidRLPEncoding();
        offset += 1;

        bytes32 transactionsRoot;
        assembly {
            transactionsRoot := calldataload(add(blockHeader.offset, offset))
        }

        return transactionsRoot;
    }
}
