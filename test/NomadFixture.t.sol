// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {EscrowNative} from "../src/EscrowNative.sol";
import {EscrowERC20} from "../src/EscrowERC20.sol";

// Token mock matching the anvil test token's interface, including the
// non-standard `send` used by EscrowERC20._payout on chain id 11155111.
contract FixtureToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function send(address to, uint256 amount) external returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        return _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

// Replays collect fixtures captured from a full nomad node e2e run against anvil
// (NOMAD_PROOF_FIXTURE_DIR, crates/enclave/src/ethereum/mod.rs::dump_collect_fixture).
// The MPT proofs, block headers, and EIP-712 execution signatures are the exact
// bytes the enclave produced and successfully collected with on-chain, so these
// tests pin the off-chain prover/signer and the contracts to each other.
contract NomadFixtureTest is Test {
    uint256 constant PAYMENT = 0.05 ether;

    function _load(string memory name) internal view returns (string memory json) {
        return vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/", name));
    }

    function testNativeCollectFromNomadFixture() public {
        string memory json = _load("native_collect_fixture.json");

        uint256 chainId = vm.parseJsonUint(json, ".chainId");
        address escrowAddr = vm.parseJsonAddress(json, ".escrow");
        address recipient = vm.parseJsonAddress(json, ".expectedRecipient");
        uint256 expectedAmount = vm.parseJsonUint(json, ".expectedAmount");
        uint256 reward = vm.parseJsonUint(json, ".rewardAmount");
        address payout = vm.parseJsonAddress(json, ".payoutAddress");
        uint256 targetBlock = vm.parseJsonUint(json, ".targetBlockNumber");
        bytes32 blockHash = vm.parseJsonBytes32(json, ".blockHash");
        bytes memory sig = vm.parseJsonBytes(json, ".executionSig");

        // The execution signature's EIP-712 domain binds the chain id and the
        // escrow address from the anvil run, so the escrow must be recreated at
        // that exact address on that exact chain id.
        vm.chainId(chainId);
        vm.deal(address(this), reward + PAYMENT);
        deployCodeTo(
            "EscrowNative.sol:EscrowNative",
            abi.encode(recipient, expectedAmount, reward, PAYMENT),
            reward + PAYMENT,
            escrowAddr
        );

        vm.roll(targetBlock + 5);
        vm.setBlockhash(targetBlock, blockHash);

        EscrowNative.NativeTransferProof memory proof = EscrowNative.NativeTransferProof({
            blockHeader: vm.parseJsonBytes(json, ".proof.header"),
            transactionRlp: vm.parseJsonBytes(json, ".proof.transaction"),
            txProofNodes: vm.parseJsonBytes(json, ".proof.txProof"),
            receiptRlp: vm.parseJsonBytes(json, ".proof.receipt"),
            receiptProofNodes: vm.parseJsonBytes(json, ".proof.receiptProof"),
            path: vm.parseJsonBytes(json, ".proof.path")
        });

        uint256 balanceBefore = payout.balance;
        EscrowNative(escrowAddr).collect(proof, targetBlock, payout, sig);

        assertEq(payout.balance, balanceBefore + reward + PAYMENT, "payout amount");
        assertTrue(EscrowNative(escrowAddr).collected(), "collected flag");
    }

    function testErc20CollectFromNomadFixture() public {
        string memory json = _load("erc20_collect_fixture.json");

        uint256 chainId = vm.parseJsonUint(json, ".chainId");
        address escrowAddr = vm.parseJsonAddress(json, ".escrow");
        address tokenAddr = vm.parseJsonAddress(json, ".token");
        address recipient = vm.parseJsonAddress(json, ".expectedRecipient");
        uint256 expectedAmount = vm.parseJsonUint(json, ".expectedAmount");
        uint256 reward = vm.parseJsonUint(json, ".rewardAmount");
        address payout = vm.parseJsonAddress(json, ".payoutAddress");
        uint256 targetBlock = vm.parseJsonUint(json, ".targetBlockNumber");
        bytes32 blockHash = vm.parseJsonBytes32(json, ".blockHash");
        bytes memory sig = vm.parseJsonBytes(json, ".executionSig");

        vm.chainId(chainId);

        // The proven receipt's Transfer log was emitted by the anvil token, so
        // the token mock must live at that exact address.
        deployCodeTo("NomadFixture.t.sol:FixtureToken", "", 0, tokenAddr);
        FixtureToken token = FixtureToken(tokenAddr);
        token.mint(address(this), reward + PAYMENT);
        token.approve(escrowAddr, reward + PAYMENT);

        deployCodeTo(
            "EscrowERC20.sol:EscrowERC20",
            abi.encode(tokenAddr, recipient, expectedAmount, reward, PAYMENT),
            0,
            escrowAddr
        );

        vm.roll(targetBlock + 5);
        vm.setBlockhash(targetBlock, blockHash);

        EscrowERC20.ReceiptProof memory proof = EscrowERC20.ReceiptProof({
            blockHeader: vm.parseJsonBytes(json, ".proof.header"),
            receiptRlp: vm.parseJsonBytes(json, ".proof.receipt"),
            proofNodes: vm.parseJsonBytes(json, ".proof.proof"),
            receiptPath: vm.parseJsonBytes(json, ".proof.path"),
            logIndex: vm.parseJsonUint(json, ".proof.log")
        });

        EscrowERC20(escrowAddr).collect(proof, targetBlock, payout, sig);

        assertEq(token.balanceOf(payout), reward + PAYMENT, "payout amount");
        assertTrue(EscrowERC20(escrowAddr).collected(), "collected flag");
    }
}
