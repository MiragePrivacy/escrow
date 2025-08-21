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
        escrow = new Escrow(address(token), recipient, EXPECTED_AMOUNT);
        vm.stopPrank();

        token.mint(deployer, 10000e18);
        token.mint(executor, 10000e18);
        token.mint(other, 10000e18);
    }

    function testConstructor() public {
        assertEq(escrow.currentRewardAmount(), 0);
        assertEq(escrow.currentPaymentAmount(), 0);
        assertEq(escrow.funded(), false);
        assertEq(escrow.expectedRecipient(), recipient);
        assertEq(escrow.expectedAmount(), EXPECTED_AMOUNT);
    }

    function testFund() public {
        vm.startPrank(deployer);
        token.approve(address(escrow), REWARD_AMOUNT + PAYMENT_AMOUNT);
        escrow.fund(REWARD_AMOUNT, PAYMENT_AMOUNT);
        vm.stopPrank();

        assertEq(escrow.currentRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow.originalRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow.currentPaymentAmount(), PAYMENT_AMOUNT);
        assertEq(escrow.funded(), true);
        assertEq(token.balanceOf(address(escrow)), REWARD_AMOUNT + PAYMENT_AMOUNT);
    }

    function testFundOnlyDeployer() public {
        vm.startPrank(executor);
        token.approve(address(escrow), REWARD_AMOUNT + PAYMENT_AMOUNT);
        vm.expectRevert("Only callable by the deployer");
        escrow.fund(REWARD_AMOUNT, PAYMENT_AMOUNT);
        vm.stopPrank();
    }

    function testFundAlreadyFunded() public {
        vm.startPrank(deployer);
        token.approve(address(escrow), (REWARD_AMOUNT + PAYMENT_AMOUNT) * 2);
        escrow.fund(REWARD_AMOUNT, PAYMENT_AMOUNT);

        vm.expectRevert("Contract already funded");
        escrow.fund(REWARD_AMOUNT, PAYMENT_AMOUNT);
        vm.stopPrank();
    }

    function testBond() public {
        _fundContract();

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
        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT);
        vm.expectRevert("Contract not funded");
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();
    }

    function testBondCancellationRequested() public {
        _fundContract();

        vm.prank(deployer);
        escrow.requestCancellation();

        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT);
        vm.expectRevert("Cancellation requested");
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();
    }

    function testBondInsufficientAmount() public {
        _fundContract();

        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT / 4);
        vm.expectRevert("Bond must be at least half of reward amount");
        escrow.bond(BOND_AMOUNT / 4);
        vm.stopPrank();
    }

    function testBondAfterDeadlinePassed() public {
        _fundContract();
        _bondExecutor();

        vm.warp(block.timestamp + 6 minutes);

        vm.startPrank(other);
        token.approve(address(escrow), BOND_AMOUNT);
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();

        assertEq(escrow.bondedExecutor(), other);
        assertEq(escrow.currentRewardAmount(), REWARD_AMOUNT + BOND_AMOUNT);
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
        _fundContract();
        _bondExecutor();

        Escrow.ReceiptProof memory dummyProof = Escrow.ReceiptProof({
            blockHeader: hex"",
            receiptRlp: hex"",
            proofNodes: hex"",
            receiptPath: hex"",
            logIndex: 0
        });

        vm.prank(executor);
        vm.expectRevert();
        escrow.collect(dummyProof, block.number - 1);
    }

    function testCollectNotFunded() public {
        Escrow.ReceiptProof memory dummyProof = Escrow.ReceiptProof({
            blockHeader: hex"",
            receiptRlp: hex"",
            proofNodes: hex"",
            receiptPath: hex"",
            logIndex: 0
        });

        vm.prank(executor);
        vm.expectRevert("Contract not funded");
        escrow.collect(dummyProof, block.number - 1);
    }

    function testCollectNotBondedExecutor() public {
        _fundContract();
        _bondExecutor();

        Escrow.ReceiptProof memory dummyProof = Escrow.ReceiptProof({
            blockHeader: hex"",
            receiptRlp: hex"",
            proofNodes: hex"",
            receiptPath: hex"",
            logIndex: 0
        });

        vm.prank(other);
        vm.expectRevert("Only bonded executor can collect");
        escrow.collect(dummyProof, block.number - 1);
    }

    function testCollectAfterDeadline() public {
        _fundContract();
        _bondExecutor();

        vm.warp(block.timestamp + 6 minutes);

        Escrow.ReceiptProof memory dummyProof = Escrow.ReceiptProof({
            blockHeader: hex"",
            receiptRlp: hex"",
            proofNodes: hex"",
            receiptPath: hex"",
            logIndex: 0
        });

        vm.prank(executor);
        vm.expectRevert("Only bonded executor can collect");
        escrow.collect(dummyProof, block.number - 1);
    }

    function testWithdraw() public {
        _fundContract();

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
        vm.expectRevert("Contract not funded");
        escrow.withdraw();
    }

    function testWithdrawOnlyDeployer() public {
        _fundContract();

        vm.prank(executor);
        vm.expectRevert("Only callable by the deployer");
        escrow.withdraw();
    }

    function testWithdrawWhileBonded() public {
        _fundContract();
        _bondExecutor();

        vm.prank(deployer);
        vm.expectRevert("Cannot reset while bond is active");
        escrow.withdraw();
    }

    function testWithdrawAfterBondExpired() public {
        _fundContract();
        _bondExecutor();

        vm.warp(block.timestamp + 6 minutes);

        vm.prank(deployer);
        escrow.withdraw();

        assertFalse(escrow.funded());
    }

    function testIsBonded() public {
        _fundContract();

        assertFalse(escrow.is_bonded());

        _bondExecutor();
        assertTrue(escrow.is_bonded());

        vm.warp(block.timestamp + 6 minutes);
        assertFalse(escrow.is_bonded());
    }

    function testMultipleBondCycles() public {
        _fundContract();

        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT);
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();

        vm.warp(block.timestamp + 6 minutes);

        vm.startPrank(other);
        token.approve(address(escrow), BOND_AMOUNT);
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();

        assertEq(escrow.bondedExecutor(), other);
        assertEq(escrow.currentRewardAmount(), REWARD_AMOUNT + BOND_AMOUNT);
    }

    function testWithdrawAfterCollectingBonds() public {
        _fundContract();

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

        // Second executor bonds at startTime + 6 minutes
        vm.startPrank(other);
        token.approve(address(escrow), BOND_AMOUNT);
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();
        // Second deadline = (startTime + 6 minutes) + 5 minutes = startTime + 11 minutes

        // Verify first bond was collected
        assertEq(escrow.currentRewardAmount(), REWARD_AMOUNT + BOND_AMOUNT);
        assertEq(escrow.bondedExecutor(), other);

        // Warp to startTime + 12 minutes (second deadline expires)
        vm.warp(startTime + 12 minutes);
        assertFalse(escrow.is_bonded());

        uint256 initialBalance = token.balanceOf(deployer);

        vm.prank(deployer);
        escrow.withdraw();

        assertEq(token.balanceOf(deployer), initialBalance + REWARD_AMOUNT + PAYMENT_AMOUNT);
        assertEq(token.balanceOf(address(escrow)), BOND_AMOUNT * 2);
    }

    function _fundContract() internal {
        vm.startPrank(deployer);
        token.approve(address(escrow), REWARD_AMOUNT + PAYMENT_AMOUNT);
        escrow.fund(REWARD_AMOUNT, PAYMENT_AMOUNT);
        vm.stopPrank();
    }

    function _bondExecutor() internal {
        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT);
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();
    }
}
