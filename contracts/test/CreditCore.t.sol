// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CreditCore} from "../src/cc3/CreditCore.sol";
import {LPPool} from "../src/cc3/LPPool.sol";
import {INativeQueryVerifier} from "../src/cc3/INativeQueryVerifier.sol";
import {MockNativeQueryVerifier} from "./TruthGateBase.t.sol";

contract CreditCoreTest is Test {
    address constant PRECOMPILE = 0x0000000000000000000000000000000000000FD2;
    address constant VAULT_ON_SEPOLIA = address(0x5EF0);
    address constant LOANBOOK_ON_SEPOLIA = address(0x10AB);
    address constant BRIDGE = address(0xB41D);
    address constant BURN = address(0xdEaD);

    address alice = address(0xA11CE); // LP
    address bob = address(0xB0B); // borrower (same address on Sepolia and CC3)

    MockNativeQueryVerifier mock;
    LPPool pool;
    CreditCore core;

    // Local copies of the signatures: helpers must not make external calls to core,
    // otherwise vm.expectRevert latches onto the getter call instead of execute.
    bytes32 constant DEPOSIT_SIG = keccak256("FundsDeposited(address,uint256,uint256)");
    bytes32 constant REPAY_SIG = keccak256("LoanRepaidOnEth(address,uint256,uint256)");
    bytes32 constant LIQUIDATION_SIG = keccak256("LiquidationCall(address,address,address,uint256,uint256,address,bool)");

    // Layout-identical to EvmV1Decoder.LogEntryTuple: (address, bytes32[], bytes)
    struct LogTuple {
        address address_;
        bytes32[] topics;
        bytes data;
    }

    function setUp() public {
        vm.etch(PRECOMPILE, address(new MockNativeQueryVerifier()).code);
        mock = MockNativeQueryVerifier(PRECOMPILE);

        pool = new LPPool();
        core = new CreditCore(payable(address(pool)), 0, 0); // 0,0 → production defaults 100k/25k
        pool.setCreditCore(address(core));
        core.registerVaultOnSepolia(VAULT_ON_SEPOLIA);
        core.registerLoanBookOnSepolia(LOANBOOK_ON_SEPOLIA);
        core.setRepaymentBridge(BRIDGE);

        vm.deal(alice, 1000 ether);
        vm.prank(alice);
        pool.stake{value: 100 ether}();
    }

    // ---------- encoding helpers (EvmV1: abi.encode(uint8 txType, bytes[] chunks)) ----------

    function _encodeTx(uint8 receiptStatus, LogTuple[] memory logs) internal pure returns (bytes memory) {
        bytes memory chunk0 =
            abi.encode(uint64(1), uint64(100_000), address(0x1), false, address(0x2), uint256(0), bytes(""));
        bytes memory chunk2 = abi.encode(receiptStatus, uint64(50_000), logs, bytes(""));

        bytes[] memory chunks = new bytes[](3);
        chunks[0] = chunk0;
        chunks[1] = "";
        chunks[2] = chunk2;
        return abi.encode(uint8(2), chunks);
    }

    function _depositTx(address emitter, address depositor, uint256 amount, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        LogTuple[] memory logs = new LogTuple[](1);
        logs[0].address_ = emitter;
        logs[0].topics = new bytes32[](2);
        logs[0].topics[0] = DEPOSIT_SIG;
        logs[0].topics[1] = bytes32(uint256(uint160(depositor)));
        logs[0].data = abi.encode(amount, nonce);
        return _encodeTx(1, logs);
    }

    function _repayOnEthTx(address emitter, address borrower, uint256 loanId, uint256 amount)
        internal
        view
        returns (bytes memory)
    {
        LogTuple[] memory logs = new LogTuple[](1);
        logs[0].address_ = emitter;
        logs[0].topics = new bytes32[](2);
        logs[0].topics[0] = REPAY_SIG;
        logs[0].topics[1] = bytes32(uint256(uint160(borrower)));
        logs[0].data = abi.encode(loanId, amount);
        return _encodeTx(1, logs);
    }

    /// @dev Aave v3 LiquidationCall layout: 4 topics (collateralAsset, debtAsset,
    /// user indexed), data = abi.encode(debtToCover, liquidatedCollateralAmount,
    /// liquidator, receiveAToken) — matches LoanBookSim / the real Aave event.
    function _liquidationTx(address emitter, address user, uint256 debtToCover)
        internal
        view
        returns (bytes memory)
    {
        LogTuple[] memory logs = new LogTuple[](1);
        logs[0].address_ = emitter;
        logs[0].topics = new bytes32[](4);
        logs[0].topics[0] = LIQUIDATION_SIG;
        logs[0].topics[1] = bytes32(uint256(uint160(address(0xC01A)))); // collateralAsset
        logs[0].topics[2] = bytes32(uint256(uint160(address(0xDEB7)))); // debtAsset
        logs[0].topics[3] = bytes32(uint256(uint160(user)));
        logs[0].data = abi.encode(debtToCover, uint256(0.2 ether), address(0x11C0), false);
        return _encodeTx(1, logs);
    }

    function _execute(uint8 action, uint64 height, bytes memory encodedTx) internal returns (bool) {
        return _executeOn(core, action, height, encodedTx);
    }

    function _executeOn(CreditCore target, uint8 action, uint64 height, bytes memory encodedTx)
        internal
        returns (bool)
    {
        INativeQueryVerifier.MerkleProofEntry[] memory siblings = new INativeQueryVerifier.MerkleProofEntry[](0);
        bytes32[] memory roots = new bytes32[](0);
        return target.execute(action, 1, height, encodedTx, bytes32("root"), siblings, bytes32("digest"), roots);
    }

    function _proveDeposit(uint256 amount, uint64 height) internal {
        _execute(0, height, _depositTx(VAULT_ON_SEPOLIA, bob, amount, 1));
    }

    function _ethScore(address who) internal view returns (uint256 s) {
        (s, , , , ) = core.borrowers(who);
    }

    // ---------- scoring ----------

    function test_eventSignatureConstants() public view {
        assertEq(core.DEPOSIT_EVENT_SIGNATURE(), keccak256("FundsDeposited(address,uint256,uint256)"));
        assertEq(core.REPAY_EVENT_SIGNATURE(), keccak256("LoanRepaidOnEth(address,uint256,uint256)"));
    }

    function test_scoreGrowsOnlyViaValidProof() public {
        assertEq(_ethScore(bob), 0);

        // an event with the right signature but from a foreign contract does not count
        vm.expectRevert("log from unexpected source contract");
        _execute(0, 100, _depositTx(address(0xDEAD00), bob, 1 ether, 1));
        assertEq(_ethScore(bob), 0);

        // a repayment event submitted under action=ScoreDeposit — the signature will not match
        vm.expectRevert("No events of required type found");
        _execute(0, 101, _repayOnEthTx(LOANBOOK_ON_SEPOLIA, bob, 1, 1 ether));
        assertEq(_ethScore(bob), 0);

        // a valid deposit proof
        _proveDeposit(1 ether, 102);
        assertEq(_ethScore(bob), 1 ether);

        // a valid proof of repayment on Sepolia: score += amount + flat bonus
        _execute(1, 103, _repayOnEthTx(LOANBOOK_ON_SEPOLIA, bob, 7, 0.5 ether));
        assertEq(_ethScore(bob), 1.6 ether); // 1 + 0.5 + 0.1
    }

    function test_depositCirculationCappedByScoreCap() public {
        // score farming by circulation: three deposits of the same funds (deposit →
        // withdraw → deposit) — the total deposit contribution never exceeds DEPOSIT_SCORE_CAP
        _proveDeposit(1 ether, 300);
        _proveDeposit(1 ether, 301);
        _proveDeposit(1 ether, 302); // over the cap: verifies, but does not grow the score
        assertEq(_ethScore(bob), core.DEPOSIT_SCORE_CAP());
        assertEq(core.depositScoreOf(bob), core.DEPOSIT_SCORE_CAP());

        // repayments are not limited by the cap
        _execute(1, 303, _repayOnEthTx(LOANBOOK_ON_SEPOLIA, bob, 7, 1 ether));
        assertEq(_ethScore(bob), core.DEPOSIT_SCORE_CAP() + 1.1 ether);
    }

    function test_replayedScoreProofDoesNotDoubleScore() public {
        mock.setTxIndex(5);
        _proveDeposit(1 ether, 200);
        assertEq(_ethScore(bob), 1 ether);

        // same height + same txIndex → same queryId → replay rejected by the base
        vm.expectRevert("Query already processed");
        _proveDeposit(1 ether, 200);
        assertEq(_ethScore(bob), 1 ether);
    }

    function test_freshnessWindowAppliesToScoring() public {
        core.setMinAcceptedHeight(1000);

        vm.expectRevert("proof below min accepted height");
        _proveDeposit(1 ether, 999);

        _proveDeposit(1 ether, 1000);
        assertEq(_ethScore(bob), 1 ether);
    }

    // ---------- liquidation penalty ----------

    function test_liquidationPenalty_flatEscalatingAndCapped() public {
        _proveDeposit(1 ether, 500); // ethScore 1 ETH → limit 5 + 0.99×10 = 14.9
        uint256 limitBefore = core.creditLimit(bob);
        assertEq(limitBefore, 14.9 ether);

        // The penalty is per-event, NOT amount-proportional: debtToCover is in an
        // arbitrary reserve token and its magnitude must not matter. First proof
        // carries a "500 USDC"-scale amount (6 decimals) → flat −1 CTC.
        _execute(2, 501, _liquidationTx(LOANBOOK_ON_SEPOLIA, bob, 500e6));
        assertEq(core.creditLimit(bob), limitBefore - core.LIQUIDATION_PENALTY_FIRST());

        // Second proof carries a "500 DAI"-scale amount (18 decimals, 1e12× larger) —
        // identical economics, escalated flat −2 CTC (repeat offense).
        _execute(2, 502, _liquidationTx(LOANBOOK_ON_SEPOLIA, bob, 500e18));
        assertEq(core.creditLimit(bob), limitBefore - 3 ether); // 1 + 2

        // Third proof: another −2 → total 5 == LIQUIDATION_PENALTY_CAP
        _execute(2, 503, _liquidationTx(LOANBOOK_ON_SEPOLIA, bob, 1));
        assertEq(core.creditLimit(bob), limitBefore - core.LIQUIDATION_PENALTY_CAP());

        // Fourth proof: total cap reached — verifies, emits, but adds nothing
        _execute(2, 504, _liquidationTx(LOANBOOK_ON_SEPOLIA, bob, 1_000_000 ether));
        assertEq(core.creditLimit(bob), limitBefore - core.LIQUIDATION_PENALTY_CAP());

        // ethScore is untouched — the penalty is a separate counter
        assertEq(_ethScore(bob), 1 ether);
        (, , , , uint256 penalty) = core.borrowers(bob);
        assertEq(penalty, core.LIQUIDATION_PENALTY_CAP());

        // wrong log shape (a 2-topic event forged under the liquidation signature) reverts
        LogTuple[] memory logs = new LogTuple[](1);
        logs[0].address_ = LOANBOOK_ON_SEPOLIA;
        logs[0].topics = new bytes32[](2);
        logs[0].topics[0] = LIQUIDATION_SIG;
        logs[0].topics[1] = bytes32(uint256(uint160(bob)));
        logs[0].data = abi.encode(uint256(1 ether), uint256(0), address(0), false);
        vm.expectRevert("Invalid LiquidationCall topics");
        _execute(2, 505, _encodeTx(1, logs));
    }

    /// The no-hard-block guard: liquidation proofs degrade, never lock out.
    /// (1) the penalized bonus floors at 0; (2) BASE_LIMIT always survives;
    /// (3) borrowing against the base still works after adversarial liquidation spam.
    function test_liquidationNeverHardBlocks_baseLimitAndBorrowSurvive() public {
        // established borrower with a modest earned bonus above the base
        _proveDeposit(0.05 ether, 600); // ethScore 0.05 → limit 5 + 0.4 = 5.4
        assertEq(core.creditLimit(bob), 5.4 ether);

        // adversarial third party proves five liquidations with arbitrary huge amounts
        for (uint64 i; i < 5; i++) {
            _execute(2, 601 + i, _liquidationTx(LOANBOOK_ON_SEPOLIA, bob, 1000 ether));
        }

        // accumulated penalty (1+2+2 = 5 CTC, the total cap) dwarfs the bonus
        // (0.4 CTC), but the clamp floors the penalized bonus at 0: the limit is
        // exactly BASE_LIMIT, never below — degraded score, base still available
        assertEq(core.creditLimit(bob), core.BASE_LIMIT());

        // and borrowing against the base limit still works — degraded, not locked out
        vm.prank(bob);
        uint256 loanId = core.borrow(1 ether);
        assertEq(loanId, 1);
        (, , uint256 openDebt, , ) = core.borrowers(bob);
        assertEq(openDebt, 1.05 ether);
    }

    // ---------- borrow ----------

    function test_borrowOverLimitReverts() public {
        // ethScore = 1 ETH → limit = 5 + 9.9 = 14.9 CTC
        _proveDeposit(1 ether, 100);
        assertEq(core.creditLimit(bob), 14.9 ether);

        // 15 CTC + 5% interest = 15.75 > 14.9
        vm.prank(bob);
        vm.expectRevert("over credit limit");
        core.borrow(15 ether);

        // without scoring the limit is zero
        vm.prank(alice);
        vm.expectRevert("over credit limit");
        core.borrow(1);
    }

    function test_fullCycle_pathA_withBurn() public {
        _proveDeposit(1 ether, 100);

        vm.prank(bob);
        uint256 loanId = core.borrow(10 ether);

        // CTC reached the borrower, the pool reserved the principal
        assertEq(bob.balance, 10 ether);
        assertEq(address(pool).balance, 90 ether);
        assertEq(pool.outstandingPrincipal(), 10 ether);
        (, , uint256 openDebt, , ) = core.borrowers(bob);
        assertEq(openDebt, 10.5 ether); // principal + 5%

        // full repayment via path A
        vm.deal(bob, 10.5 ether);
        vm.prank(bob);
        core.repayInCTC{value: 10.5 ether}(loanId);

        // burn: 10% of the 0.5 interest part = 0.05; pool: 90 + 10 + 0.45
        assertEq(BURN.balance, 0.05 ether);
        assertEq(address(pool).balance, 100.45 ether);
        assertEq(pool.outstandingPrincipal(), 0);

        (, , , uint256 repaid, , , CreditCore.LoanStatus status, ) = core.loans(loanId);
        assertEq(repaid, 10.5 ether);
        assertEq(uint8(status), uint8(CreditCore.LoanStatus.Repaid));

        // repayment in the origination block: the loan is closed, but localScore does
        // not grow — held shorter than MIN_HOLD_BLOCKS (see the "localScore: anti score-farming" section)
        (, uint256 localScore, uint256 debtAfter, uint256 completed, ) = core.borrowers(bob);
        assertEq(localScore, 0);
        assertEq(debtAfter, 0);
        assertEq(completed, 1);
        assertEq(core.openLoansOf(bob).length, 0);
    }

    function test_partialRepayments() public {
        _proveDeposit(1 ether, 100);
        vm.prank(bob);
        uint256 loanId = core.borrow(10 ether);

        vm.deal(bob, 10.5 ether);

        vm.prank(bob);
        core.repayInCTC{value: 4 ether}(loanId);
        (, , , uint256 repaid1, , , CreditCore.LoanStatus st1, ) = core.loans(loanId);
        assertEq(repaid1, 4 ether);
        assertEq(uint8(st1), uint8(CreditCore.LoanStatus.PartlyRepaid));
        assertEq(pool.outstandingPrincipal(), 6 ether); // principal is repaid first

        vm.prank(bob);
        core.repayInCTC{value: 6.5 ether}(loanId);
        (, , , uint256 repaid2, , , CreditCore.LoanStatus st2, ) = core.loans(loanId);
        assertEq(repaid2, 10.5 ether);
        assertEq(uint8(st2), uint8(CreditCore.LoanStatus.Repaid));
        assertEq(pool.outstandingPrincipal(), 0);
        assertEq(BURN.balance, 0.05 ether); // burned only from the interest part

        // overpaying beyond the outstanding amount reverts
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert("invalid loan status");
        core.repayInCTC{value: 1 ether}(loanId);
    }

    // ---------- path B ----------

    function test_bridgeRepayment_onlyBridge() public {
        _proveDeposit(1 ether, 100);
        vm.prank(bob);
        uint256 loanId = core.borrow(10 ether);

        vm.prank(bob);
        vm.expectRevert("not RepaymentBridge");
        core.creditRepaymentFromBridge(loanId, 1 ether);

        vm.prank(BRIDGE);
        core.creditRepaymentFromBridge(loanId, 3 ether);

        (, , , uint256 repaid, uint256 usdcShare, , CreditCore.LoanStatus status, ) = core.loans(loanId);
        assertEq(repaid, 3 ether);
        assertEq(usdcShare, 3 ether);
        assertEq(uint8(status), uint8(CreditCore.LoanStatus.PartlyRepaid));

        // No CTC moved: the pool balance and outstanding are unchanged. Outstanding
        // is released later — via LPPool.settle when the SwapDesk sells the wUSDC
        // (see RepaymentBridge.t.sol)
        assertEq(address(pool).balance, 90 ether);
        assertEq(pool.outstandingPrincipal(), 10 ether);

        (, , uint256 openDebt, , ) = core.borrowers(bob);
        assertEq(openDebt, 7.5 ether);
    }

    function test_bridgeRepayment_completesLoanAndGrowsLocalScore() public {
        _proveDeposit(1 ether, 100);
        vm.prank(bob);
        uint256 loanId = core.borrow(10 ether);

        vm.deal(bob, 8 ether);
        vm.prank(bob);
        core.repayInCTC{value: 8 ether}(loanId);

        // the closing payment is path B at full term: heldBlocks is measured by the
        // CC3 block of proof delivery, same formula as for path A
        vm.roll(block.number + core.LOAN_DURATION_BLOCKS());
        vm.prank(BRIDGE);
        core.creditRepaymentFromBridge(loanId, 2.5 ether);

        (, , , uint256 repaid, uint256 usdcShare, , CreditCore.LoanStatus status, ) = core.loans(loanId);
        assertEq(repaid, 10.5 ether);
        assertEq(usdcShare, 2.5 ether);
        assertEq(uint8(status), uint8(CreditCore.LoanStatus.Repaid));

        // principal of 10 CTC over the full term → 10/4.5 ≈ 2.22 units of localScore
        (, uint256 localScore, , uint256 completed, ) = core.borrowers(bob);
        assertEq(localScore, (uint256(10 ether) * 1 ether) / core.LOCAL_SCORE_NORM_PRINCIPAL());
        assertEq(completed, 1);
    }

    // ---------- localScore: anti score-farming ----------

    function test_instantCycleFarming_noScoreNoLimitGrowth() public {
        _proveDeposit(1 ether, 100);
        uint256 limitBefore = core.creditLimit(bob); // 14.9 CTC

        // attack: 20 cycles of "borrow the minimum — repay in the same block".
        // The old model would grant +20 localScore = +20 CTC of limit for ~0.001 CTC of interest
        vm.deal(bob, 1 ether);
        for (uint256 i; i < 20; i++) {
            vm.prank(bob);
            uint256 id = core.borrow(0.001 ether);
            vm.prank(bob);
            core.repayInCTC{value: 0.00105 ether}(id);
        }

        (, uint256 localScore, , uint256 completed, ) = core.borrowers(bob);
        assertEq(localScore, 0);
        assertEq(core.creditLimit(bob), limitBefore);
        assertEq(completed, 20); // informational counter, not part of the limit
    }

    function test_fullTermRepayment_matchesOldModelScale() public {
        _proveDeposit(1 ether, 100);
        uint256 limitBefore = core.creditLimit(bob);

        vm.prank(bob);
        uint256 id = core.borrow(4.5 ether);

        // exactly the deadline: block.number == deadlineBlock — not overdue yet
        vm.roll(block.number + core.LOAN_DURATION_BLOCKS());
        vm.deal(bob, 4.725 ether);
        vm.prank(bob);
        core.repayInCTC{value: 4.725 ether}(id);

        // the normalization principal over the full term → exactly 1 unit,
        // limit growth of +1 CTC — like the "+1 per repayment" of the old model
        (, uint256 localScore, , , ) = core.borrowers(bob);
        assertEq(localScore, 1 ether);
        assertEq(core.creditLimit(bob), limitBefore + core.LOCAL_SCORE_K());
    }

    function test_halfTermRepayment_givesHalfScore() public {
        _proveDeposit(1 ether, 100);

        vm.prank(bob);
        uint256 id = core.borrow(4.5 ether);
        vm.roll(block.number + core.LOAN_DURATION_BLOCKS() / 2);
        vm.deal(bob, 4.725 ether);
        vm.prank(bob);
        core.repayInCTC{value: 4.725 ether}(id);

        (, uint256 localScore, , , ) = core.borrowers(bob);
        assertEq(localScore, 0.5 ether);
    }

    function test_minHoldBoundary() public {
        _proveDeposit(1 ether, 100);
        vm.deal(bob, 9.45 ether);

        // one block before the threshold — repayment goes through, score stays zero
        vm.prank(bob);
        uint256 id1 = core.borrow(4.5 ether);
        vm.roll(block.number + core.MIN_HOLD_BLOCKS() - 1);
        vm.prank(bob);
        core.repayInCTC{value: 4.725 ether}(id1);
        (, uint256 s1, , , ) = core.borrowers(bob);
        assertEq(s1, 0);

        // exactly at the threshold — a quarter of the full score (MIN_HOLD = term/4)
        vm.prank(bob);
        uint256 id2 = core.borrow(4.5 ether);
        vm.roll(block.number + core.MIN_HOLD_BLOCKS());
        vm.prank(bob);
        core.repayInCTC{value: 4.725 ether}(id2);
        (, uint256 s2, , , ) = core.borrowers(bob);
        assertEq(s2, 0.25 ether);
    }

    function test_constructorDefaults_and_minHoldValidation() public {
        // sentinel 0,0 → production defaults
        assertEq(core.LOAN_DURATION_BLOCKS(), core.DEFAULT_LOAN_DURATION_BLOCKS());
        assertEq(core.MIN_HOLD_BLOCKS(), core.DEFAULT_MIN_HOLD_BLOCKS());

        // the threshold cannot exceed the term
        vm.expectRevert("min hold exceeds duration");
        new CreditCore(payable(address(pool)), 240, 241);
    }

    /// Scale similarity under term compression (demo deploy 240/60 vs production 100k/25k):
    /// localScore growth depends on the FRACTION of the term the loan was held, not on
    /// the absolute duration — the same fraction yields the same score on both parameter sets.
    function test_scoreScaleInvariantUnderCompressedSchedule() public {
        LPPool demoPool = new LPPool();
        CreditCore demo = new CreditCore(payable(address(demoPool)), 240, 60);
        demoPool.setCreditCore(address(demo));
        demo.registerVaultOnSepolia(VAULT_ON_SEPOLIA);
        demo.registerLoanBookOnSepolia(LOANBOOK_ON_SEPOLIA);
        vm.prank(alice);
        demoPool.stake{value: 100 ether}();

        // identical ethScore on both cores (each has its own processedQueries)
        _proveDeposit(1 ether, 100);
        _executeOn(demo, 0, 100, _depositTx(VAULT_ON_SEPOLIA, bob, 1 ether, 1));

        vm.deal(bob, 20 ether);

        // half the term: production 50_000 blocks, demo 120 blocks → identical 0.5 units
        vm.prank(bob);
        uint256 idProd = core.borrow(4.5 ether);
        vm.roll(block.number + core.LOAN_DURATION_BLOCKS() / 2);
        vm.prank(bob);
        core.repayInCTC{value: 4.725 ether}(idProd);

        vm.prank(bob);
        uint256 idDemo = demo.borrow(4.5 ether);
        vm.roll(block.number + demo.LOAN_DURATION_BLOCKS() / 2);
        vm.prank(bob);
        demo.repayInCTC{value: 4.725 ether}(idDemo);

        (, uint256 sProd, , , ) = core.borrowers(bob);
        (, uint256 sDemo, , , ) = demo.borrowers(bob);
        assertEq(sProd, sDemo);
        assertEq(sDemo, 0.5 ether);

        // full term: another +1 unit on both
        vm.prank(bob);
        uint256 idProd2 = core.borrow(4.5 ether);
        vm.roll(block.number + core.LOAN_DURATION_BLOCKS());
        vm.prank(bob);
        core.repayInCTC{value: 4.725 ether}(idProd2);

        vm.prank(bob);
        uint256 idDemo2 = demo.borrow(4.5 ether);
        vm.roll(block.number + demo.LOAN_DURATION_BLOCKS());
        vm.prank(bob);
        demo.repayInCTC{value: 4.725 ether}(idDemo2);

        (, sProd, , , ) = core.borrowers(bob);
        (, sDemo, , , ) = demo.borrowers(bob);
        assertEq(sProd, sDemo);
        assertEq(sDemo, 1.5 ether);

        // and the limits grew identically
        assertEq(core.creditLimit(bob), demo.creditLimit(bob));
    }

    // ---------- LP pool ----------

    function test_expiredLoanRehabilitation() public {
        _proveDeposit(1 ether, 100);
        vm.prank(bob);
        uint256 loanId = core.borrow(10 ether);

        // overdue: the deadline has passed, the owner marks the loan Expired
        vm.roll(block.number + core.LOAN_DURATION_BLOCKS() + 1);
        core.markLoanAsExpired(loanId);

        // an Expired loan blocks new borrows
        vm.prank(bob);
        vm.expectRevert("overdue loan outstanding");
        core.borrow(1 ether);

        // penalty rate: interestDue 0.5 * 1.5 = 0.75 → totalDue 10.75
        assertEq(core.totalDueFor(loanId), 10.75 ether);

        // repayment without the penalty does not close the loan (stays Expired)
        vm.deal(bob, 10.75 ether);
        vm.prank(bob);
        core.repayInCTC{value: 10.5 ether}(loanId);
        (, , , , , , CreditCore.LoanStatus stMid, ) = core.loans(loanId);
        assertEq(uint8(stMid), uint8(CreditCore.LoanStatus.Expired));

        // paying the penalty on top closes the loan
        vm.prank(bob);
        core.repayInCTC{value: 0.25 ether}(loanId);
        (, , , uint256 repaid, , , CreditCore.LoanStatus st, ) = core.loans(loanId);
        assertEq(repaid, 10.75 ether);
        assertEq(uint8(st), uint8(CreditCore.LoanStatus.Repaid));

        // rehabilitation: borrow is unblocked, but localScore/loansCompleted did not grow
        (, uint256 localScore, uint256 openDebt, uint256 completed, ) = core.borrowers(bob);
        assertEq(localScore, 0);
        assertEq(completed, 0);
        assertEq(openDebt, 0);
        assertEq(core.openLoansOf(bob).length, 0);

        vm.prank(bob);
        core.borrow(1 ether); // passes
    }

    function test_unstakeBlockedByReservedLiquidity() public {
        // large score via repayments (deposits are capped): 1 + (9 + 0.1) = 10.1 ETH
        _proveDeposit(1 ether, 100);
        _execute(1, 101, _repayOnEthTx(LOANBOOK_ON_SEPOLIA, bob, 1, 9 ether));

        vm.prank(bob);
        core.borrow(95 ether); // 5 free CTC remain in the pool

        // alice owns 100% of the shares (assets 100), but only 5 are free
        vm.prank(alice);
        vm.expectRevert("liquidity reserved for open loans");
        pool.unstake(100 ether);

        // partial withdrawal within the free liquidity passes
        uint256 before = alice.balance;
        vm.prank(alice);
        pool.unstake(5 ether);
        assertEq(alice.balance - before, 5 ether);
    }
}
