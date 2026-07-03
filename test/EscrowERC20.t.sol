// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {EscrowERC20} from "../src/EscrowERC20.sol";
import {EscrowBase} from "../src/EscrowBase.sol";
import {BondAuth} from "./helpers/BondAuth.sol";

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

    // The "enclave" whose blinded key gates bonding. blindedSigner = enclave.addr.
    Vm.Wallet enclave;

    uint256 constant EXPECTED_AMOUNT = 1000e18;
    uint256 constant REWARD_AMOUNT = 500e18;
    uint256 constant PAYMENT_AMOUNT = 500e18;
    uint256 constant BOND_POT = 0.25 ether;

    function setUp() public {
        deployer = makeAddr("deployer");
        executor = makeAddr("executor");
        recipient = makeAddr("recipient");
        other = makeAddr("other");
        enclave = vm.createWallet("enclave");

        vm.deal(deployer, 100 ether);

        vm.startPrank(deployer);
        token = new MockERC20();
        token.mint(deployer, 10000e18);

        address futureEscrow = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        token.approve(futureEscrow, REWARD_AMOUNT + PAYMENT_AMOUNT);

        escrow = new EscrowERC20{value: BOND_POT}(
            address(token), recipient, EXPECTED_AMOUNT, enclave.addr, REWARD_AMOUNT, PAYMENT_AMOUNT
        );
        vm.stopPrank();
    }

    // Deploys an unfunded escrow (constructor defers fund()).
    function _newUnfunded() internal returns (EscrowERC20) {
        vm.prank(deployer);
        return new EscrowERC20(address(token), recipient, EXPECTED_AMOUNT, enclave.addr, 0, 0);
    }

    // Signs a valid BondAuth for `bondingExecutor` against `escrowAddr`.
    function _sig(address escrowAddr, address bondingExecutor) internal view returns (bytes memory) {
        return BondAuth.sign(vm, enclave.privateKey, escrowAddr, bondingExecutor);
    }

    function _bondExecutor() internal {
        vm.prank(executor);
        escrow.bond(_sig(address(escrow), executor));
    }

    function testConstructor() public view {
        assertEq(escrow.currentRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow.currentPaymentAmount(), PAYMENT_AMOUNT);
        assertEq(escrow.funded(), true);
        assertEq(escrow.expectedRecipient(), recipient);
        assertEq(escrow.expectedAmount(), EXPECTED_AMOUNT);
        assertEq(escrow.blindedSigner(), enclave.addr);
        assertEq(escrow.bondPot(), BOND_POT);
        assertEq(address(escrow).balance, BOND_POT);
        assertEq(token.balanceOf(address(escrow)), REWARD_AMOUNT + PAYMENT_AMOUNT);
    }

    function testFund() public {
        vm.startPrank(deployer);

        address futureEscrow2 = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        token.approve(futureEscrow2, REWARD_AMOUNT + PAYMENT_AMOUNT);

        EscrowERC20 escrow2 = new EscrowERC20(address(token), recipient, EXPECTED_AMOUNT, enclave.addr, 0, 0);

        token.approve(address(escrow2), REWARD_AMOUNT + PAYMENT_AMOUNT);
        escrow2.fund{value: BOND_POT}(REWARD_AMOUNT, PAYMENT_AMOUNT);
        vm.stopPrank();

        assertEq(escrow2.currentRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow2.originalRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow2.currentPaymentAmount(), PAYMENT_AMOUNT);
        assertEq(escrow2.funded(), true);
        assertEq(escrow2.bondPot(), BOND_POT);
        assertEq(token.balanceOf(address(escrow2)), REWARD_AMOUNT + PAYMENT_AMOUNT);
        assertEq(address(escrow2).balance, BOND_POT);
    }

    function testFundZeroReward() public {
        EscrowERC20 unfunded = _newUnfunded();
        vm.startPrank(deployer);
        token.approve(address(unfunded), PAYMENT_AMOUNT);
        vm.expectRevert(EscrowERC20.ZeroRewardAmount.selector);
        unfunded.fund{value: BOND_POT}(0, PAYMENT_AMOUNT);
        vm.stopPrank();
    }

    function testFundZeroBond() public {
        EscrowERC20 unfunded = _newUnfunded();
        vm.startPrank(deployer);
        token.approve(address(unfunded), REWARD_AMOUNT + PAYMENT_AMOUNT);
        vm.expectRevert(EscrowERC20.ZeroBondAmount.selector);
        unfunded.fund{value: 0}(REWARD_AMOUNT, PAYMENT_AMOUNT);
        vm.stopPrank();
    }

    function testFundOnlyDeployer() public {
        vm.deal(executor, 1 ether);
        vm.startPrank(executor);
        token.approve(address(escrow), REWARD_AMOUNT + PAYMENT_AMOUNT);
        vm.expectRevert(EscrowBase.OnlyDeployer.selector);
        escrow.fund{value: BOND_POT}(REWARD_AMOUNT, PAYMENT_AMOUNT);
        vm.stopPrank();
    }

    function testFundAlreadyFunded() public {
        vm.startPrank(deployer);
        token.approve(address(escrow), REWARD_AMOUNT + PAYMENT_AMOUNT);
        vm.expectRevert(EscrowERC20.AlreadyFunded.selector);
        escrow.fund{value: BOND_POT}(REWARD_AMOUNT, PAYMENT_AMOUNT);
        vm.stopPrank();
    }

    // Bonding pays the ETH bond pot out to the fresh EOA to bootstrap its gas.
    function testBond() public {
        uint256 executorBefore = executor.balance;

        _bondExecutor();

        assertEq(escrow.bondedExecutor(), executor);
        assertEq(escrow.executionDeadline(), block.timestamp + 5 minutes);
        assertTrue(escrow.is_bonded());
        assertEq(escrow.bondPot(), 0);
        assertEq(address(escrow).balance, 0);
        assertEq(executor.balance, executorBefore + BOND_POT);
    }

    function testBondInvalidSignature() public {
        // Signature from a non-enclave key does not recover to blindedSigner.
        Vm.Wallet memory attacker = vm.createWallet("attacker");
        bytes memory badSig = BondAuth.sign(vm, attacker.privateKey, address(escrow), executor);

        vm.prank(executor);
        vm.expectRevert(EscrowBase.InvalidBondSignature.selector);
        escrow.bond(badSig);
    }

    function testBondSignatureBoundToCaller() public {
        // A signature authorizing `executor` cannot be replayed by `other`.
        bytes memory sigForExecutor = _sig(address(escrow), executor);

        vm.prank(other);
        vm.expectRevert(EscrowBase.InvalidBondSignature.selector);
        escrow.bond(sigForExecutor);
    }

    function testBondNotFunded() public {
        EscrowERC20 unfunded = _newUnfunded();
        vm.prank(executor);
        vm.expectRevert(EscrowBase.NotFunded.selector);
        unfunded.bond(_sig(address(unfunded), executor));
    }

    function testBondCancellationRequested() public {
        vm.prank(deployer);
        escrow.requestCancellation();

        vm.prank(executor);
        vm.expectRevert(EscrowBase.CancellationRequested.selector);
        escrow.bond(_sig(address(escrow), executor));
    }

    // An expired bond frees the lock; a fresh enclave-authorized EOA can bond, but the
    // pot is already spent (one-shot faucet) so no further ETH is paid out.
    function testBondAfterDeadlinePassed() public {
        _bondExecutor();

        vm.warp(block.timestamp + 6 minutes);

        uint256 otherBefore = other.balance;
        vm.prank(other);
        escrow.bond(_sig(address(escrow), other));

        assertEq(escrow.bondedExecutor(), other);
        assertEq(escrow.currentRewardAmount(), REWARD_AMOUNT);
        assertEq(escrow.bondPot(), 0);
        assertEq(other.balance, otherBefore); // pot already drained by first bond
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

    function _dummyProof() internal pure returns (EscrowERC20.ReceiptProof memory) {
        return EscrowERC20.ReceiptProof({
            blockHeader: hex"", receiptRlp: hex"", proofNodes: hex"", receiptPath: hex"", logIndex: 0
        });
    }

    function testCollectRequiresProof() public {
        _bondExecutor();
        vm.prank(executor);
        vm.expectRevert();
        escrow.collect(_dummyProof(), block.number - 1);
    }

    function testCollectNotFunded() public {
        EscrowERC20 unfunded = _newUnfunded();
        vm.prank(executor);
        vm.expectRevert(EscrowBase.NotFunded.selector);
        unfunded.collect(_dummyProof(), block.number - 1);
    }

    function testCollectNotBondedExecutor() public {
        _bondExecutor();
        vm.prank(other);
        vm.expectRevert(EscrowBase.OnlyBondedExecutor.selector);
        escrow.collect(_dummyProof(), block.number - 1);
    }

    function testCollectAfterDeadline() public {
        _bondExecutor();
        vm.warp(block.timestamp + 6 minutes);
        vm.prank(executor);
        vm.expectRevert(EscrowBase.OnlyBondedExecutor.selector);
        escrow.collect(_dummyProof(), block.number - 1);
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
        vm.prank(other);
        vm.expectRevert(EscrowBase.ExecutorAlreadyBonded.selector);
        escrow.bond(_sig(address(escrow), other));
    }

    function testBondAfterFirstExecutorStillActive() public {
        _bondExecutor();

        vm.warp(block.timestamp + 4 minutes);
        assertTrue(escrow.is_bonded());

        vm.prank(other);
        vm.expectRevert(EscrowBase.ExecutorAlreadyBonded.selector);
        escrow.bond(_sig(address(escrow), other));

        assertEq(escrow.bondedExecutor(), executor);
    }

    // Withdraw returns the token reward/payment and the unspent ETH bond pot.
    function testCancelAndWithdraw() public {
        uint256 tokenBefore = token.balanceOf(deployer);
        uint256 ethBefore = deployer.balance;

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertTrue(escrow.cancellationRequest());
        assertFalse(escrow.funded());
        assertEq(escrow.currentPaymentAmount(), 0);
        assertEq(escrow.currentRewardAmount(), 0);
        assertEq(escrow.bondPot(), 0);
        assertEq(token.balanceOf(deployer), tokenBefore + REWARD_AMOUNT + PAYMENT_AMOUNT);
        assertEq(deployer.balance, ethBefore + BOND_POT);
    }

    function testCancelAndWithdrawOnlyDeployer() public {
        vm.prank(executor);
        vm.expectRevert(EscrowBase.OnlyDeployer.selector);
        escrow.cancelAndWithdraw();
    }

    function testCancelAndWithdrawNotFunded() public {
        EscrowERC20 unfunded = _newUnfunded();
        vm.prank(deployer);
        vm.expectRevert(EscrowBase.NotFunded.selector);
        unfunded.cancelAndWithdraw();
    }

    function testCancelAndWithdrawWhileBonded() public {
        _bondExecutor();
        vm.prank(deployer);
        vm.expectRevert(EscrowBase.BondActive.selector);
        escrow.cancelAndWithdraw();
    }

    // After a bond expires, the pot is already spent, so only the token reward is returned.
    function testCancelAndWithdrawAfterBondExpired() public {
        _bondExecutor();
        vm.warp(block.timestamp + 6 minutes);

        uint256 tokenBefore = token.balanceOf(deployer);
        uint256 ethBefore = deployer.balance;

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertTrue(escrow.cancellationRequest());
        assertFalse(escrow.funded());
        assertEq(token.balanceOf(deployer), tokenBefore + REWARD_AMOUNT + PAYMENT_AMOUNT);
        assertEq(deployer.balance, ethBefore); // pot drained at bond()
    }

    function testCancelAndWithdrawPreventsRaceCondition() public {
        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        vm.prank(executor);
        vm.expectRevert(EscrowBase.NotFunded.selector);
        escrow.bond(_sig(address(escrow), executor));
    }

    function testCancelAndWithdrawAlreadyCancelled() public {
        vm.prank(deployer);
        escrow.requestCancellation();

        uint256 tokenBefore = token.balanceOf(deployer);

        vm.prank(deployer);
        escrow.cancelAndWithdraw();

        assertTrue(escrow.cancellationRequest());
        assertFalse(escrow.funded());
        assertEq(token.balanceOf(deployer), tokenBefore + REWARD_AMOUNT + PAYMENT_AMOUNT);
    }
}
