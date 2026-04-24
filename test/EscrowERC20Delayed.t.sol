// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {EscrowERC20Delayed} from "../src/EscrowERC20Delayed.sol";

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

contract EscrowERC20DelayedTest is Test {
    EscrowERC20Delayed public escrow;
    MockERC20 public token;
    address public deployer;
    address public executor;
    address public recipient;
    address public other;

    uint256 constant EXPECTED_AMOUNT = 1000e18;
    uint256 constant REWARD_AMOUNT = 500e18;
    uint256 constant FUND_REQUIRED = EXPECTED_AMOUNT + REWARD_AMOUNT;
    uint256 constant BOND_AMOUNT = 250e18; // Half of reward amount

    function setUp() public {
        deployer = makeAddr("deployer");
        executor = makeAddr("executor");
        recipient = makeAddr("recipient");
        other = makeAddr("other");

        vm.startPrank(deployer);
        token = new MockERC20();
        token.mint(deployer, 10000e18);
        escrow = new EscrowERC20Delayed(address(token), recipient, EXPECTED_AMOUNT, REWARD_AMOUNT);
        vm.stopPrank();

        token.mint(executor, 10000e18);
        token.mint(other, 10000e18);
    }

    function testConstructorDelayedState() public view {
        assertEq(escrow.expectedRecipient(), recipient);
        assertEq(escrow.expectedAmount(), EXPECTED_AMOUNT);
        assertEq(escrow.currentRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow.originalRewardAmount(), REWARD_AMOUNT);
        // Escrow holds no tokens yet: stored state 1, balance short -> view returns 0.
        assertEq(escrow.funded(), 0);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function testConstructorZeroToken() public {
        vm.expectRevert(EscrowERC20Delayed.ZeroAddress.selector);
        new EscrowERC20Delayed(address(0), recipient, EXPECTED_AMOUNT, REWARD_AMOUNT);
    }

    function testConstructorZeroRecipient() public {
        vm.expectRevert(EscrowERC20Delayed.ZeroAddress.selector);
        new EscrowERC20Delayed(address(token), address(0), EXPECTED_AMOUNT, REWARD_AMOUNT);
    }

    function testConstructorZeroAmounts() public {
        vm.expectRevert(EscrowERC20Delayed.ZeroAmount.selector);
        new EscrowERC20Delayed(address(token), recipient, 0, REWARD_AMOUNT);
        vm.expectRevert(EscrowERC20Delayed.ZeroRewardAmount.selector);
        new EscrowERC20Delayed(address(token), recipient, EXPECTED_AMOUNT, 0);
    }

    function testFundedViewUpgradesWithBalance() public {
        assertEq(escrow.funded(), 0);

        vm.prank(deployer);
        token.transfer(address(escrow), FUND_REQUIRED - 1);
        assertEq(escrow.funded(), 0, "short balance stays 0");

        vm.prank(deployer);
        token.transfer(address(escrow), 1);
        assertEq(escrow.funded(), 2, "exact balance flips to 2");
    }

    function testBondRevertsBeforeTransfer() public {
        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT);
        vm.expectRevert(EscrowERC20Delayed.NotFunded.selector);
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();
    }

    function testBondRevertsOnShortBalance() public {
        vm.prank(deployer);
        token.transfer(address(escrow), FUND_REQUIRED - 1);

        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT);
        vm.expectRevert(EscrowERC20Delayed.NotFunded.selector);
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();
    }

    function testBondUpgradesStateAndSucceeds() public {
        vm.prank(deployer);
        token.transfer(address(escrow), FUND_REQUIRED);

        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT);
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();

        assertEq(escrow.bondedExecutor(), executor);
        assertEq(escrow.bondAmount(), BOND_AMOUNT);
        assertEq(escrow.executionDeadline(), block.timestamp + 5 minutes);
        assertTrue(escrow.is_bonded());
        assertEq(escrow.funded(), 2);
    }

    function testBondInsufficientAmount() public {
        vm.prank(deployer);
        token.transfer(address(escrow), FUND_REQUIRED);

        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT);
        vm.expectRevert(EscrowERC20Delayed.InsufficientBond.selector);
        escrow.bond(BOND_AMOUNT - 1);
        vm.stopPrank();
    }

    function testBondCancellationRequested() public {
        vm.prank(deployer);
        token.transfer(address(escrow), FUND_REQUIRED);

        vm.prank(deployer);
        escrow.requestCancellation();

        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT);
        vm.expectRevert(EscrowERC20Delayed.CancellationRequested.selector);
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();
    }

    function testDoubleBondingPrevented() public {
        _fundAndBond();

        vm.startPrank(other);
        token.approve(address(escrow), BOND_AMOUNT);
        vm.expectRevert(EscrowERC20Delayed.ExecutorAlreadyBonded.selector);
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();
    }

    function testBondAfterDeadlinePassed() public {
        _fundAndBond();

        vm.warp(block.timestamp + 6 minutes);

        // Expired bond folds BOND_AMOUNT into currentRewardAmount; new floor is updated/2.
        uint256 newReward = REWARD_AMOUNT + BOND_AMOUNT;
        uint256 newBondFloor = newReward / 2;

        vm.startPrank(other);
        token.approve(address(escrow), newBondFloor);
        escrow.bond(newBondFloor);
        vm.stopPrank();

        assertEq(escrow.bondedExecutor(), other);
        assertEq(escrow.currentRewardAmount(), newReward);
        assertEq(escrow.bondAmount(), newBondFloor);
    }

    function testRequestCancellationOnlyDeployer() public {
        vm.prank(executor);
        vm.expectRevert(EscrowERC20Delayed.OnlyDeployer.selector);
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

    function testCollectNotFundedWhenDelayedShort() public {
        EscrowERC20Delayed.ReceiptProof memory dummy = EscrowERC20Delayed.ReceiptProof({
            blockHeader: hex"", receiptRlp: hex"", proofNodes: hex"", receiptPath: hex"", logIndex: 0
        });
        vm.prank(executor);
        vm.expectRevert(EscrowERC20Delayed.NotFunded.selector);
        escrow.collect(dummy, block.number - 1);
    }

    function testCollectNotBondedExecutor() public {
        _fundAndBond();

        EscrowERC20Delayed.ReceiptProof memory dummy = EscrowERC20Delayed.ReceiptProof({
            blockHeader: hex"", receiptRlp: hex"", proofNodes: hex"", receiptPath: hex"", logIndex: 0
        });
        vm.prank(other);
        vm.expectRevert(EscrowERC20Delayed.OnlyBondedExecutor.selector);
        escrow.collect(dummy, block.number - 1);
    }

    function testCancelAndWithdrawSweepsBalance() public {
        vm.prank(deployer);
        token.transfer(address(escrow), FUND_REQUIRED / 2);

        uint256 before = token.balanceOf(deployer);

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(token.balanceOf(deployer), before + FUND_REQUIRED / 2);
        // Stored state is 0 and cancellationRequest cleared so the escrow can be reinit-ed.
        assertEq(escrow.funded(), 0);
        assertFalse(escrow.cancellationRequest());
    }

    function testCancelAndWithdrawOnlyDeployer() public {
        vm.prank(executor);
        vm.expectRevert(EscrowERC20Delayed.OnlyDeployer.selector);
        escrow.cancelAndWithdraw();
    }

    function testCancelAndWithdrawRevertsIfNotFunded() public {
        // First drain
        vm.prank(deployer);
        token.transfer(address(escrow), 1);
        vm.prank(deployer);
        escrow.cancelAndWithdraw();
        // Now stored state is 0; cancelAndWithdraw reverts NotFunded.
        vm.prank(deployer);
        vm.expectRevert(EscrowERC20Delayed.NotFunded.selector);
        escrow.cancelAndWithdraw();
    }

    function testCancelAndWithdrawRevertsIfEmpty() public {
        // Stored state is 1 but balance is 0 -> NoWithdrawableFunds.
        vm.prank(deployer);
        vm.expectRevert(EscrowERC20Delayed.NoWithdrawableFunds.selector);
        escrow.cancelAndWithdraw();
    }

    function testCancelAndWithdrawRevertsWhileBondActive() public {
        _fundAndBond();

        vm.prank(deployer);
        vm.expectRevert(EscrowERC20Delayed.BondActive.selector);
        escrow.cancelAndWithdraw();
    }

    function testReinitAfterCancel() public {
        // Arm -> partially fund -> cancel (drains) -> reinit -> new args active.
        vm.prank(deployer);
        token.transfer(address(escrow), 1);
        vm.prank(deployer);
        escrow.cancelAndWithdraw();
        assertEq(escrow.funded(), 0);

        address newRecipient = makeAddr("newRecipient");
        vm.prank(deployer);
        escrow.reinit(newRecipient, EXPECTED_AMOUNT * 2, REWARD_AMOUNT * 2);

        assertEq(escrow.expectedRecipient(), newRecipient);
        assertEq(escrow.expectedAmount(), EXPECTED_AMOUNT * 2);
        assertEq(escrow.currentRewardAmount(), REWARD_AMOUNT * 2);
        assertEq(escrow.originalRewardAmount(), REWARD_AMOUNT * 2);
        assertEq(escrow.funded(), 0); // stored state 1, no balance
    }

    function testReinitFromUnfundedDelayedState() public {
        // State 1 with insufficient balance is now permitted: the deployer
        // re-arms a slot that the previous user abandoned without funding.
        address newRecipient = makeAddr("newRecipient");
        vm.prank(deployer);
        escrow.reinit(newRecipient, EXPECTED_AMOUNT * 2, REWARD_AMOUNT * 2);

        assertEq(escrow.expectedRecipient(), newRecipient);
        assertEq(escrow.expectedAmount(), EXPECTED_AMOUNT * 2);
        assertEq(escrow.currentRewardAmount(), REWARD_AMOUNT * 2);
    }

    function testReinitRevertsWhenFullyFunded() public {
        // State 2 (fully funded, ready to bond) blocks reinit — the deployer
        // must let it close out via collect or cancelAndWithdraw first.
        vm.prank(deployer);
        token.transfer(address(escrow), FUND_REQUIRED);
        // Cause stored state to flip to 2 by triggering an upgrade (bond
        // performs the upgrade inline; here we force it via the same path).
        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT);
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();

        // Bond is active so we'd hit BondActive first; warp past the deadline
        // so the next reinit attempt sees state == 2 with no live bond.
        vm.warp(block.timestamp + 6 minutes);

        vm.prank(deployer);
        vm.expectRevert(EscrowERC20Delayed.AlreadyArmed.selector);
        escrow.reinit(recipient, EXPECTED_AMOUNT, REWARD_AMOUNT);
    }

    function testReinitOnlyDeployer() public {
        // First tear down to state 0.
        vm.prank(deployer);
        token.transfer(address(escrow), 1);
        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        vm.prank(executor);
        vm.expectRevert(EscrowERC20Delayed.OnlyDeployer.selector);
        escrow.reinit(recipient, EXPECTED_AMOUNT, REWARD_AMOUNT);
    }

    function testReinitRetainsPartialBalance() public {
        // Tear down to state 0 without draining (impossible with cancelAndWithdraw,
        // which always sweeps). Instead simulate the collect path: fund+bond and
        // let the deadline expire, then the escrow sits with the original balance
        // plus bond, fundedState stays 2. To land in state 0 with a balance,
        // exercise the full happy collect path (out of scope for this unit) OR
        // demonstrate the intent via direct storage manipulation.
        //
        // For now we verify the documented behavior: reinit does NOT touch
        // balanceOf. Balance persists into the new signal's funded view.
        vm.prank(deployer);
        token.transfer(address(escrow), 1);
        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        // Balance is now 0 (cancelAndWithdraw swept). Seed a new balance from
        // someone else to simulate "leftover tokens at this address."
        vm.prank(other);
        token.transfer(address(escrow), FUND_REQUIRED);

        // Reinit with args whose required == leftover. Funded view should flip
        // to 2 without any further transfer.
        vm.prank(deployer);
        escrow.reinit(recipient, EXPECTED_AMOUNT, REWARD_AMOUNT);
        assertEq(escrow.funded(), 2, "leftover balance satisfies new arming");
    }

    function _fundAndBond() internal {
        vm.prank(deployer);
        token.transfer(address(escrow), FUND_REQUIRED);

        vm.startPrank(executor);
        token.approve(address(escrow), BOND_AMOUNT);
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();
    }
}
