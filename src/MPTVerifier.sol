// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./RLPParser.sol";

/**
 * @title MPTVerifier
 * @dev Library for verifying Merkle Patricia Trie inclusion proofs
 * Used to prove that transaction receipts are included in Ethereum blocks
 */
library MPTVerifier {
    using RLPParser for bytes;

    /**
     * @dev Verify receipt inclusion using Merkle Patricia Trie proof
     * @param receiptRlp RLP-encoded transaction receipt
     * @param proofNodes RLP-encoded array of MPT proof nodes
     * @param receiptPath RLP-encoded transaction index (key)
     * @param receiptsRoot Root hash of the receipts trie
     * @return True if the proof is valid
     */
    function verifyReceiptProof(
        bytes calldata receiptRlp,
        bytes calldata proofNodes,
        bytes calldata receiptPath,
        bytes32 receiptsRoot
    ) internal pure returns (bool) {
        // Key is the RLP-encoded tx index BYTES (unmodified)
        bytes memory key = receiptPath;
        // Value is EXACT receipt bytes
        bytes memory value = receiptRlp;

        // Verify MPT proof
        return verifyProof(key, value, proofNodes, receiptsRoot);
    }

    /**
     * @dev Core MPT proof verification algorithm with RLP array format
     * @param key The key to prove (RLP-encoded transaction index)
     * @param value The value to prove (transaction receipt)
     * @param proofArray RLP-encoded array of proof nodes
     * @param root Root hash of the trie
     * @return True if the proof is valid
     */
    function verifyProof(bytes memory key, bytes memory value, bytes calldata proofArray, bytes32 root)
        internal
        pure
        returns (bool)
    {
        // Parse the RLP array header
        uint256 arrayOffset = 0;
        require(proofArray[0] >= 0xc0, "Expected RLP list for proof nodes");

        if (proofArray[0] >= 0xf8) {
            uint256 lengthBytes = uint8(proofArray[0]) - 0xf7;
            arrayOffset = 1 + lengthBytes;
        } else {
            arrayOffset = 1;
        }

        bytes32 currentHash = root;
        uint256 proofOffset = arrayOffset;
        uint256 keyOffset = 0;

        while (proofOffset < proofArray.length) {
            // Parse next node from proof array
            (bytes memory node, uint256 nodeLength) = proofArray.parseItem(proofOffset);
            proofOffset += nodeLength;

            // Verify current hash matches this node
            if (keccak256(node) != currentHash) {
                return false;
            }

            // Decode node to determine type
            uint256 nodeOffset = 0;
            if (node[0] >= 0xc0) {
                nodeOffset = 1;
                if (node[0] >= 0xf8) {
                    nodeOffset += uint8(node[0]) - 0xf7;
                }

                uint256 items = countListItems(node, nodeOffset);

                if (items == 17) {
                    // Branch node
                    (bool success, uint256 newKeyOffset, bytes32 newHash) =
                        processBranchNode(node, nodeOffset, key, keyOffset, value);

                    if (!success) return false;
                    if (newHash == bytes32(0)) return true;

                    keyOffset = newKeyOffset;
                    currentHash = newHash;
                } else if (items == 2) {
                    // Leaf or Extension node
                    (bool success, uint256 newKeyOffset, bytes32 newHash) =
                        processLeafOrExtensionNode(node, nodeOffset, key, keyOffset, value);

                    if (!success) {
                        return false;
                    }
                    if (newHash == bytes32(0)) {
                        return true;
                    }

                    keyOffset = newKeyOffset;
                    currentHash = newHash;
                } else {
                    return false;
                }
            } else {
                return false;
            }
        }

        return false;
    }

    /**
     * @dev Count RLP items in a list
     * @param data The RLP encoded list
     * @param startOffset Offset to start counting from
     * @return Number of items in the list
     */
    function countListItems(bytes memory data, uint256 startOffset) private pure returns (uint256) {
        uint256 offset = startOffset;
        uint256 items = 0;
        while (offset < data.length) {
            offset += data.getItemLength(offset);
            items++;
        }
        return items;
    }

    /**
     * @dev Process a branch node in the MPT
     * @param node The RLP-encoded node
     * @param nodeOffset Offset within the node data
     * @param key The key being searched
     * @param keyOffset Current position in the key
     * @param value The value being proven
     * @return success Whether processing succeeded
     * @return newKeyOffset Updated key offset
     * @return newHash Next hash to follow (or 0 if value found)
     */
    function processBranchNode(
        bytes memory node,
        uint256 nodeOffset,
        bytes memory key,
        uint256 keyOffset,
        bytes memory value
    ) private pure returns (bool success, uint256 newKeyOffset, bytes32 newHash) {
        if (keyOffset >= key.length * 2) {
            // Check value in branch node (at index 16)
            uint256 valueOffset = nodeOffset;
            for (uint256 i = 0; i < 16; i++) {
                valueOffset += node.getItemLength(valueOffset);
            }
            (bytes memory nodeValue,) = node.parseItem(valueOffset);
            if (keccak256(nodeValue) == keccak256(value)) {
                return (true, keyOffset, bytes32(0)); // Found value, signal end
            } else {
                return (false, 0, bytes32(0));
            }
        }

        // Navigate to next branch
        uint8 nibble = uint8(key[keyOffset / 2]);
        if (keyOffset % 2 == 0) {
            nibble = nibble >> 4;
        } else {
            nibble = nibble & 0x0f;
        }

        // Get the branch at this nibble
        uint256 branchOffset = nodeOffset;
        for (uint256 i = 0; i < nibble; i++) {
            branchOffset += node.getItemLength(branchOffset);
        }

        (bytes memory nextHash,) = node.parseItem(branchOffset);
        if (nextHash.length == 0) {
            return (false, 0, bytes32(0)); // Empty branch
        }

        bytes32 hash;
        if (nextHash.length == 32) {
            assembly {
                hash := mload(add(nextHash, 32))
            }
        } else {
            hash = keccak256(nextHash);
        }

        return (true, keyOffset + 1, hash);
    }

    /**
     * @dev Process a leaf or extension node in the MPT
     * @param node The RLP-encoded node
     * @param nodeOffset Offset within the node data
     * @param key The key being searched
     * @param keyOffset Current position in the key
     * @param value The value being proven
     * @return success Whether processing succeeded
     * @return newKeyOffset Updated key offset
     * @return newHash Next hash to follow (or 0 if value found)
     */
    function processLeafOrExtensionNode(
        bytes memory node,
        uint256 nodeOffset,
        bytes memory key,
        uint256 keyOffset,
        bytes memory value
    ) private pure returns (bool success, uint256 newKeyOffset, bytes32 newHash) {
        (bytes memory keyEnc, uint256 keyEncLen) = node.parseItem(nodeOffset);
        bool isLeaf = (uint8(keyEnc[0]) & 0x20) != 0; // HP flag
        bytes memory nodeKey = extractKeyFromNode(keyEnc);

        if (isLeaf) {
            // Check if the remaining path in the key matches this leaf's key
            if (keyOffset + nodeKey.length == key.length * 2) {
                bool keyMatches = true;
                if (nodeKey.length > 0) {
                    keyMatches = compareKeys(key, keyOffset, nodeKey);
                }

                if (keyMatches) {
                    (bytes memory nodeValue,) = node.parseItem(nodeOffset + keyEncLen);
                    if (keccak256(nodeValue) == keccak256(value)) {
                        return (true, keyOffset + nodeKey.length, bytes32(0));
                    }
                }
            }

            return (false, 0, bytes32(0));
        } else {
            // Extension node
            if (!compareKeys(key, keyOffset, nodeKey)) {
                return (false, 0, bytes32(0));
            }

            (bytes memory nextRef,) = node.parseItem(nodeOffset + keyEncLen);
            bytes32 hash;
            if (nextRef.length == 32) {
                assembly {
                    hash := mload(add(nextRef, 32))
                }
            } else if (nextRef.length > 0) {
                hash = keccak256(nextRef);
            } else {
                return (false, 0, bytes32(0));
            }

            return (true, keyOffset + nodeKey.length, hash);
        }
    }

    /**
     * @dev Extract key from MPT node (Hex-Prefix decoding)
     * @param nodeKey HP-encoded key from the node
     * @return Decoded nibble array
     */
    function extractKeyFromNode(bytes memory nodeKey) private pure returns (bytes memory) {
        if (nodeKey.length == 0) return nodeKey;

        uint8 firstByte = uint8(nodeKey[0]);
        bool isOdd = (firstByte & 0x10) != 0;

        bytes memory result;
        if (isOdd) {
            result = new bytes(nodeKey.length * 2 - 1);
            result[0] = bytes1(firstByte & 0x0f);
            for (uint256 i = 1; i < nodeKey.length; i++) {
                result[i * 2 - 1] = bytes1(uint8(nodeKey[i]) >> 4);
                result[i * 2] = bytes1(uint8(nodeKey[i]) & 0x0f);
            }
        } else {
            result = new bytes(nodeKey.length * 2 - 2);
            for (uint256 i = 1; i < nodeKey.length; i++) {
                result[(i - 1) * 2] = bytes1(uint8(nodeKey[i]) >> 4);
                result[(i - 1) * 2 + 1] = bytes1(uint8(nodeKey[i]) & 0x0f);
            }
        }

        return result;
    }

    /**
     * @dev Compare keys starting from offset
     * @param key The full key
     * @param offset Starting position in the key
     * @param nodeKey The node key to compare against
     * @return True if keys match
     */
    function compareKeys(bytes memory key, uint256 offset, bytes memory nodeKey) private pure returns (bool) {
        if (offset + nodeKey.length > key.length * 2) return false;

        for (uint256 i = 0; i < nodeKey.length; i++) {
            uint8 keyNibble;
            if ((offset + i) % 2 == 0) {
                keyNibble = uint8(key[(offset + i) / 2]) >> 4;
            } else {
                keyNibble = uint8(key[(offset + i) / 2]) & 0x0f;
            }

            if (keyNibble != uint8(nodeKey[i])) {
                return false;
            }
        }

        return true;
    }
}
