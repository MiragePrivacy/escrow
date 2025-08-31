// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Escrow} from "../src/Escrow.sol";
import {IERC20} from "../src/Escrow.sol";

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
    uint256 constant TRANSFER_AMOUNT = 0x17d7840; // From: logs[0].data
    uint256 constant REWARD_AMOUNT = 500e18;
    uint256 constant PAYMENT_AMOUNT = 500e18;
    uint256 constant BOND_AMOUNT = 250e18;

    uint256 constant TARGET_BLOCK_NUMBER = 9084468; // From: block_number
    bytes32 constant TARGET_BLOCK_HASH = 0x490a3fc0b0c2170b55ca18ce6c73fc1af50ebe0931b525a3510c048f2b428617; // From: block_hash

    function testCollectWithTransferProof() public {
        address proofTokenAddress = address(0xBe41a9EC942d5b52bE07cC7F4D7E30E10e9B652A); // From: logs[0].address
        address proofRecipient = address(0x658D9C76ff358984D6436eA11ee1eda08894C818); // From: logs[0].topics[2] (to address)
        address proofExecutor = address(0xE1A9d9C9abB872dDEF70A4d108Fd8fc3c7cE4dC4); // From: logs[0].topics[1] (from address)

        MockERC20 proofToken = new MockERC20();

        vm.startPrank(deployer);
        Escrow proofEscrow = new Escrow(proofTokenAddress, proofRecipient, TRANSFER_AMOUNT);
        vm.stopPrank();

        console.log("Setup escrow address:", address(escrow));
        console.log("Proof escrow address:", address(proofEscrow));
        console.log("Expected amount in proof escrow:", proofEscrow.expectedAmount());

        vm.mockCall(proofTokenAddress, abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));
        vm.mockCall(proofTokenAddress, abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(true));

        // fund the proof escrow
        _fundProofContract(proofEscrow, proofToken);

        // mint tokens for the executor and bond
        proofToken.mint(proofExecutor, 10000e18);
        vm.startPrank(proofExecutor);
        proofToken.approve(address(proofEscrow), BOND_AMOUNT);
        proofEscrow.bond(BOND_AMOUNT);
        vm.stopPrank();

        vm.roll(TARGET_BLOCK_NUMBER + 10);
        vm.setBlockhash(TARGET_BLOCK_NUMBER, TARGET_BLOCK_HASH);

        Escrow.ReceiptProof memory proof = Escrow.ReceiptProof({
            blockHeader: hex"f90284a038d8a229ef5ed7e4c0ae36034362b7ed00d49d57f1b31e60190befaeca73ff37a01dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347945cc0dde14e7256340cc820415a6022a7d1c93a35a02624c60133f2c08e34990e93b66aaa3a72b135f77cf00c043a35caebf39ae54ba00ca3a794d63539a566e6a5d8cfbbf9c0e603022ae866248e7006710fde83eb12a025996241a33fe6ed92599ff80b2021d5f60993913b9e0552762d03104aa40996b901000224180066041c1200807d10a642c8950918d3200d0230551880a124009a5d50419a900270c0032603ab204001208000d54911110080ac20840900227e2841101224280202206149000c105cc0081020910100c58244804009828403e0828040020e400922215048954cc0d184112c8298ca001044584c1b20544050101c004008c028ca30523c142041038022228c0c514405110000c00b0052904914b46cc04209ba00088100812b005a054068204802b2008882009888a06022b0e02024254a110846880000008447002000d692c832540005a8a4001011800996203969225018901428000820dc121002c0a10042a05910a50208414404c852460012000380838a9e34840393870084011657b98468b0bba099d883010f0b846765746888676f312e32342e32856c696e7578a07e4379dbae3938a4b37b5b2cee386d2d9211adb64f4e3e2639ce9a4a721ea446880000000000000000826d7ba07f589ddc82719228971df748642152411fdd81592b880c2d913aeab7c415c204830a00008405580000a08744f3f453b537272189a1a10202fbfa9fb991fa1f431a5dd96cb6255ea39c58a0e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            receiptRlp: hex"02f901a801840114e0a3b9010000000000000000000000000000000880000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000010000000000000200000000000004000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000001000000000000000000000000000f89df89b94be41a9ec942d5b52be07cc7f4d7e30e10e9b652af863a0ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3efa0000000000000000000000000e1a9d9c9abb872ddef70a4d108fd8fc3c7ce4dc4a0000000000000000000000000658d9c76ff358984d6436ea11ee1eda08894c818a000000000000000000000000000000000000000000000000000000000017d7840",
            proofNodes: hex"f903c2b90114f90111a0521cc12bd9690d6917c873bca358761ebe614bcdda311ae96a565eb3541fb976a0b02184e8a0f42f8fc9334201f746a9baff3de9e8f41eea0e18fad0548b97e764a0bf9522de2efbf1ecd763d7d07c04b9579780e4dfcef4cd95d28941645d47b1cda09a0a1fe35afc2e59684ff2f5daa1c73b86cdcdae91e3368474eb9022bda2d063a013bdd2da4c785610d0f05060fe681f5e477f50c69194c0e28136e69206563696a05560234c78f21ba3a9aae7cba7ae577bfef05933de718331d878c739507efa02a0d845d6731dfdf289204a3a1ffe46af371ad170b4daac166e62904542c6f878be80a0e58215be848c1293dd381210359d84485553000a82b67410406d183b42adbbdd8080808080808080b8f3f8f1a05de6d331fd323cecf969809160b38063ad1e7a57621535a2c9503cf09ef18e74a0020c21c6134f94c5450c428e2dd9c92e1f027453e4ce8a329ba860fd7b8609e7a0b9f56b8bb529ada6000134c7eaf30976bdde0677b22ef29fbe235df54205cb83a0f57f302c4dd5c6a92c1f8349d86e89e0fe628640114cbc39417dcfc4a30ac43da0781c51cf0bce52b41a3304f2a8e588127c811c0c69988cd84527721c7f39e8eea0a2d9ebe7b6cb704af1eed8dd7524ee7d1b762e83e602f07053a93c2c230a91b7a052dca8e0b775939ceafe9bceb2bb92fd94196bc96e377721bd1e58899065341080808080808080808080b901b3f901b020b901ac02f901a801840114e0a3b9010000000000000000000000000000000880000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000010000000000000200000000000004000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000001000000000000000000000000000f89df89b94be41a9ec942d5b52be07cc7f4d7e30e10e9b652af863a0ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3efa0000000000000000000000000e1a9d9c9abb872ddef70a4d108fd8fc3c7ce4dc4a0000000000000000000000000658d9c76ff358984d6436ea11ee1eda08894c818a000000000000000000000000000000000000000000000000000000000017d7840",
            receiptPath: hex"62",
            logIndex: 0
        });

        vm.prank(proofExecutor);
        proofEscrow.collect(proof, TARGET_BLOCK_NUMBER);

        console.log("Proved transfer from:", proofExecutor);
        console.log("To recipient:", proofRecipient);
        console.log("Amount:", TRANSFER_AMOUNT);
    }

    function _fundProofContract(Escrow _escrow, MockERC20 _token) internal {
        vm.startPrank(deployer);
        _token.mint(deployer, 10000e18);
        _token.approve(address(_escrow), REWARD_AMOUNT + PAYMENT_AMOUNT);
        _escrow.fund(REWARD_AMOUNT, PAYMENT_AMOUNT);
        vm.stopPrank();
    }
}
