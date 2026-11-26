// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {EscrowERC20} from "../src/EscrowERC20.sol";
import {EscrowBatchZK} from "../src/EscrowBatchZK.sol";
import {ReceiveAuthorization} from "../src/utils/ReceiveAuthorization.sol";
import {USDC3009Mock} from "./helpers/USDC3009Mock.sol";

contract ReceiveAuthorizationTest is Test {
    uint256 constant KEY = 0xA11CE;
    uint256 constant AMOUNT = 11_000_000;
    uint256 constant REWARD = 1_000_000;
    bytes32 constant NONCE = keccak256("funding authorization");
    bytes32 constant DOMAIN = keccak256("escrow domain");
    bytes32 constant REQUEST = keccak256("escrow request");
    bytes32 constant COMMITMENT = keccak256("single row");
    address constant SIGNER = address(0xB0B);

    USDC3009Mock token;
    address owner;

    function setUp() public {
        vm.warp(100);
        owner = vm.addr(KEY);
        token = new USDC3009Mock();
        token.mint(owner, AMOUNT + REWARD);
        vm.deal(owner, 1 ether);
    }

    function predict() internal view returns (address) {
        return vm.computeCreateAddress(owner, vm.getNonce(owner));
    }

    function authorization(address payee, uint256 value)
        internal
        view
        returns (ReceiveAuthorization.Authorization memory a)
    {
        a.token = address(token);
        a.validAfter = block.timestamp - 1;
        a.validBefore = block.timestamp + 300;
        a.nonce = NONCE;
        bytes32 structHash = keccak256(
            abi.encode(
                token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), owner, payee, value, a.validAfter, a.validBefore, a.nonce
            )
        );
        (a.v, a.r, a.s) = vm.sign(KEY, keccak256(abi.encodePacked(hex"1901", token.DOMAIN_SEPARATOR(), structHash)));
    }

    function singleCode(uint256 reward, bytes memory trailer) internal view returns (bytes memory) {
        return bytes.concat(
            vm.getCode("EscrowERC203009.sol:EscrowERC203009"),
            abi.encode(address(token), AMOUNT, COMMITMENT, DOMAIN, REQUEST, SIGNER, reward, 0),
            trailer
        );
    }

    function batchCode(EscrowBatchZK.Row[] memory rows, address rewardAsset, uint256 reward, bytes memory trailer)
        internal
        view
        returns (bytes memory)
    {
        address[] memory signers = new address[](1);
        signers[0] = SIGNER;
        return bytes.concat(
            vm.getCode("EscrowBatchZK3009.sol:EscrowBatchZK3009"),
            abi.encode(rewardAsset, rows, reward, 0, signers, DOMAIN, REQUEST),
            trailer
        );
    }

    function deploy(bytes memory code, uint256 value) internal returns (address deployed) {
        vm.prank(owner);
        assembly ("memory-safe") {
            deployed := create(value, add(code, 32), mload(code))
        }
    }

    function testSinglePullsExactSignedAmountWithNoAllowance() public {
        address expected = predict();
        bytes memory code = singleCode(REWARD, abi.encode(authorization(expected, AMOUNT + REWARD)));
        assertEq(deploy(code, 0), expected);
        assertEq(token.balanceOf(expected), AMOUNT + REWARD);
        assertEq(token.balanceOf(owner), 0);
        assertEq(token.allowance(owner, expected), 0);
        assertTrue(token.authorizationState(owner, NONCE));
        EscrowERC20 escrow = EscrowERC20(expected);
        assertTrue(escrow.funded());
        assertEq(escrow.deployerAddress(), owner);
        assertEq(escrow.currentRewardAmount(), REWARD);
        assertGt(escrow.paymentDeadline(), 0);
    }

    function testSingleRequiresCorrectPayeeValueValidityAndToken() public {
        address expected = predict();
        bytes memory noWitness = singleCode(REWARD, "");
        assertEq(deploy(noWitness, 0), address(0));
        // An unsuccessful CREATE consumes its nonce just as a mined failed deployment does.
        expected = predict();
        assertEq(deploy(singleCode(REWARD, abi.encode(authorization(expected, AMOUNT))), 0), address(0));
        assertEq(deploy(singleCode(REWARD, abi.encode(authorization(address(0xDEAD), AMOUNT + REWARD))), 0), address(0));
        ReceiveAuthorization.Authorization memory auth = authorization(predict(), AMOUNT + REWARD);
        vm.warp(auth.validBefore);
        assertEq(deploy(singleCode(REWARD, abi.encode(auth)), 0), address(0));
        auth = authorization(predict(), AMOUNT + REWARD);
        auth.token = address(0xBAD);
        assertEq(deploy(singleCode(REWARD, abi.encode(auth)), 0), address(0));
        assertFalse(token.authorizationState(owner, NONCE));
        assertEq(token.balanceOf(owner), AMOUNT + REWARD);
    }

    function testBatchMixesMultipleUsdcRowsNativeAndApprovedToken() public {
        USDC3009Mock other = new USDC3009Mock();
        other.mint(owner, 5);
        EscrowBatchZK.Row[] memory rows = new EscrowBatchZK.Row[](4);
        rows[0] = EscrowBatchZK.Row(address(token), AMOUNT - 1, 2, keccak256("first"));
        rows[1] = EscrowBatchZK.Row(address(0), 123, 3, keccak256("second"));
        rows[2] = EscrowBatchZK.Row(address(other), 5, 4, keccak256("third"));
        rows[3] = EscrowBatchZK.Row(address(token), 1, 1, keccak256("fourth"));
        address expected = predict();
        vm.prank(owner);
        other.approve(expected, 5);
        bytes memory code =
            batchCode(rows, address(token), REWARD, abi.encode(authorization(expected, AMOUNT + REWARD)));
        assertEq(deploy(code, 123), expected);
        EscrowBatchZK escrow = EscrowBatchZK(expected);
        assertTrue(escrow.funded());
        assertEq(escrow.deployerAddress(), owner);
        assertEq(escrow.currentAssetPaymentAmount(address(token)), AMOUNT);
        assertEq(token.balanceOf(expected), AMOUNT + REWARD);
        assertEq(other.balanceOf(expected), 5);
        assertEq(expected.balance, 123);
        assertTrue(token.authorizationState(owner, NONCE));
        assertEq(token.allowance(owner, expected), 0);
        assertEq(other.allowance(owner, expected), 0);
    }

    function testBatchUsesAuthorizationForRewardOnlyToken() public {
        EscrowBatchZK.Row[] memory rows = new EscrowBatchZK.Row[](1);
        rows[0] = EscrowBatchZK.Row(address(0), 7, 1, COMMITMENT);
        address expected = predict();
        bytes memory code = batchCode(rows, address(token), REWARD, abi.encode(authorization(expected, REWARD)));
        assertEq(deploy(code, 7), expected);
        assertEq(token.balanceOf(expected), REWARD);
    }

    function testBatchRejectsUnusedAuthorizationAndRollsBackOnAllowanceFailure() public {
        EscrowBatchZK.Row[] memory rows = new EscrowBatchZK.Row[](1);
        rows[0] = EscrowBatchZK.Row(address(0), 7, 1, COMMITMENT);
        bytes memory unused = abi.encode(authorization(predict(), AMOUNT + REWARD));
        assertEq(deploy(batchCode(rows, address(0), REWARD, unused), 7 + REWARD), address(0));
        USDC3009Mock other = new USDC3009Mock();
        rows = new EscrowBatchZK.Row[](2);
        rows[0] = EscrowBatchZK.Row(address(token), AMOUNT, 1, COMMITMENT);
        rows[1] = EscrowBatchZK.Row(address(other), 5, 1, keccak256("other"));
        bytes memory code =
            batchCode(rows, address(token), REWARD, abi.encode(authorization(predict(), AMOUNT + REWARD)));
        assertEq(deploy(code, 0), address(0));
        assertFalse(token.authorizationState(owner, NONCE));
        assertEq(token.balanceOf(owner), AMOUNT + REWARD);
    }

    function testSimulationCanDeployWithoutRewardAndFundWithAllowance() public {
        address deployed = deploy(singleCode(0, ""), 0);
        EscrowERC20 escrow = EscrowERC20(deployed);
        assertFalse(escrow.funded());
        vm.startPrank(owner);
        token.approve(deployed, AMOUNT + REWARD);
        escrow.fund(REWARD);
        vm.stopPrank();
        assertTrue(escrow.funded());
        assertFalse(token.authorizationState(owner, NONCE));
    }
}
