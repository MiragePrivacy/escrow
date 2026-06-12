// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {EscrowNative} from "../src/EscrowNative.sol";
import {EscrowERC20, IERC20} from "../src/EscrowERC20.sol";
import {EscrowBase} from "../src/EscrowBase.sol";
import {ProofFixture} from "./helpers/ProofFixture.sol";
import {TxBuilder} from "./helpers/TxBuilder.sol";

// End-to-end bond-less collect tests using a hermetic single-tx-block proof fixture
// built from a controlled key, so the MPT proof, the recovered tx sender, and the
// execution signature all line up (Native), and the Transfer event `from` lines up
// with the execution signature (ERC20).
contract CollectTest is Test {
    uint256 constant CHAIN_ID = 31337; // foundry default
    uint256 constant EXPECTED_AMOUNT = 1 ether;
    uint256 constant REWARD = 0.5 ether;
    uint256 constant PAYMENT = 0.5 ether;
    uint256 constant TARGET_BLOCK = 1000;

    address deployer = makeAddr("deployer");
    address recipient = makeAddr("recipient");
    Vm.Wallet transferEOA;
    address payout = makeAddr("payout");

    function setUp() public {
        vm.chainId(CHAIN_ID);
        transferEOA = vm.createWallet("transferEOA");
        vm.deal(deployer, 100 ether);
    }

    // --- Native ---

    function _deployNative() internal returns (EscrowNative escrow) {
        vm.prank(deployer);
        escrow = new EscrowNative{value: REWARD + PAYMENT}(recipient, EXPECTED_AMOUNT, REWARD, PAYMENT);
    }

    // Build a native proof for a transfer of EXPECTED_AMOUNT to `recipient` from the
    // transferEOA, landing in TARGET_BLOCK, and roll forward so the block hash resolves.
    function _nativeProof() internal returns (EscrowNative.NativeTransferProof memory proof) {
        bytes memory txRlp =
            TxBuilder.signedNativeTransfer(transferEOA.privateKey, CHAIN_ID, 0, recipient, EXPECTED_AMOUNT);
        bytes memory receiptRlp = ProofFixture.successReceiptNoLogs();

        (bytes32 txRoot, bytes memory txProof, bytes memory path) = ProofFixture.singleLeaf(txRlp);
        (bytes32 rcRoot, bytes memory rcProof,) = ProofFixture.singleLeaf(receiptRlp);

        bytes memory header = ProofFixture.buildHeader(txRoot, rcRoot, TARGET_BLOCK);
        vm.roll(TARGET_BLOCK + 5);
        vm.setBlockhash(TARGET_BLOCK, keccak256(header));

        proof = EscrowNative.NativeTransferProof({
            blockHeader: header,
            transactionRlp: txRlp,
            txProofNodes: txProof,
            receiptRlp: receiptRlp,
            receiptProofNodes: rcProof,
            path: path
        });
    }

    function _signAuth(address escrow, address payoutAddr) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("ExecutionAuth(address expectedRecipient,uint256 expectedAmount,address payoutAddress)"),
                recipient,
                EXPECTED_AMOUNT,
                payoutAddr
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("MirageEscrow"),
                keccak256("1"),
                CHAIN_ID,
                escrow
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(transferEOA.privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function testNativeHappyPath() public {
        EscrowNative escrow = _deployNative();
        EscrowNative.NativeTransferProof memory proof = _nativeProof();
        bytes memory sig = _signAuth(address(escrow), payout);

        uint256 before = payout.balance;
        // Any caller may submit; the signature gates the payout, not msg.sender.
        escrow.collect(proof, TARGET_BLOCK, payout, sig);

        assertEq(payout.balance, before + REWARD + PAYMENT);
        assertTrue(escrow.collected());
        assertFalse(escrow.funded());
    }

    // (e) execution sig from a non-txSender reverts.
    function testNativeWrongSignerReverts() public {
        EscrowNative escrow = _deployNative();
        EscrowNative.NativeTransferProof memory proof = _nativeProof();

        Vm.Wallet memory attacker = vm.createWallet("attacker");
        bytes32 digest = _digest(address(escrow), payout);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attacker.privateKey, digest);

        vm.expectRevert(EscrowBase.SignerNotTxSender.selector);
        escrow.collect(proof, TARGET_BLOCK, payout, abi.encodePacked(r, s, v));
    }

    // (a) observer cannot redirect the payout: a sig authorizing payoutA can't collect
    // to payoutB (digest binds payoutAddress).
    function testNativeObserverCannotRedirect() public {
        EscrowNative escrow = _deployNative();
        EscrowNative.NativeTransferProof memory proof = _nativeProof();
        bytes memory sigForPayout = _signAuth(address(escrow), payout);

        address attackerPayout = makeAddr("attackerPayout");
        vm.expectRevert(EscrowBase.SignerNotTxSender.selector);
        escrow.collect(proof, TARGET_BLOCK, attackerPayout, sigForPayout);
    }

    // (b) wrong-escrow replay: a sig made for escrow A can't collect escrow B.
    function testNativeWrongEscrowReplayReverts() public {
        EscrowNative escrowA = _deployNative();
        EscrowNative escrowB = _deployNative();
        EscrowNative.NativeTransferProof memory proof = _nativeProof();

        bytes memory sigForA = _signAuth(address(escrowA), payout);
        vm.expectRevert(EscrowBase.SignerNotTxSender.selector);
        escrowB.collect(proof, TARGET_BLOCK, payout, sigForA);
    }

    // (c) double-collect reverts on the collected guard.
    function testNativeDoubleCollectReverts() public {
        EscrowNative escrow = _deployNative();
        EscrowNative.NativeTransferProof memory proof = _nativeProof();
        bytes memory sig = _signAuth(address(escrow), payout);

        escrow.collect(proof, TARGET_BLOCK, payout, sig);
        vm.expectRevert(EscrowBase.AlreadyCollected.selector);
        escrow.collect(proof, TARGET_BLOCK, payout, sig);
    }

    // (d) payout lands at the signed payoutAddress, not msg.sender or txSender.
    function testNativePayoutGoesToSignedAddress() public {
        EscrowNative escrow = _deployNative();
        EscrowNative.NativeTransferProof memory proof = _nativeProof();
        bytes memory sig = _signAuth(address(escrow), payout);

        address caller = makeAddr("randomCaller");
        uint256 callerBefore = caller.balance;
        uint256 senderBefore = transferEOA.addr.balance;

        vm.prank(caller);
        escrow.collect(proof, TARGET_BLOCK, payout, sig);

        assertEq(payout.balance, REWARD + PAYMENT);
        assertEq(caller.balance, callerBefore); // caller gets nothing
        assertEq(transferEOA.addr.balance, senderBefore); // txSender gets nothing
    }

    function _digest(address escrow, address payoutAddr) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("ExecutionAuth(address expectedRecipient,uint256 expectedAmount,address payoutAddress)"),
                recipient,
                EXPECTED_AMOUNT,
                payoutAddr
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("MirageEscrow"),
                keccak256("1"),
                CHAIN_ID,
                escrow
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    // --- ERC20 ---

    function _erc20Proof(address token) internal returns (EscrowERC20.ReceiptProof memory proof) {
        // The Transfer event `from` is the transferEOA (direct token.transfer()).
        bytes memory receiptRlp =
            ProofFixture.successReceiptWithTransfer(token, transferEOA.addr, recipient, EXPECTED_AMOUNT);

        (bytes32 rcRoot, bytes memory rcProof, bytes memory path) = ProofFixture.singleLeaf(receiptRlp);
        bytes memory header = ProofFixture.buildHeader(bytes32(uint256(1)), rcRoot, TARGET_BLOCK);
        vm.roll(TARGET_BLOCK + 5);
        vm.setBlockhash(TARGET_BLOCK, keccak256(header));

        proof = EscrowERC20.ReceiptProof({
            blockHeader: header, receiptRlp: receiptRlp, proofNodes: rcProof, receiptPath: path, logIndex: 0
        });
    }

    function testErc20HappyPath() public {
        address token = makeAddr("token");
        // Mock funding + payout token transfers.
        vm.mockCall(token, abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));
        vm.mockCall(token, abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(true));

        vm.prank(deployer);
        EscrowERC20 escrow = new EscrowERC20(token, recipient, EXPECTED_AMOUNT, REWARD, PAYMENT);

        EscrowERC20.ReceiptProof memory proof = _erc20Proof(token);
        bytes memory sig = _signAuth(address(escrow), payout);

        // Expect a token.transfer(payout, reward+payment) on collect.
        vm.expectCall(token, abi.encodeWithSelector(IERC20.transfer.selector, payout, REWARD + PAYMENT));
        escrow.collect(proof, TARGET_BLOCK, payout, sig);

        assertTrue(escrow.collected());
    }

    function testErc20WrongSignerReverts() public {
        address token = makeAddr("token");
        vm.mockCall(token, abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));
        vm.mockCall(token, abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(true));

        vm.prank(deployer);
        EscrowERC20 escrow = new EscrowERC20(token, recipient, EXPECTED_AMOUNT, REWARD, PAYMENT);

        EscrowERC20.ReceiptProof memory proof = _erc20Proof(token);

        Vm.Wallet memory attacker = vm.createWallet("attacker2");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attacker.privateKey, _digest(address(escrow), payout));

        vm.expectRevert(EscrowBase.SignerNotTxSender.selector);
        escrow.collect(proof, TARGET_BLOCK, payout, abi.encodePacked(r, s, v));
    }
}
