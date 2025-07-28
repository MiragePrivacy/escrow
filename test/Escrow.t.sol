// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Escrow} from "../src/Escrow.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
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
    address public other;

    uint256 constant REWARD_AMOUNT = 1000e18;
    uint256 constant PAYMENT_AMOUNT = 500e18;
    uint256 constant BOND_AMOUNT = 500e18;

    function setUp() public {
        deployer = makeAddr("deployer");
        executor = makeAddr("executor");
        other = makeAddr("other");

        vm.startPrank(deployer);
        token = new MockERC20();
        escrow = new Escrow(address(token));
        vm.stopPrank();

        token.mint(deployer, 10000e18);
        token.mint(executor, 10000e18);
        token.mint(other, 10000e18);
    }

    function testConstructor() public {
        assertEq(escrow.currentRewardAmount(), 0);
        assertEq(escrow.currentPaymentAmount(), 0);
        assertEq(escrow.funded(), false);
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

    function testCollect() public {
        _fundContract();
        _bondExecutor();

        uint256 expectedPayout = BOND_AMOUNT + REWARD_AMOUNT + PAYMENT_AMOUNT;
        uint256 initialBalance = token.balanceOf(executor);

        vm.prank(executor);
        escrow.collect();

        assertEq(token.balanceOf(executor), initialBalance + expectedPayout);
        assertEq(escrow.bondedExecutor(), address(0));
        assertEq(escrow.bondAmount(), 0);
        assertEq(escrow.executionDeadline(), 0);
        assertFalse(escrow.funded());
        assertEq(escrow.currentPaymentAmount(), 0);
        assertEq(escrow.currentRewardAmount(), 0);
    }

    function testCollectNotFunded() public {
        vm.prank(executor);
        vm.expectRevert("Contract not funded");
        escrow.collect();
    }

    function testCollectNotBondedExecutor() public {
        _fundContract();
        _bondExecutor();

        vm.prank(other);
        vm.expectRevert("Only bonded executor can collect");
        escrow.collect();
    }

    function testCollectAfterDeadline() public {
        _fundContract();
        _bondExecutor();

        vm.warp(block.timestamp + 6 minutes);

        vm.prank(executor);
        vm.expectRevert("Only bonded executor can collect");
        escrow.collect();
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

        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT);
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();

        vm.warp(block.timestamp + 6 minutes);

        vm.startPrank(other);
        token.approve(address(escrow), BOND_AMOUNT);
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();

        vm.warp(block.timestamp + 6 minutes);

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
