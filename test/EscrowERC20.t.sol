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

contract EscrowERC20Test is Test {
    EscrowERC20 public escrow;
    MockERC20 public token;
    address public deployer;
    address public executor;
    address public recipient;
    address public other;

    uint256 constant DEPOSIT_AMOUNT = 1000e18;
    uint256 constant BOND_AMOUNT = 2.5e18; // 0.25% of deposit
    bytes32 constant SALT = bytes32(uint256(99));
    bytes32 COMMITMENT;

    function setUp() public {
        deployer = makeAddr("deployer");
        executor = makeAddr("executor");
        recipient = makeAddr("recipient");
        other = makeAddr("other");

        COMMITMENT = keccak256(abi.encodePacked(recipient, address(0), DEPOSIT_AMOUNT, SALT));

        vm.startPrank(deployer);
        token = new MockERC20();
        token.mint(deployer, 10000e18);

        escrow = new EscrowERC20(address(token), 0, bytes32(0));
        token.approve(address(escrow), DEPOSIT_AMOUNT);
        escrow.fund(DEPOSIT_AMOUNT, COMMITMENT);
        vm.stopPrank();

        token.mint(executor, 10000e18);
        token.mint(other, 10000e18);
    }

    function testConstructor() public view {
        assertEq(escrow.deposit(), DEPOSIT_AMOUNT);
        assertEq(escrow.funded(), true);
        assertEq(escrow.commitment(), COMMITMENT);
    }

    function testFund() public {
        vm.startPrank(deployer);

        EscrowERC20 escrow2 = new EscrowERC20(address(token), 0, bytes32(0));

        token.approve(address(escrow2), DEPOSIT_AMOUNT);
        escrow2.fund(DEPOSIT_AMOUNT, COMMITMENT);
        vm.stopPrank();

        assertEq(escrow2.deposit(), DEPOSIT_AMOUNT);
        assertEq(escrow2.funded(), true);
        assertEq(escrow2.commitment(), COMMITMENT);
        assertEq(token.balanceOf(address(escrow2)), DEPOSIT_AMOUNT);
    }

    function testFundZeroAmount() public {
        vm.startPrank(deployer);
        EscrowERC20 unfundedEscrow = new EscrowERC20(address(token), 0, bytes32(0));

        vm.expectRevert(EscrowERC20.ZeroAmount.selector);
        unfundedEscrow.fund(0, COMMITMENT);
        vm.stopPrank();
    }

    function testFundOnlyDeployer() public {
        vm.startPrank(executor);
        token.approve(address(escrow), DEPOSIT_AMOUNT);
        vm.expectRevert(EscrowBase.OnlyDeployer.selector);
        escrow.fund(DEPOSIT_AMOUNT, COMMITMENT);
        vm.stopPrank();
    }

    function testFundAlreadyFunded() public {
        vm.startPrank(deployer);
        token.approve(address(escrow), DEPOSIT_AMOUNT);
        vm.expectRevert(EscrowERC20.AlreadyFunded.selector);
        escrow.fund(DEPOSIT_AMOUNT, COMMITMENT);
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
        vm.startPrank(deployer);
        EscrowERC20 unfundedEscrow = new EscrowERC20(address(token), 0, bytes32(0));
        vm.stopPrank();

        vm.startPrank(executor);
        token.approve(address(unfundedEscrow), BOND_AMOUNT);
        vm.expectRevert(EscrowBase.NotFunded.selector);
        unfundedEscrow.bond(BOND_AMOUNT);
        vm.stopPrank();
    }

    function testBondCancellationRequested() public {
        vm.prank(deployer);
        escrow.requestCancellation();

        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT);
        vm.expectRevert(EscrowBase.CancellationRequested.selector);
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();
    }

    function testBondInsufficientAmount() public {
        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT / 4);
        vm.expectRevert(EscrowBase.InsufficientBond.selector);
        escrow.bond(BOND_AMOUNT / 4);
        vm.stopPrank();
    }

    function testBondAfterDeadlinePassed() public {
        _bondExecutor();

        vm.warp(block.timestamp + 6 minutes);

        uint256 updatedDeposit = DEPOSIT_AMOUNT + BOND_AMOUNT;
        uint256 newBondAmount = updatedDeposit / 400;

        vm.startPrank(other);
        token.approve(address(escrow), newBondAmount);
        escrow.bond(newBondAmount);
        vm.stopPrank();

        assertEq(escrow.bondedExecutor(), other);
        assertEq(escrow.deposit(), updatedDeposit);
        assertEq(escrow.bondAmount(), newBondAmount);
    }

    function testBondRequiresUpdatedDepositMinimum() public {
        _bondExecutor();

        vm.warp(block.timestamp + 6 minutes);

        uint256 updatedDeposit = DEPOSIT_AMOUNT + BOND_AMOUNT;
        uint256 minimumRequiredBond = updatedDeposit / 400;

        vm.startPrank(other);
        token.approve(address(escrow), type(uint256).max);

        // Bond below minimum should fail
        vm.expectRevert(EscrowBase.InsufficientBond.selector);
        escrow.bond(minimumRequiredBond - 1);

        escrow.bond(minimumRequiredBond);
        vm.stopPrank();

        assertEq(escrow.deposit(), updatedDeposit);
        assertEq(escrow.bondAmount(), minimumRequiredBond);
        assertEq(escrow.bondedExecutor(), other);
    }

    function testRequestCancellation() public {
        vm.prank(deployer);
        escrow.requestCancellation();

        assertTrue(escrow.cancellationRequest());
    }

    function testRequestCancellationOnlyDeployer() public {
        vm.prank(executor);
        vm.expectRevert(EscrowBase.OnlyDeployer.selector);
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
        vm.expectRevert(EscrowBase.OnlyDeployer.selector);
        escrow.resume();
    }

    function testCollectRequiresProof() public {
        _bondExecutor();

        EscrowERC20.ReceiptProof memory dummyProof = EscrowERC20.ReceiptProof({
            blockHeader: hex"", receiptRlp: hex"", proofNodes: hex"", receiptPath: hex"", logIndex: 0
        });

        vm.prank(executor);
        vm.expectRevert();
        escrow.collect(dummyProof, block.number - 1, SALT);
    }

    function testCollectNotFunded() public {
        vm.prank(deployer);
        EscrowERC20 unfundedEscrow = new EscrowERC20(address(token), 0, bytes32(0));

        EscrowERC20.ReceiptProof memory dummyProof = EscrowERC20.ReceiptProof({
            blockHeader: hex"", receiptRlp: hex"", proofNodes: hex"", receiptPath: hex"", logIndex: 0
        });

        vm.prank(executor);
        vm.expectRevert(EscrowBase.NotFunded.selector);
        unfundedEscrow.collect(dummyProof, block.number - 1, SALT);
    }

    function testCollectNotBondedExecutor() public {
        _bondExecutor();

        EscrowERC20.ReceiptProof memory dummyProof = EscrowERC20.ReceiptProof({
            blockHeader: hex"", receiptRlp: hex"", proofNodes: hex"", receiptPath: hex"", logIndex: 0
        });

        vm.prank(other);
        vm.expectRevert(EscrowBase.OnlyBondedExecutor.selector);
        escrow.collect(dummyProof, block.number - 1, SALT);
    }

    function testCollectAfterDeadline() public {
        _bondExecutor();

        vm.warp(block.timestamp + 6 minutes);

        EscrowERC20.ReceiptProof memory dummyProof = EscrowERC20.ReceiptProof({
            blockHeader: hex"", receiptRlp: hex"", proofNodes: hex"", receiptPath: hex"", logIndex: 0
        });

        vm.prank(executor);
        vm.expectRevert(EscrowBase.OnlyBondedExecutor.selector);
        escrow.collect(dummyProof, block.number - 1, SALT);
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
        vm.expectRevert(EscrowBase.ExecutorAlreadyBonded.selector);
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();
    }

    function testBondAfterFirstExecutorStillActive() public {
        _bondExecutor();

        vm.warp(block.timestamp + 4 minutes);
        assertTrue(escrow.is_bonded());

        vm.startPrank(other);
        token.approve(address(escrow), BOND_AMOUNT);
        vm.expectRevert(EscrowBase.ExecutorAlreadyBonded.selector);
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

        uint256 updatedDeposit = DEPOSIT_AMOUNT + BOND_AMOUNT;
        uint256 newBondAmount = updatedDeposit / 400;

        vm.startPrank(other);
        token.approve(address(escrow), newBondAmount);
        escrow.bond(newBondAmount);
        vm.stopPrank();

        assertEq(escrow.bondedExecutor(), other);
        assertEq(escrow.deposit(), updatedDeposit);
        assertEq(escrow.bondAmount(), newBondAmount);
    }

    function testCancelAndWithdraw() public {
        uint256 initialBalance = token.balanceOf(deployer);

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertTrue(escrow.cancellationRequest());
        assertFalse(escrow.funded());
        assertEq(escrow.deposit(), 0);
        assertEq(token.balanceOf(deployer), initialBalance + DEPOSIT_AMOUNT);
    }

    function testCancelAndWithdrawOnlyDeployer() public {
        vm.prank(executor);
        vm.expectRevert(EscrowBase.OnlyDeployer.selector);
        escrow.cancelAndWithdraw();
    }

    function testCancelAndWithdrawNotFunded() public {
        vm.prank(deployer);
        EscrowERC20 unfundedEscrow = new EscrowERC20(address(token), 0, bytes32(0));

        vm.prank(deployer);
        vm.expectRevert(EscrowBase.NotFunded.selector);
        unfundedEscrow.cancelAndWithdraw();
    }

    function testCancelAndWithdrawWhileBonded() public {
        _bondExecutor();

        vm.prank(deployer);
        vm.expectRevert(EscrowBase.BondActive.selector);
        escrow.cancelAndWithdraw();
    }

    function testCancelAndWithdrawAfterBondExpired() public {
        _bondExecutor();

        vm.warp(block.timestamp + 6 minutes);

        uint256 initialBalance = token.balanceOf(deployer);

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertTrue(escrow.cancellationRequest());
        assertFalse(escrow.funded());
        assertEq(token.balanceOf(deployer), initialBalance + DEPOSIT_AMOUNT + BOND_AMOUNT);
    }

    function testCancelAndWithdrawPreventsRaceCondition() public {
        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        // Escrow is now unfunded — executor cannot bond
        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT);
        vm.expectRevert(EscrowBase.NotFunded.selector);
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();
    }

    function testCancelAndWithdrawAlreadyCancelled() public {
        vm.prank(deployer);
        escrow.requestCancellation();

        uint256 initialBalance = token.balanceOf(deployer);

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertTrue(escrow.cancellationRequest());
        assertFalse(escrow.funded());
        assertEq(token.balanceOf(deployer), initialBalance + DEPOSIT_AMOUNT);
    }

    function testCancelAndWithdrawAfterCollectingBonds() public {
        uint256 startTime = block.timestamp;

        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT);
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();

        vm.warp(startTime + 6 minutes);

        uint256 initialBalance = token.balanceOf(deployer);

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        // Deployer gets back everything (deposit + seized bond)
        assertEq(token.balanceOf(deployer), initialBalance + DEPOSIT_AMOUNT + BOND_AMOUNT);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function _bondExecutor() internal {
        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT);
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();
    }
}
