// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {StatementHash} from "../src/StatementHash.sol";

/// @title Differential test against the Rust reference encoder
/// @notice Spec 19.1. `test/fixtures/statement.json` is the authority;
/// if this disagrees with it, this is wrong.
///
/// Every case checks the packed preimage before the digest. `encodePacked` will
/// happily pack `uint32` as 32 bytes if the field is typed `uint256`, producing
/// a wrong-length preimage and a wrong hash, and comparing only digests would
/// not say which stage failed.
///
/// The file is vendored from the circuits repository; see
/// test/fixtures/README.md for how to regenerate it.
contract StatementHashTest is Test {
    string internal json;

    function setUp() public {
        json = vm.readFile("test/fixtures/statement.json");
    }

    /// Every vector's preimage, digest, and signals must match exactly.
    function test_MatchesEveryVector() public view {
        uint256 count = _caseCount();
        assertGt(count, 0, "no vectors found");

        for (uint256 i = 0; i < count; i++) {
            string memory at = string.concat(".cases[", vm.toString(i), "]");
            string memory name = vm.parseJsonString(json, string.concat(at, ".name"));

            StatementHash.Context memory c = _context(string.concat(at, ".input"));

            assertEq(
                StatementHash.preimage(c),
                vm.parseJsonBytes(json, string.concat(at, ".expected.preimage")),
                string.concat("preimage mismatch: ", name)
            );
            assertEq(
                StatementHash.hash(c),
                vm.parseJsonBytes32(json, string.concat(at, ".expected.statement_hash")),
                string.concat("digest mismatch: ", name)
            );

            uint256[2] memory got = StatementHash.signals(c);
            assertEq(
                got[0],
                vm.parseJsonUint(json, string.concat(at, ".expected.signal_hi")),
                string.concat("high limb mismatch: ", name)
            );
            assertEq(
                got[1],
                vm.parseJsonUint(json, string.concat(at, ".expected.signal_lo")),
                string.concat("low limb mismatch: ", name)
            );
        }
    }

    /// The preimage is fixed-width, so its length is a constant.
    ///
    /// A variable-length preimage would mean a field packed at the wrong width,
    /// which changes the digest for every input rather than failing loudly.
    function test_PreimageIsAlways285Bytes() public view {
        uint256 count = _caseCount();
        for (uint256 i = 0; i < count; i++) {
            StatementHash.Context memory c = _context(string.concat(".cases[", vm.toString(i), "].input"));
            assertEq(StatementHash.preimage(c).length, StatementHash.PREIMAGE_LENGTH, "wrong preimage length");
        }
    }

    /// The limbs must reconstruct the digest, since the verifier sees only them.
    function test_SignalsReconstructTheDigest() public view {
        StatementHash.Context memory c = _context(".cases[0].input");
        uint256[2] memory s = StatementHash.signals(c);
        assertEq(bytes32((s[0] << 128) | s[1]), StatementHash.hash(c), "limbs do not rebuild the digest");
    }

    /// Spec 10.1: omitting any context field is a critical soundness bug.
    ///
    /// Mutating each of the 14 fields in turn must change the digest. If a
    /// field is ever dropped from the packing, this catches it; the Rust side
    /// has the same test.
    ///
    /// Each case re-reads the base context rather than copying a local. A
    /// `memory` struct assignment in Solidity aliases rather than copies, so
    /// `m = base; m.field = x;` would mutate `base` too and each case would
    /// build on the last one's corruption. The Rust equivalent is safe because
    /// `Statement { field: x, ..sample() }` constructs a fresh value.
    function test_EveryFieldIsBound() public view {
        bytes32 want = StatementHash.hash(_base());

        StatementHash.Context memory m;

        m = _base();
        m.instanceDomain = bytes32(uint256(1));
        _mustDiffer(m, want, "instanceDomain");
        m = _base();
        m.chainId += 1;
        _mustDiffer(m, want, "chainId");
        m = _base();
        m.escrow = address(1);
        _mustDiffer(m, want, "escrow");
        m = _base();
        m.requestId = bytes32(uint256(1));
        _mustDiffer(m, want, "requestId");
        m = _base();
        m.rowIndex += 1;
        _mustDiffer(m, want, "rowIndex");
        m = _base();
        m.intentCommitment = bytes32(uint256(1));
        _mustDiffer(m, want, "intentCommitment");
        m = _base();
        m.bondAttempt += 1;
        _mustDiffer(m, want, "bondAttempt");
        m = _base();
        m.bondStartBlock += 1;
        _mustDiffer(m, want, "bondStartBlock");
        m = _base();
        m.bondDeadline += 1;
        _mustDiffer(m, want, "bondDeadline");
        m = _base();
        m.bondedCollector = address(1);
        _mustDiffer(m, want, "bondedCollector");
        m = _base();
        m.rowPayoutAsset = address(1);
        _mustDiffer(m, want, "rowPayoutAsset");
        m = _base();
        m.rowPayoutAmount += 1;
        _mustDiffer(m, want, "rowPayoutAmount");
        m = _base();
        m.witnessBlockNumber += 1;
        _mustDiffer(m, want, "witnessBlockNumber");
        m = _base();
        m.witnessBlockHash = bytes32(uint256(1));
        _mustDiffer(m, want, "witnessBlockHash");

        // The base must be unchanged: if any case above had aliased it, this
        // fails and the 14 assertions were checking corrupted inputs.
        assertEq(StatementHash.hash(_base()), want, "base context was mutated");
    }

    /// The replay-tag property, spec 10.2: a proof for one bond attempt must
    /// not verify under a later attempt of the same row.
    function test_BondAttemptSeparatesLeases() public view {
        StatementHash.Context memory a = _base();
        StatementHash.Context memory b = _base();
        b.bondAttempt = a.bondAttempt + 1;
        assertTrue(StatementHash.hash(a) != StatementHash.hash(b), "attempts share a digest");
    }

    // ------------------------------------------------------------- helpers

    function _mustDiffer(StatementHash.Context memory m, bytes32 want, string memory field) internal pure {
        require(StatementHash.hash(m) != want, string.concat("field not bound: ", field));
    }

    /// A fresh copy of the first vector's context on every call.
    function _base() internal view returns (StatementHash.Context memory) {
        return _context(".cases[0].input");
    }

    /// Number of cases in the vector file.
    ///
    /// Counted by probing indexes rather than a `.cases[*]` wildcard, which
    /// forge rejects for returning multiple values.
    function _caseCount() internal view returns (uint256 n) {
        while (vm.keyExistsJson(json, string.concat(".cases[", vm.toString(n), "].name"))) {
            n++;
        }
    }

    function _context(string memory at) internal view returns (StatementHash.Context memory) {
        return StatementHash.Context({
            instanceDomain: vm.parseJsonBytes32(json, string.concat(at, ".instance_domain")),
            chainId: vm.parseJsonUint(json, string.concat(at, ".chain_id")),
            escrow: vm.parseJsonAddress(json, string.concat(at, ".escrow")),
            requestId: vm.parseJsonBytes32(json, string.concat(at, ".request_id")),
            rowIndex: uint32(vm.parseJsonUint(json, string.concat(at, ".row_index"))),
            intentCommitment: vm.parseJsonBytes32(json, string.concat(at, ".intent_commitment")),
            bondAttempt: uint32(vm.parseJsonUint(json, string.concat(at, ".bond_attempt"))),
            bondStartBlock: uint64(vm.parseJsonUint(json, string.concat(at, ".bond_start_block"))),
            bondDeadline: uint64(vm.parseJsonUint(json, string.concat(at, ".bond_deadline"))),
            bondedCollector: vm.parseJsonAddress(json, string.concat(at, ".bonded_collector")),
            rowPayoutAsset: vm.parseJsonAddress(json, string.concat(at, ".row_payout_asset")),
            rowPayoutAmount: vm.parseJsonUint(json, string.concat(at, ".row_payout_amount")),
            witnessBlockNumber: uint64(vm.parseJsonUint(json, string.concat(at, ".witness_block_number"))),
            witnessBlockHash: vm.parseJsonBytes32(json, string.concat(at, ".witness_block_hash"))
        });
    }
}
