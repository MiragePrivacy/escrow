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

        Escrow.TransactionProof memory dummyProof = Escrow.TransactionProof({
            blockHeader: hex"",
            transactionRlp: hex"",
            proofNodes: hex"",
            transactionPath: hex""
        });

        vm.prank(executor);
        vm.expectRevert();
        escrow.collectNative(dummyProof, block.number - 1);
    }

    function testCollectNativeNotFunded() public {
        vm.prank(deployer);
        Escrow unfundedEscrow = new Escrow(address(0), recipient, EXPECTED_AMOUNT, 0, 0);

        Escrow.TransactionProof memory dummyProof = Escrow.TransactionProof({
            blockHeader: hex"",
            transactionRlp: hex"",
            proofNodes: hex"",
            transactionPath: hex""
        });

        vm.prank(executor);
        vm.expectRevert("Contract not funded");
        unfundedEscrow.collectNative(dummyProof, block.number - 1);
    }

    function testCollectNativeNotBondedExecutor() public {
        _bondExecutor();

        Escrow.TransactionProof memory dummyProof = Escrow.TransactionProof({
            blockHeader: hex"",
            transactionRlp: hex"",
            proofNodes: hex"",
            transactionPath: hex""
        });

        vm.prank(other);
        vm.expectRevert("Only bonded executor can collect");
        escrow.collectNative(dummyProof, block.number - 1);
    }

    function testCollectNativeAfterDeadline() public {
        _bondExecutor();

        vm.warp(block.timestamp + 6 minutes);

        Escrow.TransactionProof memory dummyProof = Escrow.TransactionProof({
            blockHeader: hex"",
            transactionRlp: hex"",
            proofNodes: hex"",
            transactionPath: hex""
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
