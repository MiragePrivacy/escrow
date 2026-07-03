// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {EscrowNative} from "../src/EscrowNative.sol";
import {EscrowBase} from "../src/EscrowBase.sol";
import {ReceiptValidator} from "../src/ReceiptValidator.sol";
import {BondAuth} from "./helpers/BondAuth.sol";

contract EscrowNativeTest is Test {
    EscrowNative public escrow;
    address public deployer;
    address public executor;
    address public recipient;
    address public other;

    // The "enclave" whose blinded key gates bonding. blindedSigner = enclave.addr.
    Vm.Wallet enclave;

    uint256 constant EXPECTED_AMOUNT = 1 ether;
    uint256 constant REWARD_AMOUNT = 0.5 ether;
    uint256 constant PAYMENT_AMOUNT = 0.5 ether;
    uint256 constant BOND_POT = 0.25 ether;
    uint256 constant TOTAL = REWARD_AMOUNT + PAYMENT_AMOUNT + BOND_POT;

    function setUp() public {
        deployer = makeAddr("deployer");
        executor = makeAddr("executor");
        recipient = makeAddr("recipient");
        other = makeAddr("other");
        enclave = vm.createWallet("enclave");

        vm.deal(deployer, 100 ether);
        vm.deal(executor, 100 ether);
        vm.deal(other, 100 ether);

        vm.prank(deployer);
        escrow = new EscrowNative{value: TOTAL}(
            recipient, EXPECTED_AMOUNT, enclave.addr, REWARD_AMOUNT, PAYMENT_AMOUNT, BOND_POT
        );
    }

    function _newUnfunded() internal returns (EscrowNative) {
        vm.prank(deployer);
        return new EscrowNative(recipient, EXPECTED_AMOUNT, enclave.addr, 0, 0, 0);
    }

    function _sig(address escrowAddr, address bondingExecutor) internal view returns (bytes memory) {
        return BondAuth.sign(vm, enclave.privateKey, escrowAddr, bondingExecutor);
    }

    function _bondExecutor() internal {
        vm.prank(executor);
        escrow.bond(_sig(address(escrow), executor));
    }

    function testConstructorNative() public view {
        assertEq(escrow.currentRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow.currentPaymentAmount(), PAYMENT_AMOUNT);
        assertEq(escrow.originalRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow.funded(), true);
        assertEq(escrow.expectedRecipient(), recipient);
        assertEq(escrow.expectedAmount(), EXPECTED_AMOUNT);
        assertEq(escrow.blindedSigner(), enclave.addr);
        assertEq(escrow.bondPot(), BOND_POT);
        assertEq(address(escrow).balance, TOTAL);
    }

    function testConstructorNativeIncorrectAmount() public {
        vm.prank(deployer);
        vm.expectRevert(EscrowNative.IncorrectETHAmount.selector);
        new EscrowNative{value: 0.5 ether}( // Wrong amount - should be TOTAL
            recipient, EXPECTED_AMOUNT, enclave.addr, REWARD_AMOUNT, PAYMENT_AMOUNT, BOND_POT
        );
    }

    function testConstructorNativeZeroBond() public {
        vm.prank(deployer);
        vm.expectRevert(EscrowNative.ZeroBondAmount.selector);
        new EscrowNative{value: REWARD_AMOUNT + PAYMENT_AMOUNT}(
            recipient, EXPECTED_AMOUNT, enclave.addr, REWARD_AMOUNT, PAYMENT_AMOUNT, 0
        );
    }

    function testFundNative() public {
        EscrowNative escrow2 = _newUnfunded();

        vm.prank(deployer);
        escrow2.fund{value: TOTAL}(REWARD_AMOUNT, PAYMENT_AMOUNT, BOND_POT);

        assertEq(escrow2.currentRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow2.originalRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow2.currentPaymentAmount(), PAYMENT_AMOUNT);
        assertEq(escrow2.funded(), true);
        assertEq(escrow2.bondPot(), BOND_POT);
        assertEq(address(escrow2).balance, TOTAL);
    }

    function testFundNativeZeroReward() public {
        EscrowNative unfunded = _newUnfunded();
        vm.prank(deployer);
        vm.expectRevert(EscrowNative.ZeroRewardAmount.selector);
        unfunded.fund{value: PAYMENT_AMOUNT + BOND_POT}(0, PAYMENT_AMOUNT, BOND_POT);
    }

    function testFundNativeZeroBond() public {
        EscrowNative unfunded = _newUnfunded();
        vm.prank(deployer);
        vm.expectRevert(EscrowNative.ZeroBondAmount.selector);
        unfunded.fund{value: REWARD_AMOUNT + PAYMENT_AMOUNT}(REWARD_AMOUNT, PAYMENT_AMOUNT, 0);
    }

    function testFundNativeOnlyDeployer() public {
        EscrowNative unfunded = _newUnfunded();
        vm.prank(executor);
        vm.expectRevert(EscrowBase.OnlyDeployer.selector);
        unfunded.fund{value: TOTAL}(REWARD_AMOUNT, PAYMENT_AMOUNT, BOND_POT);
    }

    function testFundNativeAlreadyFunded() public {
        vm.prank(deployer);
        vm.expectRevert(EscrowNative.AlreadyFunded.selector);
        escrow.fund{value: TOTAL}(REWARD_AMOUNT, PAYMENT_AMOUNT, BOND_POT);
    }

    function testFundNativeIncorrectAmount() public {
        EscrowNative unfunded = _newUnfunded();
        vm.prank(deployer);
        vm.expectRevert(EscrowNative.IncorrectETHAmount.selector);
        unfunded.fund{value: 0.5 ether}(REWARD_AMOUNT, PAYMENT_AMOUNT, BOND_POT);
    }

    // Bonding pays the ETH bond pot out to the fresh EOA to bootstrap its gas.
    function testBondNative() public {
        uint256 executorBefore = executor.balance;

        _bondExecutor();

        assertEq(escrow.bondedExecutor(), executor);
        assertEq(escrow.executionDeadline(), block.timestamp + 5 minutes);
        assertTrue(escrow.is_bonded());
        assertEq(escrow.bondPot(), 0);
        assertEq(address(escrow).balance, REWARD_AMOUNT + PAYMENT_AMOUNT);
        assertEq(executor.balance, executorBefore + BOND_POT);
    }

    function testBondNativeInvalidSignature() public {
        Vm.Wallet memory attacker = vm.createWallet("attacker");
        bytes memory badSig = BondAuth.sign(vm, attacker.privateKey, address(escrow), executor);

        vm.prank(executor);
        vm.expectRevert(EscrowBase.InvalidBondSignature.selector);
        escrow.bond(badSig);
    }

    function testBondNativeSignatureBoundToCaller() public {
        bytes memory sigForExecutor = _sig(address(escrow), executor);

        vm.prank(other);
        vm.expectRevert(EscrowBase.InvalidBondSignature.selector);
        escrow.bond(sigForExecutor);
    }

    function testBondNativeNotFunded() public {
        EscrowNative unfunded = _newUnfunded();
        vm.prank(executor);
        vm.expectRevert(EscrowBase.NotFunded.selector);
        unfunded.bond(_sig(address(unfunded), executor));
    }

    function testBondNativeCancellationRequested() public {
        vm.prank(deployer);
        escrow.requestCancellation();

        vm.prank(executor);
        vm.expectRevert(EscrowBase.CancellationRequested.selector);
        escrow.bond(_sig(address(escrow), executor));
    }

    // An expired bond frees the lock; a fresh enclave-authorized EOA can bond, but the
    // pot is already spent (one-shot faucet) so no further ETH is paid out.
    function testBondNativeAfterDeadlinePassed() public {
        _bondExecutor();

        vm.warp(block.timestamp + 6 minutes);

        uint256 otherBefore = other.balance;
        vm.prank(other);
        escrow.bond(_sig(address(escrow), other));

        assertEq(escrow.bondedExecutor(), other);
        assertEq(escrow.currentRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow.bondPot(), 0);
        assertEq(other.balance, otherBefore); // pot already drained by first bond
    }

    function _dummyProof() internal pure returns (EscrowNative.NativeTransferProof memory) {
        return EscrowNative.NativeTransferProof({
            blockHeader: hex"",
            transactionRlp: hex"",
            txProofNodes: hex"",
            receiptRlp: hex"",
            receiptProofNodes: hex"",
            path: hex""
        });
    }

    function testCollectNativeRequiresProof() public {
        _bondExecutor();
        vm.prank(executor);
        vm.expectRevert();
        escrow.collect(_dummyProof(), block.number - 1);
    }

    function testCollectNativeNotFunded() public {
        EscrowNative unfunded = _newUnfunded();
        vm.prank(executor);
        vm.expectRevert(EscrowBase.NotFunded.selector);
        unfunded.collect(_dummyProof(), block.number - 1);
    }

    function testCollectNativeNotBondedExecutor() public {
        _bondExecutor();
        vm.prank(other);
        vm.expectRevert(EscrowBase.OnlyBondedExecutor.selector);
        escrow.collect(_dummyProof(), block.number - 1);
    }

    function testCollectNativeAfterDeadline() public {
        _bondExecutor();
        vm.warp(block.timestamp + 6 minutes);
        vm.prank(executor);
        vm.expectRevert(EscrowBase.OnlyBondedExecutor.selector);
        escrow.collect(_dummyProof(), block.number - 1);
    }

    function testIsBondedNative() public {
        assertFalse(escrow.is_bonded());
        _bondExecutor();
        assertTrue(escrow.is_bonded());
        vm.warp(block.timestamp + 6 minutes);
        assertFalse(escrow.is_bonded());
    }

    function testDoubleBondingPreventedNative() public {
        _bondExecutor();
        vm.prank(other);
        vm.expectRevert(EscrowBase.ExecutorAlreadyBonded.selector);
        escrow.bond(_sig(address(escrow), other));
    }

    function testBondNativeAfterFirstExecutorStillActive() public {
        _bondExecutor();

        vm.warp(block.timestamp + 4 minutes);
        assertTrue(escrow.is_bonded());

        vm.prank(other);
        vm.expectRevert(EscrowBase.ExecutorAlreadyBonded.selector);
        escrow.bond(_sig(address(escrow), other));

        assertEq(escrow.bondedExecutor(), executor);
    }

    function testRequestCancellationNative() public {
        vm.prank(deployer);
        escrow.requestCancellation();
        assertTrue(escrow.cancellationRequest());
    }

    function testResumeNative() public {
        vm.startPrank(deployer);
        escrow.requestCancellation();
        assertTrue(escrow.cancellationRequest());
        escrow.resume();
        assertFalse(escrow.cancellationRequest());
        vm.stopPrank();
    }

    // --- cancelAndWithdraw tests ---

    // Withdraw returns reward + payment + the unspent ETH bond pot.
    function testCancelAndWithdrawNative() public {
        uint256 initialBalance = deployer.balance;

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertTrue(escrow.cancellationRequest());
        assertFalse(escrow.funded());
        assertEq(escrow.currentPaymentAmount(), 0);
        assertEq(escrow.currentRewardAmount(), 0);
        assertEq(escrow.bondPot(), 0);
        assertEq(deployer.balance, initialBalance + TOTAL);
    }

    function testCancelAndWithdrawNativeOnlyDeployer() public {
        vm.prank(executor);
        vm.expectRevert(EscrowBase.OnlyDeployer.selector);
        escrow.cancelAndWithdraw();
    }

    function testCancelAndWithdrawNativeNotFunded() public {
        EscrowNative unfunded = _newUnfunded();
        vm.prank(deployer);
        vm.expectRevert(EscrowBase.NotFunded.selector);
        unfunded.cancelAndWithdraw();
    }

    function testCancelAndWithdrawNativeWhileBonded() public {
        _bondExecutor();
        vm.prank(deployer);
        vm.expectRevert(EscrowBase.BondActive.selector);
        escrow.cancelAndWithdraw();
    }

    // After a bond expires, the pot is already spent, so only reward + payment is returned.
    function testCancelAndWithdrawNativeAfterBondExpired() public {
        _bondExecutor();
        vm.warp(block.timestamp + 6 minutes);

        uint256 initialBalance = deployer.balance;

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertTrue(escrow.cancellationRequest());
        assertFalse(escrow.funded());
        assertEq(deployer.balance, initialBalance + REWARD_AMOUNT + PAYMENT_AMOUNT);
        assertEq(address(escrow).balance, 0);
    }

    function testCancelAndWithdrawNativePreventsRaceCondition() public {
        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        vm.prank(executor);
        vm.expectRevert(EscrowBase.NotFunded.selector);
        escrow.bond(_sig(address(escrow), executor));
    }

    function testCancelAndWithdrawNativeAlreadyCancelled() public {
        vm.prank(deployer);
        escrow.requestCancellation();

        uint256 initialBalance = deployer.balance;

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertTrue(escrow.cancellationRequest());
        assertFalse(escrow.funded());
        assertEq(deployer.balance, initialBalance + TOTAL);
    }
}

// Helper contract to test ReceiptValidator with calldata
contract ReceiptValidatorWrapper {
    function validateReceiptStatus(bytes calldata receiptRlp) external pure returns (bool) {
        return ReceiptValidator.validateReceiptStatus(receiptRlp);
    }
}

contract ReceiptValidatorTest is Test {
    ReceiptValidatorWrapper wrapper;

    function setUp() public {
        wrapper = new ReceiptValidatorWrapper();
    }

    // Test that successful transaction receipt (status = 1) passes validation
    function testValidateReceiptStatusSuccess() public view {
        bytes memory successReceipt =
            hex"02f901a801840114e0a3b9010000000000000000000000000000000880000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000010000000000000200000000000004000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000001000000000000000000000000000f89df89b94be41a9ec942d5b52be07cc7f4d7e30e10e9b652af863a0ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3efa0000000000000000000000000e1a9d9c9abb872ddef70a4d108fd8fc3c7ce4dc4a0000000000000000000000000658d9c76ff358984d6436ea11ee1eda08894c818a000000000000000000000000000000000000000000000000000000000017d7840";

        bool result = wrapper.validateReceiptStatus(successReceipt);
        assertTrue(result);
    }

    // Test that failed transaction receipt (status = 0) fails validation
    function testValidateReceiptStatusFailure() public {
        bytes memory failedReceipt =
            hex"02f901a880840114e0a3b9010000000000000000000000000000000880000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000010000000000000200000000000004000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000001000000000000000000000000000f89df89b94be41a9ec942d5b52be07cc7f4d7e30e10e9b652af863a0ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3efa0000000000000000000000000e1a9d9c9abb872ddef70a4d108fd8fc3c7ce4dc4a0000000000000000000000000658d9c76ff358984d6436ea11ee1eda08894c818a000000000000000000000000000000000000000000000000000000000017d7840";

        vm.expectRevert(ReceiptValidator.ReceiptStatusNotSuccess.selector);
        wrapper.validateReceiptStatus(failedReceipt);
    }

    // Test legacy receipt format (no type prefix)
    function testValidateReceiptStatusLegacySuccess() public view {
        bytes memory legacySuccessReceipt =
            hex"f901a801840114e0a3b9010000000000000000000000000000000880000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000010000000000000200000000000004000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000001000000000000000000000000000f89df89b94be41a9ec942d5b52be07cc7f4d7e30e10e9b652af863a0ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3efa0000000000000000000000000e1a9d9c9abb872ddef70a4d108fd8fc3c7ce4dc4a0000000000000000000000000658d9c76ff358984d6436ea11ee1eda08894c818a000000000000000000000000000000000000000000000000000000000017d7840";

        bool result = wrapper.validateReceiptStatus(legacySuccessReceipt);
        assertTrue(result);
    }

    // Test legacy receipt format with failed status
    function testValidateReceiptStatusLegacyFailure() public {
        bytes memory legacyFailedReceipt =
            hex"f901a880840114e0a3b9010000000000000000000000000000000880000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000010000000000000200000000000004000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000001000000000000000000000000000f89df89b94be41a9ec942d5b52be07cc7f4d7e30e10e9b652af863a0ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3efa0000000000000000000000000e1a9d9c9abb872ddef70a4d108fd8fc3c7ce4dc4a0000000000000000000000000658d9c76ff358984d6436ea11ee1eda08894c818a000000000000000000000000000000000000000000000000000000000017d7840";

        vm.expectRevert(ReceiptValidator.ReceiptStatusNotSuccess.selector);
        wrapper.validateReceiptStatus(legacyFailedReceipt);
    }
}
