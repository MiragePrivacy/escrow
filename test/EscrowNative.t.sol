// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {EscrowNative} from "../src/EscrowNative.sol";
import {EscrowBase} from "../src/EscrowBase.sol";
import {ReceiptValidator} from "../src/ReceiptValidator.sol";

// Funding, withdraw, and access-control tests for the bond-less EscrowNative.
// Collect (proof + execution signature) is covered in Collect.t.sol.
contract EscrowNativeTest is Test {
    EscrowNative public escrow;
    address public deployer;
    address public executor;
    address public recipient;
    address public other;

    uint256 constant EXPECTED_AMOUNT = 1 ether;
    uint256 constant REWARD_AMOUNT = 0.5 ether;
    uint256 constant PAYMENT_AMOUNT = 0.5 ether;

    function setUp() public {
        deployer = makeAddr("deployer");
        executor = makeAddr("executor");
        recipient = makeAddr("recipient");
        other = makeAddr("other");

        vm.deal(deployer, 100 ether);
        vm.deal(executor, 100 ether);
        vm.deal(other, 100 ether);

        vm.prank(deployer);
        escrow = new EscrowNative{value: REWARD_AMOUNT + PAYMENT_AMOUNT}(
            recipient, EXPECTED_AMOUNT, REWARD_AMOUNT, PAYMENT_AMOUNT
        );
    }

    function testConstructorNative() public view {
        assertEq(escrow.currentRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow.currentPaymentAmount(), PAYMENT_AMOUNT);
        assertEq(escrow.originalRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow.funded(), true);
        assertEq(escrow.collected(), false);
        assertEq(escrow.expectedRecipient(), recipient);
        assertEq(escrow.expectedAmount(), EXPECTED_AMOUNT);
        assertEq(address(escrow).balance, REWARD_AMOUNT + PAYMENT_AMOUNT);
    }

    function testConstructorNativeIncorrectAmount() public {
        vm.prank(deployer);
        vm.expectRevert(EscrowNative.IncorrectETHAmount.selector);
        new EscrowNative{value: 0.5 ether}(recipient, EXPECTED_AMOUNT, REWARD_AMOUNT, PAYMENT_AMOUNT);
    }

    function testConstructorNativeZeroValueWithAmounts() public {
        vm.prank(deployer);
        vm.expectRevert(EscrowNative.IncorrectETHAmount.selector);
        new EscrowNative{value: 0}(recipient, EXPECTED_AMOUNT, REWARD_AMOUNT, PAYMENT_AMOUNT);
    }

    function testFundNative() public {
        vm.startPrank(deployer);
        EscrowNative escrow2 = new EscrowNative(recipient, EXPECTED_AMOUNT, 0, 0);
        escrow2.fund{value: REWARD_AMOUNT + PAYMENT_AMOUNT}(REWARD_AMOUNT, PAYMENT_AMOUNT);
        vm.stopPrank();

        assertEq(escrow2.currentRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow2.originalRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow2.currentPaymentAmount(), PAYMENT_AMOUNT);
        assertEq(escrow2.funded(), true);
        assertEq(address(escrow2).balance, REWARD_AMOUNT + PAYMENT_AMOUNT);
    }

    function testFundNativeZeroReward() public {
        vm.startPrank(deployer);
        EscrowNative unfundedEscrow = new EscrowNative(recipient, EXPECTED_AMOUNT, 0, 0);

        vm.expectRevert(EscrowNative.ZeroRewardAmount.selector);
        unfundedEscrow.fund{value: PAYMENT_AMOUNT}(0, PAYMENT_AMOUNT);
        vm.stopPrank();
    }

    function testFundNativeOnlyDeployer() public {
        vm.prank(deployer);
        EscrowNative unfundedEscrow = new EscrowNative(recipient, EXPECTED_AMOUNT, 0, 0);

        vm.prank(executor);
        vm.expectRevert(EscrowBase.OnlyDeployer.selector);
        unfundedEscrow.fund{value: REWARD_AMOUNT + PAYMENT_AMOUNT}(REWARD_AMOUNT, PAYMENT_AMOUNT);
    }

    function testFundNativeAlreadyFunded() public {
        vm.prank(deployer);
        vm.expectRevert(EscrowNative.AlreadyFunded.selector);
        escrow.fund{value: REWARD_AMOUNT + PAYMENT_AMOUNT}(REWARD_AMOUNT, PAYMENT_AMOUNT);
    }

    function testFundNativeIncorrectAmount() public {
        vm.startPrank(deployer);
        EscrowNative unfundedEscrow = new EscrowNative(recipient, EXPECTED_AMOUNT, 0, 0);

        vm.expectRevert(EscrowNative.IncorrectETHAmount.selector);
        unfundedEscrow.fund{value: 0.5 ether}(REWARD_AMOUNT, PAYMENT_AMOUNT);
        vm.stopPrank();
    }

    // --- cancelAndWithdraw ---

    function testCancelAndWithdrawNative() public {
        uint256 initialBalance = deployer.balance;

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertFalse(escrow.funded());
        assertEq(escrow.currentPaymentAmount(), 0);
        assertEq(escrow.currentRewardAmount(), 0);
        assertEq(deployer.balance, initialBalance + REWARD_AMOUNT + PAYMENT_AMOUNT);
    }

    function testCancelAndWithdrawNativeOnlyDeployer() public {
        vm.prank(executor);
        vm.expectRevert(EscrowBase.OnlyDeployer.selector);
        escrow.cancelAndWithdraw();
    }

    function testCancelAndWithdrawNativeNotFunded() public {
        vm.prank(deployer);
        EscrowNative unfundedEscrow = new EscrowNative(recipient, EXPECTED_AMOUNT, 0, 0);

        vm.prank(deployer);
        vm.expectRevert(EscrowBase.NotFunded.selector);
        unfundedEscrow.cancelAndWithdraw();
    }
}

// ReceiptValidator status-parsing tests, independent of the escrow lifecycle.
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

    function testValidateReceiptStatusSuccess() public view {
        bytes memory successReceipt =
            hex"02f901a801840114e0a3b9010000000000000000000000000000000880000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000010000000000000200000000000004000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000001000000000000000000000000000f89df89b94be41a9ec942d5b52be07cc7f4d7e30e10e9b652af863a0ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3efa0000000000000000000000000e1a9d9c9abb872ddef70a4d108fd8fc3c7ce4dc4a0000000000000000000000000658d9c76ff358984d6436ea11ee1eda08894c818a000000000000000000000000000000000000000000000000000000000017d7840";
        assertTrue(wrapper.validateReceiptStatus(successReceipt));
    }

    function testValidateReceiptStatusFailure() public {
        bytes memory failedReceipt =
            hex"02f901a880840114e0a3b9010000000000000000000000000000000880000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000010000000000000200000000000004000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000001000000000000000000000000000f89df89b94be41a9ec942d5b52be07cc7f4d7e30e10e9b652af863a0ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3efa0000000000000000000000000e1a9d9c9abb872ddef70a4d108fd8fc3c7ce4dc4a0000000000000000000000000658d9c76ff358984d6436ea11ee1eda08894c818a000000000000000000000000000000000000000000000000000000000017d7840";
        vm.expectRevert(ReceiptValidator.ReceiptStatusNotSuccess.selector);
        wrapper.validateReceiptStatus(failedReceipt);
    }

    function testValidateReceiptStatusLegacySuccess() public view {
        bytes memory legacySuccessReceipt =
            hex"f901a801840114e0a3b9010000000000000000000000000000000880000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000010000000000000200000000000004000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000001000000000000000000000000000f89df89b94be41a9ec942d5b52be07cc7f4d7e30e10e9b652af863a0ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3efa0000000000000000000000000e1a9d9c9abb872ddef70a4d108fd8fc3c7ce4dc4a0000000000000000000000000658d9c76ff358984d6436ea11ee1eda08894c818a000000000000000000000000000000000000000000000000000000000017d7840";
        assertTrue(wrapper.validateReceiptStatus(legacySuccessReceipt));
    }

    function testValidateReceiptStatusLegacyFailure() public {
        bytes memory legacyFailedReceipt =
            hex"f901a880840114e0a3b9010000000000000000000000000000000880000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000010000000000000200000000000004000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000001000000000000000000000000000f89df89b94be41a9ec942d5b52be07cc7f4d7e30e10e9b652af863a0ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3efa0000000000000000000000000e1a9d9c9abb872ddef70a4d108fd8fc3c7ce4dc4a0000000000000000000000000658d9c76ff358984d6436ea11ee1eda08894c818a000000000000000000000000000000000000000000000000000000000017d7840";
        vm.expectRevert(ReceiptValidator.ReceiptStatusNotSuccess.selector);
        wrapper.validateReceiptStatus(legacyFailedReceipt);
    }
}
