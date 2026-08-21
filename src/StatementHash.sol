// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @title Spec 10.2 statement hash
/// @notice Packs the 285-byte statement preimage and splits its keccak-256
/// digest into the two 128-bit limbs the Groth16 verifier takes as public
/// signals.
///
/// The Rust reference lives in the circuits repository at
/// `crates/encoding/src/statement.rs`, and the authority is its vector file,
/// vendored here as `test/fixtures/statement.json`. A one-byte disagreement
/// between this library, the circuit, and the reference surfaces only as
/// "proof rejected", with nothing indicating which side is wrong, so
/// `test/StatementHash.t.sol` checks every field width against those vectors.
///
/// Field widths are the spec packing, not Solidity's natural types. In
/// particular `rowIndex` and `bondAttempt` pack as 4 bytes, the block numbers
/// as 8, and `chainId` as a left-padded 32-byte word.
library StatementHash {
    /// Leading byte of the preimage, spec 18.4. Bumping the relation is a new
    /// circuit version and a new verifying key.
    uint8 internal constant RELATION_VERSION = 2;

    /// Exact packed length. Checked in tests rather than trusted: `encodePacked`
    /// silently accepts a wrong-width argument.
    uint256 internal constant PREIMAGE_LENGTH = 285;

    /// @dev Grouped into a struct because the packing takes 14 fields and
    /// Solidity's stack cannot hold them as separate arguments.
    struct Context {
        bytes32 instanceDomain;
        uint256 chainId;
        address escrow;
        bytes32 requestId;
        uint32 rowIndex;
        bytes32 intentCommitment;
        uint32 bondAttempt;
        uint64 bondStartBlock;
        uint64 bondDeadline;
        address bondedCollector;
        address rowPayoutAsset;
        uint256 rowPayoutAmount;
        uint64 witnessBlockNumber;
        bytes32 witnessBlockHash;
    }

    /// @notice The 285-byte packed preimage.
    /// @dev Exposed so tests can compare packing and hashing independently. A
    /// mismatch in the digest alone does not say which of the two is wrong.
    function preimage(Context memory c) internal pure returns (bytes memory) {
        return abi.encodePacked(
            RELATION_VERSION,
            c.instanceDomain,
            c.chainId,
            c.escrow,
            c.requestId,
            c.rowIndex,
            c.intentCommitment,
            c.bondAttempt,
            c.bondStartBlock,
            c.bondDeadline,
            c.bondedCollector,
            c.rowPayoutAsset,
            c.rowPayoutAmount,
            c.witnessBlockNumber,
            c.witnessBlockHash
        );
    }

    function hash(Context memory c) internal pure returns (bytes32) {
        return keccak256(preimage(c));
    }

    /// @notice The two Groth16 public signals: the high and low 128-bit limbs.
    /// @dev Spec 8.1: one BN254 field element cannot hold a 256-bit value, so
    /// the digest is carried as two limbs and never reduced modulo the field
    /// order. Order is high then low, matching the verifier's input array.
    function signals(Context memory c) internal pure returns (uint256[2] memory) {
        uint256 h = uint256(hash(c));
        return [h >> 128, h & type(uint128).max];
    }
}
