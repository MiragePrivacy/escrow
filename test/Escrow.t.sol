// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Escrow} from "../src/Escrow.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract EscrowTest is Test {
    Escrow public escrow;
    MockERC20 public token;
    address public deployer;
    address public executor;
    address public recipient;
    address public other;

    uint256 constant EXPECTED_AMOUNT = 1000e18;
    uint256 constant REWARD_AMOUNT = 500e18;
    uint256 constant PAYMENT_AMOUNT = 500e18;
    uint256 constant BOND_AMOUNT = 250e18; // Half of reward amount

    function setUp() public {
        deployer = makeAddr("deployer");
        executor = makeAddr("executor");
        recipient = makeAddr("recipient");
        other = makeAddr("other");

        vm.startPrank(deployer);
        token = new MockERC20();
        token.mint(deployer, 10000e18);

        address futureEscrow = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        token.approve(futureEscrow, REWARD_AMOUNT + PAYMENT_AMOUNT);

        escrow = new Escrow(address(token), recipient, EXPECTED_AMOUNT, REWARD_AMOUNT, PAYMENT_AMOUNT);
        vm.stopPrank();

        token.mint(executor, 10000e18);
        token.mint(other, 10000e18);
    }

    function testConstructor() public {
        assertEq(escrow.currentRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow.currentPaymentAmount(), PAYMENT_AMOUNT);
        assertEq(escrow.funded(), true);
        assertEq(escrow.expectedRecipient(), recipient);
        assertEq(escrow.expectedAmount(), EXPECTED_AMOUNT);
    }

    function testFund() public {
        vm.startPrank(deployer);

        address futureEscrow2 = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        token.approve(futureEscrow2, REWARD_AMOUNT + PAYMENT_AMOUNT);

        Escrow escrow2 = new Escrow(address(token), recipient, EXPECTED_AMOUNT, 0, 0);

        token.approve(address(escrow2), REWARD_AMOUNT + PAYMENT_AMOUNT);
        escrow2.fund(REWARD_AMOUNT, PAYMENT_AMOUNT);
        vm.stopPrank();

        assertEq(escrow2.currentRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow2.originalRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow2.currentPaymentAmount(), PAYMENT_AMOUNT);
        assertEq(escrow2.funded(), true);
        assertEq(token.balanceOf(address(escrow2)), REWARD_AMOUNT + PAYMENT_AMOUNT);
    }

    function testFundZeroReward() public {
        vm.startPrank(deployer);
        Escrow unfundedEscrow = new Escrow(address(token), recipient, EXPECTED_AMOUNT, 0, 0);

        token.approve(address(unfundedEscrow), PAYMENT_AMOUNT);
        vm.expectRevert("Reward amount must be non-zero");
        unfundedEscrow.fund(0, PAYMENT_AMOUNT);
        vm.stopPrank();
    }

    function testFundOnlyDeployer() public {
        vm.startPrank(executor);
        token.approve(address(escrow), REWARD_AMOUNT + PAYMENT_AMOUNT);
        vm.expectRevert("Only callable by the deployer");
        escrow.fund(REWARD_AMOUNT, PAYMENT_AMOUNT);
        vm.stopPrank();
    }

    function testFundAlreadyFunded() public {
        // Escrow is already funded in setUp, so any fund() call should revert
        vm.startPrank(deployer);
        token.approve(address(escrow), REWARD_AMOUNT + PAYMENT_AMOUNT);
        vm.expectRevert("Contract already funded");
        escrow.fund(REWARD_AMOUNT, PAYMENT_AMOUNT);
        vm.stopPrank();
    }

    function testBond() public {
        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT);
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();

        assertEq(escrow.bondedExecutor(), executor);
        assertEq(escrow.bondAmount(), BOND_AMOUNT);
        assertEq(escrow.executionDeadline(), block.timestamp + 5 minutes);
        assertTrue(escrow.is_bonded());
    }

    function testBondNotFunded() public {
        // Create an unfunded escrow
        vm.startPrank(deployer);
        Escrow unfundedEscrow = new Escrow(address(token), recipient, EXPECTED_AMOUNT, 0, 0);
        vm.stopPrank();

        vm.startPrank(executor);
        token.approve(address(unfundedEscrow), BOND_AMOUNT);
        vm.expectRevert("Contract not funded");
        unfundedEscrow.bond(BOND_AMOUNT);
        vm.stopPrank();
    }

    function testBondCancellationRequested() public {
        vm.prank(deployer);
        escrow.requestCancellation();

        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT);
        vm.expectRevert("Cancellation requested");
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();
    }

    function testBondInsufficientAmount() public {
        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT / 4);
        vm.expectRevert("Bond must be at least half of reward amount");
        escrow.bond(BOND_AMOUNT / 4);
        vm.stopPrank();
    }

    function testBondAfterDeadlinePassed() public {
        _bondExecutor();

        vm.warp(block.timestamp + 6 minutes);

        // After first bond fails, reward = 500 + 250 = 750, so minimum bond = 375
        uint256 updatedReward = REWARD_AMOUNT + BOND_AMOUNT;
        uint256 newBondAmount = updatedReward / 2;

        vm.startPrank(other);
        token.approve(address(escrow), newBondAmount);
        escrow.bond(newBondAmount);
        vm.stopPrank();

        assertEq(escrow.bondedExecutor(), other);
        assertEq(escrow.currentRewardAmount(), updatedReward);
        assertEq(escrow.bondAmount(), newBondAmount);
        assertEq(escrow.totalBondsDeposited(), BOND_AMOUNT);
    }

    function testBondRequiresUpdatedRewardAmount() public {
        _bondExecutor();

        vm.warp(block.timestamp + 6 minutes);

        uint256 updatedReward = REWARD_AMOUNT + BOND_AMOUNT;
        uint256 minimumRequiredBond = updatedReward / 2;

        vm.startPrank(other);
        token.approve(address(escrow), type(uint256).max);

        vm.expectRevert("Bond must be at least half of reward amount");
        escrow.bond(BOND_AMOUNT);

        escrow.bond(minimumRequiredBond);
        vm.stopPrank();

        assertEq(escrow.currentRewardAmount(), updatedReward);
        assertEq(escrow.bondAmount(), minimumRequiredBond);
        assertEq(escrow.bondedExecutor(), other);
        assertEq(escrow.totalBondsDeposited(), BOND_AMOUNT);
    }

    function testRequestCancellation() public {
        vm.prank(deployer);
        escrow.requestCancellation();

        assertTrue(escrow.cancellationRequest());
    }

    function testRequestCancellationOnlyDeployer() public {
        vm.prank(executor);
        vm.expectRevert("Only callable by the deployer");
        escrow.requestCancellation();
    }

    function testResume() public {
        vm.startPrank(deployer);
        escrow.requestCancellation();
        assertTrue(escrow.cancellationRequest());

        escrow.resume();
        assertFalse(escrow.cancellationRequest());
        vm.stopPrank();
    }

    function testResumeOnlyDeployer() public {
        vm.prank(deployer);
        escrow.requestCancellation();

        vm.prank(executor);
        vm.expectRevert("Only callable by the deployer");
        escrow.resume();
    }

    function testCollectRequiresProof() public {
        _bondExecutor();

        Escrow.ReceiptProof memory dummyProof =
            Escrow.ReceiptProof({blockHeader: hex"", receiptRlp: hex"", proofNodes: hex"", receiptPath: hex"", logIndex: 0});

        vm.prank(executor);
        vm.expectRevert();
        escrow.collect(dummyProof, block.number - 1);
    }

    function testCollectNotFunded() public {
        vm.prank(deployer);
        Escrow unfundedEscrow = new Escrow(address(token), recipient, EXPECTED_AMOUNT, 0, 0);

        Escrow.ReceiptProof memory dummyProof =
            Escrow.ReceiptProof({blockHeader: hex"", receiptRlp: hex"", proofNodes: hex"", receiptPath: hex"", logIndex: 0});

        vm.prank(executor);
        vm.expectRevert("Contract not funded");
        unfundedEscrow.collect(dummyProof, block.number - 1);
    }

    function testCollectNotBondedExecutor() public {
        _bondExecutor();

        Escrow.ReceiptProof memory dummyProof =
            Escrow.ReceiptProof({blockHeader: hex"", receiptRlp: hex"", proofNodes: hex"", receiptPath: hex"", logIndex: 0});

        vm.prank(other);
        vm.expectRevert("Only bonded executor can collect");
        escrow.collect(dummyProof, block.number - 1);
    }

    function testCollectAfterDeadline() public {
        _bondExecutor();

        vm.warp(block.timestamp + 6 minutes);

        Escrow.ReceiptProof memory dummyProof =
            Escrow.ReceiptProof({blockHeader: hex"", receiptRlp: hex"", proofNodes: hex"", receiptPath: hex"", logIndex: 0});

        vm.prank(executor);
        vm.expectRevert("Only bonded executor can collect");
        escrow.collect(dummyProof, block.number - 1);
    }

    function testWithdraw() public {
        uint256 initialBalance = token.balanceOf(deployer);

        vm.prank(deployer);
        escrow.withdraw();

        assertEq(token.balanceOf(deployer), initialBalance + REWARD_AMOUNT + PAYMENT_AMOUNT);
        assertFalse(escrow.funded());
        assertEq(escrow.currentPaymentAmount(), 0);
        assertEq(escrow.currentRewardAmount(), 0);
    }

    function testWithdrawNotFunded() public {
        vm.prank(deployer);
        Escrow unfundedEscrow = new Escrow(address(token), recipient, EXPECTED_AMOUNT, 0, 0);

        vm.prank(deployer);
        vm.expectRevert("Contract not funded");
        unfundedEscrow.withdraw();
    }

    function testWithdrawOnlyDeployer() public {
        vm.prank(executor);
        vm.expectRevert("Only callable by the deployer");
        escrow.withdraw();
    }

    function testWithdrawWhileBonded() public {
        _bondExecutor();

        vm.prank(deployer);
        vm.expectRevert("Cannot reset while bond is active");
        escrow.withdraw();
    }

    function testWithdrawAfterBondExpired() public {
        _bondExecutor();

        vm.warp(block.timestamp + 6 minutes);

        vm.prank(deployer);
        escrow.withdraw();

        assertFalse(escrow.funded());
    }

    function testIsBonded() public {
        assertFalse(escrow.is_bonded());

        _bondExecutor();
        assertTrue(escrow.is_bonded());

        vm.warp(block.timestamp + 6 minutes);
        assertFalse(escrow.is_bonded());
    }

    function testDoubleBondingPrevented() public {
        _bondExecutor();

        vm.startPrank(other);
        token.approve(address(escrow), BOND_AMOUNT);
        vm.expectRevert("Another executor is already bonded");
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();
    }

    function testBondAfterFirstExecutorStillActive() public {
        _bondExecutor();

        vm.warp(block.timestamp + 4 minutes);
        assertTrue(escrow.is_bonded());

        vm.startPrank(other);
        token.approve(address(escrow), BOND_AMOUNT);
        vm.expectRevert("Another executor is already bonded");
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();

        assertEq(escrow.bondedExecutor(), executor);
    }

    function testMultipleBondCycles() public {
        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT);
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();

        vm.warp(block.timestamp + 6 minutes);

        // After first bond fails, reward = 500 + 250 = 750, so minimum bond = 375
        uint256 updatedReward = REWARD_AMOUNT + BOND_AMOUNT;
        uint256 newBondAmount = updatedReward / 2;

        vm.startPrank(other);
        token.approve(address(escrow), newBondAmount);
        escrow.bond(newBondAmount);
        vm.stopPrank();

        assertEq(escrow.bondedExecutor(), other);
        assertEq(escrow.currentRewardAmount(), updatedReward);
        assertEq(escrow.bondAmount(), newBondAmount);
    }

    function testWithdrawAfterCollectingBonds() public {
        uint256 startTime = block.timestamp;

        // First executor bonds at time 0
        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT);
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();
        // First deadline = startTime + 5 minutes

        // Warp to startTime + 6 minutes (first deadline expires)
        vm.warp(startTime + 6 minutes);
        assertFalse(escrow.is_bonded());

        // After first bond fails, reward = 500 + 250 = 750, so minimum bond = 375
        uint256 updatedReward = REWARD_AMOUNT + BOND_AMOUNT;
        uint256 newBondAmount = updatedReward / 2;

        // Second executor bonds at startTime + 6 minutes
        vm.startPrank(other);
        token.approve(address(escrow), newBondAmount);
        escrow.bond(newBondAmount);
        vm.stopPrank();
        // Second deadline = (startTime + 6 minutes) + 5 minutes = startTime + 11 minutes

        // Verify first bond was collected
        assertEq(escrow.currentRewardAmount(), updatedReward);
        assertEq(escrow.bondAmount(), newBondAmount);
        assertEq(escrow.bondedExecutor(), other);

        // Warp to startTime + 12 minutes (second deadline expires)
        vm.warp(startTime + 12 minutes);
        assertFalse(escrow.is_bonded());

        uint256 initialBalance = token.balanceOf(deployer);

        vm.prank(deployer);
        escrow.withdraw();

        assertEq(token.balanceOf(deployer), initialBalance + REWARD_AMOUNT + PAYMENT_AMOUNT);
        // Escrow holds both failed bonds: first bond (250) + second bond (375)
        assertEq(token.balanceOf(address(escrow)), BOND_AMOUNT + newBondAmount);
    }

    function _bondExecutor() internal {
        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT);
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();
    }
}
