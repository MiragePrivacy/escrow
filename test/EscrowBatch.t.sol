// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {EscrowBatch} from "../src/EscrowBatch.sol";

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
    address public bidder;
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
        bidder = makeAddr("bidder");
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

        token.mint(bidder, 10_000e18);
        token.mint(other, 10_000e18);
    }

    function testConstructorStoresBatch() public view {
        assertEq(escrow.deployerAddress(), deployer);
        assertEq(escrow.rewardAsset(), address(token));
        assertEq(escrow.expectedTransferCount(), 2);
        assertEq(escrow.totalTransferAmount(), PAYMENT_AMOUNT);
        assertEq(escrow.currentTransferAmount(), PAYMENT_AMOUNT);
        assertEq(escrow.currentRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow.completedTransferCount(), 0);
        assertEq(escrow.activeBidCount(), 0);
        assertTrue(escrow.funded());

        (address firstAsset, address firstRecipient, uint256 firstAmount) = escrow.expectedTransfers(0);
        (address secondAsset, address secondRecipient, uint256 secondAmount) = escrow.expectedTransfers(1);

        assertEq(firstAsset, address(token));
        assertEq(firstRecipient, recipientA);
        assertEq(firstAmount, AMOUNT_A);
        assertEq(secondAsset, address(token));
        assertEq(secondRecipient, recipientB);
        assertEq(secondAmount, AMOUNT_B);
    }

    function testConstructorRejectsEmptyBatch() public {
        EscrowBatch.BatchTransfer[] memory transfers = new EscrowBatch.BatchTransfer[](0);

        vm.prank(deployer);
        vm.expectRevert(EscrowBatch.EmptyBatch.selector);
        new EscrowBatch(address(token), transfers, REWARD_AMOUNT);
    }

    function testConstructorRejectsZeroAmount() public {
        EscrowBatch.BatchTransfer[] memory transfers = new EscrowBatch.BatchTransfer[](1);
        transfers[0] = EscrowBatch.BatchTransfer({asset: address(token), recipient: recipientA, amount: 0});

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
        assertEq(unfunded.currentTransferAmount(), PAYMENT_AMOUNT);
        assertEq(unfunded.currentRewardAmount(), REWARD_AMOUNT);
        assertEq(token.balanceOf(address(unfunded)), PAYMENT_AMOUNT + REWARD_AMOUNT);
    }

    function testFundOnlyDeployer() public {
        vm.prank(deployer);
        EscrowBatch unfunded = new EscrowBatch(address(token), _batch(), 0);

        vm.startPrank(bidder);
        token.approve(address(unfunded), PAYMENT_AMOUNT + REWARD_AMOUNT);
        vm.expectRevert(EscrowBatch.OnlyDeployer.selector);
        unfunded.fund(REWARD_AMOUNT);
        vm.stopPrank();
    }

    function testConstructorFundsNativeAsset() public {
        EscrowBatch.BatchTransfer[] memory transfers = new EscrowBatch.BatchTransfer[](1);
        transfers[0] = EscrowBatch.BatchTransfer({asset: address(0), recipient: recipientA, amount: 1 ether});

        vm.startPrank(deployer);
        vm.deal(deployer, 1 ether);
        token.approve(vm.computeCreateAddress(deployer, vm.getNonce(deployer)), REWARD_AMOUNT);
        EscrowBatch nativeEscrow = new EscrowBatch{value: 1 ether}(address(token), transfers, REWARD_AMOUNT);
        vm.stopPrank();

        assertTrue(nativeEscrow.funded());
        assertEq(nativeEscrow.currentAssetPaymentAmount(address(0)), 1 ether);
        assertEq(address(nativeEscrow).balance, 1 ether);
        assertEq(nativeEscrow.totalTransferAmount(), 1 ether);
    }

    function testBid() public {
        _placeBid(_fullIndexes(), BOND_AMOUNT);

        (uint256 bondAmount, uint256 expiresAt, uint256 startBlock) = escrow.bids(bidder);

        assertEq(bondAmount, BOND_AMOUNT);
        assertEq(expiresAt, block.timestamp + escrow.BID_DURATION());
        assertEq(startBlock, block.number);
        assertEq(escrow.activeBidCount(), 1);
        assertEq(escrow.transferBidder(0), bidder);
        assertEq(escrow.transferBidder(1), bidder);
        assertEq(escrow.bidTransferCount(bidder), 2);
        assertEq(escrow.bidTransferIndex(bidder, 0), 0);
        assertEq(escrow.bidTransferIndex(bidder, 1), 1);
        assertTrue(escrow.is_bonded());
    }

    function testMultipleBiddersCanCoverDisjointTransfers() public {
        _placeBid(_singleIndex(0), BOND_AMOUNT);

        vm.startPrank(other);
        token.approve(address(escrow), BOND_AMOUNT);
        escrow.bid(_singleIndex(1), BOND_AMOUNT);
        vm.stopPrank();

        assertEq(escrow.activeBidCount(), 2);
        assertEq(escrow.transferBidder(0), bidder);
        assertEq(escrow.transferBidder(1), other);
    }

    function testBidRejectsOverlap() public {
        _placeBid(_singleIndex(0), BOND_AMOUNT);

        vm.startPrank(other);
        token.approve(address(escrow), BOND_AMOUNT);
        vm.expectRevert(EscrowBatch.TransferStateConflict.selector);
        escrow.bid(_singleIndex(0), BOND_AMOUNT);
        vm.stopPrank();
    }

    function testBidRejectsDuplicateTransferIndex() public {
        uint256[] memory duplicateIndexes = new uint256[](2);
        duplicateIndexes[0] = 0;
        duplicateIndexes[1] = 0;

        vm.startPrank(bidder);
        token.approve(address(escrow), BOND_AMOUNT);
        vm.expectRevert(EscrowBatch.DuplicateProofItem.selector);
        escrow.bid(duplicateIndexes, BOND_AMOUNT);
        vm.stopPrank();
    }

    function testBidRejectsInsufficientBondForSubset() public {
        vm.startPrank(bidder);
        token.approve(address(escrow), 1);
        vm.expectRevert(EscrowBatch.InsufficientBond.selector);
        escrow.bid(_singleIndex(1), 1);
        vm.stopPrank();
    }

    function testBidAfterDeadlinePassed() public {
        _placeBid(_fullIndexes(), BOND_AMOUNT);

        vm.warp(block.timestamp + 6 minutes);

        uint256 updatedReward = REWARD_AMOUNT + BOND_AMOUNT;
        uint256 newBondAmount = updatedReward / 2;

        vm.startPrank(other);
        token.approve(address(escrow), newBondAmount);
        escrow.bid(_fullIndexes(), newBondAmount);
        vm.stopPrank();

        (uint256 otherBondAmount, uint256 expiresAt, uint256 startBlock) = escrow.bids(other);

        assertEq(otherBondAmount, newBondAmount);
        assertEq(expiresAt, block.timestamp + escrow.BID_DURATION());
        assertEq(startBlock, block.number);
        assertEq(escrow.currentRewardAmount(), updatedReward);
        assertEq(escrow.activeBidCount(), 1);
        assertEq(escrow.transferBidder(0), other);
        assertEq(escrow.transferBidder(1), other);
    }

    function testCollectRejectsInvalidBatchProofLength() public {
        _placeBid(_fullIndexes(), BOND_AMOUNT);

        uint256[] memory transferIndexes = _singleIndex(0);
        uint256[] memory logIndexes = new uint256[](2);

        vm.prank(bidder);
        vm.expectRevert(EscrowBatch.MalformedProof.selector);
        escrow.collect(_proofs(transferIndexes, logIndexes));
    }

    function testCollectRejectsDuplicateLogIndex() public {
        _placeBid(_fullIndexes(), BOND_AMOUNT);

        uint256[] memory logIndexes = new uint256[](2);
        logIndexes[0] = 3;
        logIndexes[1] = 3;

        vm.prank(bidder);
        vm.expectRevert(EscrowBatch.DuplicateProofItem.selector);
        escrow.collect(_proofs(_fullIndexes(), logIndexes));
    }

    function testCollectRejectsDuplicateTransferIndex() public {
        _placeBid(_fullIndexes(), BOND_AMOUNT);

        uint256[] memory duplicateIndexes = new uint256[](2);
        duplicateIndexes[0] = 0;
        duplicateIndexes[1] = 0;
        uint256[] memory logIndexes = new uint256[](2);
        logIndexes[0] = 0;
        logIndexes[1] = 1;

        vm.prank(bidder);
        vm.expectRevert(EscrowBatch.DuplicateProofItem.selector);
        escrow.collect(_proofs(duplicateIndexes, logIndexes));
    }

    function testCollectRejectsUncoveredTransfer() public {
        _placeBid(_singleIndex(0), BOND_AMOUNT);

        vm.prank(bidder);
        vm.expectRevert(EscrowBatch.TransferStateConflict.selector);
        escrow.collect(_proofs(_singleIndex(1), _singleIndex(0)));
    }

    function testCollectRequiresActiveBidder() public {
        EscrowBatch.BatchProof[] memory proofs = new EscrowBatch.BatchProof[](0);

        vm.prank(other);
        vm.expectRevert(EscrowBatch.OnlyActiveBidder.selector);
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

    function testCancelAndWithdrawRejectsActiveBid() public {
        _placeBid(_singleIndex(0), BOND_AMOUNT);

        vm.prank(deployer);
        vm.expectRevert(EscrowBatch.BidActive.selector);
        escrow.cancelAndWithdraw();
    }

    function testCancelAndWithdrawAfterExpiredBid() public {
        _placeBid(_singleIndex(0), BOND_AMOUNT);
        vm.warp(block.timestamp + 6 minutes);

        uint256 initialBalance = token.balanceOf(deployer);

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertFalse(escrow.funded());
        assertEq(escrow.activeBidCount(), 0);
        assertEq(token.balanceOf(deployer), initialBalance + PAYMENT_AMOUNT + REWARD_AMOUNT + BOND_AMOUNT);
    }

    function testEthBondEscrowAcceptsEthBid() public {
        EscrowBatch.BatchTransfer[] memory transfers = new EscrowBatch.BatchTransfer[](2);
        transfers[0] = EscrowBatch.BatchTransfer({asset: address(token), recipient: recipientA, amount: AMOUNT_A});
        transfers[1] = EscrowBatch.BatchTransfer({asset: address(token), recipient: recipientB, amount: AMOUNT_B});

        vm.deal(deployer, REWARD_AMOUNT);
        vm.startPrank(deployer);
        token.approve(vm.computeCreateAddress(deployer, vm.getNonce(deployer)), PAYMENT_AMOUNT);
        EscrowBatch ethEscrow = new EscrowBatch{value: REWARD_AMOUNT}(address(0), transfers, REWARD_AMOUNT);
        vm.stopPrank();

        assertEq(ethEscrow.rewardAsset(), address(0));
        assertEq(ethEscrow.currentRewardAmount(), REWARD_AMOUNT);
        assertEq(address(ethEscrow).balance, REWARD_AMOUNT);

        vm.deal(bidder, BOND_AMOUNT);
        vm.prank(bidder);
        ethEscrow.bid{value: BOND_AMOUNT}(_fullIndexes(), BOND_AMOUNT);

        (uint256 bondAmount,,) = ethEscrow.bids(bidder);
        assertEq(bondAmount, BOND_AMOUNT);
        assertEq(address(ethEscrow).balance, REWARD_AMOUNT + BOND_AMOUNT);
    }

    function testEthBondEscrowRejectsZeroValueBid() public {
        EscrowBatch.BatchTransfer[] memory transfers = _batch();
        vm.deal(deployer, REWARD_AMOUNT);
        vm.startPrank(deployer);
        token.approve(vm.computeCreateAddress(deployer, vm.getNonce(deployer)), PAYMENT_AMOUNT);
        EscrowBatch ethEscrow = new EscrowBatch{value: REWARD_AMOUNT}(address(0), transfers, REWARD_AMOUNT);
        vm.stopPrank();

        vm.deal(bidder, BOND_AMOUNT);
        vm.startPrank(bidder);
        vm.expectRevert(EscrowBatch.IncorrectNativeAmount.selector);
        ethEscrow.bid(_fullIndexes(), BOND_AMOUNT); // msg.value omitted → 0 ≠ BOND_AMOUNT
        vm.stopPrank();
    }

    function testErc20BondEscrowRejectsExtraValueOnBid() public {
        vm.deal(bidder, 1 ether);
        vm.startPrank(bidder);
        token.approve(address(escrow), BOND_AMOUNT);
        vm.expectRevert(EscrowBatch.IncorrectNativeAmount.selector);
        escrow.bid{value: 1}(_fullIndexes(), BOND_AMOUNT);
        vm.stopPrank();
    }

    function testEthBondCancelAndWithdrawRefundsEth() public {
        EscrowBatch.BatchTransfer[] memory transfers = _batch();
        vm.deal(deployer, REWARD_AMOUNT);
        vm.startPrank(deployer);
        token.approve(vm.computeCreateAddress(deployer, vm.getNonce(deployer)), PAYMENT_AMOUNT);
        EscrowBatch ethEscrow = new EscrowBatch{value: REWARD_AMOUNT}(address(0), transfers, REWARD_AMOUNT);
        vm.stopPrank();

        uint256 tokenBalanceBefore = token.balanceOf(deployer);
        uint256 ethBalanceBefore = deployer.balance;

        vm.prank(deployer);
        ethEscrow.cancelAndWithdraw();

        assertEq(deployer.balance, ethBalanceBefore + REWARD_AMOUNT, "reward refunded in ETH");
        assertEq(token.balanceOf(deployer), tokenBalanceBefore + PAYMENT_AMOUNT, "payment refunded in ERC-20");
        assertFalse(ethEscrow.funded());
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

    function _placeBid(uint256[] memory transferIndexes, uint256 bondAmount) internal {
        vm.startPrank(bidder);
        token.approve(address(escrow), bondAmount);
        escrow.bid(transferIndexes, bondAmount);
        vm.stopPrank();
    }

    function _batch() internal view returns (EscrowBatch.BatchTransfer[] memory transfers) {
        transfers = new EscrowBatch.BatchTransfer[](2);
        transfers[0] = EscrowBatch.BatchTransfer({asset: address(token), recipient: recipientA, amount: AMOUNT_A});
        transfers[1] = EscrowBatch.BatchTransfer({asset: address(token), recipient: recipientB, amount: AMOUNT_B});
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
        returns (EscrowBatch.BatchProof[] memory proofs)
    {
        proofs = new EscrowBatch.BatchProof[](1);
        proofs[0] = EscrowBatch.BatchProof({
            receiptProof: _emptyProof(),
            transactionRlp: hex"",
            txProofNodes: hex"",
            transferIndexes: transferIndexes,
            logIndexes: logIndexes
        });
    }

    function _emptyProof() internal view returns (EscrowBatch.BatchReceiptProof memory proof) {
        proof = EscrowBatch.BatchReceiptProof({
            blockHeader: hex"",
            receiptRlp: hex"",
            proofNodes: hex"",
            receiptPath: hex"01",
            targetBlockNumber: block.number
        });
    }
}
