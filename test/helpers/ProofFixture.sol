// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

// Builds a hermetic, single-transaction-block proof fixture entirely in Solidity, so
// the bond-less collect happy-path can be tested with a key we control (no live node,
// no committed RLP blobs). A block with one tx makes each trie a single leaf: the trie
// root is keccak256(leaf), the proof is just that leaf node, and the path is the
// RLP-encoded tx index 0 == 0x80 (nibbles [8,0], HP-encoded leaf key 0x2080).
library ProofFixture {
    // RLP-encode a byte string.
    function rlpBytes(bytes memory item) internal pure returns (bytes memory) {
        if (item.length == 1 && uint8(item[0]) < 0x80) {
            return item;
        }
        return bytes.concat(_lenPrefix(item.length, 0x80, 0xb7), item);
    }

    // RLP-encode a list given its already-encoded concatenated items.
    function rlpList(bytes memory items) internal pure returns (bytes memory) {
        return bytes.concat(_lenPrefix(items.length, 0xc0, 0xf7), items);
    }

    // RLP-encode a 32-byte hash (always 0xa0 ++ 32 bytes).
    function rlpHash(bytes32 h) internal pure returns (bytes memory) {
        return bytes.concat(hex"a0", h);
    }

    // Single-leaf trie: root, leaf node, and the RLP([leaf]) proof array, for tx index 0.
    // value is the exact bytes stored (raw tx for the tx trie, raw receipt for receipts).
    function singleLeaf(bytes memory value)
        internal
        pure
        returns (bytes32 root, bytes memory proofArray, bytes memory path)
    {
        // HP-encoded key for nibbles [8,0] (even-length leaf): 0x20 ++ 0x80.
        bytes memory leaf = rlpList(bytes.concat(rlpBytes(hex"2080"), rlpBytes(value)));
        root = keccak256(leaf);
        proofArray = rlpList(leaf); // RLP array containing the single leaf node
        path = hex"80"; // RLP-encoded tx index 0
    }

    // Build a valid block header whose fields 4/5/8 are txRoot/receiptsRoot/number.
    // Other fields are placeholder hashes/values; only the parsed indices must be right.
    function buildHeader(bytes32 txRoot, bytes32 receiptsRoot, uint256 blockNumber)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 ph = keccak256("placeholder");
        bytes memory items = bytes.concat(
            rlpHash(ph), // 0 parentHash
            rlpHash(ph), // 1 ommersHash
            _rlpAddress(address(0)), // 2 beneficiary
            rlpHash(ph), // 3 stateRoot
            rlpHash(txRoot), // 4 transactionsRoot
            rlpHash(receiptsRoot), // 5 receiptsRoot
            _rlpEmptyBloom(), // 6 logsBloom (256 bytes)
            rlpBytes(hex"") // 7 difficulty (0)
        );
        items = bytes.concat(items, _rlpUint(blockNumber)); // 8 number
        return rlpList(items);
    }

    // Minimal successful type-0x02 receipt with no logs:
    // 0x02 ++ rlp([status=1, cumulativeGasUsed, bloom(256 zero), logs=[]]).
    function successReceiptNoLogs() internal pure returns (bytes memory) {
        bytes memory items = bytes.concat(
            rlpUint(1), // status = 1
            rlpUint(21000), // cumulativeGasUsed
            _rlpEmptyBloom(), // logsBloom
            hex"c0" // empty logs list
        );
        return bytes.concat(hex"02", rlpList(items));
    }

    // Successful type-0x02 receipt with a single ERC20 Transfer log.
    // logs = [ [token, [TRANSFER_SIG, from, to], amount] ].
    function successReceiptWithTransfer(address token, address from, address to, uint256 amount)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 transferSig = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;
        bytes memory topics = rlpList(
            bytes.concat(
                rlpHash(transferSig), rlpHash(bytes32(uint256(uint160(from)))), rlpHash(bytes32(uint256(uint160(to))))
            )
        );
        bytes memory log = rlpList(bytes.concat(_rlpAddress(token), topics, rlpBytes(_trim(amount))));
        bytes memory logs = rlpList(log);
        bytes memory items = bytes.concat(rlpUint(1), rlpUint(21000), _rlpEmptyBloom(), logs);
        return bytes.concat(hex"02", rlpList(items));
    }

    // Big-endian minimal bytes of a uint (for the log data amount).
    function _trim(uint256 value) private pure returns (bytes memory) {
        if (value == 0) return hex"";
        uint256 len = 0;
        uint256 tmp = value;
        while (tmp != 0) {
            ++len;
            tmp >>= 8;
        }
        bytes memory body = new bytes(len);
        for (uint256 i = 0; i < len; ++i) {
            body[len - 1 - i] = bytes1(uint8(value >> (8 * i)));
        }
        return body;
    }

    // --- internal RLP primitives ---

    function _lenPrefix(uint256 len, uint8 shortBase, uint8 longBase) private pure returns (bytes memory) {
        if (len < 56) {
            return bytes.concat(bytes1(uint8(shortBase + len)));
        }
        uint256 lenLen = 0;
        uint256 tmp = len;
        while (tmp != 0) {
            ++lenLen;
            tmp >>= 8;
        }
        bytes memory out = new bytes(1 + lenLen);
        out[0] = bytes1(uint8(longBase + lenLen));
        for (uint256 i = 0; i < lenLen; ++i) {
            out[lenLen - i] = bytes1(uint8(len >> (8 * i)));
        }
        return out;
    }

    // RLP-encode a non-negative integer (minimal big-endian).
    function rlpUint(uint256 value) internal pure returns (bytes memory) {
        if (value == 0) return hex"80";
        if (value < 0x80) return bytes.concat(bytes1(uint8(value)));
        uint256 len = 0;
        uint256 tmp = value;
        while (tmp != 0) {
            ++len;
            tmp >>= 8;
        }
        bytes memory body = new bytes(len);
        for (uint256 i = 0; i < len; ++i) {
            body[len - 1 - i] = bytes1(uint8(value >> (8 * i)));
        }
        return rlpBytes(body);
    }

    function _rlpUint(uint256 value) private pure returns (bytes memory) {
        return rlpUint(value);
    }

    function _rlpAddress(address a) private pure returns (bytes memory) {
        return bytes.concat(hex"94", bytes20(a));
    }

    function _rlpEmptyBloom() private pure returns (bytes memory) {
        // 256-byte zero bloom: long-string prefix 0xb9 0x0100 ++ 256 zero bytes.
        bytes memory bloom = new bytes(256);
        return bytes.concat(hex"b90100", bloom);
    }
}
