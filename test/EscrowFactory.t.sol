// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {EscrowFactory} from "../src/EscrowFactory.sol";
import {EscrowERC20} from "../src/EscrowERC20.sol";
import {EscrowNative} from "../src/EscrowNative.sol";
import {EscrowBase} from "../src/EscrowBase.sol";

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

contract EscrowFactoryTest is Test {
    EscrowFactory public factory;
    MockERC20 public token;
    address public deployer;
    address public recipient;

    uint256 constant EXPECTED_AMOUNT = 1000e18;
    uint256 constant REWARD_AMOUNT = 500e18;
    uint256 constant PAYMENT_AMOUNT = 500e18;

    event EscrowCreated(address indexed deployer, address escrow);

    function setUp() public {
        factory = new EscrowFactory();
        deployer = makeAddr("deployer");
        recipient = makeAddr("recipient");

        token = new MockERC20();
        token.mint(deployer, 10000e18);
    }

    // --- ERC20 creation ---

    function testCreateEscrowERC20() public {
        vm.prank(deployer);
        address escrowAddr = factory.createEscrowERC20(0, address(token), recipient, EXPECTED_AMOUNT);

        EscrowERC20 escrow = EscrowERC20(escrowAddr);
        assertEq(escrow.expectedRecipient(), recipient);
        assertEq(escrow.expectedAmount(), EXPECTED_AMOUNT);
        assertEq(escrow.tokenContract(), address(token));
        assertFalse(escrow.funded());
    }

    function testCreateEscrowERC20EmitsEvent() public {
        address predicted = factory.predictEscrowERC20Address(deployer, 0, address(token), recipient, EXPECTED_AMOUNT);

        vm.expectEmit(true, false, false, true);
        emit EscrowCreated(deployer, predicted);

        vm.prank(deployer);
        factory.createEscrowERC20(0, address(token), recipient, EXPECTED_AMOUNT);
    }

    function testCreateEscrowERC20DeployerIsCallerNotFactory() public {
        vm.prank(deployer);
        address escrowAddr = factory.createEscrowERC20(0, address(token), recipient, EXPECTED_AMOUNT);

        // Deployer can fund and cancel — proves deployer identity is correct
        vm.startPrank(deployer);
        token.approve(escrowAddr, REWARD_AMOUNT + PAYMENT_AMOUNT);
        EscrowERC20(escrowAddr).fund(REWARD_AMOUNT, PAYMENT_AMOUNT);
        EscrowERC20(escrowAddr).cancelAndWithdraw();
        vm.stopPrank();
    }

    function testCreateEscrowERC20NonDeployerCannotFund() public {
        vm.prank(deployer);
        address escrowAddr = factory.createEscrowERC20(0, address(token), recipient, EXPECTED_AMOUNT);

        address other = makeAddr("other");
        token.mint(other, 10000e18);

        vm.startPrank(other);
        token.approve(escrowAddr, REWARD_AMOUNT + PAYMENT_AMOUNT);
        vm.expectRevert(EscrowBase.OnlyDeployer.selector);
        EscrowERC20(escrowAddr).fund(REWARD_AMOUNT, PAYMENT_AMOUNT);
        vm.stopPrank();
    }

    // --- Native creation ---

    function testCreateEscrowNative() public {
        vm.prank(deployer);
        address escrowAddr = factory.createEscrowNative(0, recipient, EXPECTED_AMOUNT);

        EscrowNative escrow = EscrowNative(payable(escrowAddr));
        assertEq(escrow.expectedRecipient(), recipient);
        assertEq(escrow.expectedAmount(), EXPECTED_AMOUNT);
        assertFalse(escrow.funded());
    }

    function testCreateEscrowNativeEmitsEvent() public {
        address predicted = factory.predictEscrowNativeAddress(deployer, 0, recipient, EXPECTED_AMOUNT);

        vm.expectEmit(true, false, false, true);
        emit EscrowCreated(deployer, predicted);

        vm.prank(deployer);
        factory.createEscrowNative(0, recipient, EXPECTED_AMOUNT);
    }

    function testCreateEscrowNativeDeployerIsCallerNotFactory() public {
        vm.deal(deployer, 10000 ether);

        vm.prank(deployer);
        address escrowAddr = factory.createEscrowNative(0, recipient, EXPECTED_AMOUNT);

        vm.startPrank(deployer);
        EscrowNative(payable(escrowAddr)).fund{value: REWARD_AMOUNT + PAYMENT_AMOUNT}(REWARD_AMOUNT, PAYMENT_AMOUNT);
        EscrowNative(payable(escrowAddr)).cancelAndWithdraw();
        vm.stopPrank();
    }

    function testCreateEscrowNativeNonDeployerCannotFund() public {
        vm.prank(deployer);
        address escrowAddr = factory.createEscrowNative(0, recipient, EXPECTED_AMOUNT);

        address other = makeAddr("other");
        vm.deal(other, 10000 ether);

        vm.prank(other);
        vm.expectRevert(EscrowBase.OnlyDeployer.selector);
        EscrowNative(payable(escrowAddr)).fund{value: REWARD_AMOUNT + PAYMENT_AMOUNT}(REWARD_AMOUNT, PAYMENT_AMOUNT);
    }

    // --- Address prediction ---

    function testPredictEscrowERC20Address() public {
        address predicted = factory.predictEscrowERC20Address(deployer, 42, address(token), recipient, EXPECTED_AMOUNT);

        vm.prank(deployer);
        address actual = factory.createEscrowERC20(42, address(token), recipient, EXPECTED_AMOUNT);

        assertEq(predicted, actual);
    }

    function testPredictEscrowNativeAddress() public {
        address predicted = factory.predictEscrowNativeAddress(deployer, 42, recipient, EXPECTED_AMOUNT);

        vm.prank(deployer);
        address actual = factory.createEscrowNative(42, recipient, EXPECTED_AMOUNT);

        assertEq(predicted, actual);
    }

    function testPredictAddressDifferentNonces() public {
        address predicted0 = factory.predictEscrowERC20Address(deployer, 0, address(token), recipient, EXPECTED_AMOUNT);
        address predicted1 = factory.predictEscrowERC20Address(deployer, 1, address(token), recipient, EXPECTED_AMOUNT);

        assertTrue(predicted0 != predicted1);
    }

    function testPredictAddressDifferentDeployers() public {
        address other = makeAddr("other");

        address predicted1 =
            factory.predictEscrowERC20Address(deployer, 0, address(token), recipient, EXPECTED_AMOUNT);
        address predicted2 = factory.predictEscrowERC20Address(other, 0, address(token), recipient, EXPECTED_AMOUNT);

        assertTrue(predicted1 != predicted2);
    }

    // --- Duplicate salt ---

    function testDuplicateSaltReverts() public {
        vm.startPrank(deployer);
        factory.createEscrowERC20(0, address(token), recipient, EXPECTED_AMOUNT);

        vm.expectRevert();
        factory.createEscrowERC20(0, address(token), recipient, EXPECTED_AMOUNT);
        vm.stopPrank();
    }

    // --- Full flow: factory deploy then fund ---

    function testFullFlowERC20() public {
        // Predict address
        address predicted = factory.predictEscrowERC20Address(deployer, 0, address(token), recipient, EXPECTED_AMOUNT);

        // Pre-approve the predicted escrow address
        vm.prank(deployer);
        token.approve(predicted, REWARD_AMOUNT + PAYMENT_AMOUNT);

        // Deploy via factory
        vm.prank(deployer);
        address escrowAddr = factory.createEscrowERC20(0, address(token), recipient, EXPECTED_AMOUNT);
        assertEq(escrowAddr, predicted);

        // Fund directly on the escrow
        vm.prank(deployer);
        EscrowERC20(escrowAddr).fund(REWARD_AMOUNT, PAYMENT_AMOUNT);

        assertTrue(EscrowERC20(escrowAddr).funded());
        assertEq(token.balanceOf(escrowAddr), REWARD_AMOUNT + PAYMENT_AMOUNT);
    }

    function testFullFlowNative() public {
        vm.deal(deployer, 10000 ether);

        // Predict address
        address predicted = factory.predictEscrowNativeAddress(deployer, 0, recipient, EXPECTED_AMOUNT);

        // Deploy via factory
        vm.prank(deployer);
        address escrowAddr = factory.createEscrowNative(0, recipient, EXPECTED_AMOUNT);
        assertEq(escrowAddr, predicted);

        // Fund directly on the escrow
        vm.prank(deployer);
        EscrowNative(payable(escrowAddr)).fund{value: REWARD_AMOUNT + PAYMENT_AMOUNT}(REWARD_AMOUNT, PAYMENT_AMOUNT);

        assertTrue(EscrowNative(payable(escrowAddr)).funded());
        assertEq(escrowAddr.balance, REWARD_AMOUNT + PAYMENT_AMOUNT);
    }
}
