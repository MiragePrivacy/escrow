// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {EscrowERC20} from "../src/EscrowERC20.sol";
import {EscrowBase} from "../src/EscrowBase.sol";

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

// Funding, withdraw, and access-control tests for the bond-less EscrowERC20.
// Collect (proof + execution signature) is covered in Collect.t.sol.
contract EscrowERC20Test is Test {
    EscrowERC20 public escrow;
    MockERC20 public token;
    address public deployer;
    address public executor;
    address public recipient;
    address public other;

    uint256 constant EXPECTED_AMOUNT = 1000e18;
    uint256 constant REWARD_AMOUNT = 500e18;
    uint256 constant PAYMENT_AMOUNT = 500e18;

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

        escrow = new EscrowERC20(address(token), recipient, EXPECTED_AMOUNT, REWARD_AMOUNT, PAYMENT_AMOUNT);
        vm.stopPrank();

        token.mint(executor, 10000e18);
        token.mint(other, 10000e18);
    }

    function testConstructor() public view {
        assertEq(escrow.currentRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow.currentPaymentAmount(), PAYMENT_AMOUNT);
        assertEq(escrow.funded(), true);
        assertEq(escrow.collected(), false);
        assertEq(escrow.expectedRecipient(), recipient);
        assertEq(escrow.expectedAmount(), EXPECTED_AMOUNT);
    }

    function testFund() public {
        vm.startPrank(deployer);

        address futureEscrow2 = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        token.approve(futureEscrow2, REWARD_AMOUNT + PAYMENT_AMOUNT);

        EscrowERC20 escrow2 = new EscrowERC20(address(token), recipient, EXPECTED_AMOUNT, 0, 0);

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
        EscrowERC20 unfundedEscrow = new EscrowERC20(address(token), recipient, EXPECTED_AMOUNT, 0, 0);

        token.approve(address(unfundedEscrow), PAYMENT_AMOUNT);
        vm.expectRevert(EscrowERC20.ZeroRewardAmount.selector);
        unfundedEscrow.fund(0, PAYMENT_AMOUNT);
        vm.stopPrank();
    }

    function testFundOnlyDeployer() public {
        vm.startPrank(executor);
        token.approve(address(escrow), REWARD_AMOUNT + PAYMENT_AMOUNT);
        vm.expectRevert(EscrowBase.OnlyDeployer.selector);
        escrow.fund(REWARD_AMOUNT, PAYMENT_AMOUNT);
        vm.stopPrank();
    }

    function testFundAlreadyFunded() public {
        vm.startPrank(deployer);
        token.approve(address(escrow), REWARD_AMOUNT + PAYMENT_AMOUNT);
        vm.expectRevert(EscrowERC20.AlreadyFunded.selector);
        escrow.fund(REWARD_AMOUNT, PAYMENT_AMOUNT);
        vm.stopPrank();
    }

    // --- cancelAndWithdraw ---

    function testCancelAndWithdraw() public {
        uint256 initialBalance = token.balanceOf(deployer);

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertFalse(escrow.funded());
        assertEq(escrow.currentPaymentAmount(), 0);
        assertEq(escrow.currentRewardAmount(), 0);
        assertEq(token.balanceOf(deployer), initialBalance + REWARD_AMOUNT + PAYMENT_AMOUNT);
    }

    function testCancelAndWithdrawOnlyDeployer() public {
        vm.prank(executor);
        vm.expectRevert(EscrowBase.OnlyDeployer.selector);
        escrow.cancelAndWithdraw();
    }

    function testCancelAndWithdrawNotFunded() public {
        vm.prank(deployer);
        EscrowERC20 unfundedEscrow = new EscrowERC20(address(token), recipient, EXPECTED_AMOUNT, 0, 0);

        vm.prank(deployer);
        vm.expectRevert(EscrowBase.NotFunded.selector);
        unfundedEscrow.cancelAndWithdraw();
    }
}
