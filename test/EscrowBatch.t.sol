// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {EscrowBatch} from "../src/EscrowBatch.sol";
import {IEscrowBatch} from "../src/IEscrowBatch.sol";

contract BatchMockERC20 {
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

contract EscrowBatchTest is Test {
    EscrowBatch public escrow;
    BatchMockERC20 public token;

    address public deployer;
    address public executor;
    address public recipientA;
    address public recipientB;
    address public other;

    uint256 constant AMOUNT_A = 100e18;
    uint256 constant AMOUNT_B = 250e18;
    uint256 constant PAYMENT_AMOUNT = AMOUNT_A + AMOUNT_B;
    uint256 constant REWARD_AMOUNT = 50e18;
    uint256 constant BOND_AMOUNT = 25e18;

    function setUp() public {
        deployer = makeAddr("deployer");
        executor = makeAddr("executor");
        recipientA = makeAddr("recipientA");
        recipientB = makeAddr("recipientB");
        other = makeAddr("other");

        vm.startPrank(deployer);
        token = new BatchMockERC20();
        token.mint(deployer, 10_000e18);

        address futureEscrow = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        token.approve(futureEscrow, PAYMENT_AMOUNT + REWARD_AMOUNT);

        escrow = new EscrowBatch(address(token), _batch(), REWARD_AMOUNT);
        vm.stopPrank();

        token.mint(executor, 10_000e18);
        token.mint(other, 10_000e18);
    }

    function testConstructorStoresBatch() public view {
        assertEq(escrow.tokenContract(), address(token));
        assertEq(escrow.expectedTransferCount(), 2);
        assertEq(escrow.totalPaymentAmount(), PAYMENT_AMOUNT);
        assertEq(escrow.currentPaymentAmount(), PAYMENT_AMOUNT);
        assertEq(escrow.currentRewardAmount(), REWARD_AMOUNT);
        assertTrue(escrow.funded());

        (address firstRecipient, uint256 firstAmount) = escrow.expectedTransfers(0);
        (address secondRecipient, uint256 secondAmount) = escrow.expectedTransfers(1);

        assertEq(firstRecipient, recipientA);
        assertEq(firstAmount, AMOUNT_A);
        assertEq(secondRecipient, recipientB);
        assertEq(secondAmount, AMOUNT_B);
    }

    function testConstructorRejectsEmptyBatch() public {
        IEscrowBatch.BatchTransfer[] memory transfers = new IEscrowBatch.BatchTransfer[](0);

        vm.prank(deployer);
        vm.expectRevert(EscrowBatch.EmptyBatch.selector);
        new EscrowBatch(address(token), transfers, REWARD_AMOUNT);
    }

    function testConstructorRejectsZeroAmount() public {
        IEscrowBatch.BatchTransfer[] memory transfers = new IEscrowBatch.BatchTransfer[](1);
        transfers[0] = IEscrowBatch.BatchTransfer({recipient: recipientA, amount: 0});

        vm.prank(deployer);
        vm.expectRevert(EscrowBatch.ZeroPaymentAmount.selector);
        new EscrowBatch(address(token), transfers, REWARD_AMOUNT);
    }

    function testFundUnfundedBatch() public {
        vm.startPrank(deployer);
        EscrowBatch unfunded = new EscrowBatch(address(token), _batch(), 0);

        token.approve(address(unfunded), PAYMENT_AMOUNT + REWARD_AMOUNT);
        unfunded.fund(REWARD_AMOUNT);
        vm.stopPrank();

        assertTrue(unfunded.funded());
        assertEq(unfunded.currentPaymentAmount(), PAYMENT_AMOUNT);
        assertEq(unfunded.currentRewardAmount(), REWARD_AMOUNT);
        assertEq(token.balanceOf(address(unfunded)), PAYMENT_AMOUNT + REWARD_AMOUNT);
    }

    function testFundOnlyDeployer() public {
        vm.prank(deployer);
        EscrowBatch unfunded = new EscrowBatch(address(token), _batch(), 0);

        vm.startPrank(executor);
        token.approve(address(unfunded), PAYMENT_AMOUNT + REWARD_AMOUNT);
        vm.expectRevert(EscrowBatch.OnlyDeployer.selector);
        unfunded.fund(REWARD_AMOUNT);
        vm.stopPrank();
    }

    function testBond() public {
        _bondExecutor();

        assertEq(escrow.bondedExecutor(), executor);
        assertEq(escrow.bondAmount(), BOND_AMOUNT);
        assertEq(escrow.executionDeadline(), block.timestamp + 5 minutes);
        assertTrue(escrow.is_bonded());
    }

    function testBondAfterDeadlinePassed() public {
        _bondExecutor();

        vm.warp(block.timestamp + 6 minutes);

        uint256 updatedReward = REWARD_AMOUNT + BOND_AMOUNT;
        uint256 newBondAmount = updatedReward / 2;

        vm.startPrank(other);
        token.approve(address(escrow), newBondAmount);
        escrow.bond(newBondAmount);
        vm.stopPrank();

        assertEq(escrow.bondedExecutor(), other);
        assertEq(escrow.currentRewardAmount(), updatedReward);
        assertEq(escrow.totalBondsDeposited(), BOND_AMOUNT);
    }

    function testCollectRejectsInvalidBatchProofLength() public {
        _bondExecutor();

        IEscrowBatch.BatchReceiptProof memory proof = _emptyProof();
        uint256[] memory logIndexes = new uint256[](1);

        vm.prank(executor);
        vm.expectRevert(EscrowBatch.InvalidBatchProofLength.selector);
        escrow.collect(proof, logIndexes);
    }

    function testCollectRejectsDuplicateLogIndex() public {
        _bondExecutor();

        IEscrowBatch.BatchReceiptProof memory proof = _emptyProof();
        uint256[] memory logIndexes = new uint256[](2);
        logIndexes[0] = 3;
        logIndexes[1] = 3;

        vm.prank(executor);
        vm.expectRevert(EscrowBatch.DuplicateLogIndex.selector);
        escrow.collect(proof, logIndexes);
    }

    function testCollectRequiresBondedExecutor() public {
        IEscrowBatch.BatchReceiptProof memory proof = _emptyProof();
        uint256[] memory logIndexes = new uint256[](2);

        vm.prank(other);
        vm.expectRevert(EscrowBatch.OnlyBondedExecutor.selector);
        escrow.collect(proof, logIndexes);
    }

    function testCancelAndWithdraw() public {
        uint256 initialBalance = token.balanceOf(deployer);

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertTrue(escrow.cancellationRequest());
        assertFalse(escrow.funded());
        assertEq(token.balanceOf(deployer), initialBalance + PAYMENT_AMOUNT + REWARD_AMOUNT);
    }

    function _bondExecutor() internal {
        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT);
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();
    }

    function _batch() internal view returns (IEscrowBatch.BatchTransfer[] memory transfers) {
        transfers = new IEscrowBatch.BatchTransfer[](2);
        transfers[0] = IEscrowBatch.BatchTransfer({recipient: recipientA, amount: AMOUNT_A});
        transfers[1] = IEscrowBatch.BatchTransfer({recipient: recipientB, amount: AMOUNT_B});
    }

    function _emptyProof() internal view returns (IEscrowBatch.BatchReceiptProof memory proof) {
        proof = IEscrowBatch.BatchReceiptProof({
            blockHeader: hex"",
            receiptRlp: hex"",
            proofNodes: hex"",
            receiptPath: hex"01",
            targetBlockNumber: block.number
        });
    }
}
