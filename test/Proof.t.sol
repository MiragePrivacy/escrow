// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, Vm, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EscrowNative} from "../src/EscrowNative.sol";
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

contract ProofTest is Test {
    MockERC20 public token;

    address public deployer;
    uint256 constant TRANSFER_AMOUNT = 0x17d7840; // From: logs[0].data
    uint256 constant REWARD_AMOUNT = 500e18;
    uint256 constant PAYMENT_AMOUNT = TRANSFER_AMOUNT;

    uint256 constant TARGET_BLOCK_NUMBER = 9084468; // From: block_number
    bytes32 constant TARGET_BLOCK_HASH = 0x490a3fc0b0c2170b55ca18ce6c73fc1af50ebe0931b525a3510c048f2b428617; // From: block_hash

    // testCollectWithTransferProof_EIP1559 was removed here. It proved an
    // ERC-20 Transfer by parsing an RLP receipt and walking an MPT proof
    // on-chain, which EscrowERC20 no longer does; EscrowZK.t.sol covers the
    // same settlement through a Groth16 proof instead. The native case below
    // still uses the plaintext path, since the circuit is ERC-20 only.

    function testCollectNativeWithTransactionProof_EIP1559() public {
        // Skip this test when on Tempo chain since it uses EIP-1559 block header
        if (block.chainid == 42429) {
            vm.skip(true);
        }

        deployer = makeAddr("deployer");
        Vm.Wallet memory enclave = vm.createWallet("enclave");

        // From the proof data (Sepolia block 10108338, tx index 34)
        // Generated: 2026-01-23 - Native ETH transfer with full tx + receipt proofs
        uint256 targetBlockNumber = 10108338;
        bytes32 targetBlockHash = 0xcde568d2d6aba1b5f2cfba08fec1019ef7ff7a3b889b67fbbad59df526ace18a;
        address proofRecipient = address(0x3C86ee0028788FCeA3d1c0C486D3794254ADcAFC);
        uint256 expectedAmount = 1000000000000000; // 0.001 ETH

        vm.deal(deployer, 10 ether);
        vm.startPrank(deployer);

        // Create native ETH escrow
        // Pass a zero reward to defer funding (constructor auto-funds if non-zero).
        EscrowNative proofEscrow = new EscrowNative(proofRecipient, expectedAmount, enclave.addr, 0, 0);

        // Fund the escrow with reward + recipient principal only.
        proofEscrow.fund{value: 0.5 ether + expectedAmount}(0.5 ether);
        vm.stopPrank();

        console.log("Native proof escrow address:", address(proofEscrow));
        console.log("Expected amount:", proofEscrow.expectedAmount());

        // Bond as executor, gated by the enclave's BondAuth signature.
        //
        // Bonding happens one block before the settlement, because the lease is
        // now measured in blocks: bonding at block 1 and rolling forward nine
        // million blocks would expire it. The escrow also requires the proof's
        // block to be strictly after bondStartBlock.
        address executor = makeAddr("executor");
        vm.deal(executor, 1 ether);
        vm.roll(targetBlockNumber - 1);

        vm.prank(executor);
        proofEscrow.bond(0, BondAuth.sign(vm, enclave.privateKey, address(proofEscrow), executor));

        vm.roll(targetBlockNumber + 10);
        vm.setBlockhash(targetBlockNumber, targetBlockHash);

        // Full native ETH transfer proof with both transaction and receipt Merkle proofs
        // This proves: (1) tx was included in block, (2) tx succeeded (receipt status=1)
        EscrowNative.NativeTransferProof memory proof = EscrowNative.NativeTransferProof({
            blockHeader: hex"f90281a0397210743fb9da13aeccc4aabe2661bfa32141d4f29f6e7d19f9b687e9ed528aa01dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347944df6eb2ec570b58cc64f540247a8adfa11f1cf63a00e7e627445ec722103ef8589db019ed664c2b60135149c2aac77592cbc73f2e1a0de2ddb3e41cd5a8ea1ba0ca1edb40173c290f986b2b90b2b04e57dbd1188d3b0a049342d87846703e91c3996fd651fe201e2b0438b89e72c306c91f5553014b47eb9010090296205660011a20c500a44024053005a0802482220050020a0304116423100008024420a000010a2c3404810001a0644040e0134882e10200100101245bc0010000049088843082044248b042806ac0001002820e4800802030044801102000400030a82840a58368401202031080042020094c424804080060036004900c43840001010366032620903c140000924210010030001a4018424106000820c004010b2260800040840089229d08400008002008c800c2490d17081030041a0802a0401220047000085420305080403820482008904200321005021499e1660400c120d400080000790c2d10220081908551000084d2040400c103c0a2821962480839a3db2840393870083bc0cee846973d94c95657269676f6e2d332e332e332d3762633364366431a0da7f921ea19c9df08304a2f4bca0af0a03ac9460ce65f0fe3bfa2d8ca2fb41b0880000000000000000843e642ba6a0d1a30c37e5696198b78a5f5acbb4695000eadc4e1c0c418ec2d64084e733c60c830e0000840c845646a026a71dc0fcb6c3cc98c6cea6459e4474085101a08c5c47b44b5297c2067ec2e9a0e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            transactionRlp: hex"02f87483aa36a703840349764384522407e2825208943c86ee0028788fcea3d1c0c486d3794254adcafc87038d7ea4c6800080c001a0bf78958050d25c0a20b23c53fffe328af09621b4aee42ea533e7dc361c89e80fa010a717301aa6292f8662f42c8f813e6f469e7ff87db37fe92afd0bb5849dd078",
            txProofNodes: hex"f9030ab893f891a04df2041d420fa3d55f34a8746442bb2ed115d53d152bae9a1e06c87a96495b26a096914abc2f5dedf4238ec649c5c802d4b845f3626da32c55a6bdfd0319ed674ea0c34cb53df6c5f6bd768894697e2a863ab3ade892f1014b73e739f4b63a5f3c1e8080808080a071bb16c3a3fa6ada920324ef40f4d5a36428f1430e14cae9a3bd98045ecf47ec8080808080808080b901f4f901f1a02aa618e5267c0753bd259e9012e392b7051d7350d437e3f70b97896f9eddd0bca037054656be02df06093636df195366c503730bf8dbec5c7322865ea8f0eaf4f0a0a258f45df5fa79f1f445ff6c0d6ffcc3ef5722ece8641a8bbb680a5765aea922a0a352b719cd5389335fff522878e047447dc1a2309e11ae5981a11ddc0b77da6da04d7f26ce3509ea037fa9b90188fd386851dbd9188fc55bd0fdf9c4b80c5f9379a0757f4d110e8958bd48fd1c674f7c1640d29d300ab2fdd6e5841dfbf2c59eb897a05ca297ed486e83631116a2e3a4b4729e67f8a5c87b3540b2e9f5a6827ca2f794a0606e7d8f4a1147546b12bf57b8e5dc9dd3b7e452cdec901410c4fe1ea9702a8ea03d03afcdf2972ac57a4751773cc002788967548f2b865832f911523eb5653c9ea087e14e540fa705597c4168e5903968cf5c76dd99c59ff1a3560166951fe44f62a0be5d49ad02271c9a68eb24f463b6b2fc985fc907f2de62c9ea9cdd1996d2cb3ca025e85233691d941a8bee020fe80354f21407625db38745d915e22bbd870bb451a0d3519df5120c28feeeb18c727bf8a013648308f32820558bb6fb2be4a1e89f16a0f87abef5804462906a643dd6a5fb7d0c84e9baa58a019b7627ac12219a49b145a0db699bee4861ee642e3088dc28ef8a9d1fdb5a5eb7f9bb8ad5f28f38717cd0698080b87cf87a20b87702f87483aa36a703840349764384522407e2825208943c86ee0028788fcea3d1c0c486d3794254adcafc87038d7ea4c6800080c001a0bf78958050d25c0a20b23c53fffe328af09621b4aee42ea533e7dc361c89e80fa010a717301aa6292f8662f42c8f813e6f469e7ff87db37fe92afd0bb5849dd078",
            // Receipt with status=1 (success), cumulativeGasUsed=0x5b7459, empty logsBloom, no logs
            receiptRlp: hex"02f9010901835b7459b9010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c0",
            receiptProofNodes: hex"f903a3b893f891a0e0c7e93b2cfe84b1a304cbe04e2f8c7ebdd2e8ee1582f5d94b2e15e5c9aa1b27a0c4d35ea3c917ec2fed880ed796213ef8822a97447e7c8238f47509b9aca8368da018bb3efb1044af329d0961b445ae94abe7a92a6ac68b9e0093254fddf86b3cc88080808080a09f0fd06810e1b9d3a06b3c59c790638ce40fb5ce3a66c5d942be4f1c0fb3c0c18080808080808080b901f4f901f1a00de026cdb9ea8e5c07dae1730fbd9f61eee75dd8bc9dd5f31437ad1b7fc3f02da067c0d5dad7217228e20426263685dcba31315a795777794315cac047d67a713aa05b2e03189113dbaf785f3ae763e238cde070c6f6ad730f19d295a31c49c07e45a06a7f4d0e8209eb6b93be36c6fe3881b09df8b64cb68dd22dad37515bae3bc4bda03c398130be50e0b5dd00ad97fff19231418d76bc17cc419fa765a72acb0ed352a02457e909e45da5bfff302723ae0081187abc25152a72ff1e895a47ee6bd041d7a038a9c00a70d58d4a32d691a85a9318fa0aa17976345a38a2a8d328938b05d4b0a08b91dee2fe71c9d877cdbe46d39cccbcff2fdbff2e19f2a89c7fe05899413a60a0fc93ce3146520c8a8706fa447ca39160df85c6d7fa17d4081e4d529c3a2a04eca05a1ce05e0164d3a110456c1d681e4b555bc6725067864672249cd035d9a8aba6a0d826506d25e5d97aa87dade82553a96505274f32592de19b5b166fa6c0dbde40a0919517c55c26498649fab415b98c011ab984a3e0e491449c82a641cd6da24eb5a043c990e8d31af4bb52502821b2ba84cc57365f62aef6452d610a503e26c1f747a0172f2c433164bd24b87ec08d7f55b788eb060e2570bbc926b22ed7fe689c4acca0fbb729496c6a787dc0d0b94ce7a761003cbf424575c977b71edf6757884ea2308080b90114f9011120b9010d02f9010901835b7459b9010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c0",
            path: hex"22" // tx index 34 = 0x22
        });

        vm.prank(executor);
        proofEscrow.collect(proof, targetBlockNumber);

        console.log("Proved native ETH transfer");
        console.log("To recipient:", proofRecipient);
        console.log("Amount:", expectedAmount);
    }
}
