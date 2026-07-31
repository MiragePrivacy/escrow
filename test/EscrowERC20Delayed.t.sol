// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {EscrowERC20Delayed} from "../src/EscrowERC20Delayed.sol";
import {BondAuth} from "./helpers/BondAuth.sol";

contract MockDelayedERC20 {
    mapping(address => uint256) public balanceOf;

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
}

contract EscrowERC20DelayedTest is Test {
    EscrowERC20Delayed public escrow;
    MockDelayedERC20 public token;
    address public deployer;
    address public executor;
    address public recipient;
    address public other;
    Vm.Wallet enclave;

    uint256 constant EXPECTED_AMOUNT = 1000e18;
    uint256 constant REWARD_AMOUNT = 500e18;
    uint256 constant EXECUTION_POT_AMOUNT = 25e18;
    uint256 constant FUND_REQUIRED = EXPECTED_AMOUNT + REWARD_AMOUNT + EXECUTION_POT_AMOUNT;

    function setUp() public {
        deployer = makeAddr("deployer");
        executor = makeAddr("executor");
        recipient = makeAddr("recipient");
        other = makeAddr("other");
        enclave = vm.createWallet("enclave");

        vm.startPrank(deployer);
        token = new MockDelayedERC20();
        token.mint(deployer, 10000e18);
        escrow = new EscrowERC20Delayed(
            address(token), recipient, EXPECTED_AMOUNT, enclave.addr, REWARD_AMOUNT, EXECUTION_POT_AMOUNT
        );
        vm.stopPrank();
    }

    function _sig(address escrowAddress, address bondingExecutor) internal view returns (bytes memory) {
        return BondAuth.sign(vm, enclave.privateKey, escrowAddress, bondingExecutor);
    }

    function _fund() internal {
        vm.prank(deployer);
        token.transfer(address(escrow), FUND_REQUIRED);
    }

    function _fundAndBond() internal {
        _fund();
        vm.prank(executor);
        escrow.bond(_sig(address(escrow), executor));
    }

    function _dummyProof() internal pure returns (EscrowERC20Delayed.ReceiptProof memory) {
        return EscrowERC20Delayed.ReceiptProof({
            blockHeader: hex"", receiptRlp: hex"", proofNodes: hex"", receiptPath: hex"", logIndex: 0
        });
    }

    function testConstructorDelayedState() public view {
        assertEq(escrow.tokenContract(), address(token));
        assertEq(escrow.expectedRecipient(), recipient);
        assertEq(escrow.expectedAmount(), EXPECTED_AMOUNT);
        assertEq(escrow.blindedSigner(), enclave.addr);
        assertEq(escrow.currentPaymentAmount(), EXPECTED_AMOUNT);
        assertEq(escrow.currentRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow.originalRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow.executionPotAmount(), EXECUTION_POT_AMOUNT);
        assertEq(escrow.bondPot(), 0);
        assertEq(escrow.funded(), 0);
    }

    function testConstructorRejectsZeroAddresses() public {
        vm.startPrank(deployer);
        vm.expectRevert(EscrowERC20Delayed.ZeroAddress.selector);
        new EscrowERC20Delayed(
            address(0), recipient, EXPECTED_AMOUNT, enclave.addr, REWARD_AMOUNT, EXECUTION_POT_AMOUNT
        );
        vm.expectRevert(EscrowERC20Delayed.ZeroAddress.selector);
        new EscrowERC20Delayed(
            address(token), address(0), EXPECTED_AMOUNT, enclave.addr, REWARD_AMOUNT, EXECUTION_POT_AMOUNT
        );
        vm.expectRevert(EscrowERC20Delayed.ZeroAddress.selector);
        new EscrowERC20Delayed(
            address(token), recipient, EXPECTED_AMOUNT, address(0), REWARD_AMOUNT, EXECUTION_POT_AMOUNT
        );
        vm.stopPrank();
    }

    function testConstructorRejectsZeroPaymentOrReward() public {
        vm.startPrank(deployer);
        vm.expectRevert(EscrowERC20Delayed.ZeroAmount.selector);
        new EscrowERC20Delayed(address(token), recipient, 0, enclave.addr, REWARD_AMOUNT, EXECUTION_POT_AMOUNT);
        vm.expectRevert(EscrowERC20Delayed.ZeroRewardAmount.selector);
        new EscrowERC20Delayed(address(token), recipient, EXPECTED_AMOUNT, enclave.addr, 0, EXECUTION_POT_AMOUNT);
        vm.stopPrank();
    }

    function testFundedRequiresPaymentRewardAndExecutionPot() public {
        vm.prank(deployer);
        token.transfer(address(escrow), FUND_REQUIRED - 1);
        assertEq(escrow.funded(), 0);

        vm.prank(deployer);
        token.transfer(address(escrow), 1);
        assertEq(escrow.funded(), 2);
    }

    function testBondRejectsUnfundedEscrow() public {
        vm.prank(executor);
        vm.expectRevert(EscrowERC20Delayed.NotFunded.selector);
        escrow.bond(_sig(address(escrow), executor));
    }

    function testBondPaysTokenExecutionPot() public {
        _fund();
        uint256 executorBefore = token.balanceOf(executor);

        vm.prank(executor);
        escrow.bond(_sig(address(escrow), executor));

        assertEq(escrow.bondedExecutor(), executor);
        assertEq(escrow.executionDeadline(), block.timestamp + 5 minutes);
        assertEq(escrow.bondStartBlock(), block.number);
        assertTrue(escrow.is_bonded());
        assertEq(escrow.executionPotAmount(), 0);
        assertEq(token.balanceOf(executor), executorBefore + EXECUTION_POT_AMOUNT);
        assertEq(token.balanceOf(address(escrow)), EXPECTED_AMOUNT + REWARD_AMOUNT);
        assertEq(escrow.funded(), 2);
    }

    function testBondRequiresBlindedSignerAuthorization() public {
        _fund();

        vm.prank(executor);
        vm.expectRevert(EscrowERC20Delayed.InvalidBondSignature.selector);
        escrow.bond(_sig(address(escrow), other));
    }

    function testDoubleBondingPrevented() public {
        _fundAndBond();

        vm.prank(other);
        vm.expectRevert(EscrowERC20Delayed.ExecutorAlreadyBonded.selector);
        escrow.bond(_sig(address(escrow), other));
    }

    function testExpiredBondCanBeRetriedWithoutRepayingPot() public {
        _fundAndBond();
        vm.warp(block.timestamp + 6 minutes);

        uint256 otherBefore = token.balanceOf(other);
        vm.prank(other);
        escrow.bond(_sig(address(escrow), other));

        assertEq(escrow.bondedExecutor(), other);
        assertEq(token.balanceOf(other), otherBefore);
    }

    function testCancellationBlocksBond() public {
        _fund();
        vm.prank(deployer);
        escrow.requestCancellation();

        vm.prank(executor);
        vm.expectRevert(EscrowERC20Delayed.CancellationRequested.selector);
        escrow.bond(_sig(address(escrow), executor));
    }

    function testRequestCancellationAndResumeOnlyDeployer() public {
        vm.prank(executor);
        vm.expectRevert(EscrowERC20Delayed.OnlyDeployer.selector);
        escrow.requestCancellation();

        vm.prank(deployer);
        escrow.requestCancellation();
        assertTrue(escrow.cancellationRequest());

        vm.prank(executor);
        vm.expectRevert(EscrowERC20Delayed.OnlyDeployer.selector);
        escrow.resume();

        vm.prank(deployer);
        escrow.resume();
        assertFalse(escrow.cancellationRequest());
    }

    function testCollectRejectsUnfundedEscrow() public {
        vm.prank(executor);
        vm.expectRevert(EscrowERC20Delayed.NotFunded.selector);
        escrow.collect(_dummyProof(), block.number);
    }

    function testCollectRequiresBondedExecutor() public {
        _fundAndBond();
        vm.roll(block.number + 1);

        vm.prank(other);
        vm.expectRevert(EscrowERC20Delayed.OnlyBondedExecutor.selector);
        escrow.collect(_dummyProof(), block.number);
    }

    function testCollectRejectsProofFromBeforeBond() public {
        vm.roll(100);
        _fundAndBond();
        vm.roll(101);

        vm.prank(executor);
        vm.expectRevert(EscrowERC20Delayed.ProofBeforeBond.selector);
        escrow.collect(_dummyProof(), 100);
    }

    function testCancelAndWithdrawRetiresEscrow() public {
        uint256 partialFunding = FUND_REQUIRED / 2;
        vm.prank(deployer);
        token.transfer(address(escrow), partialFunding);
        uint256 deployerBefore = token.balanceOf(deployer);

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertEq(token.balanceOf(deployer), deployerBefore + partialFunding);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(escrow.funded(), 0);
        assertEq(escrow.currentPaymentAmount(), 0);
        assertEq(escrow.currentRewardAmount(), 0);
        assertEq(escrow.executionPotAmount(), 0);
    }

    function testRetiredEscrowCannotBeReused() public {
        vm.prank(deployer);
        token.transfer(address(escrow), 1);
        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        vm.prank(deployer);
        token.transfer(address(escrow), FUND_REQUIRED);
        assertEq(escrow.funded(), 0);

        vm.prank(executor);
        vm.expectRevert(EscrowERC20Delayed.NotFunded.selector);
        escrow.bond(_sig(address(escrow), executor));
    }

    function testCancelAndWithdrawRejectsUnauthorizedOrEmpty() public {
        vm.prank(executor);
        vm.expectRevert(EscrowERC20Delayed.OnlyDeployer.selector);
        escrow.cancelAndWithdraw();

        vm.prank(deployer);
        vm.expectRevert(EscrowERC20Delayed.NoWithdrawableFunds.selector);
        escrow.cancelAndWithdraw();
    }

    function testCancelAndWithdrawRejectsActiveBond() public {
        _fundAndBond();

        vm.prank(deployer);
        vm.expectRevert(EscrowERC20Delayed.BondActive.selector);
        escrow.cancelAndWithdraw();
    }

    function testCancelAndWithdrawAfterExpiredBond() public {
        _fundAndBond();
        vm.warp(block.timestamp + 6 minutes);
        uint256 deployerBefore = token.balanceOf(deployer);

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertEq(token.balanceOf(deployer), deployerBefore + EXPECTED_AMOUNT + REWARD_AMOUNT);
        assertEq(escrow.funded(), 0);
    }
}
