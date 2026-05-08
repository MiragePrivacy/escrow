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
        assertEq(escrow.completedTransferCount(), 0);
        assertEq(escrow.activeReservationCount(), 0);
        assertTrue(escrow.funded());

        (
            IEscrowBatch.AssetType firstAssetType,
            address firstAsset,
            address firstRecipient,
            uint256 firstAmount,
            uint256 firstRewardWeight
        ) = escrow.expectedTransfers(0);
        (
            IEscrowBatch.AssetType secondAssetType,
            address secondAsset,
            address secondRecipient,
            uint256 secondAmount,
            uint256 secondRewardWeight
        ) = escrow.expectedTransfers(1);

        assertEq(uint256(firstAssetType), uint256(IEscrowBatch.AssetType.ERC20));
        assertEq(firstAsset, address(token));
        assertEq(firstRecipient, recipientA);
        assertEq(firstAmount, AMOUNT_A);
        assertEq(firstRewardWeight, AMOUNT_A);
        assertEq(uint256(secondAssetType), uint256(IEscrowBatch.AssetType.ERC20));
        assertEq(secondAsset, address(token));
        assertEq(secondRecipient, recipientB);
        assertEq(secondAmount, AMOUNT_B);
        assertEq(secondRewardWeight, AMOUNT_B);
    }

    function testConstructorRejectsEmptyBatch() public {
        IEscrowBatch.BatchTransfer[] memory transfers = new IEscrowBatch.BatchTransfer[](0);

        vm.prank(deployer);
        vm.expectRevert(EscrowBatch.EmptyBatch.selector);
        new EscrowBatch(address(token), transfers, REWARD_AMOUNT);
    }

    function testConstructorRejectsZeroAmount() public {
        IEscrowBatch.BatchTransfer[] memory transfers = new IEscrowBatch.BatchTransfer[](1);
        transfers[0] = IEscrowBatch.BatchTransfer({
            assetType: IEscrowBatch.AssetType.ERC20,
            asset: address(token),
            recipient: recipientA,
            amount: 0,
            rewardWeight: AMOUNT_A
        });

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

    function testConstructorFundsNativeAsset() public {
        IEscrowBatch.BatchTransfer[] memory transfers = new IEscrowBatch.BatchTransfer[](1);
        transfers[0] = IEscrowBatch.BatchTransfer({
            assetType: IEscrowBatch.AssetType.NATIVE,
            asset: address(0),
            recipient: recipientA,
            amount: 1 ether,
            rewardWeight: 1 ether
        });

        vm.startPrank(deployer);
        vm.deal(deployer, 1 ether);
        token.approve(vm.computeCreateAddress(deployer, vm.getNonce(deployer)), REWARD_AMOUNT);
        EscrowBatch nativeEscrow = new EscrowBatch{value: 1 ether}(address(token), transfers, REWARD_AMOUNT);
        vm.stopPrank();

        assertTrue(nativeEscrow.funded());
        assertEq(nativeEscrow.currentAssetPaymentAmount(address(0)), 1 ether);
        assertEq(address(nativeEscrow).balance, 1 ether);
        assertEq(nativeEscrow.totalRewardWeight(), 1 ether);
    }

    function testBond() public {
        _bondExecutor(_fullIndexes(), BOND_AMOUNT);

        (
            uint256 bondAmount,
            uint256 deadline,
            uint256 startBlock,
            uint256 reservedPaymentAmount,
            uint256 reservedCount
        ) = escrow.reservations(executor);

        assertEq(bondAmount, BOND_AMOUNT);
        assertEq(deadline, block.timestamp + 5 minutes);
        assertEq(startBlock, block.number);
        assertEq(reservedPaymentAmount, PAYMENT_AMOUNT);
        assertEq(reservedCount, 2);
        assertEq(escrow.activeReservationCount(), 1);
        assertEq(escrow.transferExecutor(0), executor);
        assertEq(escrow.transferExecutor(1), executor);
        assertEq(escrow.reservedTransferCount(executor), 2);
        assertEq(escrow.reservedTransferIndex(executor, 0), 0);
        assertEq(escrow.reservedTransferIndex(executor, 1), 1);
        assertTrue(escrow.is_bonded());
    }

    function testMultipleExecutorsCanReserveDisjointTransfers() public {
        _bondExecutor(_singleIndex(0), BOND_AMOUNT);

        vm.startPrank(other);
        token.approve(address(escrow), BOND_AMOUNT);
        escrow.bond(_singleIndex(1), BOND_AMOUNT);
        vm.stopPrank();

        assertEq(escrow.activeReservationCount(), 2);
        assertEq(escrow.transferExecutor(0), executor);
        assertEq(escrow.transferExecutor(1), other);
    }

    function testBondRejectsOverlap() public {
        _bondExecutor(_singleIndex(0), BOND_AMOUNT);

        vm.startPrank(other);
        token.approve(address(escrow), BOND_AMOUNT);
        vm.expectRevert(EscrowBatch.TransferAlreadyReserved.selector);
        escrow.bond(_singleIndex(0), BOND_AMOUNT);
        vm.stopPrank();
    }

    function testBondRejectsDuplicateTransferIndex() public {
        uint256[] memory duplicateIndexes = new uint256[](2);
        duplicateIndexes[0] = 0;
        duplicateIndexes[1] = 0;

        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT);
        vm.expectRevert(EscrowBatch.DuplicateTransferIndex.selector);
        escrow.bond(duplicateIndexes, BOND_AMOUNT);
        vm.stopPrank();
    }

    function testBondRejectsInsufficientBondForSubset() public {
        vm.startPrank(executor);
        token.approve(address(escrow), 1);
        vm.expectRevert(EscrowBatch.InsufficientBond.selector);
        escrow.bond(_singleIndex(1), 1);
        vm.stopPrank();
    }

    function testBondAfterDeadlinePassed() public {
        _bondExecutor(_fullIndexes(), BOND_AMOUNT);

        vm.warp(block.timestamp + 6 minutes);

        uint256 updatedReward = REWARD_AMOUNT + BOND_AMOUNT;
        uint256 newBondAmount = updatedReward / 2;

        vm.startPrank(other);
        token.approve(address(escrow), newBondAmount);
        escrow.bond(_fullIndexes(), newBondAmount);
        vm.stopPrank();

        (uint256 otherBondAmount, uint256 deadline, uint256 startBlock,, uint256 reservedCount) =
            escrow.reservations(other);

        assertEq(otherBondAmount, newBondAmount);
        assertEq(deadline, block.timestamp + 5 minutes);
        assertEq(startBlock, block.number);
        assertEq(reservedCount, 2);
        assertEq(escrow.currentRewardAmount(), updatedReward);
        assertEq(escrow.totalBondsDeposited(), BOND_AMOUNT);
        assertEq(escrow.activeReservationCount(), 1);
        assertEq(escrow.transferExecutor(0), other);
        assertEq(escrow.transferExecutor(1), other);
    }

    function testCollectRejectsInvalidBatchProofLength() public {
        _bondExecutor(_fullIndexes(), BOND_AMOUNT);

        uint256[] memory transferIndexes = _singleIndex(0);
        uint256[] memory logIndexes = new uint256[](2);

        vm.prank(executor);
        vm.expectRevert(EscrowBatch.InvalidBatchProofLength.selector);
        escrow.collect(_proofs(transferIndexes, logIndexes));
    }

    function testCollectRejectsDuplicateLogIndex() public {
        _bondExecutor(_fullIndexes(), BOND_AMOUNT);

        uint256[] memory logIndexes = new uint256[](2);
        logIndexes[0] = 3;
        logIndexes[1] = 3;

        vm.prank(executor);
        vm.expectRevert(EscrowBatch.DuplicateLogIndex.selector);
        escrow.collect(_proofs(_fullIndexes(), logIndexes));
    }

    function testCollectRejectsDuplicateTransferIndex() public {
        _bondExecutor(_fullIndexes(), BOND_AMOUNT);

        uint256[] memory duplicateIndexes = new uint256[](2);
        duplicateIndexes[0] = 0;
        duplicateIndexes[1] = 0;
        uint256[] memory logIndexes = new uint256[](2);
        logIndexes[0] = 0;
        logIndexes[1] = 1;

        vm.prank(executor);
        vm.expectRevert(EscrowBatch.DuplicateTransferIndex.selector);
        escrow.collect(_proofs(duplicateIndexes, logIndexes));
    }

    function testCollectRejectsUnreservedTransfer() public {
        _bondExecutor(_singleIndex(0), BOND_AMOUNT);

        vm.prank(executor);
        vm.expectRevert(EscrowBatch.TransferNotReserved.selector);
        escrow.collect(_proofs(_singleIndex(1), _singleIndex(0)));
    }

    function testCollectRequiresBondedExecutor() public {
        IEscrowBatch.BatchProof[] memory proofs = new IEscrowBatch.BatchProof[](0);

        vm.prank(other);
        vm.expectRevert(EscrowBatch.OnlyBondedExecutor.selector);
        escrow.collect(proofs);
    }

    function testCancelAndWithdraw() public {
        uint256 initialBalance = token.balanceOf(deployer);

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertTrue(escrow.cancellationRequest());
        assertFalse(escrow.funded());
        assertEq(token.balanceOf(deployer), initialBalance + PAYMENT_AMOUNT + REWARD_AMOUNT);
    }

    function testCancelAndWithdrawRejectsActiveReservation() public {
        _bondExecutor(_singleIndex(0), BOND_AMOUNT);

        vm.prank(deployer);
        vm.expectRevert(EscrowBatch.BondActive.selector);
        escrow.cancelAndWithdraw();
    }

    function testCancelAndWithdrawAfterExpiredReservation() public {
        _bondExecutor(_singleIndex(0), BOND_AMOUNT);
        vm.warp(block.timestamp + 6 minutes);

        uint256 initialBalance = token.balanceOf(deployer);

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertFalse(escrow.funded());
        assertEq(escrow.activeReservationCount(), 0);
        assertEq(escrow.totalBondsDeposited(), BOND_AMOUNT);
        assertEq(token.balanceOf(deployer), initialBalance + PAYMENT_AMOUNT + REWARD_AMOUNT + BOND_AMOUNT);
    }

    function testFundAfterCancelRejected() public {
        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        vm.startPrank(deployer);
        token.approve(address(escrow), PAYMENT_AMOUNT + REWARD_AMOUNT);
        vm.expectRevert(EscrowBatch.AlreadyFunded.selector);
        escrow.fund(REWARD_AMOUNT);
        vm.stopPrank();
    }

    function _bondExecutor(uint256[] memory transferIndexes, uint256 bondAmount) internal {
        vm.startPrank(executor);
        token.approve(address(escrow), bondAmount);
        escrow.bond(transferIndexes, bondAmount);
        vm.stopPrank();
    }

    function _batch() internal view returns (IEscrowBatch.BatchTransfer[] memory transfers) {
        transfers = new IEscrowBatch.BatchTransfer[](2);
        transfers[0] = IEscrowBatch.BatchTransfer({
            assetType: IEscrowBatch.AssetType.ERC20,
            asset: address(token),
            recipient: recipientA,
            amount: AMOUNT_A,
            rewardWeight: AMOUNT_A
        });
        transfers[1] = IEscrowBatch.BatchTransfer({
            assetType: IEscrowBatch.AssetType.ERC20,
            asset: address(token),
            recipient: recipientB,
            amount: AMOUNT_B,
            rewardWeight: AMOUNT_B
        });
    }

    function _fullIndexes() internal pure returns (uint256[] memory indexes) {
        indexes = new uint256[](2);
        indexes[0] = 0;
        indexes[1] = 1;
    }

    function _singleIndex(uint256 index) internal pure returns (uint256[] memory indexes) {
        indexes = new uint256[](1);
        indexes[0] = index;
    }

    function _proofs(uint256[] memory transferIndexes, uint256[] memory logIndexes)
        internal
        view
        returns (IEscrowBatch.BatchProof[] memory proofs)
    {
        proofs = new IEscrowBatch.BatchProof[](1);
        proofs[0] = IEscrowBatch.BatchProof({
            proofType: IEscrowBatch.AssetType.ERC20,
            receiptProof: _emptyProof(),
            transactionRlp: hex"",
            txProofNodes: hex"",
            transferIndexes: transferIndexes,
            logIndexes: logIndexes
        });
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
