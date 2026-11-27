// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {EscrowNativeZK} from "../src/EscrowNativeZK.sol";
import {RequestWindow} from "../src/RequestWindow.sol";
import {BondAuth} from "./helpers/BondAuth.sol";

contract RequestWindowTest is Test {
    uint256 private constant SIGNER_KEY = 123;
    EscrowNativeZK private escrow;
    address private collector;

    function setUp() public {
        vm.warp(1_000);
        vm.roll(100);
        vm.deal(address(this), 10 ether);
        collector = makeAddr("collector");
        escrow = _deploy(1 ether);
    }

    receive() external payable {}

    function _deploy(uint256 reward) private returns (EscrowNativeZK) {
        return new EscrowNativeZK{value: reward == 0 ? 0 : reward + 1 ether}(
            1 ether, bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3)), vm.addr(SIGNER_KEY), reward, 0
        );
    }

    function _bond(address bidder) private {
        bytes memory signature = BondAuth.sign(vm, SIGNER_KEY, address(escrow), bidder);
        vm.prank(bidder);
        escrow.bond(0, signature);
    }

    function testFundingAnchorsBothClocksExactlyOnce() public view {
        assertEq(escrow.requestStartedAt(), 1_000);
        assertEq(escrow.paymentDeadline(), 1_900);
        assertEq(escrow.collectionDeadline(), 2_800);
        assertEq(escrow.paymentBlockDeadline(), 175);
        assertEq(escrow.collectionBlockDeadline(), 250);
    }

    function testFundingUsesTheReservedStorageNamespace() public view {
        bytes32 slot = bytes32(uint256(0x014ac5509487808893ddf697b19b08bdb0));
        uint256 domainPrefix = uint128(bytes16(keccak256("mirage.escrow.request-window.v1")));
        assertEq(slot, bytes32(((uint256(1) << 128) | domainPrefix) & ~uint256(7)));
        assertEq(vm.load(address(escrow), slot), bytes32(uint256(1_000)));
        assertEq(vm.load(address(escrow), bytes32(uint256(slot) + 1)), bytes32(uint256(1_900)));
        assertEq(vm.load(address(escrow), bytes32(uint256(slot) + 2)), bytes32(uint256(2_800)));
        assertEq(vm.load(address(escrow), bytes32(uint256(slot) + 3)), bytes32(uint256(175)));
        assertEq(vm.load(address(escrow), bytes32(uint256(slot) + 4)), bytes32(uint256(250)));
    }

    function testUnfundedDeploymentDoesNotStartTheClock() public {
        EscrowNativeZK unfunded = _deploy(0);
        assertEq(unfunded.requestStartedAt(), 0);
        vm.warp(2_000);
        vm.roll(200);
        unfunded.fund{value: 2 ether}(1 ether);
        assertEq(unfunded.requestStartedAt(), 2_000);
        assertEq(unfunded.paymentDeadline(), 2_900);
        assertEq(unfunded.collectionDeadline(), 3_800);
        assertEq(unfunded.paymentBlockDeadline(), 275);
        assertEq(unfunded.paymentStartBlock(), 100);
    }

    function testLateBondAndResumeCannotExtendTheClock() public {
        vm.warp(1_800);
        vm.roll(150);
        escrow.requestCancellation();
        escrow.resume();
        _bond(collector);
        assertEq(escrow.executionDeadline(), 175);
        assertEq(escrow.bondStartBlock(), 150);
        assertEq(escrow.paymentStartBlock(), 100);
        assertEq(escrow.paymentDeadline(), 1_900);
        assertEq(escrow.collectionDeadline(), 2_800);
    }

    function testTimestampCutoffStopsNewBonds() public {
        vm.warp(1_900);
        bytes memory signature = BondAuth.sign(vm, SIGNER_KEY, address(escrow), collector);
        vm.prank(collector);
        vm.expectRevert(RequestWindow.PaymentWindowClosed.selector);
        escrow.bond(0, signature);
        assertEq(escrow.bondAttempt(), 0);
    }

    function testBlockCutoffStopsNewBondsOnAFastChain() public {
        vm.roll(176);
        bytes memory signature = BondAuth.sign(vm, SIGNER_KEY, address(escrow), collector);
        vm.prank(collector);
        vm.expectRevert(RequestWindow.PaymentWindowClosed.selector);
        escrow.bond(0, signature);
    }

    function testPaymentExpiryPreservesTheOriginalClaim() public {
        _bond(collector);
        vm.warp(2_000);
        vm.roll(176);
        assertTrue(escrow.is_bonded());
        assertEq(escrow.bondedExecutor(), collector);
        vm.expectRevert(RequestWindow.RedemptionWindowActive.selector);
        escrow.cancelAndWithdraw();
        bytes memory signature = BondAuth.sign(vm, SIGNER_KEY, address(escrow), makeAddr("another"));
        vm.prank(makeAddr("another"));
        vm.expectRevert(RequestWindow.PaymentWindowClosed.selector);
        escrow.bond(0, signature);
        assertEq(escrow.bondedExecutor(), collector);
    }

    function testFastBlocksCannotMakeRefundsEarly() public {
        vm.roll(251);
        vm.warp(2_799);
        vm.expectRevert(RequestWindow.RedemptionWindowActive.selector);
        escrow.cancelAndWithdraw();
    }

    function testRefundAtThirtyMinutesDoesNotRestartTheRequest() public {
        _bond(collector);
        vm.warp(2_800);
        uint256 before = address(this).balance;
        escrow.cancelAndWithdraw();
        assertEq(address(this).balance, before + 2 ether);
        assertFalse(escrow.funded());
        assertFalse(escrow.is_bonded());
        vm.expectRevert(RequestWindow.RequestAlreadyStarted.selector);
        escrow.fund{value: 2 ether}(1 ether);
        assertEq(escrow.collectionDeadline(), 2_800);
    }
}
