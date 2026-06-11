// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./RLPParser.sol";
import "./utils/ECDSA.sol";

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
    error InvalidSignatureV();

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

    /**
     * @dev Recover the sender (`from`) of a signed transaction from its raw RLP.
     * Tx-type aware: legacy (EIP-155) / EIP-2930 (0x01) / EIP-1559 (0x02).
     *
     * Reconstructs the signing hash the sender originally signed -- the tx body
     * with the `[v, r, s]` (legacy) / `[yParity, r, s]` (typed) trailer stripped --
     * then ecrecovers. This yields the executing account trustlessly from the same
     * proof, with no extra calldata.
     *
     * @param txRlp RLP-encoded signed transaction (typed txs include the type prefix)
     * @return The recovered sender address
     */
    function recoverTxSender(bytes calldata txRlp) internal pure returns (address) {
        uint256 offset = 0;
        uint8 txType = 0;

        // Field count before the signature trailer:
        //   legacy: [nonce, gasPrice, gasLimit, to, value, data]                       -> 6
        //   2930:   [chainId, nonce, gasPrice, gasLimit, to, value, data, accessList]  -> 8
        //   1559:   [chainId, nonce, maxPrio, maxFee, gasLimit, to, value, data, al]   -> 9
        uint256 preSigFields = 6;
        if (txRlp.length > 0 && uint8(txRlp[0]) < 0x80) {
            txType = uint8(txRlp[0]);
            offset = 1;
            if (txType == 0x01) {
                preSigFields = 8;
            } else if (txType == 0x02) {
                preSigFields = 9;
            } else {
                revert UnsupportedTxType();
            }
        }

        // Outer list bounds
        (uint256 contentStart, uint256 contentEnd) = RLPParser.itemBounds(txRlp, offset);

        // Walk past the pre-signature fields to find where the signature trailer begins.
        uint256 cursor = contentStart;
        for (uint256 i = 0; i < preSigFields;) {
            cursor = RLPParser.skipItem(txRlp, cursor);
            unchecked {
                ++i;
            }
        }
        uint256 sigStart = cursor;

        // Parse the signature trailer: v/yParity, r, s.
        (bytes32 vScalar, uint256 afterV) = RLPParser.readScalar(txRlp, sigStart);
        (bytes32 r, uint256 afterR) = RLPParser.readScalar(txRlp, afterV);
        (bytes32 s,) = RLPParser.readScalar(txRlp, afterR);

        bytes32 signingHash;
        uint8 v;
        if (txType == 0) {
            // Legacy (EIP-155): signed over rlp([nonce, gasPrice, gasLimit, to, value,
            // data, chainId, 0, 0]). The first 6 fields are a prefix of the content; we
            // append rlp(chainId) ++ 0x80 ++ 0x80 and recompute the list header.
            uint256 vRaw = uint256(vScalar);
            uint256 chainId;
            if (vRaw == 27 || vRaw == 28) {
                // Pre-EIP-155 transaction: no chainId in the signing payload.
                v = uint8(vRaw);
                signingHash = keccak256(_legacySigningPayload(txRlp, contentStart, sigStart, type(uint256).max));
            } else {
                // EIP-155: v = chainId * 2 + 35 + yParity, so chainId = (v - 35) / 2
                // and yParity = (v - 35) & 1.
                chainId = (vRaw - 35) >> 1;
                v = uint8(27 + ((vRaw - 35) & 1));
                signingHash = keccak256(_legacySigningPayload(txRlp, contentStart, sigStart, chainId));
            }
        } else {
            // Typed (EIP-2930 / EIP-1559): signed over
            // txType ++ rlp([...fields without signature...]).
            // The fields-without-signature are content[contentStart:sigStart]; recompute
            // the list header for that shortened length.
            uint256 payloadLen = sigStart - contentStart;
            bytes memory header = _rlpListHeader(payloadLen);
            signingHash = keccak256(bytes.concat(bytes1(txType), header, txRlp[contentStart:sigStart]));

            uint256 yParity = uint256(vScalar);
            if (yParity > 1) revert InvalidSignatureV();
            v = uint8(27 + yParity);
        }

        // Silence unused warning for contentEnd (bounds were validated by itemBounds).
        contentEnd;

        return ECDSA.recover(signingHash, v, r, s);
    }

    /**
     * @dev Build the EIP-155 legacy signing payload:
     * rlp([nonce, gasPrice, gasLimit, to, value, data, chainId, 0, 0]).
     * The first six fields are copied verbatim from the tx content; chainId/0/0 are
     * appended. Pass `chainId == type(uint256).max` for a pre-EIP-155 tx (omit the
     * trailing chainId/0/0 entirely).
     */
    function _legacySigningPayload(bytes calldata txRlp, uint256 contentStart, uint256 sigStart, uint256 chainId)
        private
        pure
        returns (bytes memory)
    {
        bytes calldata sixFields = txRlp[contentStart:sigStart];

        bytes memory tail;
        if (chainId == type(uint256).max) {
            tail = "";
        } else {
            // rlp(chainId) ++ rlp(0) ++ rlp(0); rlp(0) == 0x80.
            tail = bytes.concat(_rlpUint(chainId), hex"8080");
        }

        uint256 payloadLen = sixFields.length + tail.length;
        return bytes.concat(_rlpListHeader(payloadLen), sixFields, tail);
    }

    /**
     * @dev RLP-encode a non-negative integer (minimal big-endian, no leading zeros).
     */
    function _rlpUint(uint256 value) private pure returns (bytes memory) {
        if (value == 0) return hex"80";
        if (value < 0x80) return bytes.concat(bytes1(uint8(value)));

        // Minimal big-endian byte length.
        uint256 len = 0;
        uint256 tmp = value;
        while (tmp != 0) {
            ++len;
            tmp >>= 8;
        }
        bytes memory out = new bytes(1 + len);
        out[0] = bytes1(uint8(0x80 + len));
        for (uint256 i = 0; i < len;) {
            out[len - i] = bytes1(uint8(value >> (8 * i)));
            unchecked {
                ++i;
            }
        }
        return out;
    }

    /**
     * @dev RLP list header for a payload of `payloadLen` bytes.
     */
    function _rlpListHeader(uint256 payloadLen) private pure returns (bytes memory) {
        if (payloadLen < 56) {
            return bytes.concat(bytes1(uint8(0xc0 + payloadLen)));
        }
        // Long list: 0xf7 + lengthOfLength, then the big-endian length.
        uint256 lenLen = 0;
        uint256 tmp = payloadLen;
        while (tmp != 0) {
            ++lenLen;
            tmp >>= 8;
        }
        bytes memory out = new bytes(1 + lenLen);
        out[0] = bytes1(uint8(0xf7 + lenLen));
        for (uint256 i = 0; i < lenLen;) {
            out[lenLen - i] = bytes1(uint8(payloadLen >> (8 * i)));
            unchecked {
                ++i;
            }
        }
        return out;
    }
}
