// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

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

    function testCollectWithTransferProof_EIP1559() public {
        // Skip this test when on Tempo chain since it uses EIP-1559 block header
        if (block.chainid == 42429) {
            vm.skip(true);
        }

        deployer = makeAddr("deployer");
        address proofTokenAddress = address(0xBe41a9EC942d5b52bE07cC7F4D7E30E10e9B652A); // From: logs[0].address
        address proofRecipient = address(0x658D9C76ff358984D6436eA11ee1eda08894C818); // From: logs[0].topics[2] (to address)
        address proofExecutor = address(0xE1A9d9C9abB872dDEF70A4d108Fd8fc3c7cE4dC4); // From: logs[0].topics[1] (from address)

        vm.startPrank(deployer);

        // Mock the token transfers for constructor funding
        vm.mockCall(proofTokenAddress, abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));

        Escrow proofEscrow =
            new Escrow(proofTokenAddress, proofRecipient, TRANSFER_AMOUNT, REWARD_AMOUNT, PAYMENT_AMOUNT);
        vm.stopPrank();

        console.log("Proof escrow address:", address(proofEscrow));
        console.log("Expected amount in proof escrow:", proofEscrow.expectedAmount());

        // Mock transfers for bonding and collect payout
        vm.mockCall(proofTokenAddress, abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));
        vm.mockCall(proofTokenAddress, abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(true));
        vm.mockCall(proofTokenAddress, abi.encodeWithSelector(IERC20.send.selector), abi.encode(true));

        // Bond as executor
        vm.prank(proofExecutor);
        proofEscrow.bond(BOND_AMOUNT);

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

    function testCollectNativeWithTransactionProof_EIP1559() public {
        // Skip this test when on Tempo chain since it uses EIP-1559 block header
        if (block.chainid == 42429) {
            vm.skip(true);
        }

        deployer = makeAddr("deployer");

        // From the proof data
        uint256 targetBlockNumber = 10080186;
        bytes32 targetBlockHash = 0x3cc791aebe19951e540f697d14544ef4ff889d1505c1d1c69cd60aa27ca626bd;
        address proofRecipient = address(0x3C86ee0028788FCeA3d1c0C486D3794254ADcAFC);
        uint256 expectedAmount = 1000000000000000; // 0.001 ETH

        vm.deal(deployer, 10 ether);
        vm.startPrank(deployer);

        // Create native ETH escrow (tokenContract = address(0))
        // Pass 0, 0 to defer funding (constructor auto-calls fund() if non-zero)
        Escrow proofEscrow = new Escrow(
            address(0), // Native ETH
            proofRecipient,
            expectedAmount,
            0, // reward - defer to fundNative
            0 // payment - defer to fundNative
        );

        // Fund the escrow with ETH
        proofEscrow.fundNative{value: 1 ether}(0.5 ether, 0.5 ether);
        vm.stopPrank();

        console.log("Native proof escrow address:", address(proofEscrow));
        console.log("Expected amount:", proofEscrow.expectedAmount());

        // Bond as executor (any address can be executor for native transfers)
        address executor = makeAddr("executor");
        vm.deal(executor, 1 ether);
        vm.prank(executor);
        proofEscrow.bondNative{value: 0.25 ether}();

        vm.roll(targetBlockNumber + 10);
        vm.setBlockhash(targetBlockNumber, targetBlockHash);

        Escrow.TransactionProof memory proof = Escrow.TransactionProof({
            blockHeader: hex"f9028ca05d27c0235746b1575fcbb7230c9157b875b302ed0931ecbd1a7026d75d178951a01dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d493479413cb6ae34a13a0977f4d7101ebc24b87bb23f0d5a06bdc3a3c9dc98fe7ebb4fe9082edac759a3ea7132614fe7754dd41fea5a4fa90a001b53883993e8eccd22fbb47f79fdd68adef92cef4f3c00868a297421d93c261a0f1b65883c9c32b13324cd66f9e1e947086371feb084530234d7df768b0605dabb9010024a55c644a01804102b0d80445f30048d809b208a1ee8448c2c298a6c006e40b1fb07f4701c678492a61714610a48899003ebb0c7a89ae681d3093e8bc370210da2917020f80020a10a4148a1b1c467011f1184268c622b1208a0208809384b50a260099e25d05f8222647680335295956490cc13e3340ce1044a034a9286dc383c7048b193df034e60b27c9079881913340d9d1024db0801024625194888dc94249a105b2005700c70305df1111009c4c4214d380028c06997587000e677380428030fe6323413af6c784062b0415aa5010238804d533739ac060537012e06e53d421cd90f04721d8a71c02b40449047a4e0e4c4af24aca0f21665a84092069808399cfba840392a22084019f8bd184696e92d49f496c6c756d696e61746520446d6f63726174697a6520447374726962757465a09ad125b48a1761a7d7ed324b33aef35fe1536aa73909cd4733b036861810ed0888000000000000000084404ed89ea0e05153307bafe9d6b862385189e7a77174ca9a83051dac038f063cbdc469639383220000840c8e6a1ba0ad40631c80a294c2d0ba3b3436549c51c1fb73fc3e8b907ca9cf39f6085bf7cca0e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            transactionRlp: hex"02f87483aa36a780844384d5138491fda78e825208943c86ee0028788fcea3d1c0c486d3794254adcafc87038d7ea4c6800080c080a0d075a8721103d76ce07a65bffe86a87ceaaef9e7240493f9873fbcacf1f31139a04d1b5493b7cf831ff79ee91221d0e1cb79b71f6652f95d64c87cd6ec8dc4bdba",
            proofNodes: hex"f9038ab8f3f8f1a0ea417aa3337d89aa308e729b85e534018eeb0d27e45e30f4596a5c828522d5d5a0b99463d0ace6bbff8debb499d30e69915be4f1825e02467ffca41db658458290a073c7342c76ac2bbfac25b013b99b05813071db94149be92569d11d532ff8a1a0a06a16804a4598f6943641b7289d8867f808f3812a939b485be62a09235c49adf5a0cf56ce4669a2501831bd6f7178dd719bc9596a4ac311ae9952274862ed85ba5ea044763a1b4a817a7486aeccb75044f19560e4dc8de5eba8cb298da17b328aa2438080a010dacdfc0730fae51f072b9b148eb522f61428237d506cf73152107ffabe24c98080808080808080b90214f90211a0603bf2b689978c2767949a1b012dd6ede8607d27cdd464e26ecd3de4212f9569a07544470cdd5d4343bc85745dc65652d4de077dc1129a0738a5269635871eca75a091ba79b0a28b4cb8dee169259d48395ebc22810a37c71cb2d57aec65edad8a9aa0b3cabd9bdc55289f0833c3ecd9311aca117db9d12582dcad0a2f4ee37875cb19a045d6138c33c09806ca501e4600e375fba3ac7a35d8aa7a9377138963bacfc018a02774c2a4b03fbda71df1b988dfff4c94ee39dfd329a49f4772ad52780b5ea167a0edcdbfcda677db06341d7bfebf7a0865fe563e3e5aad8417dcafbb4eab37e067a0d75cd00b4236f58b7274e5db82d900a9f523af7a0f12dcc05350944000d52e8da049845e16ecad3608ef413e979ff4fba131d86bb6e0b89dbc710c384c62d5f827a026d0467d35c273a5f179349ae7af07d75dc12f2a3a8341794f86b2c4b8b8b36ba0d6a5f31d7e040a3a47b335ae9a80af8c7d383fa3c513cca5b19706d741428f46a0b2b9bdbe1e7692aef9414fb1bf5fc5a2e353a4fa9f825f9c2a4831eccf282312a02a07787d1f9daffdf47af66182257c6e2393b7074714b98a803b14759784e989a0e40d552606d64fa5db611583741b00d2da7c070f0f9f682140b0d4f29d1ad5e0a0a74019f48d4f133858c9796a6985901e0ebb337206d416a646190cb5a2063f18a00c9e711239b2154c29f66edce7f9db2aecf8c8d617dfbddd6dc66d41807aa8ab80b87cf87a20b87702f87483aa36a780844384d5138491fda78e825208943c86ee0028788fcea3d1c0c486d3794254adcafc87038d7ea4c6800080c080a0d075a8721103d76ce07a65bffe86a87ceaaef9e7240493f9873fbcacf1f31139a04d1b5493b7cf831ff79ee91221d0e1cb79b71f6652f95d64c87cd6ec8dc4bdba",
            transactionPath: hex"3d"
        });

        vm.prank(executor);
        proofEscrow.collectNative(proof, targetBlockNumber);

        console.log("Proved native ETH transfer");
        console.log("To recipient:", proofRecipient);
        console.log("Amount:", expectedAmount);
    }
}
