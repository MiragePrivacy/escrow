// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EscrowERC20} from "../src/EscrowERC20.sol";
import {EscrowBase} from "../src/EscrowBase.sol";

/// @title End-to-end collection against a real Groth16 proof
/// @notice The test that would catch a broken swap. Everything else in the
/// suite exercises guard clauses that run before the proof logic, so they keep
/// passing whatever `collect` does internally.
///
/// The proof comes from `test/fixtures/proof.json`, vendored from the circuits
/// repository and produced by its `export-verifier` binary. Its statement
/// block records the context the circuit committed to; the escrow must
/// reproduce that context byte for byte from its own storage or the proof will
/// not verify against it.
///
/// Reproducing it takes cheatcodes: the escrow has to live at the fixture's
/// address, hold its bond state, and see its witness block hash. That is the
/// point — it demonstrates the escrow's computed statement and the circuit's
/// agree, which is the single property the integration depends on.
contract EscrowZKTest is Test {
    EscrowERC20 internal escrow;

    uint256[8] internal proof;
    uint256[2] internal signals;

    // Statement context the proof was generated against.
    address internal fixtureEscrow;
    address internal collector;
    uint64 internal witnessBlockNumber;
    bytes32 internal witnessBlockHash;
    uint64 internal bondStartBlock;
    uint64 internal bondDeadline;
    uint32 internal bondAttempt;
    bytes32 internal instanceDomain;
    bytes32 internal requestId;
    bytes32 internal intentCommitment;
    address internal payoutAsset;
    uint256 internal payoutAmount;

    function setUp() public {
        string memory json = vm.readFile("test/fixtures/proof.json");

        // The statement binds chainId, and the fixture was generated for
        // mainnet. Foundry's default 31337 would produce a different digest.
        vm.chainId(vm.parseJsonUint(json, ".statement.chainId"));

        uint256[] memory p = vm.parseJsonUintArray(json, ".proof");
        for (uint256 i = 0; i < 8; i++) {
            proof[i] = p[i];
        }
        uint256[] memory s = vm.parseJsonUintArray(json, ".publicSignals");
        signals[0] = s[0];
        signals[1] = s[1];

        fixtureEscrow = vm.parseJsonAddress(json, ".statement.escrow");
        collector = vm.parseJsonAddress(json, ".statement.bondedCollector");
        witnessBlockNumber = uint64(vm.parseJsonUint(json, ".statement.witnessBlockNumber"));
        witnessBlockHash = vm.parseJsonBytes32(json, ".statement.witnessBlockHash");
        bondStartBlock = uint64(vm.parseJsonUint(json, ".statement.bondStartBlock"));
        bondDeadline = uint64(vm.parseJsonUint(json, ".statement.bondDeadline"));
        bondAttempt = uint32(vm.parseJsonUint(json, ".statement.bondAttempt"));
        instanceDomain = vm.parseJsonBytes32(json, ".statement.instanceDomain");
        requestId = vm.parseJsonBytes32(json, ".statement.requestId");
        intentCommitment = vm.parseJsonBytes32(json, ".statement.intentCommitment");
        payoutAsset = vm.parseJsonAddress(json, ".statement.rowPayoutAsset");
        payoutAmount = vm.parseJsonUint(json, ".statement.rowPayoutAmount");

        _deployAtFixtureAddress();
        _forceBondState();
    }

    /// The property the integration rests on: the escrow's own statement, built
    /// from storage, equals what the circuit committed to.
    ///
    /// If this fails, every other test here fails too and the fault is in the
    /// encoder or the escrow's field wiring, not in the proof.
    function test_EscrowRebuildsTheCircuitsStatement() public view {
        uint256[2] memory got = escrow.statementSignals(witnessBlockNumber);
        assertEq(got[0], signals[0], "high limb differs from the circuit's");
        assertEq(got[1], signals[1], "low limb differs from the circuit's");
    }

    /// A real proof must settle the escrow and pay the collector.
    function test_CollectsAgainstARealProof() public {
        vm.prank(collector);
        escrow.collect(proof, signals, witnessBlockNumber);

        assertFalse(escrow.funded(), "escrow still funded after collection");
        assertEq(escrow.bondedExecutor(), address(0), "bond not cleared");
        assertEq(escrow.currentRewardAmount(), 0, "reward not cleared");
    }

    /// Gas for the ZK path, against 724,991 for the plaintext path.
    function test_ReportsCollectGas() public {
        vm.prank(collector);
        uint256 before = gasleft();
        escrow.collect(proof, signals, witnessBlockNumber);
        emit log_named_uint("zk collect gas", before - gasleft());
    }

    /// Signals that do not match the escrow's own computation are rejected
    /// before the pairing check.
    function test_RejectsMismatchedSignals() public {
        uint256[2] memory tampered = [signals[0] + 1, signals[1]];
        vm.prank(collector);
        vm.expectRevert(EscrowERC20.StatementMismatch.selector);
        escrow.collect(proof, tampered, witnessBlockNumber);
    }

    /// A tampered proof must not verify. The verifier reverts rather than
    /// returning false, so the whole collection reverts.
    function test_RejectsATamperedProof() public {
        uint256[8] memory bad = proof;
        bad[0] = bad[0] ^ 1;
        vm.prank(collector);
        vm.expectRevert();
        escrow.collect(bad, signals, witnessBlockNumber);
    }

    /// Only the bonded collector may collect, even holding a valid proof.
    function test_RejectsAnyoneButTheBondedCollector() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(EscrowBase.OnlyBondedExecutor.selector);
        escrow.collect(proof, signals, witnessBlockNumber);
    }

    /// Spec 12.10: witness blocks older than 128 are refused, so a proof cannot
    /// be anchored to a block whose hash the EVM no longer serves.
    function test_RejectsAStaleWitnessBlock() public {
        // Roll past the lookback window but keep the lease live, so the
        // witness-age check is what fires rather than the bond guard.
        vm.roll(witnessBlockNumber + escrow.MAX_WITNESS_LOOKBACK() + 1);
        vm.store(address(escrow), bytes32(uint256(4)), bytes32(uint256(block.number + 10)));
        vm.prank(collector);
        vm.expectRevert(EscrowERC20.WitnessBlockTooOld.selector);
        escrow.collect(proof, signals, witnessBlockNumber);
    }

    /// Spec 12.7: the settlement must fall inside the lease, so a witness at or
    /// before the bond start is refused.
    function test_RejectsAWitnessBeforeTheBond() public {
        // Re-point bondStartBlock (slot 5) to the witness block, so the
        // settlement no longer falls strictly inside the lease.
        vm.store(address(escrow), bytes32(uint256(5)), bytes32(uint256(witnessBlockNumber)));
        vm.prank(collector);
        vm.expectRevert(EscrowBase.ProofBeforeBond.selector);
        escrow.collect(proof, signals, witnessBlockNumber);
    }

    // ------------------------------------------------------------- helpers

    /// Deploys the escrow, then relocates it to the address the circuit
    /// committed to.
    ///
    /// `address(this)` is inside the statement hash, so a proof is bound to one
    /// escrow address. The fixture used 0x2222...2222, which no ordinary
    /// deployment produces.
    function _deployAtFixtureAddress() internal {
        vm.mockCall(payoutAsset, abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));
        vm.mockCall(payoutAsset, abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(true));

        EscrowERC20 built = new EscrowERC20(
            payoutAsset,
            payoutAmount,
            intentCommitment,
            instanceDomain,
            requestId,
            vm.addr(uint256(keccak256("enclave"))),
            payoutAmount / 4,
            0
        );

        vm.etch(fixtureEscrow, address(built).code);
        escrow = EscrowERC20(fixtureEscrow);

        // Immutables live in code, so etch carries them. Storage does not, so
        // the mutable funding state is written below.
    }

    /// Writes the bond and funding state the statement commits to.
    ///
    /// Bonding through `bond()` would set the deadline from the current block
    /// and the attempt from whatever the counter held; the fixture pins both,
    /// so they are stored directly. `_forceBondState` therefore stands in for a
    /// bond that happened at the fixture's block height.
    function _forceBondState() internal {
        vm.roll(witnessBlockNumber + 1);
        vm.setBlockhash(witnessBlockNumber, witnessBlockHash);

        // EscrowBase storage layout, verified in test_StorageLayoutIsAsAssumed.
        //
        // The statement binds `rowPayoutAmount`, which the escrow computes as
        // reward + payment. The two must therefore sum to the fixture's value,
        // not each equal it.
        uint256 reward = payoutAmount / 4;
        vm.store(address(escrow), bytes32(uint256(0)), bytes32(reward));                  // currentRewardAmount
        vm.store(address(escrow), bytes32(uint256(1)), bytes32(payoutAmount - reward));   // currentPaymentAmount
        vm.store(address(escrow), bytes32(uint256(2)), bytes32(reward));                  // originalRewardAmount
        vm.store(address(escrow), bytes32(uint256(3)), bytes32(uint256(uint160(collector)))); // bondedExecutor
        vm.store(address(escrow), bytes32(uint256(4)), bytes32(uint256(bondDeadline)));   // executionDeadline
        vm.store(address(escrow), bytes32(uint256(5)), bytes32(uint256(bondStartBlock))); // bondStartBlock

        // Slot 6 packs bondAttempt at offset 0 (4 bytes), then gasAdvanceClaimed,
        // cancellationRequest and funded at byte offsets 4, 5 and 6. Setting
        // funded means bit 48, per `forge inspect EscrowERC20 storageLayout`.
        vm.store(
            address(escrow),
            bytes32(uint256(6)),
            bytes32(uint256(bondAttempt) | (uint256(1) << 48))
        );

        vm.mockCall(payoutAsset, abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(true));
    }

    /// The storage writes above assume a layout. If it shifts, they silently
    /// write the wrong slots and every test here fails obscurely.
    function test_StorageLayoutIsAsAssumed() public view {
        assertEq(
            escrow.currentRewardAmount() + escrow.currentPaymentAmount(),
            payoutAmount,
            "reward + payment must equal the statement's rowPayoutAmount"
        );
        assertEq(escrow.bondedExecutor(), collector, "slot 3 is not bondedExecutor");
        assertEq(escrow.executionDeadline(), bondDeadline, "slot 4 is not executionDeadline");
        assertEq(escrow.bondStartBlock(), bondStartBlock, "slot 5 is not bondStartBlock");
        assertEq(escrow.bondAttempt(), bondAttempt, "slot 6 low bytes are not bondAttempt");
        assertTrue(escrow.funded(), "funded flag not set");
        assertTrue(escrow.is_bonded(), "escrow is not bonded");
    }
}
