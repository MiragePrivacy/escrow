// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ReceiptValidator} from "../src/ReceiptValidator.sol";

// Thin harness exposing the internal library function for testing.
contract RecoverHarness {
    function recover(bytes calldata txRlp) external pure returns (address) {
        return ReceiptValidator.recoverTxSender(txRlp);
    }
}

contract RecoverTxSenderTest is Test {
    RecoverHarness harness;

    function setUp() public {
        harness = new RecoverHarness();
    }

    // Real EIP-1559 (type 0x02) Sepolia tx, same fixture used in Proof.t.sol.
    // Ground-truth signer per `cast decode-transaction`.
    function testRecover1559() public view {
        bytes memory txRlp =
            hex"02f87483aa36a703840349764384522407e2825208943c86ee0028788fcea3d1c0c486d3794254adcafc87038d7ea4c6800080c001a0bf78958050d25c0a20b23c53fffe328af09621b4aee42ea533e7dc361c89e80fa010a717301aa6292f8662f42c8f813e6f469e7ff87db37fe92afd0bb5849dd078";
        assertEq(harness.recover(txRlp), 0xb3Cf316D61D0e70df80690D8486b29d889226420);
    }

    // Real legacy (EIP-155) tx signed by anvil key #1 (0x70997970...), chainId 1.
    function testRecoverLegacy() public view {
        bytes memory txRlp =
            hex"f86a07843b9aca0082520894000000000000000000000000000000000000dead872386f26fc100008025a0d64bd915abee780c4fd1178b7c8bc96c8385e4868604e1377ae5537ac0f0b703a05e9403c0f77eea80a421a9ca81b8480ad20b4c5ffdddc28f9db79146fd4bb9e5";
        assertEq(harness.recover(txRlp), 0x70997970C51812dc3A010C7d01b50e0d17dc79C8);
    }

    // Second real EIP-1559 tx signed by the same anvil key, different chain/fields,
    // to confirm the typed-tx path is not overfit to one fixture.
    function testRecover1559_secondFixture() public view {
        bytes memory txRlp =
            hex"02f87383aa36a703830f42408477359400825208943c86ee0028788fcea3d1c0c486d3794254adcafc87038d7ea4c6800080c080a0134c06cc9a74d9a86c0c084f49458c7eac3bb8f5fbbfaaac35f6906d4ca55b9da01db2a3a8d8fc4d62ce93e501fd885b31ff1ba3b818e30e23ddcb4f80d502d317";
        assertEq(harness.recover(txRlp), 0x70997970C51812dc3A010C7d01b50e0d17dc79C8);
    }
}
