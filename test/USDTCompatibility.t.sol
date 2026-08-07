// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EscrowERC20} from "../src/EscrowERC20.sol";
import {EscrowBatch} from "../src/EscrowBatch.sol";
import {BatchBondAuth} from "./helpers/BatchBondAuth.sol";

/// @dev Models mainnet USDT's transfer API: successful calls return no data.
contract NoReturnERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 currentAllowance = allowance[from][msg.sender];
        require(currentAllowance >= amount, "Insufficient allowance");
        allowance[from][msg.sender] = currentAllowance - amount;
        _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "Insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

contract FalseReturnERC20 {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

contract USDTCompatibilityTest is Test {
    NoReturnERC20 private token;
    address private deployer;
    address private bidder;
    address private recipient;
    address private blindedSigner;

    uint256 private constant PAYMENT_AMOUNT = 100e6;
    uint256 private constant REWARD_AMOUNT = 10e6;
    uint256 private constant BATCH_SIGNER_KEY = 8_008;

    function setUp() public {
        token = new NoReturnERC20();
        deployer = makeAddr("deployer");
        bidder = makeAddr("bidder");
        recipient = makeAddr("recipient");
        blindedSigner = makeAddr("blindedSigner");

        token.mint(deployer, 1_000e6);
    }

    function testERC20FundingAndWithdrawalAcceptNoReturnData() public {
        uint256 escrowAmount = PAYMENT_AMOUNT + REWARD_AMOUNT;

        vm.startPrank(deployer);
        address futureEscrow = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        token.approve(futureEscrow, escrowAmount);
        EscrowERC20 escrow = new EscrowERC20(address(token), recipient, PAYMENT_AMOUNT, blindedSigner, REWARD_AMOUNT);
        vm.stopPrank();

        assertTrue(escrow.funded());
        assertEq(token.balanceOf(address(escrow)), escrowAmount);

        uint256 deployerBalanceBefore = token.balanceOf(deployer);
        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertFalse(escrow.funded());
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(token.balanceOf(deployer), deployerBalanceBefore + escrowAmount);
    }

    function testERC20FundingRejectsFalseReturnData() public {
        FalseReturnERC20 falseReturnToken = new FalseReturnERC20();

        vm.startPrank(deployer);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(falseReturnToken)));
        new EscrowERC20(address(falseReturnToken), recipient, PAYMENT_AMOUNT, blindedSigner, REWARD_AMOUNT);
        vm.stopPrank();
    }

    function testBatchFundingBidAndWithdrawalAcceptNoReturnData() public {
        EscrowBatch.BatchTransfer[] memory transfers = new EscrowBatch.BatchTransfer[](1);
        transfers[0] = EscrowBatch.BatchTransfer({
            asset: address(token), recipient: recipient, amount: PAYMENT_AMOUNT, valueWeight: PAYMENT_AMOUNT
        });

        uint256 escrowAmount = PAYMENT_AMOUNT + REWARD_AMOUNT;
        vm.startPrank(deployer);
        address futureEscrow = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        token.approve(futureEscrow, escrowAmount);
        address[] memory signers = new address[](1);
        signers[0] = vm.addr(BATCH_SIGNER_KEY);
        EscrowBatch escrow = new EscrowBatch(address(token), transfers, REWARD_AMOUNT, signers);
        vm.stopPrank();

        assertTrue(escrow.funded());
        assertEq(token.balanceOf(address(escrow)), escrowAmount);

        uint256[] memory indexes = new uint256[](1);
        indexes[0] = 0;
        bytes memory signature = BatchBondAuth.sign(vm, BATCH_SIGNER_KEY, address(escrow), bidder, indexes);
        vm.prank(bidder);
        escrow.bid(indexes, 0, signature);

        assertEq(token.balanceOf(address(escrow)), escrowAmount);

        vm.warp(block.timestamp + escrow.BID_DURATION() + 1);
        uint256 deployerBalanceBefore = token.balanceOf(deployer);
        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertFalse(escrow.funded());
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(token.balanceOf(deployer), deployerBalanceBefore + escrowAmount);
    }
}
