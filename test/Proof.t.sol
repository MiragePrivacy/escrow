// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Escrow} from "../src/Escrow.sol";

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

contract EscrowMPTTest is Test {
    Escrow public escrow;
    MockERC20 public token;

    address public deployer;
    address public recipient;
    uint256 constant TRANSFER_AMOUNT = 1000e18;

    uint256 constant REWARD_AMOUNT = 500e18;
    uint256 constant PAYMENT_AMOUNT = 500e18;
    uint256 constant BOND_AMOUNT = 250e18;

    uint256 constant TARGET_BLOCK_NUMBER = 396;
    bytes32 constant TARGET_BLOCK_HASH = 0xa415edcdb485c895fd657fa676f8fab30d7816db2f33616ca2d9ebc1d165331d;

    function setUp() public {
        deployer = makeAddr("deployer");
        recipient = makeAddr("recipient");

        vm.startPrank(deployer);
        token = new MockERC20();
        escrow = new Escrow(address(token), recipient, TRANSFER_AMOUNT);
        vm.stopPrank();

        token.mint(deployer, 10000e18);
    }

    function testCollectWithTransferProof() public {
        _fundContract();

        address proofExecutor = address(0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc);

        token.mint(proofExecutor, 10000e18);

        vm.startPrank(proofExecutor);
        token.approve(address(escrow), BOND_AMOUNT);
        escrow.bond(BOND_AMOUNT);
        vm.stopPrank();

        vm.roll(TARGET_BLOCK_NUMBER + 10);
        vm.setBlockhash(TARGET_BLOCK_NUMBER, TARGET_BLOCK_HASH);

        Escrow.ReceiptProof memory proof = Escrow.ReceiptProof({
            blockHeader: hex"f9025fa03875cee4987d42e40d314f0b55bc3845e8915586a67997e282af360adbbe6240a01dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347940000000000000000000000000000000000000000a0e2eb61a64d9d3e15184bf121909c534d6b37701ede0b22cdd1fef0bfdfc8a5dea001969f20078b85955a382afed7a5524190ec2d5e3f00a05a318c09a0baf6ca2ca0a40f43df7bc1c5f565ed43da9ea26d1084182aab7286c6a8c3eb93b534ad9b96b90100000000040000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000080000000000000000000080000000000000000000000000400000000000020000001000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000000000000000000428000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000008082018c8401c9c3808286a38468a4c8be80a09d5935e0b32dcd57e3263edb528977f7f0494cea452b6878a3d57b9f0ac73d3a88000000000000000008a056e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b4218080a00000000000000000000000000000000000000000000000000000000000000000a0e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            receiptRlp: hex"02f901a6018286a3b9010000000004000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000008000000000000000000000000040000000000002000000100000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000042800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000f89df89b945fbdb2315678afecb367f032d93f642f64180aa3f863a0ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3efa00000000000000000000000009965507D1a55bcC2695C58ba16FB37d819B0A4dca0000000000000000000000000deadbeefdeadbeefdeadbeefdeadbeefdeadbeefa0000000000000000000000000000000000000000000000000000000003f89de80",
            proofNodes: hex"f901b0822080b901aa02f901a6018286a3b9010000000004000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000008000000000000000000000000040000000000002000000100000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000042800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000f89df89b945fbdb2315678afecb367f032d93f642f64180aa3f863a0ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3efa00000000000000000000000009965507D1a55bcC2695C58ba16FB37d819B0A4dca0000000000000000000000000deadbeefdeadbeefdeadbeefdeadbeefdeadbeefa0000000000000000000000000000000000000000000000000000000003f89de80",
            receiptPath: hex"80",
            logIndex: 0
        });

        vm.prank(proofExecutor);
        vm.expectRevert("Wrong token contract");
        escrow.collect(proof, TARGET_BLOCK_NUMBER, proofExecutor);
    }

    function _fundContract() internal {
        vm.startPrank(deployer);
        token.approve(address(escrow), REWARD_AMOUNT + PAYMENT_AMOUNT);
        escrow.fund(REWARD_AMOUNT, PAYMENT_AMOUNT);
        vm.stopPrank();
    }
}
