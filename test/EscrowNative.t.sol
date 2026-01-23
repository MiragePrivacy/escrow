// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Escrow} from "../src/Escrow.sol";

contract EscrowNativeTest is Test {
    Escrow public escrow;
    address public deployer;
    address public executor;
    address public recipient;
    address public other;

    uint256 constant EXPECTED_AMOUNT = 1 ether;
    uint256 constant REWARD_AMOUNT = 0.5 ether;
    uint256 constant PAYMENT_AMOUNT = 0.5 ether;
    uint256 constant BOND_AMOUNT = 0.25 ether; // Half of reward amount

    function setUp() public {
        deployer = makeAddr("deployer");
        executor = makeAddr("executor");
        recipient = makeAddr("recipient");
        other = makeAddr("other");

        // Give everyone some ETH
        vm.deal(deployer, 100 ether);
        vm.deal(executor, 100 ether);
        vm.deal(other, 100 ether);

        // Deploy escrow with native ETH funding in constructor
        vm.prank(deployer);
        escrow = new Escrow{value: REWARD_AMOUNT + PAYMENT_AMOUNT}(
            address(0), // Native ETH
            recipient,
            EXPECTED_AMOUNT,
            REWARD_AMOUNT,
            PAYMENT_AMOUNT
        );
    }

    function testConstructorNative() public view {
        assertEq(escrow.currentRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow.currentPaymentAmount(), PAYMENT_AMOUNT);
        assertEq(escrow.originalRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow.funded(), true);
        assertEq(escrow.expectedRecipient(), recipient);
        assertEq(escrow.expectedAmount(), EXPECTED_AMOUNT);
        assertEq(address(escrow).balance, REWARD_AMOUNT + PAYMENT_AMOUNT);
    }

    function testConstructorNativeIncorrectAmount() public {
        vm.prank(deployer);
        vm.expectRevert("Incorrect ETH amount");
        new Escrow{value: 0.5 ether}( // Wrong amount - should be 1 ether
            address(0),
            recipient,
            EXPECTED_AMOUNT,
            REWARD_AMOUNT,
            PAYMENT_AMOUNT
        );
    }

    function testConstructorNativeZeroValueWithAmounts() public {
        vm.prank(deployer);
        vm.expectRevert("Incorrect ETH amount");
        new Escrow{value: 0}(
            address(0),
            recipient,
            EXPECTED_AMOUNT,
            REWARD_AMOUNT,
            PAYMENT_AMOUNT
        );
    }

    function testFundNative() public {
        vm.startPrank(deployer);

        // Create unfunded escrow
        Escrow escrow2 = new Escrow(address(0), recipient, EXPECTED_AMOUNT, 0, 0);

        // Fund it separately
        escrow2.fundNative{value: REWARD_AMOUNT + PAYMENT_AMOUNT}(REWARD_AMOUNT, PAYMENT_AMOUNT);
        vm.stopPrank();

        assertEq(escrow2.currentRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow2.originalRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow2.currentPaymentAmount(), PAYMENT_AMOUNT);
        assertEq(escrow2.funded(), true);
        assertEq(address(escrow2).balance, REWARD_AMOUNT + PAYMENT_AMOUNT);
    }

    function testFundNativeZeroReward() public {
        vm.startPrank(deployer);
        Escrow unfundedEscrow = new Escrow(address(0), recipient, EXPECTED_AMOUNT, 0, 0);

        vm.expectRevert("Reward amount must be non-zero");
        unfundedEscrow.fundNative{value: PAYMENT_AMOUNT}(0, PAYMENT_AMOUNT);
        vm.stopPrank();
    }

    function testFundNativeOnlyDeployer() public {
        vm.prank(deployer);
        Escrow unfundedEscrow = new Escrow(address(0), recipient, EXPECTED_AMOUNT, 0, 0);

        vm.prank(executor);
        vm.expectRevert("Only callable by the deployer");
        unfundedEscrow.fundNative{value: REWARD_AMOUNT + PAYMENT_AMOUNT}(REWARD_AMOUNT, PAYMENT_AMOUNT);
    }

    function testFundNativeAlreadyFunded() public {
        vm.prank(deployer);
        vm.expectRevert("Contract already funded");
        escrow.fundNative{value: REWARD_AMOUNT + PAYMENT_AMOUNT}(REWARD_AMOUNT, PAYMENT_AMOUNT);
    }

    function testFundNativeIncorrectAmount() public {
        vm.startPrank(deployer);
        Escrow unfundedEscrow = new Escrow(address(0), recipient, EXPECTED_AMOUNT, 0, 0);

        vm.expectRevert("Incorrect ETH amount");
        unfundedEscrow.fundNative{value: 0.5 ether}(REWARD_AMOUNT, PAYMENT_AMOUNT);
        vm.stopPrank();
    }

    function testFundNativeWrongFunction() public {
        vm.startPrank(deployer);
        Escrow unfundedEscrow = new Escrow(address(0), recipient, EXPECTED_AMOUNT, 0, 0);

        vm.expectRevert("Use fundNative for native ETH");
        unfundedEscrow.fund(REWARD_AMOUNT, PAYMENT_AMOUNT);
        vm.stopPrank();
    }

    function testBondNative() public {
        vm.prank(executor);
        escrow.bondNative{value: BOND_AMOUNT}();

        assertEq(escrow.bondedExecutor(), executor);
        assertEq(escrow.bondAmount(), BOND_AMOUNT);
        assertEq(escrow.executionDeadline(), block.timestamp + 5 minutes);
        assertTrue(escrow.is_bonded());
        assertEq(address(escrow).balance, REWARD_AMOUNT + PAYMENT_AMOUNT + BOND_AMOUNT);
    }

    function testBondNativeNotFunded() public {
        vm.prank(deployer);
        Escrow unfundedEscrow = new Escrow(address(0), recipient, EXPECTED_AMOUNT, 0, 0);

        vm.prank(executor);
        vm.expectRevert("Contract not funded");
        unfundedEscrow.bondNative{value: BOND_AMOUNT}();
    }

    function testBondNativeCancellationRequested() public {
        vm.prank(deployer);
        escrow.requestCancellation();

        vm.prank(executor);
        vm.expectRevert("Cancellation requested");
        escrow.bondNative{value: BOND_AMOUNT}();
    }

    function testBondNativeInsufficientAmount() public {
        vm.prank(executor);
        vm.expectRevert("Bond must be at least half of reward amount");
        escrow.bondNative{value: BOND_AMOUNT / 4}();
    }

    function testBondNativeAfterDeadlinePassed() public {
        _bondExecutor();

        vm.warp(block.timestamp + 6 minutes);

        // After first bond fails, reward = 0.5 + 0.25 = 0.75, so minimum bond = 0.375
        uint256 updatedReward = REWARD_AMOUNT + BOND_AMOUNT;
        uint256 newBondAmount = updatedReward / 2;

        vm.prank(other);
        escrow.bondNative{value: newBondAmount}();

        assertEq(escrow.bondedExecutor(), other);
        assertEq(escrow.currentRewardAmount(), updatedReward);
        assertEq(escrow.bondAmount(), newBondAmount);
        assertEq(escrow.totalBondsDeposited(), BOND_AMOUNT);
    }

    function testBondNativeRequiresUpdatedRewardAmount() public {
        _bondExecutor();

        vm.warp(block.timestamp + 6 minutes);

        uint256 updatedReward = REWARD_AMOUNT + BOND_AMOUNT;
        uint256 minimumRequiredBond = updatedReward / 2;

        vm.startPrank(other);

        vm.expectRevert("Bond must be at least half of reward amount");
        escrow.bondNative{value: BOND_AMOUNT}();

        escrow.bondNative{value: minimumRequiredBond}();
        vm.stopPrank();

        assertEq(escrow.currentRewardAmount(), updatedReward);
        assertEq(escrow.bondAmount(), minimumRequiredBond);
        assertEq(escrow.bondedExecutor(), other);
        assertEq(escrow.totalBondsDeposited(), BOND_AMOUNT);
    }

    function testBondNativeWrongFunction() public {
        vm.prank(executor);
        vm.expectRevert("Use bondNative for native ETH");
        escrow.bond(BOND_AMOUNT);
    }

    function testCollectNativeRequiresProof() public {
        _bondExecutor();

        Escrow.NativeTransferProof memory dummyProof = Escrow.NativeTransferProof({
            blockHeader: hex"",
            transactionRlp: hex"",
            txProofNodes: hex"",
            receiptRlp: hex"",
            receiptProofNodes: hex"",
            path: hex""
        });

        vm.prank(executor);
        vm.expectRevert();
        escrow.collectNative(dummyProof, block.number - 1);
    }

    function testCollectNativeNotFunded() public {
        vm.prank(deployer);
        Escrow unfundedEscrow = new Escrow(address(0), recipient, EXPECTED_AMOUNT, 0, 0);

        Escrow.NativeTransferProof memory dummyProof = Escrow.NativeTransferProof({
            blockHeader: hex"",
            transactionRlp: hex"",
            txProofNodes: hex"",
            receiptRlp: hex"",
            receiptProofNodes: hex"",
            path: hex""
        });

        vm.prank(executor);
        vm.expectRevert("Contract not funded");
        unfundedEscrow.collectNative(dummyProof, block.number - 1);
    }

    function testCollectNativeNotBondedExecutor() public {
        _bondExecutor();

        Escrow.NativeTransferProof memory dummyProof = Escrow.NativeTransferProof({
            blockHeader: hex"",
            transactionRlp: hex"",
            txProofNodes: hex"",
            receiptRlp: hex"",
            receiptProofNodes: hex"",
            path: hex""
        });

        vm.prank(other);
        vm.expectRevert("Only bonded executor can collect");
        escrow.collectNative(dummyProof, block.number - 1);
    }

    function testCollectNativeAfterDeadline() public {
        _bondExecutor();

        vm.warp(block.timestamp + 6 minutes);

        Escrow.NativeTransferProof memory dummyProof = Escrow.NativeTransferProof({
            blockHeader: hex"",
            transactionRlp: hex"",
            txProofNodes: hex"",
            receiptRlp: hex"",
            receiptProofNodes: hex"",
            path: hex""
        });

        vm.prank(executor);
        vm.expectRevert("Only bonded executor can collect");
        escrow.collectNative(dummyProof, block.number - 1);
    }

    function testCollectNativeWrongFunction() public {
        _bondExecutor();

        Escrow.ReceiptProof memory dummyProof = Escrow.ReceiptProof({
            blockHeader: hex"",
            receiptRlp: hex"",
            proofNodes: hex"",
            receiptPath: hex"",
            logIndex: 0
        });

        vm.prank(executor);
        vm.expectRevert("Use collectNative for native ETH");
        escrow.collect(dummyProof, block.number - 1);
    }

    function testWithdrawNative() public {
        uint256 initialBalance = deployer.balance;

        vm.prank(deployer);
        escrow.withdrawNative();

        assertEq(deployer.balance, initialBalance + REWARD_AMOUNT + PAYMENT_AMOUNT);
        assertFalse(escrow.funded());
        assertEq(escrow.currentPaymentAmount(), 0);
        assertEq(escrow.currentRewardAmount(), 0);
    }

    function testWithdrawNativeNotFunded() public {
        vm.prank(deployer);
        Escrow unfundedEscrow = new Escrow(address(0), recipient, EXPECTED_AMOUNT, 0, 0);

        vm.prank(deployer);
        vm.expectRevert("Contract not funded");
        unfundedEscrow.withdrawNative();
    }

    function testWithdrawNativeOnlyDeployer() public {
        vm.prank(executor);
        vm.expectRevert("Only callable by the deployer");
        escrow.withdrawNative();
    }

    function testWithdrawNativeWhileBonded() public {
        _bondExecutor();

        vm.prank(deployer);
        vm.expectRevert("Cannot reset while bond is active");
        escrow.withdrawNative();
    }

    function testWithdrawNativeAfterBondExpired() public {
        _bondExecutor();

        vm.warp(block.timestamp + 6 minutes);

        vm.prank(deployer);
        escrow.withdrawNative();

        assertFalse(escrow.funded());
    }

    function testWithdrawNativeWrongFunction() public {
        vm.prank(deployer);
        vm.expectRevert("Use withdrawNative for native ETH");
        escrow.withdraw();
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
        vm.expectRevert("Another executor is already bonded");
        escrow.bondNative{value: BOND_AMOUNT}();
    }

    function testBondNativeAfterFirstExecutorStillActive() public {
        _bondExecutor();

        vm.warp(block.timestamp + 4 minutes);
        assertTrue(escrow.is_bonded());

        vm.prank(other);
        vm.expectRevert("Another executor is already bonded");
        escrow.bondNative{value: BOND_AMOUNT}();

        assertEq(escrow.bondedExecutor(), executor);
    }

    function testMultipleBondCyclesNative() public {
        vm.prank(executor);
        escrow.bondNative{value: BOND_AMOUNT}();

        vm.warp(block.timestamp + 6 minutes);

        // After first bond fails, reward = 0.5 + 0.25 = 0.75, so minimum bond = 0.375
        uint256 updatedReward = REWARD_AMOUNT + BOND_AMOUNT;
        uint256 newBondAmount = updatedReward / 2;

        vm.prank(other);
        escrow.bondNative{value: newBondAmount}();

        assertEq(escrow.bondedExecutor(), other);
        assertEq(escrow.currentRewardAmount(), updatedReward);
        assertEq(escrow.bondAmount(), newBondAmount);
    }

    function testWithdrawNativeAfterCollectingBonds() public {
        uint256 startTime = block.timestamp;

        // First executor bonds at time 0
        vm.prank(executor);
        escrow.bondNative{value: BOND_AMOUNT}();

        // Warp to startTime + 6 minutes (first deadline expires)
        vm.warp(startTime + 6 minutes);
        assertFalse(escrow.is_bonded());

        // After first bond fails, reward = 0.5 + 0.25 = 0.75, so minimum bond = 0.375
        uint256 updatedReward = REWARD_AMOUNT + BOND_AMOUNT;
        uint256 newBondAmount = updatedReward / 2;

        // Second executor bonds at startTime + 6 minutes
        vm.prank(other);
        escrow.bondNative{value: newBondAmount}();

        // Verify first bond was collected
        assertEq(escrow.currentRewardAmount(), updatedReward);
        assertEq(escrow.bondAmount(), newBondAmount);
        assertEq(escrow.bondedExecutor(), other);

        // Warp to startTime + 12 minutes (second deadline expires)
        vm.warp(startTime + 12 minutes);
        assertFalse(escrow.is_bonded());

        uint256 initialBalance = deployer.balance;

        vm.prank(deployer);
        escrow.withdrawNative();

        assertEq(deployer.balance, initialBalance + REWARD_AMOUNT + PAYMENT_AMOUNT);
        // Escrow holds both failed bonds: first bond (0.25) + second bond (0.375)
        assertEq(address(escrow).balance, BOND_AMOUNT + newBondAmount);
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

    function _bondExecutor() internal {
        vm.prank(executor);
        escrow.bondNative{value: BOND_AMOUNT}();
    }
}

// Helper contract to test ReceiptValidator with calldata
import {ReceiptValidator} from "../src/ReceiptValidator.sol";

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
        // EIP-1559 receipt with status = 1: type(02) + rlp([status=01, cumulativeGasUsed, logsBloom, logs])
        // Real receipt from Proof.t.sol - this has status=0x01 (success)
        bytes memory successReceipt =
            hex"02f901a801840114e0a3b9010000000000000000000000000000000880000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000010000000000000200000000000004000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000001000000000000000000000000000f89df89b94be41a9ec942d5b52be07cc7f4d7e30e10e9b652af863a0ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3efa0000000000000000000000000e1a9d9c9abb872ddef70a4d108fd8fc3c7ce4dc4a0000000000000000000000000658d9c76ff358984d6436ea11ee1eda08894c818a000000000000000000000000000000000000000000000000000000000017d7840";

        // Should not revert - status byte after list prefix is 0x01 (success)
        bool result = wrapper.validateReceiptStatus(successReceipt);
        assertTrue(result);
    }

    // Test that failed transaction receipt (status = 0) fails validation
    function testValidateReceiptStatusFailure() public {
        // Same receipt but with status=0x80 (empty = 0 = failed) instead of 0x01
        // Changed byte at position 5 (after 02 f9 01 a8) from 01 to 80
        bytes memory failedReceipt =
            hex"02f901a880840114e0a3b9010000000000000000000000000000000880000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000010000000000000200000000000004000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000001000000000000000000000000000f89df89b94be41a9ec942d5b52be07cc7f4d7e30e10e9b652af863a0ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3efa0000000000000000000000000e1a9d9c9abb872ddef70a4d108fd8fc3c7ce4dc4a0000000000000000000000000658d9c76ff358984d6436ea11ee1eda08894c818a000000000000000000000000000000000000000000000000000000000017d7840";

        // Should revert with "Receipt status is not success"
        vm.expectRevert("Receipt status is not success");
        wrapper.validateReceiptStatus(failedReceipt);
    }

    // Test legacy receipt format (no type prefix)
    function testValidateReceiptStatusLegacySuccess() public view {
        // Legacy receipt (no type prefix) with status = 1
        // Same structure but without the 02 type prefix
        bytes memory legacySuccessReceipt =
            hex"f901a801840114e0a3b9010000000000000000000000000000000880000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000010000000000000200000000000004000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000001000000000000000000000000000f89df89b94be41a9ec942d5b52be07cc7f4d7e30e10e9b652af863a0ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3efa0000000000000000000000000e1a9d9c9abb872ddef70a4d108fd8fc3c7ce4dc4a0000000000000000000000000658d9c76ff358984d6436ea11ee1eda08894c818a000000000000000000000000000000000000000000000000000000000017d7840";

        bool result = wrapper.validateReceiptStatus(legacySuccessReceipt);
        assertTrue(result);
    }

    // Test legacy receipt format with failed status
    function testValidateReceiptStatusLegacyFailure() public {
        // Legacy receipt (no type prefix) with status = 0 (0x80 = empty)
        bytes memory legacyFailedReceipt =
            hex"f901a880840114e0a3b9010000000000000000000000000000000880000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000010000000000000200000000000004000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000001000000000000000000000000000f89df89b94be41a9ec942d5b52be07cc7f4d7e30e10e9b652af863a0ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3efa0000000000000000000000000e1a9d9c9abb872ddef70a4d108fd8fc3c7ce4dc4a0000000000000000000000000658d9c76ff358984d6436ea11ee1eda08894c818a000000000000000000000000000000000000000000000000000000000017d7840";

        vm.expectRevert("Receipt status is not success");
        wrapper.validateReceiptStatus(legacyFailedReceipt);
    }
}
