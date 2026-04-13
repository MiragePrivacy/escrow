// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {EscrowNative} from "../src/EscrowNative.sol";
import {EscrowBase} from "../src/EscrowBase.sol";
import {ReceiptValidator} from "../src/ReceiptValidator.sol";

contract EscrowNativeTest is Test {
    EscrowNative public escrow;
    address public deployer;
    address public executor;
    address public recipient;
    address public other;

    uint256 constant DEPOSIT_AMOUNT = 1 ether;
    uint256 constant BOND_AMOUNT = 0.0025 ether; // 0.25% of deposit
    bytes32 constant SALT = bytes32(uint256(77));
    bytes32 COMMITMENT;

    function setUp() public {
        deployer = makeAddr("deployer");
        executor = makeAddr("executor");
        recipient = makeAddr("recipient");
        other = makeAddr("other");

        COMMITMENT = keccak256(abi.encodePacked(recipient, DEPOSIT_AMOUNT, SALT));

        // Give everyone some ETH
        vm.deal(deployer, 100 ether);
        vm.deal(executor, 100 ether);
        vm.deal(other, 100 ether);

        vm.prank(deployer);
        escrow = new EscrowNative{value: DEPOSIT_AMOUNT}(COMMITMENT);
    }

    function testConstructorNative() public view {
        assertEq(escrow.deposit(), DEPOSIT_AMOUNT);

        assertEq(escrow.funded(), true);
        assertEq(escrow.commitment(), COMMITMENT);
        assertEq(address(escrow).balance, DEPOSIT_AMOUNT);
    }

    function testFundNative() public {
        vm.startPrank(deployer);

        EscrowNative escrow2 = new EscrowNative(bytes32(0));
        escrow2.fund{value: DEPOSIT_AMOUNT}(COMMITMENT);
        vm.stopPrank();

        assertEq(escrow2.deposit(), DEPOSIT_AMOUNT);
        assertEq(escrow2.funded(), true);
        assertEq(escrow2.commitment(), COMMITMENT);
        assertEq(address(escrow2).balance, DEPOSIT_AMOUNT);
    }

    function testFundNativeZeroAmount() public {
        vm.startPrank(deployer);
        EscrowNative unfundedEscrow = new EscrowNative(bytes32(0));

        vm.expectRevert(EscrowNative.ZeroAmount.selector);
        unfundedEscrow.fund{value: 0}(COMMITMENT);
        vm.stopPrank();
    }

    function testFundNativeOnlyDeployer() public {
        vm.prank(deployer);
        EscrowNative unfundedEscrow = new EscrowNative(bytes32(0));

        vm.prank(executor);
        vm.expectRevert(EscrowBase.OnlyDeployer.selector);
        unfundedEscrow.fund{value: DEPOSIT_AMOUNT}(COMMITMENT);
    }

    function testFundNativeAlreadyFunded() public {
        vm.prank(deployer);
        vm.expectRevert(EscrowNative.AlreadyFunded.selector);
        escrow.fund{value: DEPOSIT_AMOUNT}(COMMITMENT);
    }

    function testBondNative() public {
        vm.prank(executor);
        escrow.bond{value: BOND_AMOUNT}();

        assertEq(escrow.bondedExecutor(), executor);
        assertEq(escrow.bondAmount(), BOND_AMOUNT);
        assertEq(escrow.executionDeadline(), block.timestamp + 5 minutes);
        assertTrue(escrow.is_bonded());
        assertEq(address(escrow).balance, DEPOSIT_AMOUNT + BOND_AMOUNT);
    }

    function testBondNativeNotFunded() public {
        vm.prank(deployer);
        EscrowNative unfundedEscrow = new EscrowNative(bytes32(0));

        vm.prank(executor);
        vm.expectRevert(EscrowBase.NotFunded.selector);
        unfundedEscrow.bond{value: BOND_AMOUNT}();
    }

    function testBondNativeCancellationRequested() public {
        vm.prank(deployer);
        escrow.requestCancellation();

        vm.prank(executor);
        vm.expectRevert(EscrowBase.CancellationRequested.selector);
        escrow.bond{value: BOND_AMOUNT}();
    }

    function testBondNativeInsufficientAmount() public {
        vm.prank(executor);
        vm.expectRevert(EscrowBase.InsufficientBond.selector);
        escrow.bond{value: BOND_AMOUNT / 4}();
    }

    function testBondNativeAfterDeadlinePassed() public {
        _bondExecutor();

        vm.warp(block.timestamp + 6 minutes);

        uint256 updatedDeposit = DEPOSIT_AMOUNT + BOND_AMOUNT;
        uint256 newBondAmount = updatedDeposit / 400;

        vm.prank(other);
        escrow.bond{value: newBondAmount}();

        assertEq(escrow.bondedExecutor(), other);
        assertEq(escrow.deposit(), updatedDeposit);
        assertEq(escrow.bondAmount(), newBondAmount);
    }

    function testBondNativeRequiresUpdatedDepositMinimum() public {
        _bondExecutor();

        vm.warp(block.timestamp + 6 minutes);

        uint256 updatedDeposit = DEPOSIT_AMOUNT + BOND_AMOUNT;
        uint256 minimumRequiredBond = updatedDeposit / 400;

        vm.startPrank(other);

        vm.expectRevert(EscrowBase.InsufficientBond.selector);
        escrow.bond{value: minimumRequiredBond - 1}();

        escrow.bond{value: minimumRequiredBond}();
        vm.stopPrank();

        assertEq(escrow.deposit(), updatedDeposit);
        assertEq(escrow.bondAmount(), minimumRequiredBond);
        assertEq(escrow.bondedExecutor(), other);
    }

    function testCollectNativeRequiresProof() public {
        _bondExecutor();

        EscrowNative.NativeTransferProof memory dummyProof = EscrowNative.NativeTransferProof({
            blockHeader: hex"",
            transactionRlp: hex"",
            txProofNodes: hex"",
            receiptRlp: hex"",
            receiptProofNodes: hex"",
            path: hex""
        });

        vm.prank(executor);
        vm.expectRevert();
        escrow.collect(dummyProof, block.number - 1, SALT);
    }

    function testCollectNativeNotFunded() public {
        vm.prank(deployer);
        EscrowNative unfundedEscrow = new EscrowNative(bytes32(0));

        EscrowNative.NativeTransferProof memory dummyProof = EscrowNative.NativeTransferProof({
            blockHeader: hex"",
            transactionRlp: hex"",
            txProofNodes: hex"",
            receiptRlp: hex"",
            receiptProofNodes: hex"",
            path: hex""
        });

        vm.prank(executor);
        vm.expectRevert(EscrowBase.NotFunded.selector);
        unfundedEscrow.collect(dummyProof, block.number - 1, SALT);
    }

    function testCollectNativeNotBondedExecutor() public {
        _bondExecutor();

        EscrowNative.NativeTransferProof memory dummyProof = EscrowNative.NativeTransferProof({
            blockHeader: hex"",
            transactionRlp: hex"",
            txProofNodes: hex"",
            receiptRlp: hex"",
            receiptProofNodes: hex"",
            path: hex""
        });

        vm.prank(other);
        vm.expectRevert(EscrowBase.OnlyBondedExecutor.selector);
        escrow.collect(dummyProof, block.number - 1, SALT);
    }

    function testCollectNativeAfterDeadline() public {
        _bondExecutor();

        vm.warp(block.timestamp + 6 minutes);

        EscrowNative.NativeTransferProof memory dummyProof = EscrowNative.NativeTransferProof({
            blockHeader: hex"",
            transactionRlp: hex"",
            txProofNodes: hex"",
            receiptRlp: hex"",
            receiptProofNodes: hex"",
            path: hex""
        });

        vm.prank(executor);
        vm.expectRevert(EscrowBase.OnlyBondedExecutor.selector);
        escrow.collect(dummyProof, block.number - 1, SALT);
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
        escrow.bond{value: BOND_AMOUNT}();
    }

    function testBondNativeAfterFirstExecutorStillActive() public {
        _bondExecutor();

        vm.warp(block.timestamp + 4 minutes);
        assertTrue(escrow.is_bonded());

        vm.prank(other);
        vm.expectRevert(EscrowBase.ExecutorAlreadyBonded.selector);
        escrow.bond{value: BOND_AMOUNT}();

        assertEq(escrow.bondedExecutor(), executor);
    }

    function testMultipleBondCyclesNative() public {
        vm.prank(executor);
        escrow.bond{value: BOND_AMOUNT}();

        vm.warp(block.timestamp + 6 minutes);

        uint256 updatedDeposit = DEPOSIT_AMOUNT + BOND_AMOUNT;
        uint256 newBondAmount = updatedDeposit / 400;

        vm.prank(other);
        escrow.bond{value: newBondAmount}();

        assertEq(escrow.bondedExecutor(), other);
        assertEq(escrow.deposit(), updatedDeposit);
        assertEq(escrow.bondAmount(), newBondAmount);
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

    function testCancelAndWithdrawNative() public {
        uint256 initialBalance = deployer.balance;

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertTrue(escrow.cancellationRequest());
        assertFalse(escrow.funded());
        assertEq(escrow.deposit(), 0);
        assertEq(deployer.balance, initialBalance + DEPOSIT_AMOUNT);
    }

    function testCancelAndWithdrawNativeOnlyDeployer() public {
        vm.prank(executor);
        vm.expectRevert(EscrowBase.OnlyDeployer.selector);
        escrow.cancelAndWithdraw();
    }

    function testCancelAndWithdrawNativeNotFunded() public {
        vm.prank(deployer);
        EscrowNative unfundedEscrow = new EscrowNative(bytes32(0));

        vm.prank(deployer);
        vm.expectRevert(EscrowBase.NotFunded.selector);
        unfundedEscrow.cancelAndWithdraw();
    }

    function testCancelAndWithdrawNativeWhileBonded() public {
        _bondExecutor();

        vm.prank(deployer);
        vm.expectRevert(EscrowBase.BondActive.selector);
        escrow.cancelAndWithdraw();
    }

    function testCancelAndWithdrawNativeAfterBondExpired() public {
        _bondExecutor();

        vm.warp(block.timestamp + 6 minutes);

        uint256 initialBalance = deployer.balance;

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertTrue(escrow.cancellationRequest());
        assertFalse(escrow.funded());
        assertEq(deployer.balance, initialBalance + DEPOSIT_AMOUNT + BOND_AMOUNT);
    }

    function testCancelAndWithdrawNativePreventsRaceCondition() public {
        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        vm.prank(executor);
        vm.expectRevert(EscrowBase.NotFunded.selector);
        escrow.bond{value: BOND_AMOUNT}();
    }

    function testCancelAndWithdrawNativeAlreadyCancelled() public {
        vm.prank(deployer);
        escrow.requestCancellation();

        uint256 initialBalance = deployer.balance;

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertTrue(escrow.cancellationRequest());
        assertFalse(escrow.funded());
        assertEq(deployer.balance, initialBalance + DEPOSIT_AMOUNT);
    }

    function testCancelAndWithdrawNativeAfterCollectingBonds() public {
        uint256 startTime = block.timestamp;

        vm.prank(executor);
        escrow.bond{value: BOND_AMOUNT}();

        vm.warp(startTime + 6 minutes);

        uint256 initialBalance = deployer.balance;

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        // Deployer gets back everything (deposit + seized bond)
        assertEq(deployer.balance, initialBalance + DEPOSIT_AMOUNT + BOND_AMOUNT);
        assertEq(address(escrow).balance, 0);
    }

    function _bondExecutor() internal {
        vm.prank(executor);
        escrow.bond{value: BOND_AMOUNT}();
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

    function testValidateReceiptStatusSuccess() public view {
        bytes memory successReceipt =
            hex"02f901a801840114e0a3b9010000000000000000000000000000000880000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000010000000000000200000000000004000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000001000000000000000000000000000f89df89b94be41a9ec942d5b52be07cc7f4d7e30e10e9b652af863a0ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3efa0000000000000000000000000e1a9d9c9abb872ddef70a4d108fd8fc3c7ce4dc4a0000000000000000000000000658d9c76ff358984d6436ea11ee1eda08894c818a000000000000000000000000000000000000000000000000000000000017d7840";

        bool result = wrapper.validateReceiptStatus(successReceipt);
        assertTrue(result);
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

        bool result = wrapper.validateReceiptStatus(legacySuccessReceipt);
        assertTrue(result);
    }

    function testValidateReceiptStatusLegacyFailure() public {
        bytes memory legacyFailedReceipt =
            hex"f901a880840114e0a3b9010000000000000000000000000000000880000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000010000000000000200000000000004000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000001000000000000000000000000000f89df89b94be41a9ec942d5b52be07cc7f4d7e30e10e9b652af863a0ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3efa0000000000000000000000000e1a9d9c9abb872ddef70a4d108fd8fc3c7ce4dc4a0000000000000000000000000658d9c76ff358984d6436ea11ee1eda08894c818a000000000000000000000000000000000000000000000000000000000017d7840";

        vm.expectRevert(ReceiptValidator.ReceiptStatusNotSuccess.selector);
        wrapper.validateReceiptStatus(legacyFailedReceipt);
    }
}
