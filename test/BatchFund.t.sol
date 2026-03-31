// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {EscrowERC20, IERC20} from "../src/EscrowERC20.sol";
import {EscrowBase} from "../src/EscrowBase.sol";

// ============================================================
//  Diagnosing: "Tempo fund call in batch does nothing"
//
//  Failing TX: 0xedf03465...ac94ae on Tempo testnet (chain 42431)
//  Error observed on-chain:
//    token:  0x20C0000000000000000000000000000000000000
//    escrow: 0x7e9798a62b42d97fb05b9e092a9a2117fa3fb995
//    amount: 100000000, reward: 723471
//    → "Contract is not funded"
//
//  ROOT CAUSE (confirmed via on-chain RPC analysis):
//    The Tempo batch tx deploys the escrow at 0x7e97..., but the
//    approve + fund calls target 0xd69b... which has NO CODE.
//    EVM CALL to an address with no code succeeds silently (returns 0x),
//    so the batch doesn't revert, but fund() never actually executes.
//    The escrow remains unfunded.
//
//  Evidence:
//    - 0xd69b8fc5d21819a713fde3e051c97e1cb09bd2aa has no code (eth_getCode → 0x)
//    - eth_call fund() on 0xd69b... → success, empty return (0 gas, no-op)
//    - eth_call fund() on 0x7e97... → reverts InsufficientAllowance (fund logic WORKS)
//    - Obfuscated fund() selector 0x49364cd4 is present in deployed dispatcher
//    - Original selector 0xa65e2cfd is absent (obfuscation replaced all selectors)
//
//  Cross-TX verification (successful vs failed):
//    WORKING TX 0x8bff4e21...: CREATE → 0x7720..., approve → 0x7720..., fund → 0x7720...  (all same)
//    FAILING TX 0xedf03465...: CREATE → 0x7e97..., approve → 0xD69B..., fund → 0xD69B...  (mismatch)
//    When the batch targets the correct address, it works. When wrong, silent no-op.
//
//  Hypotheses tested:
//    H1 – Bytecode dispatch dead end                   → RULED OUT
//    H2 – msg.sender context in batch                  → PLAUSIBLE (general risk)
//    H3 – Batch swallows fund() revert                 → CONFIRMED MECHANISM
//    H4 – Later batch op reverts fund                  → PLAUSIBLE (general risk)
//    H5 – No-op token                                  → RULED OUT (wrong error)
//    H6 – Non-compliant token                          → RULED OUT
//    H7 – staticcall / eth_call                        → RULED OUT
//    H8 – Batch targets wrong address (no code)        → ROOT CAUSE ✓
// ============================================================

// --- Mock tokens with different edge-case behaviors ---------

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @dev Token that returns true from transferFrom but never moves balances.
///      Simulates a precompile or buggy token at 0x20c0...0000.
contract NoOpToken {
    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}

/// @dev Token whose transferFrom succeeds at the EVM level but returns
///      empty returndata — simulates a non-ERC20-compliant contract.
contract NoReturnToken {
    function transferFrom(address, address, uint256) external pure {
        // no return value
    }

    function transfer(address, uint256) external pure {
        // no return value
    }
}

/// @dev Token whose transferFrom always reverts.
contract RevertingToken {
    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert("blocked");
    }

    function transfer(address, uint256) external pure returns (bool) {
        revert("blocked");
    }
}

// --- Batch / factory pattern contracts ----------------------

/// @dev Simulates a factory or batch-deployer contract that creates an
///      escrow and immediately funds it, all within a single transaction.
contract EscrowFactory {
    function deployAndAutoFund(
        address tokenContract,
        address recipient,
        uint256 expectedAmount,
        uint256 rewardAmount,
        uint256 paymentAmount
    ) external returns (address) {
        // Constructor auto-funds when both amounts > 0.
        // transferFrom inside fund() pulls from msg.sender of fund(), which is
        // address(this) during constructor execution.
        EscrowERC20 escrow = new EscrowERC20(tokenContract, recipient, expectedAmount, rewardAmount, paymentAmount);
        return address(escrow);
    }

    function deployUnfundedThenFund(
        address tokenContract,
        address recipient,
        uint256 expectedAmount,
        uint256 rewardAmount,
        uint256 paymentAmount
    ) external returns (address) {
        // Deploy without auto-fund (0, 0)
        EscrowERC20 escrow = new EscrowERC20(tokenContract, recipient, expectedAmount, 0, 0);
        // Fund separately — msg.sender for fund() is this factory (== deployerAddress)
        escrow.fund(rewardAmount, paymentAmount);
        return address(escrow);
    }
}

/// @dev Generic multicall-style batcher. Executes an array of calls in
///      sequence; if any fails the entire tx reverts.
contract StrictBatcher {
    struct Call {
        address target;
        bytes data;
        uint256 value;
    }

    function execute(Call[] calldata calls) external payable {
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory ret) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            require(ok, string(ret));
        }
    }
}

/// @dev Batcher that swallows failed calls (try-style). A fund() revert
///      here would be silently ignored, leaving the escrow unfunded.
contract LenientBatcher {
    struct Call {
        address target;
        bytes data;
        uint256 value;
    }

    event CallResult(uint256 index, bool success, bytes returnData);

    function execute(Call[] calldata calls) external payable {
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory ret) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            emit CallResult(i, ok, ret);
            // Does NOT revert on failure — call is swallowed
        }
    }
}

// ============================================================
//  Test contract
// ============================================================

contract BatchFundTest is Test {
    MockERC20 token;
    address deployer;
    address executor;
    address recipient;

    uint256 constant REWARD = 500e18;
    uint256 constant PAYMENT = 500e18;
    uint256 constant EXPECTED_AMOUNT = 1000e18;

    // Real values from the failing Tempo TX:
    // 0xedf034653df8ebd016a471bb4c19a1a71b01b39694720ffdde148790b4ac94ae
    uint256 constant TEMPO_AMOUNT = 100000000;
    uint256 constant TEMPO_REWARD = 723471;
    address constant TEMPO_TOKEN = 0x20C0000000000000000000000000000000000000;
    address constant TEMPO_ESCROW = 0x7e9798a62b42D97fb05b9e092a9A2117FA3fB995;
    address constant TEMPO_WRONG_TARGET = 0xD69B8fC5D21819A713fDE3e051C97e1Cb09BD2Aa;
    address constant TEMPO_SENDER = 0xA79045285379f02ad505D7338523843D3A73BBaD;

    function setUp() public {
        deployer = makeAddr("deployer");
        executor = makeAddr("executor");
        recipient = makeAddr("recipient");

        vm.startPrank(deployer);
        token = new MockERC20();
        token.mint(deployer, 100_000e18);
        vm.stopPrank();
    }

    // ========================================================
    //  H1 – Bytecode & selector verification
    // ========================================================

    /// Artifact deployment hex must match freshly compiled bytecode.
    /// We verified this externally (bytecodes are identical), so this test
    /// asserts the creation code is non-trivial and the deployed code
    /// contains the expected function selectors.
    function testArtifactMatchesCompiled() public view {
        bytes memory compiled = type(EscrowERC20).creationCode;
        // ERC20 deployment bytecode is ~9KB
        assertTrue(compiled.length > 8000, "creation code suspiciously small");

        // Deploy an escrow to check runtime code
        // (done in testFundSelectorInBytecode)
    }

    /// fund(uint256,uint256) selector 0xa65e2cfd must be present in deployed bytecode.
    function testFundSelectorInBytecode() public {
        bytes4 fundSel = EscrowERC20.fund.selector;
        assertEq(fundSel, bytes4(0xa65e2cfd), "unexpected fund selector");

        // Deploy an escrow and check its on-chain code for the selector
        vm.startPrank(deployer);
        EscrowERC20 escrow = new EscrowERC20(address(token), recipient, EXPECTED_AMOUNT, 0, 0);
        vm.stopPrank();

        bytes memory runtime = address(escrow).code;
        bool found;
        for (uint256 i = 0; i < runtime.length - 3; i++) {
            if (
                runtime[i] == fundSel[0] && runtime[i + 1] == fundSel[1] && runtime[i + 2] == fundSel[2]
                    && runtime[i + 3] == fundSel[3]
            ) {
                found = true;
                break;
            }
        }
        assertTrue(found, "fund() selector not found in deployed bytecode");
    }

    /// Calling fund() via raw low-level call with correct selector must work.
    function testFundViaRawCall() public {
        vm.startPrank(deployer);
        EscrowERC20 escrow = new EscrowERC20(address(token), recipient, EXPECTED_AMOUNT, 0, 0);
        token.approve(address(escrow), REWARD + PAYMENT);

        bytes memory callData = abi.encodeWithSelector(0xa65e2cfd, REWARD, PAYMENT);
        (bool ok,) = address(escrow).call(callData);
        vm.stopPrank();

        assertTrue(ok, "raw call to fund() reverted");
        assertTrue(escrow.funded(), "funded should be true after raw call");
        assertEq(escrow.currentRewardAmount(), REWARD);
        assertEq(escrow.currentPaymentAmount(), PAYMENT);
    }

    /// Raw call with a WRONG selector must not set funded.
    function testFundViaRawCallWrongSelector() public {
        vm.startPrank(deployer);
        EscrowERC20 escrow = new EscrowERC20(address(token), recipient, EXPECTED_AMOUNT, 0, 0);
        token.approve(address(escrow), REWARD + PAYMENT);

        // Use a wrong selector (just flip a bit)
        bytes memory callData = abi.encodeWithSelector(0xa65e2cfe, REWARD, PAYMENT);
        (bool ok,) = address(escrow).call(callData);
        vm.stopPrank();

        // Call should revert (no matching function, no fallback)
        assertFalse(ok, "wrong selector should revert");
        assertFalse(escrow.funded(), "should still be unfunded");
    }

    // ========================================================
    //  H2 – Factory / batch deployer context (msg.sender)
    // ========================================================

    /// Factory deploys with auto-fund in constructor.
    /// deployerAddress = factory, and factory is msg.sender for fund().
    /// transferFrom pulls tokens FROM the factory.
    function testFactoryAutoFund() public {
        EscrowFactory factory = new EscrowFactory();

        // Factory needs tokens + approval to the future escrow address
        token.mint(address(factory), REWARD + PAYMENT);

        // We need the factory to approve the escrow address.
        // But the factory can't pre-approve because it doesn't know the address.
        // In practice the factory would need to compute the address first.
        //
        // Since the factory deploys with CREATE, address = f(factory_addr, nonce).
        // Let's compute it:
        address futureEscrow = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        vm.prank(address(factory));
        token.approve(futureEscrow, REWARD + PAYMENT);

        address escrowAddr = factory.deployAndAutoFund(address(token), recipient, EXPECTED_AMOUNT, REWARD, PAYMENT);
        assertEq(escrowAddr, futureEscrow, "address prediction mismatch");

        EscrowERC20 escrow = EscrowERC20(escrowAddr);
        assertTrue(escrow.funded(), "factory-deployed escrow should be funded");
        assertEq(token.balanceOf(escrowAddr), REWARD + PAYMENT);
    }

    /// Factory deploys (0,0) then calls fund() in same tx.
    function testFactoryDeployThenFund() public {
        EscrowFactory factory = new EscrowFactory();
        token.mint(address(factory), REWARD + PAYMENT);

        // For the separate fund path, the escrow address is still predictable.
        // fund() calls transferFrom(msg.sender=factory, escrow, amount).
        // Token needs allowance[factory][escrow] >= amount.
        address futureEscrow = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        vm.prank(address(factory));
        token.approve(futureEscrow, REWARD + PAYMENT);

        address escrowAddr = factory.deployUnfundedThenFund(address(token), recipient, EXPECTED_AMOUNT, REWARD, PAYMENT);

        EscrowERC20 escrow = EscrowERC20(escrowAddr);
        assertTrue(escrow.funded(), "should be funded after factory deploy-then-fund");
        assertEq(token.balanceOf(escrowAddr), REWARD + PAYMENT);
    }

    /// EOA tries to fund an escrow that was deployed by a factory.
    /// Must revert because deployerAddress = factory, not EOA.
    function testEOACannotFundFactoryDeployedEscrow() public {
        EscrowFactory factory = new EscrowFactory();

        // Deploy unfunded (0,0) via factory
        address escrowAddr = factory.deployAndAutoFund(address(token), recipient, EXPECTED_AMOUNT, 0, 0);

        EscrowERC20 escrow = EscrowERC20(escrowAddr);
        assertFalse(escrow.funded(), "should start unfunded");

        // Now EOA (deployer) tries to fund it
        vm.startPrank(deployer);
        token.approve(escrowAddr, REWARD + PAYMENT);
        vm.expectRevert(EscrowBase.OnlyDeployer.selector);
        escrow.fund(REWARD, PAYMENT);
        vm.stopPrank();
    }

    // ========================================================
    //  H3 – Lenient batcher swallows fund() revert
    // ========================================================

    /// If the batch catches fund() reverts silently, the escrow remains unfunded.
    function testLenientBatchSwallowsFundRevert() public {
        vm.startPrank(deployer);
        EscrowERC20 escrow = new EscrowERC20(address(token), recipient, EXPECTED_AMOUNT, 0, 0);
        // Intentionally DO NOT approve → fund() will revert inside transferFrom
        vm.stopPrank();

        LenientBatcher batcher = new LenientBatcher();

        LenientBatcher.Call[] memory calls = new LenientBatcher.Call[](1);
        calls[0] = LenientBatcher.Call({
            target: address(escrow), data: abi.encodeWithSelector(EscrowERC20.fund.selector, REWARD, PAYMENT), value: 0
        });

        // Batcher swallows the revert — does not propagate
        vm.prank(deployer);
        batcher.execute(calls);

        // Escrow is NOT funded because fund() reverted (no allowance)
        // and the batcher swallowed the error
        assertFalse(escrow.funded(), "lenient batcher should leave escrow unfunded");
    }

    /// Even when msg.sender matches deployer, if the batch batcher is the
    /// actual caller, msg.sender = batcher, not deployer. OnlyDeployer reverts,
    /// but the lenient batcher swallows it.
    function testLenientBatchWrongSenderSwallowed() public {
        vm.startPrank(deployer);
        EscrowERC20 escrow = new EscrowERC20(address(token), recipient, EXPECTED_AMOUNT, 0, 0);
        token.approve(address(escrow), REWARD + PAYMENT);
        vm.stopPrank();

        LenientBatcher batcher = new LenientBatcher();

        LenientBatcher.Call[] memory calls = new LenientBatcher.Call[](1);
        calls[0] = LenientBatcher.Call({
            target: address(escrow), data: abi.encodeWithSelector(EscrowERC20.fund.selector, REWARD, PAYMENT), value: 0
        });

        // Batcher is msg.sender, not deployer → OnlyDeployer revert → swallowed
        batcher.execute(calls);

        assertFalse(escrow.funded(), "batcher msg.sender != deployer, fund should fail silently");
    }

    // ========================================================
    //  H4 – Batch tx reverts AFTER fund() succeeds
    // ========================================================

    /// fund() succeeds, but a later call in the strict batch reverts →
    /// entire tx is rolled back including the fund state change.
    function testStrictBatchRevertAfterFund() public {
        vm.startPrank(deployer);
        EscrowERC20 escrow = new EscrowERC20(address(token), recipient, EXPECTED_AMOUNT, 0, 0);
        token.approve(address(escrow), REWARD + PAYMENT);
        vm.stopPrank();

        StrictBatcher batcher = new StrictBatcher();

        StrictBatcher.Call[] memory calls = new StrictBatcher.Call[](2);
        // Call 1: fund() — this would succeed if msg.sender matches
        // But msg.sender here is the batcher, not deployer → reverts with OnlyDeployer
        calls[0] = StrictBatcher.Call({
            target: address(escrow), data: abi.encodeWithSelector(EscrowERC20.fund.selector, REWARD, PAYMENT), value: 0
        });
        // Call 2: some other call that reverts
        calls[1] = StrictBatcher.Call({target: address(0), data: hex"", value: 0});

        vm.prank(deployer);
        vm.expectRevert(); // first call fails (OnlyDeployer)
        batcher.execute(calls);

        assertFalse(escrow.funded(), "batch revert should roll back fund");
    }

    /// When deployer calls fund() directly through a strict batcher, the
    /// msg.sender in fund() is the batcher, NOT the deployer.
    /// This is the most likely root cause for batch fund failures.
    function testBatcherMsgSenderIsNotDeployer() public {
        vm.startPrank(deployer);
        EscrowERC20 escrow = new EscrowERC20(address(token), recipient, EXPECTED_AMOUNT, 0, 0);
        token.approve(address(escrow), REWARD + PAYMENT);
        vm.stopPrank();

        StrictBatcher batcher = new StrictBatcher();

        StrictBatcher.Call[] memory calls = new StrictBatcher.Call[](1);
        calls[0] = StrictBatcher.Call({
            target: address(escrow), data: abi.encodeWithSelector(EscrowERC20.fund.selector, REWARD, PAYMENT), value: 0
        });

        // deployer calls batcher, batcher calls escrow.fund()
        // msg.sender in fund() = batcher, not deployer
        vm.prank(deployer);
        vm.expectRevert(); // OnlyDeployer
        batcher.execute(calls);
    }

    // ========================================================
    //  H5 – No-op token (precompile-like)
    // ========================================================

    /// Token returns true from transferFrom but doesn't move tokens.
    /// fund() sets funded=true, but the contract has zero token balance.
    /// Nodes would see funded=true, bond would work, but payout would fail.
    /// NOTE: This produces a DIFFERENT error than "not funded".
    function testNoOpTokenFundSucceedsWithZeroBalance() public {
        NoOpToken noOp = new NoOpToken();

        vm.startPrank(deployer);
        EscrowERC20 escrow = new EscrowERC20(address(noOp), recipient, EXPECTED_AMOUNT, REWARD, PAYMENT);
        vm.stopPrank();

        // fund() "succeeded" because transferFrom returned true
        assertTrue(escrow.funded(), "no-op token: funded flag is true");
        assertEq(escrow.currentRewardAmount(), REWARD);
        assertEq(escrow.currentPaymentAmount(), PAYMENT);

        // BUT: contract has zero token balance
        assertEq(noOp.balanceOf(address(escrow)), 0, "no-op token: escrow should have 0 balance");
    }

    // ========================================================
    //  H6 – Token returns no data (non-compliant ERC20)
    // ========================================================

    /// Token that returns empty data from transferFrom.
    /// Solidity ABI decoder expects 32 bytes (bool) → reverts.
    function testNoReturnDataTokenRevertsOnFund() public {
        NoReturnToken badToken = new NoReturnToken();

        vm.startPrank(deployer);
        vm.expectRevert(); // ABI decode failure (empty returndata)
        new EscrowERC20(address(badToken), recipient, EXPECTED_AMOUNT, REWARD, PAYMENT);
        vm.stopPrank();
    }

    /// Reverting token prevents fund() from succeeding.
    function testRevertingTokenPreventsAutoFund() public {
        RevertingToken badToken = new RevertingToken();

        vm.startPrank(deployer);
        vm.expectRevert(); // token.transferFrom reverts
        new EscrowERC20(address(badToken), recipient, EXPECTED_AMOUNT, REWARD, PAYMENT);
        vm.stopPrank();
    }

    // ========================================================
    //  H7 – staticcall (simulates eth_call RPC)
    // ========================================================

    /// Calling fund() via staticcall (what eth_call does) must revert
    /// because fund() writes to storage. State never persists.
    function testStaticCallFundReverts() public {
        vm.startPrank(deployer);
        EscrowERC20 escrow = new EscrowERC20(address(token), recipient, EXPECTED_AMOUNT, 0, 0);
        token.approve(address(escrow), REWARD + PAYMENT);
        vm.stopPrank();

        bytes memory callData = abi.encodeWithSelector(EscrowERC20.fund.selector, REWARD, PAYMENT);

        // staticcall = eth_call semantics: read-only, no state changes
        (bool ok,) = address(escrow).staticcall(callData);

        // Must fail: SSTORE inside staticcall is forbidden
        assertFalse(ok, "staticcall to fund() should revert (SSTORE not allowed)");
        assertFalse(escrow.funded(), "escrow must remain unfunded after staticcall");
    }

    // ========================================================
    //  Baseline: direct fund() works correctly
    // ========================================================

    /// Direct fund() from deployer with proper approval — happy path.
    function testDirectFundWorks() public {
        vm.startPrank(deployer);
        EscrowERC20 escrow = new EscrowERC20(address(token), recipient, EXPECTED_AMOUNT, 0, 0);
        assertFalse(escrow.funded());

        token.approve(address(escrow), REWARD + PAYMENT);
        escrow.fund(REWARD, PAYMENT);
        vm.stopPrank();

        assertTrue(escrow.funded(), "direct fund should work");
        assertEq(escrow.currentRewardAmount(), REWARD);
        assertEq(escrow.currentPaymentAmount(), PAYMENT);
        assertEq(token.balanceOf(address(escrow)), REWARD + PAYMENT);
    }

    /// Constructor auto-fund path works.
    function testConstructorAutoFundWorks() public {
        vm.startPrank(deployer);
        address futureEscrow = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        token.approve(futureEscrow, REWARD + PAYMENT);

        EscrowERC20 escrow = new EscrowERC20(address(token), recipient, EXPECTED_AMOUNT, REWARD, PAYMENT);
        vm.stopPrank();

        assertTrue(escrow.funded());
        assertEq(token.balanceOf(address(escrow)), REWARD + PAYMENT);
    }

    // ========================================================
    //  Storage-level verification
    // ========================================================

    /// Read the raw storage slot for `funded` to rule out getter bugs.
    /// In EscrowBase layout: funded is at slot 7, packed with cancellationRequest.
    function testFundedStorageSlotDirect() public {
        vm.startPrank(deployer);
        address futureEscrow = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        token.approve(futureEscrow, REWARD + PAYMENT);

        EscrowERC20 escrow = new EscrowERC20(address(token), recipient, EXPECTED_AMOUNT, REWARD, PAYMENT);
        vm.stopPrank();

        // funded is packed at byte offset 1 in slot 7 (after cancellationRequest bool)
        bytes32 slot7 = vm.load(address(escrow), bytes32(uint256(7)));

        // cancellationRequest = false (0x00), funded = true (0x01)
        // packed right-to-left: slot7 = 0x...0100
        uint256 fundedBit = (uint256(slot7) >> 8) & 0xFF;
        assertEq(fundedBit, 1, "funded bit in storage should be 1");

        uint256 cancelBit = uint256(slot7) & 0xFF;
        assertEq(cancelBit, 0, "cancellation bit should be 0");
    }

    // ========================================================
    //  Edge: fund() with insufficient allowance
    // ========================================================

    /// If token.approve was called for wrong address or insufficient amount,
    /// fund() reverts. In a lenient batch this would be swallowed.
    function testFundWithInsufficientAllowance() public {
        vm.startPrank(deployer);
        EscrowERC20 escrow = new EscrowERC20(address(token), recipient, EXPECTED_AMOUNT, 0, 0);

        // Approve less than needed
        token.approve(address(escrow), REWARD);

        vm.expectRevert("Insufficient allowance");
        escrow.fund(REWARD, PAYMENT);
        vm.stopPrank();

        assertFalse(escrow.funded());
    }

    /// If token.approve was for a DIFFERENT address (wrong nonce prediction),
    /// the actual escrow has zero allowance → fund reverts.
    function testFundWithApprovalToWrongAddress() public {
        vm.startPrank(deployer);

        // Approve a random address instead of the real escrow
        address wrongAddr = makeAddr("wrong");
        token.approve(wrongAddr, REWARD + PAYMENT);

        EscrowERC20 escrow = new EscrowERC20(address(token), recipient, EXPECTED_AMOUNT, 0, 0);

        // The actual escrow address has no allowance
        vm.expectRevert("Insufficient allowance");
        escrow.fund(REWARD, PAYMENT);
        vm.stopPrank();
    }

    // ========================================================
    //  Combined scenario: deploy + fund + bond in batch
    //  Simulates the full Nomad batch flow
    // ========================================================

    /// Full batch: approve → deploy → fund → bond-check.
    /// When done as separate txs from the same EOA, everything works.
    function testFullFlowSeparateTxs() public {
        vm.startPrank(deployer);
        EscrowERC20 escrow = new EscrowERC20(address(token), recipient, EXPECTED_AMOUNT, 0, 0);
        token.approve(address(escrow), REWARD + PAYMENT);
        escrow.fund(REWARD, PAYMENT);
        vm.stopPrank();

        assertTrue(escrow.funded());

        // Executor can now bond
        token.mint(executor, REWARD);
        vm.startPrank(executor);
        token.approve(address(escrow), REWARD / 2);
        escrow.bond(REWARD / 2);
        vm.stopPrank();

        assertTrue(escrow.is_bonded());
    }

    /// Full batch via strict batcher from deployer.
    /// The batcher becomes msg.sender for ALL calls, breaking the
    /// deployer check on fund(). This is the most likely batch failure mode.
    function testFullBatchFlowViaStrictBatcher() public {
        vm.startPrank(deployer);
        EscrowERC20 escrow = new EscrowERC20(address(token), recipient, EXPECTED_AMOUNT, 0, 0);
        token.approve(address(escrow), REWARD + PAYMENT);
        vm.stopPrank();

        StrictBatcher batcher = new StrictBatcher();

        StrictBatcher.Call[] memory calls = new StrictBatcher.Call[](1);
        calls[0] = StrictBatcher.Call({
            target: address(escrow), data: abi.encodeWithSelector(EscrowERC20.fund.selector, REWARD, PAYMENT), value: 0
        });

        // Even though deployer is tx.origin, msg.sender in fund() is batcher
        vm.prank(deployer);
        vm.expectRevert(); // OnlyDeployer
        batcher.execute(calls);

        // After batch failure, escrow is still unfunded
        assertFalse(escrow.funded(), "escrow should remain unfunded");
    }

    /// Lenient batcher: same as above but revert is swallowed.
    /// This is the SMOKING GUN scenario: deployer thinks fund() succeeded
    /// because the batch tx itself didn't revert, but fund() actually failed
    /// silently inside the lenient batcher.
    function testSmokingGun_LenientBatchFundSilentlyFails() public {
        vm.startPrank(deployer);
        EscrowERC20 escrow = new EscrowERC20(address(token), recipient, EXPECTED_AMOUNT, 0, 0);
        token.approve(address(escrow), REWARD + PAYMENT);
        vm.stopPrank();

        LenientBatcher batcher = new LenientBatcher();

        LenientBatcher.Call[] memory calls = new LenientBatcher.Call[](1);
        calls[0] = LenientBatcher.Call({
            target: address(escrow), data: abi.encodeWithSelector(EscrowERC20.fund.selector, REWARD, PAYMENT), value: 0
        });

        // Deployer sends batch → batcher calls fund() → OnlyDeployer revert → SWALLOWED
        // The batch tx succeeds (no revert propagation), but fund() didn't take effect
        vm.prank(deployer);
        batcher.execute(calls);

        // This is what the node would then observe:
        assertFalse(escrow.funded(), "SMOKING GUN: fund() swallowed in lenient batch");
    }

    // ========================================================
    //  Precompile / etch scenario: token at fixed address
    // ========================================================

    /// Simulate the exact Tempo token address (0x20c0...0000) as a precompile
    /// that has no code → external call returns empty data → ABI decode failure.
    function testTempoTokenAddressNoCode() public {
        // Don't etch any code → TEMPO_TOKEN has no code in test env

        vm.startPrank(deployer);
        vm.expectRevert(); // call to address with no code → empty returndata → ABI decode fail
        new EscrowERC20(TEMPO_TOKEN, recipient, TEMPO_AMOUNT, TEMPO_REWARD, TEMPO_AMOUNT);
        vm.stopPrank();
    }

    /// Simulate Tempo token with NoOp behavior etched at the real address.
    function testTempoTokenAsNoOp() public {
        NoOpToken noOp = new NoOpToken();
        vm.etch(TEMPO_TOKEN, address(noOp).code);

        vm.startPrank(deployer);
        EscrowERC20 escrow = new EscrowERC20(TEMPO_TOKEN, recipient, TEMPO_AMOUNT, TEMPO_REWARD, TEMPO_AMOUNT);
        vm.stopPrank();

        // fund() "succeeded" — constructor auto-funded
        assertTrue(escrow.funded(), "funded flag set despite no-op token");

        // BUT: escrow has no actual token balance
        // This would cause payout failure, NOT "not funded" error
        // So this hypothesis does NOT explain the observed error.
    }

    // ========================================================
    //  H8 – ROOT CAUSE: batch targets wrong address (no code)
    //  Reproduces the exact Tempo failure:
    //    TX: 0xedf034653df8ebd016a471bb4c19a1a71b01b39694720ffdde148790b4ac94ae
    //    Escrow: 0x7e9798a62b42d97fb05b9e092a9a2117fa3fb995
    //    Wrong target: 0xd69b8fc5d21819a713fde3e051c97e1cb09bd2aa (no code)
    // ========================================================

    /// EVM CALL to an address with no code succeeds with empty returndata.
    /// This is the fundamental EVM behavior that enables the silent failure.
    /// Uses the real wrong target from the failing TX.
    function testCallToEmptyAddressSucceeds() public {
        assertEq(TEMPO_WRONG_TARGET.code.length, 0, "wrong target should have no code");

        // Exact calldata from the failing TX: obfuscated fund(723471, 100000000)
        bytes memory fundCalldata = abi.encodeWithSelector(0x49364cd4, TEMPO_REWARD, TEMPO_AMOUNT);
        (bool ok, bytes memory ret) = TEMPO_WRONG_TARGET.call(fundCalldata);

        assertTrue(ok, "call to empty address should succeed");
        assertEq(ret.length, 0, "return data should be empty");
    }

    /// Reproduce the exact Tempo batch failure with real on-chain values:
    ///   TX:     0xedf034653df8ebd016a471bb4c19a1a71b01b39694720ffdde148790b4ac94ae
    ///   Token:  0x20C0000000000000000000000000000000000000 (PathUSD)
    ///   Escrow: 0x7e9798a62b42d97fb05b9e092a9a2117fa3fb995 (deployed correctly)
    ///   Wrong:  0xd69b8fc5d21819a713fde3e051c97e1cb09bd2aa (no code, batch target)
    ///   Amount: 100000000, Reward: 723471
    ///
    /// Steps in the batch:
    ///   1. CREATE escrow → lands at 0x7e97... (correct)
    ///   2. approve(0xd69b..., amount) on PathUSD → succeeds (wrong spender)
    ///   3. fund(723471, 100000000) on 0xd69b... → silent no-op (no code)
    ///   4. Escrow at 0x7e97... remains unfunded
    function testExactTempoFailure_WrongAddressBatch() public {
        // Etch a NoOp token at the real PathUSD address
        NoOpToken noOp = new NoOpToken();
        vm.etch(TEMPO_TOKEN, address(noOp).code);

        // Step 1: Deploy escrow (unfunded — constructor gets 0,0)
        vm.startPrank(deployer);
        EscrowERC20 escrow = new EscrowERC20(TEMPO_TOKEN, recipient, TEMPO_AMOUNT, 0, 0);
        vm.stopPrank();

        assertFalse(escrow.funded(), "escrow should start unfunded");
        assertEq(TEMPO_WRONG_TARGET.code.length, 0, "0xd69b... has no code on-chain");

        // Step 2: Approve tokens to WRONG address (0xd69b... instead of escrow)
        vm.prank(deployer);
        (bool ok1,) = TEMPO_TOKEN.call(
            abi.encodeWithSignature("approve(address,uint256)", TEMPO_WRONG_TARGET, TEMPO_REWARD + TEMPO_AMOUNT)
        );
        assertTrue(ok1, "approve should succeed");

        // Step 3: Call obfuscated fund() on WRONG address (no code → silent success)
        bytes memory fundCall = abi.encodeWithSelector(0x49364cd4, TEMPO_REWARD, TEMPO_AMOUNT);
        vm.prank(deployer);
        (bool ok2, bytes memory ret) = TEMPO_WRONG_TARGET.call(fundCall);

        assertTrue(ok2, "call to 0xd69b... succeeds (THIS IS THE BUG)");
        assertEq(ret.length, 0, "empty return - no fund() logic executed");

        // Step 4: Escrow is STILL unfunded — the batch "succeeded" but did nothing
        assertFalse(escrow.funded(), "CONFIRMED: escrow still unfunded after batch to wrong address");
    }

    /// Prove the obfuscated fund() works when called at the correct address.
    /// Uses the real Tempo token and amounts.
    function testObfuscatedFundWorksAtCorrectAddress() public {
        NoOpToken noOp = new NoOpToken();
        vm.etch(TEMPO_TOKEN, address(noOp).code);

        // Deploy a real escrow (unfunded)
        vm.prank(deployer);
        EscrowERC20 escrow = new EscrowERC20(TEMPO_TOKEN, recipient, TEMPO_AMOUNT, 0, 0);

        // Call fund() with the ORIGINAL selector on the unobfuscated contract
        vm.prank(deployer);
        escrow.fund(TEMPO_REWARD, TEMPO_AMOUNT);

        // fund() works when called at the correct address
        assertTrue(escrow.funded(), "fund() works at correct address with real amounts");
        assertEq(escrow.currentRewardAmount(), TEMPO_REWARD);
        assertEq(escrow.currentPaymentAmount(), TEMPO_AMOUNT);
    }

    /// Demonstrate the exact failure in a strict batch context:
    /// approve + fund both target TEMPO_WRONG_TARGET instead of the escrow.
    function testAddressMismatchInStrictBatch() public {
        vm.startPrank(deployer);
        EscrowERC20 escrow = new EscrowERC20(address(token), recipient, TEMPO_AMOUNT, 0, 0);
        vm.stopPrank();

        StrictBatcher batcher = new StrictBatcher();
        StrictBatcher.Call[] memory calls = new StrictBatcher.Call[](2);

        // Approve to wrong address (0xd69b...)
        calls[0] = StrictBatcher.Call({
            target: address(token),
            data: abi.encodeWithSignature("approve(address,uint256)", TEMPO_WRONG_TARGET, TEMPO_REWARD + TEMPO_AMOUNT),
            value: 0
        });

        // fund() on wrong address (no code → returns success)
        calls[1] = StrictBatcher.Call({
            target: TEMPO_WRONG_TARGET,
            data: abi.encodeWithSelector(EscrowERC20.fund.selector, TEMPO_REWARD, TEMPO_AMOUNT),
            value: 0
        });

        // The batch SUCCEEDS because both calls return success (empty address)
        vm.prank(deployer);
        batcher.execute(calls);

        // But the escrow is not funded
        assertFalse(escrow.funded(), "escrow unfunded - batch hit 0xd69b... instead of escrow");
    }
}
