// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {EscrowBatch} from "../src/EscrowBatch.sol";
import {BatchBondAuth} from "./helpers/BatchBondAuth.sol";

contract BatchMockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public transferCalls;
    uint256 public transferFromCalls;
    uint256 public totalTransferAmount;
    uint256 public totalTransferFromAmount;
    bool public transfersDisabled;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(!transfersDisabled, "Transfers disabled");
        transferCalls += 1;
        totalTransferAmount += amount;
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        transferFromCalls += 1;
        totalTransferFromAmount += amount;
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

    function resetCallStats() external {
        transferCalls = 0;
        transferFromCalls = 0;
        totalTransferAmount = 0;
        totalTransferFromAmount = 0;
    }

    function setTransfersDisabled(bool disabled) external {
        transfersDisabled = disabled;
    }
}

contract EscrowBatchHarness is EscrowBatch {
    constructor(
        address rewardAsset,
        BatchTransfer[] memory expectedTransfers,
        uint256 currentRewardAmount,
        uint256 maxGasAdvance,
        address[] memory blindedSigners
    ) payable EscrowBatch(rewardAsset, expectedTransfers, currentRewardAmount, maxGasAdvance, blindedSigners) {}

    function settleRowsForTest(uint256[] calldata transferIndexes) external {
        uint256[] memory provedTransferIndexes = new uint256[](transferIndexes.length);

        for (uint256 i = 0; i < transferIndexes.length; ++i) {
            uint256 transferIndex = transferIndexes[i];
            require(transferBidder[transferIndex] == msg.sender, "Row not assigned");
            provedTransferIndexes[i] = transferIndex;
        }

        _settleProvedRows(msg.sender, provedTransferIndexes, transferIndexes.length);
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
    uint256 constant GAS_ADVANCE_BUDGET = REWARD_AMOUNT / 2;
    uint256 constant BLINDED_SIGNER_KEY_BASE = 10_000;
    uint256 nextSignerIndex;

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

        escrow = new EscrowBatch(address(token), _batch(), REWARD_AMOUNT, GAS_ADVANCE_BUDGET, _blindedSigners(16));
        vm.stopPrank();

        token.mint(bidder, 10_000e18);
        token.mint(other, 10_000e18);
    }

    function testConstructorStoresBatch() public view {
        assertEq(escrow.deployerAddress(), deployer);
        assertEq(escrow.rewardAsset(), address(token));
        assertEq(escrow.maxGasAdvance(), GAS_ADVANCE_BUDGET);
        assertEq(escrow.blindedSignerCount(), 16);
        assertEq(escrow.expectedTransferCount(), 2);
        assertEq(escrow.totalTransferAmount(), PAYMENT_AMOUNT);
        assertEq(escrow.totalValueWeight(), PAYMENT_AMOUNT);
        assertEq(escrow.currentTransferAmount(), PAYMENT_AMOUNT);
        assertEq(escrow.currentValueWeight(), PAYMENT_AMOUNT);
        assertEq(escrow.currentRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow.completedTransferCount(), 0);
        assertEq(escrow.activeBidCount(), 0);
        assertTrue(escrow.funded());
        assertEq(token.transferFromCalls(), 1);
        assertEq(token.totalTransferFromAmount(), PAYMENT_AMOUNT + REWARD_AMOUNT);

        (address firstAsset, address firstRecipient, uint256 firstAmount, uint256 firstWeight) =
            escrow.expectedTransfers(0);
        (address secondAsset, address secondRecipient, uint256 secondAmount, uint256 secondWeight) =
            escrow.expectedTransfers(1);

        assertEq(firstAsset, address(token));
        assertEq(firstRecipient, recipientA);
        assertEq(firstAmount, AMOUNT_A);
        assertEq(firstWeight, AMOUNT_A);
        assertEq(secondAsset, address(token));
        assertEq(secondRecipient, recipientB);
        assertEq(secondAmount, AMOUNT_B);
        assertEq(secondWeight, AMOUNT_B);
    }

    function testConstructorRejectsEmptyBatch() public {
        EscrowBatch.BatchTransfer[] memory transfers = new EscrowBatch.BatchTransfer[](0);

        vm.prank(deployer);
        vm.expectRevert(EscrowBatch.EmptyBatch.selector);
        new EscrowBatch(address(token), transfers, REWARD_AMOUNT, GAS_ADVANCE_BUDGET, _blindedSigners(1));
    }

    function testConstructorRejectsZeroAmount() public {
        EscrowBatch.BatchTransfer[] memory transfers = new EscrowBatch.BatchTransfer[](1);
        transfers[0] =
            EscrowBatch.BatchTransfer({asset: address(token), recipient: recipientA, amount: 0, valueWeight: 1});

        vm.prank(deployer);
        vm.expectRevert(EscrowBatch.ZeroPaymentAmount.selector);
        new EscrowBatch(address(token), transfers, REWARD_AMOUNT, GAS_ADVANCE_BUDGET, _blindedSigners(1));
    }

    function testConstructorRejectsZeroValueWeight() public {
        EscrowBatch.BatchTransfer[] memory transfers = new EscrowBatch.BatchTransfer[](1);
        transfers[0] =
            EscrowBatch.BatchTransfer({asset: address(token), recipient: recipientA, amount: AMOUNT_A, valueWeight: 0});

        vm.prank(deployer);
        vm.expectRevert(EscrowBatch.ZeroValueWeight.selector);
        new EscrowBatch(address(token), transfers, REWARD_AMOUNT, GAS_ADVANCE_BUDGET, _blindedSigners(1));
    }

    function testConstructorRejectsEmptyBlindedSigners() public {
        address[] memory signers = new address[](0);

        vm.prank(deployer);
        vm.expectRevert(EscrowBatch.EmptyBlindedSigners.selector);
        new EscrowBatch(address(token), _batch(), REWARD_AMOUNT, GAS_ADVANCE_BUDGET, signers);
    }

    function testConstructorRejectsZeroBlindedSigner() public {
        address[] memory signers = new address[](1);

        vm.prank(deployer);
        vm.expectRevert(EscrowBatch.ZeroBlindedSigner.selector);
        new EscrowBatch(address(token), _batch(), REWARD_AMOUNT, GAS_ADVANCE_BUDGET, signers);
    }

    function testConstructorRejectsDuplicateBlindedSigner() public {
        address[] memory signers = new address[](2);
        signers[0] = vm.addr(BLINDED_SIGNER_KEY_BASE);
        signers[1] = signers[0];

        vm.prank(deployer);
        vm.expectRevert(EscrowBatch.DuplicateBlindedSigner.selector);
        new EscrowBatch(address(token), _batch(), REWARD_AMOUNT, GAS_ADVANCE_BUDGET, signers);
    }

    function testConstructorRejectsTooManyBlindedSigners() public {
        address[] memory signers = _blindedSigners(escrow.MAX_BLINDED_SIGNERS() + 1);

        vm.prank(deployer);
        vm.expectRevert(EscrowBatch.TooManyBlindedSigners.selector);
        new EscrowBatch(address(token), _batch(), REWARD_AMOUNT, GAS_ADVANCE_BUDGET, signers);
    }

    function testConstructorRejectsTooManyRows() public {
        EscrowBatch.BatchTransfer[] memory transfers = new EscrowBatch.BatchTransfer[](escrow.MAX_ROWS() + 1);

        vm.prank(deployer);
        vm.expectRevert(EscrowBatch.TooManyRows.selector);
        new EscrowBatch(address(token), transfers, REWARD_AMOUNT, GAS_ADVANCE_BUDGET, _blindedSigners(1));
    }

    function testConstructorRejectsGasAdvanceBudgetAboveReward() public {
        vm.startPrank(deployer);
        address futureEscrow = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        token.approve(futureEscrow, PAYMENT_AMOUNT + REWARD_AMOUNT);
        vm.expectRevert(EscrowBatch.GasAdvanceBudgetExceedsReward.selector);
        new EscrowBatch(address(token), _batch(), REWARD_AMOUNT, REWARD_AMOUNT + 1, _blindedSigners(2));
        vm.stopPrank();
    }

    function testFundUnfundedBatch() public {
        vm.startPrank(deployer);
        EscrowBatch unfunded = new EscrowBatch(address(token), _batch(), 0, GAS_ADVANCE_BUDGET, _blindedSigners(2));

        token.approve(address(unfunded), PAYMENT_AMOUNT + REWARD_AMOUNT);
        token.resetCallStats();
        unfunded.fund(REWARD_AMOUNT);
        vm.stopPrank();

        assertTrue(unfunded.funded());
        assertEq(unfunded.currentTransferAmount(), PAYMENT_AMOUNT);
        assertEq(unfunded.currentRewardAmount(), REWARD_AMOUNT);
        assertEq(token.balanceOf(address(unfunded)), PAYMENT_AMOUNT + REWARD_AMOUNT);
        assertEq(token.transferFromCalls(), 1);
        assertEq(token.totalTransferFromAmount(), PAYMENT_AMOUNT + REWARD_AMOUNT);
    }

    function testFundOnlyDeployer() public {
        vm.prank(deployer);
        EscrowBatch unfunded = new EscrowBatch(address(token), _batch(), 0, GAS_ADVANCE_BUDGET, _blindedSigners(2));

        vm.startPrank(bidder);
        token.approve(address(unfunded), PAYMENT_AMOUNT + REWARD_AMOUNT);
        vm.expectRevert(EscrowBatch.OnlyDeployer.selector);
        unfunded.fund(REWARD_AMOUNT);
        vm.stopPrank();
    }

    function testConstructorFundsNativeAsset() public {
        EscrowBatch.BatchTransfer[] memory transfers = new EscrowBatch.BatchTransfer[](1);
        transfers[0] = EscrowBatch.BatchTransfer({
            asset: address(0), recipient: recipientA, amount: 1 ether, valueWeight: 1 ether
        });

        vm.startPrank(deployer);
        vm.deal(deployer, 1 ether);
        token.approve(vm.computeCreateAddress(deployer, vm.getNonce(deployer)), REWARD_AMOUNT);
        EscrowBatch nativeEscrow = new EscrowBatch{value: 1 ether}(
            address(token), transfers, REWARD_AMOUNT, GAS_ADVANCE_BUDGET, _blindedSigners(2)
        );
        vm.stopPrank();

        assertTrue(nativeEscrow.funded());
        assertEq(nativeEscrow.currentAssetPaymentAmount(address(0)), 1 ether);
        assertEq(address(nativeEscrow).balance, 1 ether);
        assertEq(nativeEscrow.totalTransferAmount(), 1 ether);
    }

    function testBid() public {
        _placeBid(_fullIndexes());

        (uint256 remainingRows, uint256 expiresAt, uint256 startBlock) = escrow.bids(bidder);
        (address signer, bool used) = escrow.blindedSignerAt(0);

        assertEq(remainingRows, 2);
        assertEq(expiresAt, block.timestamp + escrow.BID_DURATION());
        assertEq(startBlock, block.number);
        assertEq(signer, vm.addr(BLINDED_SIGNER_KEY_BASE));
        assertTrue(used);
        assertTrue(escrow.blindedSignerUsed(signer));
        assertEq(escrow.activeBidCount(), 1);
        assertEq(escrow.transferBidder(0), bidder);
        assertEq(escrow.transferBidder(1), bidder);
        assertEq(escrow.bidTransferCount(bidder), 2);
        assertEq(escrow.bidTransferIndex(bidder, 0), 0);
        assertEq(escrow.bidTransferIndex(bidder, 1), 1);
        assertTrue(escrow.is_bonded());
    }

    function testBidAdvancesRewardTokens() public {
        uint256 gasAdvance = REWARD_AMOUNT / 4;
        uint256[] memory indexes = _singleIndex(0);
        bytes memory signature =
            BatchBondAuth.sign(vm, BLINDED_SIGNER_KEY_BASE, address(escrow), bidder, indexes, gasAdvance);
        uint256 bidderBefore = token.balanceOf(bidder);

        vm.prank(bidder);
        escrow.bid(indexes, gasAdvance, signature);

        assertEq(token.balanceOf(bidder), bidderBefore + gasAdvance);
        assertEq(escrow.currentRewardAmount(), REWARD_AMOUNT - gasAdvance);
        assertEq(escrow.totalGasAdvanced(), gasAdvance);
        assertEq(escrow.remainingGasAdvance(), REWARD_AMOUNT / 2 - gasAdvance);
    }

    function testBidSignatureBindsGasAdvance() public {
        uint256[] memory indexes = _singleIndex(0);
        uint256 signedAdvance = REWARD_AMOUNT / 4;
        bytes memory signature =
            BatchBondAuth.sign(vm, BLINDED_SIGNER_KEY_BASE, address(escrow), bidder, indexes, signedAdvance);

        vm.prank(bidder);
        vm.expectRevert(EscrowBatch.InvalidBidSignature.selector);
        escrow.bid(indexes, signedAdvance + 1, signature);
    }

    function testBidAdvancesShareOneEscrowWideLimit() public {
        uint256 firstAdvance = REWARD_AMOUNT * 2 / 5;
        uint256 remainingAdvance = REWARD_AMOUNT / 10;
        uint256[] memory firstIndexes = _singleIndex(0);
        uint256[] memory secondIndexes = _singleIndex(1);

        bytes memory firstSignature =
            BatchBondAuth.sign(vm, BLINDED_SIGNER_KEY_BASE, address(escrow), bidder, firstIndexes, firstAdvance);
        vm.prank(bidder);
        escrow.bid(firstIndexes, firstAdvance, firstSignature);

        bytes memory excessiveSignature = BatchBondAuth.sign(
            vm, BLINDED_SIGNER_KEY_BASE + 1, address(escrow), other, secondIndexes, remainingAdvance + 1
        );
        vm.prank(other);
        vm.expectRevert(EscrowBatch.GasAdvanceTooLarge.selector);
        escrow.bid(secondIndexes, remainingAdvance + 1, excessiveSignature);

        bytes memory remainingSignature = BatchBondAuth.sign(
            vm, BLINDED_SIGNER_KEY_BASE + 1, address(escrow), other, secondIndexes, remainingAdvance
        );
        vm.prank(other);
        escrow.bid(secondIndexes, remainingAdvance, remainingSignature);

        assertEq(escrow.totalGasAdvanced(), REWARD_AMOUNT / 2);
        assertEq(escrow.remainingGasAdvance(), 0);
        assertEq(escrow.currentRewardAmount(), REWARD_AMOUNT / 2);
    }

    function testIsBondedIgnoresExpiredBidBeforeCleanup() public {
        _placeBid(_singleIndex(0));
        vm.warp(block.timestamp + escrow.BID_DURATION() + 1);

        assertFalse(escrow.is_bonded());
    }

    function testMultipleBiddersCanCoverDisjointTransfers() public {
        _placeBid(_singleIndex(0));
        _placeBidAs(escrow, other, _singleIndex(1));

        assertEq(escrow.activeBidCount(), 2);
        assertEq(escrow.transferBidder(0), bidder);
        assertEq(escrow.transferBidder(1), other);
    }

    function testBidRejectsOverlap() public {
        _placeBid(_singleIndex(0));

        uint256[] memory indexes = _singleIndex(0);
        bytes memory signature = _nextBidSignature(address(escrow), other, indexes);
        vm.prank(other);
        vm.expectRevert(EscrowBatch.TransferStateConflict.selector);
        escrow.bid(indexes, 0, signature);
    }

    function testBidRejectsDuplicateTransferIndex() public {
        uint256[] memory duplicateIndexes = new uint256[](2);
        duplicateIndexes[0] = 0;
        duplicateIndexes[1] = 0;

        bytes memory signature = _nextBidSignature(address(escrow), bidder, duplicateIndexes);
        vm.prank(bidder);
        vm.expectRevert(EscrowBatch.DuplicateProofItem.selector);
        escrow.bid(duplicateIndexes, 0, signature);
    }

    function testBidRejectsUnauthorizedSigner() public {
        uint256[] memory indexes = _singleIndex(1);
        bytes memory signature = BatchBondAuth.sign(vm, 999_999, address(escrow), bidder, indexes);

        vm.prank(bidder);
        vm.expectRevert(EscrowBatch.InvalidBidSignature.selector);
        escrow.bid(indexes, 0, signature);
    }

    function testBidSignatureCannotBeUsedByAnotherExecutor() public {
        uint256[] memory indexes = _singleIndex(0);
        bytes memory signature = BatchBondAuth.sign(vm, BLINDED_SIGNER_KEY_BASE, address(escrow), bidder, indexes);

        vm.prank(other);
        vm.expectRevert(EscrowBatch.InvalidBidSignature.selector);
        escrow.bid(indexes, 0, signature);
    }

    function testBidSignatureCannotAuthorizeDifferentRows() public {
        bytes memory signature =
            BatchBondAuth.sign(vm, BLINDED_SIGNER_KEY_BASE, address(escrow), bidder, _singleIndex(0));

        vm.prank(bidder);
        vm.expectRevert(EscrowBatch.InvalidBidSignature.selector);
        escrow.bid(_singleIndex(1), 0, signature);
    }

    function testBidSignatureCannotBeUsedForAnotherEscrow() public {
        EscrowBatchHarness otherEscrow = _deployHarness(_batch(), REWARD_AMOUNT);
        uint256[] memory indexes = _singleIndex(0);
        bytes memory signature = BatchBondAuth.sign(vm, BLINDED_SIGNER_KEY_BASE, address(escrow), bidder, indexes);

        vm.prank(bidder);
        vm.expectRevert(EscrowBatch.InvalidBidSignature.selector);
        otherEscrow.bid(indexes, 0, signature);
    }

    function testDomainSeparatorBindsDeploymentChain() public view {
        bytes32 domainTypeHash =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 expected = keccak256(
            abi.encode(domainTypeHash, keccak256("MirageEscrow"), keccak256("1"), block.chainid, address(escrow))
        );

        assertEq(escrow.domainSeparator(), expected);
    }

    function testBlindedSignerCannotBeReusedAfterBidExpires() public {
        uint256[] memory indexes = _singleIndex(0);
        bytes memory signature = BatchBondAuth.sign(vm, BLINDED_SIGNER_KEY_BASE, address(escrow), bidder, indexes);

        vm.prank(bidder);
        escrow.bid(indexes, 0, signature);

        vm.warp(block.timestamp + escrow.BID_DURATION() + 1);
        escrow.expireBid(bidder);

        vm.prank(bidder);
        vm.expectRevert(EscrowBatch.BlindedSignerAlreadyUsed.selector);
        escrow.bid(indexes, 0, signature);

        assertEq(escrow.activeBidCount(), 0);
        assertEq(escrow.transferBidder(0), address(0));
    }

    function testBidAutomaticallyClearsExpiredBidder() public {
        _placeBid(_fullIndexes());

        vm.warp(block.timestamp + 6 minutes);
        _placeBidAs(escrow, other, _fullIndexes());

        (uint256 remainingRows, uint256 expiresAt, uint256 startBlock) = escrow.bids(other);

        assertEq(remainingRows, 2);
        assertEq(expiresAt, block.timestamp + escrow.BID_DURATION());
        assertEq(startBlock, block.number);
        assertEq(escrow.currentRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow.activeBidCount(), 1);
        assertEq(escrow.transferBidder(0), other);
        assertEq(escrow.transferBidder(1), other);
    }

    function testCollectRejectsInvalidBatchProofLength() public {
        _placeBid(_fullIndexes());

        uint256[] memory transferIndexes = _singleIndex(0);
        uint256[] memory logIndexes = new uint256[](2);

        vm.prank(bidder);
        vm.expectRevert(EscrowBatch.MalformedProof.selector);
        escrow.collect(_proofs(transferIndexes, logIndexes));
    }

    function testCollectRejectsDuplicateLogIndex() public {
        _placeBid(_fullIndexes());

        uint256[] memory logIndexes = new uint256[](2);
        logIndexes[0] = 3;
        logIndexes[1] = 3;

        vm.prank(bidder);
        vm.expectRevert(EscrowBatch.DuplicateProofItem.selector);
        escrow.collect(_proofs(_fullIndexes(), logIndexes));
    }

    function testCollectRejectsDuplicateTransferIndex() public {
        _placeBid(_fullIndexes());

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
        _placeBid(_singleIndex(0));

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

    function testNineOfTenSettlementExpiresOnlyRemainder() public {
        EscrowBatch.BatchTransfer[] memory transfers = _equalBatch(10, 100e18);
        EscrowBatchHarness partialEscrow = _deployHarness(transfers, 100e18);
        uint256[] memory allIndexes = _sequentialIndexes(10);

        _placeBidAs(partialEscrow, bidder, allIndexes);
        vm.startPrank(bidder);
        partialEscrow.settleRowsForTest(_sequentialIndexes(9));
        vm.stopPrank();

        assertEq(partialEscrow.completedTransferCount(), 9);
        assertEq(partialEscrow.currentTransferAmount(), 100e18);
        assertEq(partialEscrow.currentValueWeight(), 100e18);
        assertEq(partialEscrow.currentRewardAmount(), 10e18);
        assertEq(partialEscrow.claimable(bidder, address(token)), 0);
        assertEq(token.balanceOf(bidder), 10_990e18);

        (uint256 remainingRows,,) = partialEscrow.bids(bidder);
        assertEq(remainingRows, 1);

        for (uint256 i = 0; i < 9; ++i) {
            assertTrue(partialEscrow.transferCompleted(i));
            assertEq(partialEscrow.transferBidder(i), address(0));
        }
        assertFalse(partialEscrow.transferCompleted(9));
        assertEq(partialEscrow.transferBidder(9), bidder);

        uint256[] memory completedIndex = _singleIndex(0);
        bytes memory completedSignature = _nextBidSignature(address(partialEscrow), other, completedIndex);
        vm.expectRevert(EscrowBatch.TransferStateConflict.selector);
        vm.prank(other);
        partialEscrow.bid(completedIndex, 0, completedSignature);

        vm.warp(block.timestamp + partialEscrow.BID_DURATION() + 1);
        _placeBidAs(partialEscrow, other, _singleIndex(9));

        assertEq(partialEscrow.currentRewardAmount(), 10e18);
        assertEq(partialEscrow.activeBidCount(), 1);
        for (uint256 i = 0; i < 9; ++i) {
            assertTrue(partialEscrow.transferCompleted(i));
        }

        assertEq(partialEscrow.transferBidder(9), other);
        vm.startPrank(other);
        partialEscrow.settleRowsForTest(_singleIndex(9));
        vm.stopPrank();

        assertFalse(partialEscrow.funded());
        assertEq(partialEscrow.completedTransferCount(), 10);
        assertEq(partialEscrow.claimable(other, address(token)), 0);
        assertEq(token.balanceOf(other), 10_110e18);
    }

    function testClaimWithdrawalRevertDoesNotReopenSettledRow() public {
        EscrowBatchHarness singleEscrow = _deployHarness(_equalBatch(1, 100e18), 20e18);

        _placeBidAs(singleEscrow, bidder, _singleIndex(0));
        vm.startPrank(bidder);
        token.setTransfersDisabled(true);
        singleEscrow.settleRowsForTest(_singleIndex(0));
        vm.stopPrank();

        uint256 claim = singleEscrow.claimable(bidder, address(token));
        assertEq(claim, 120e18);

        vm.prank(bidder);
        vm.expectRevert("Transfers disabled");
        singleEscrow.withdrawClaim(address(token));

        assertTrue(singleEscrow.transferCompleted(0));
        assertFalse(singleEscrow.funded());
        assertEq(singleEscrow.claimable(bidder, address(token)), claim);
    }

    function testHybridPayoutPaysImmediatelyAndFallsBackToClaim() public {
        EscrowBatchHarness hybridEscrow = _deployHarness(_equalBatch(2, 100e18), 20e18);

        _placeBidAs(hybridEscrow, bidder, _sequentialIndexes(2));
        vm.startPrank(bidder);

        // A successful payout is transferred during settlement and creates no claim.
        hybridEscrow.settleRowsForTest(_singleIndex(0));
        assertEq(token.balanceOf(bidder), 10_110e18);
        assertEq(hybridEscrow.claimable(bidder, address(token)), 0);
        assertTrue(hybridEscrow.transferCompleted(0));

        // A failed payout does not revert settlement; it becomes withdrawable.
        token.setTransfersDisabled(true);
        hybridEscrow.settleRowsForTest(_singleIndex(1));
        assertEq(token.balanceOf(bidder), 10_110e18);
        assertEq(hybridEscrow.claimable(bidder, address(token)), 110e18);
        assertTrue(hybridEscrow.transferCompleted(1));
        assertFalse(hybridEscrow.funded());

        token.setTransfersDisabled(false);
        hybridEscrow.withdrawClaim(address(token));
        vm.stopPrank();

        assertEq(token.balanceOf(bidder), 10_220e18);
        assertEq(hybridEscrow.claimable(bidder, address(token)), 0);
        assertTrue(hybridEscrow.transferCompleted(0));
        assertTrue(hybridEscrow.transferCompleted(1));
    }

    function testCancelAndWithdraw() public {
        uint256 initialBalance = token.balanceOf(deployer);
        token.resetCallStats();

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertTrue(escrow.cancellationRequest());
        assertFalse(escrow.funded());
        assertEq(token.balanceOf(deployer), initialBalance + PAYMENT_AMOUNT + REWARD_AMOUNT);
        assertEq(token.transferCalls(), 1);
        assertEq(token.totalTransferAmount(), PAYMENT_AMOUNT + REWARD_AMOUNT);
    }

    function testCancelAndWithdrawRejectsActiveBid() public {
        _placeBid(_singleIndex(0));

        vm.prank(deployer);
        vm.expectRevert(EscrowBatch.BidActive.selector);
        escrow.cancelAndWithdraw();
    }

    function testCancelAndWithdrawAfterExpiredBid() public {
        _placeBid(_singleIndex(0));
        vm.warp(block.timestamp + 6 minutes);

        uint256 initialBalance = token.balanceOf(deployer);

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertFalse(escrow.funded());
        assertEq(escrow.activeBidCount(), 0);
        assertEq(token.balanceOf(deployer), initialBalance + PAYMENT_AMOUNT + REWARD_AMOUNT);
    }

    function testExpireBidsClearsMultipleStaleBidsForCancellation() public {
        _placeBid(_singleIndex(0));
        _placeBidAs(escrow, other, _singleIndex(1));

        vm.prank(deployer);
        escrow.requestCancellation();
        vm.warp(block.timestamp + escrow.BID_DURATION() + 1);

        address[] memory expiredBidders = new address[](4);
        expiredBidders[0] = bidder;
        expiredBidders[1] = makeAddr("missingBidder");
        expiredBidders[2] = other;
        expiredBidders[3] = bidder;

        uint256 expiredBidCount = escrow.expireBids(expiredBidders);

        assertEq(expiredBidCount, 2);
        assertEq(escrow.activeBidCount(), 0);
        assertFalse(escrow.is_bonded());
        assertEq(escrow.transferBidder(0), address(0));
        assertEq(escrow.transferBidder(1), address(0));
        assertEq(escrow.currentRewardAmount(), REWARD_AMOUNT);

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertFalse(escrow.funded());
    }

    function testNativeRewardEscrowAcceptsFreeBid() public {
        EscrowBatch.BatchTransfer[] memory transfers = new EscrowBatch.BatchTransfer[](2);
        transfers[0] = EscrowBatch.BatchTransfer({
            asset: address(token), recipient: recipientA, amount: AMOUNT_A, valueWeight: AMOUNT_A
        });
        transfers[1] = EscrowBatch.BatchTransfer({
            asset: address(token), recipient: recipientB, amount: AMOUNT_B, valueWeight: AMOUNT_B
        });

        vm.deal(deployer, REWARD_AMOUNT);
        vm.startPrank(deployer);
        token.approve(vm.computeCreateAddress(deployer, vm.getNonce(deployer)), PAYMENT_AMOUNT);
        EscrowBatch ethEscrow = new EscrowBatch{value: REWARD_AMOUNT}(
            address(0), transfers, REWARD_AMOUNT, GAS_ADVANCE_BUDGET, _blindedSigners(16)
        );
        vm.stopPrank();

        assertEq(ethEscrow.rewardAsset(), address(0));
        assertEq(ethEscrow.currentRewardAmount(), REWARD_AMOUNT);
        assertEq(address(ethEscrow).balance, REWARD_AMOUNT);

        uint256 bidderBalanceBefore = bidder.balance;
        _placeBidAs(ethEscrow, bidder, _fullIndexes());

        (uint256 remainingRows,,) = ethEscrow.bids(bidder);
        assertEq(remainingRows, 2);
        assertEq(bidder.balance, bidderBalanceBefore);
        assertEq(address(ethEscrow).balance, REWARD_AMOUNT);
    }

    function testNativeRewardEscrowAdvancesEth() public {
        EscrowBatch.BatchTransfer[] memory transfers = _batch();
        vm.deal(deployer, REWARD_AMOUNT);
        vm.startPrank(deployer);
        token.approve(vm.computeCreateAddress(deployer, vm.getNonce(deployer)), PAYMENT_AMOUNT);
        EscrowBatch ethEscrow = new EscrowBatch{value: REWARD_AMOUNT}(
            address(0), transfers, REWARD_AMOUNT, GAS_ADVANCE_BUDGET, _blindedSigners(16)
        );
        vm.stopPrank();

        uint256 gasAdvance = REWARD_AMOUNT / 4;
        uint256[] memory indexes = _fullIndexes();
        bytes memory signature =
            BatchBondAuth.sign(vm, BLINDED_SIGNER_KEY_BASE, address(ethEscrow), bidder, indexes, gasAdvance);
        uint256 bidderBefore = bidder.balance;

        vm.prank(bidder);
        ethEscrow.bid(indexes, gasAdvance, signature);

        assertEq(bidder.balance, bidderBefore + gasAdvance);
        assertEq(address(ethEscrow).balance, REWARD_AMOUNT - gasAdvance);
        assertEq(ethEscrow.currentRewardAmount(), REWARD_AMOUNT - gasAdvance);
    }

    function testFreeBidDoesNotRequireNativeValue() public {
        EscrowBatch.BatchTransfer[] memory transfers = _batch();
        vm.deal(deployer, REWARD_AMOUNT);
        vm.startPrank(deployer);
        token.approve(vm.computeCreateAddress(deployer, vm.getNonce(deployer)), PAYMENT_AMOUNT);
        EscrowBatch ethEscrow = new EscrowBatch{value: REWARD_AMOUNT}(
            address(0), transfers, REWARD_AMOUNT, GAS_ADVANCE_BUDGET, _blindedSigners(16)
        );
        vm.stopPrank();

        _placeBidAs(ethEscrow, bidder, _fullIndexes());
        assertEq(address(ethEscrow).balance, REWARD_AMOUNT);
    }

    function testBidRejectsAttachedValue() public {
        uint256[] memory indexes = _fullIndexes();
        bytes memory signature = _nextBidSignature(address(escrow), bidder, indexes);

        vm.deal(bidder, 1 ether);
        vm.prank(bidder);
        (bool succeeded,) =
            address(escrow).call{value: 1}(abi.encodeWithSelector(escrow.bid.selector, indexes, 0, signature));

        assertFalse(succeeded);
    }

    function testNativeRewardCancelAndWithdrawRefundsEth() public {
        EscrowBatch.BatchTransfer[] memory transfers = _batch();
        vm.deal(deployer, REWARD_AMOUNT);
        vm.startPrank(deployer);
        token.approve(vm.computeCreateAddress(deployer, vm.getNonce(deployer)), PAYMENT_AMOUNT);
        EscrowBatch ethEscrow = new EscrowBatch{value: REWARD_AMOUNT}(
            address(0), transfers, REWARD_AMOUNT, GAS_ADVANCE_BUDGET, _blindedSigners(16)
        );
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

    function _placeBid(uint256[] memory transferIndexes) internal {
        _placeBidAs(escrow, bidder, transferIndexes);
    }

    function _placeBidAs(EscrowBatch target, address biddingExecutor, uint256[] memory transferIndexes) internal {
        bytes memory signature = _nextBidSignature(address(target), biddingExecutor, transferIndexes);
        vm.prank(biddingExecutor);
        target.bid(transferIndexes, 0, signature);
    }

    function _nextBidSignature(address target, address biddingExecutor, uint256[] memory transferIndexes)
        internal
        returns (bytes memory)
    {
        uint256 signerKey = BLINDED_SIGNER_KEY_BASE + nextSignerIndex;
        nextSignerIndex += 1;
        return BatchBondAuth.sign(vm, signerKey, target, biddingExecutor, transferIndexes);
    }

    function _blindedSigners(uint256 count) internal pure returns (address[] memory signers) {
        signers = new address[](count);
        for (uint256 i = 0; i < count; ++i) {
            signers[i] = vm.addr(BLINDED_SIGNER_KEY_BASE + i);
        }
    }

    function _batch() internal view returns (EscrowBatch.BatchTransfer[] memory transfers) {
        transfers = new EscrowBatch.BatchTransfer[](2);
        transfers[0] = EscrowBatch.BatchTransfer({
            asset: address(token), recipient: recipientA, amount: AMOUNT_A, valueWeight: AMOUNT_A
        });
        transfers[1] = EscrowBatch.BatchTransfer({
            asset: address(token), recipient: recipientB, amount: AMOUNT_B, valueWeight: AMOUNT_B
        });
    }

    function _equalBatch(uint256 count, uint256 amount)
        internal
        view
        returns (EscrowBatch.BatchTransfer[] memory transfers)
    {
        transfers = new EscrowBatch.BatchTransfer[](count);
        for (uint256 i = 0; i < count; ++i) {
            transfers[i] = EscrowBatch.BatchTransfer({
                asset: address(token),
                recipient: address(uint160(uint256(keccak256(abi.encode("recipient", i))))),
                amount: amount,
                valueWeight: amount
            });
        }
    }

    function _deployHarness(EscrowBatch.BatchTransfer[] memory transfers, uint256 rewardAmount)
        internal
        returns (EscrowBatchHarness deployed)
    {
        uint256 principal;
        for (uint256 i = 0; i < transfers.length; ++i) {
            principal += transfers[i].amount;
        }

        vm.startPrank(deployer);
        address futureEscrow = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        token.approve(futureEscrow, principal + rewardAmount);
        deployed =
            new EscrowBatchHarness(address(token), transfers, rewardAmount, rewardAmount / 2, _blindedSigners(16));
        vm.stopPrank();
    }

    function _sequentialIndexes(uint256 count) internal pure returns (uint256[] memory indexes) {
        indexes = new uint256[](count);
        for (uint256 i = 0; i < count; ++i) {
            indexes[i] = i;
        }
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
