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
    uint256 constant LOANBOOK_BOND = 10 ether;

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
        // v4 tiered registry: the vault is a Verified source; the loan-book sim is
        // BONDED with a real stake (mirrors the live deployment plan — it is no
        // longer silently trusted)
        core.registerVerifiedSource(VAULT_ON_SEPOLIA);
        vm.deal(address(this), 100 ether);
        core.registerBondedSource{value: LOANBOOK_BOND}(LOANBOOK_ON_SEPOLIA);
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

    bytes32 constant RP_DEPOSIT_SIG = keccak256("DepositReceived(address,uint256,uint256)");
    bytes32 constant EIGEN_DEPOSIT_SIG = keccak256("Deposit(address,address,uint256)");
    address constant ROCKET_POOL_SOURCE = address(0x40C4E7);
    address constant EIGEN_SOURCE = address(0xE16E4);

    /// @dev Rocket Pool DepositReceived layout: 2 topics (from indexed),
    /// data = abi.encode(amount, time); amount is native ETH (msg.value).
    function _rocketDepositTx(address emitter, address from, uint256 amount)
        internal
        view
        returns (bytes memory)
    {
        LogTuple[] memory logs = new LogTuple[](1);
        logs[0].address_ = emitter;
        logs[0].topics = new bytes32[](2);
        logs[0].topics[0] = RP_DEPOSIT_SIG;
        logs[0].topics[1] = bytes32(uint256(uint160(from)));
        logs[0].data = abi.encode(amount, uint256(1_777_000_000));
        return _encodeTx(1, logs);
    }

    /// @dev EigenLayer Deposit layout (current, slashing-era): ONE topic — nothing
    /// indexed — data = abi.encode(staker, strategy, shares).
    function _eigenDepositTx(address emitter, address staker, uint256 shares)
        internal
        view
        returns (bytes memory)
    {
        LogTuple[] memory logs = new LogTuple[](1);
        logs[0].address_ = emitter;
        logs[0].topics = new bytes32[](1);
        logs[0].topics[0] = EIGEN_DEPOSIT_SIG;
        logs[0].data = abi.encode(staker, address(0x5717), shares);
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
        (s, , , , , ) = core.borrowers(who);
    }

    function _discipline(address who) internal view returns (uint256 d) {
        (, , , , , d) = core.borrowers(who);
    }

    function _sourceInfo(address src)
        internal
        view
        returns (CreditCore.SourceTier tier, uint256 bond, uint256 attributed)
    {
        (tier, bond, attributed) = core.sources(src);
    }

    // ---------- scoring ----------

    function test_eventSignatureConstants() public view {
        assertEq(core.DEPOSIT_EVENT_SIGNATURE(), keccak256("FundsDeposited(address,uint256,uint256)"));
        assertEq(core.REPAY_EVENT_SIGNATURE(), keccak256("LoanRepaidOnEth(address,uint256,uint256)"));
    }

    function test_scoreGrowsOnlyViaValidProof() public {
        assertEq(_ethScore(bob), 0);

        // an event with the right signature from an UNREGISTERED contract verifies
        // and emits, but carries zero weight (v4 tier model: Unknown = 0)
        _execute(0, 100, _depositTx(address(0xDEAD00), bob, 1 ether, 1));
        assertEq(_ethScore(bob), 0);

        // a repayment event submitted under action=ScoreDeposit — the signature will not match
        vm.expectRevert("No events of required type found");
        _execute(0, 101, _repayOnEthTx(LOANBOOK_ON_SEPOLIA, bob, 1, 1 ether));
        assertEq(_ethScore(bob), 0);

        // a valid deposit proof from the Verified vault → CAPITAL
        _proveDeposit(1 ether, 102);
        assertEq(_ethScore(bob), 1 ether);

        // a valid proof of repayment on Sepolia → DISCIPLINE (v4 split):
        // amount + flat bonus, in disciplineScore, not ethScore
        _execute(1, 103, _repayOnEthTx(LOANBOOK_ON_SEPOLIA, bob, 7, 0.5 ether));
        assertEq(_ethScore(bob), 1 ether);
        assertEq(_discipline(bob), 0.6 ether); // 0.5 + 0.1
        // capital 1 ETH >= gate 0.015 → discipline counts in the effective score
        assertEq(core.effectiveScoreOf(bob), 1.6 ether);
        // bond-cap accounting: the bonded loan book was charged 0.6 × slope = 6 CTC
        (, , uint256 attributed) = _sourceInfo(LOANBOOK_ON_SEPOLIA);
        assertEq(attributed, 6 ether);
    }

    function test_depositCirculationCappedByScoreCap() public {
        // score farming by circulation: three deposits of the same funds (deposit →
        // withdraw → deposit) — the total deposit contribution never exceeds DEPOSIT_SCORE_CAP
        _proveDeposit(1 ether, 300);
        _proveDeposit(1 ether, 301);
        _proveDeposit(1 ether, 302); // over the cap: verifies, but does not grow the score
        assertEq(_ethScore(bob), core.DEPOSIT_SCORE_CAP());
        assertEq(core.depositScoreOf(bob), core.DEPOSIT_SCORE_CAP());

        // repayments draw from their own cap: a 1.1 base (1 + flat) clamps at
        // DISCIPLINE_SCORE_CAP — flat-credit farming is bounded per borrower
        _execute(1, 303, _repayOnEthTx(LOANBOOK_ON_SEPOLIA, bob, 7, 1 ether));
        assertEq(_ethScore(bob), core.DEPOSIT_SCORE_CAP());
        assertEq(_discipline(bob), core.DISCIPLINE_SCORE_CAP());
        assertEq(core.effectiveScoreOf(bob), core.DEPOSIT_SCORE_CAP() + core.DISCIPLINE_SCORE_CAP());
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
        (, , , , uint256 penalty, ) = core.borrowers(bob);
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
        (, , uint256 openDebt, , , ) = core.borrowers(bob);
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
        (, , uint256 openDebt, , , ) = core.borrowers(bob);
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
        (, uint256 localScore, uint256 debtAfter, uint256 completed, , ) = core.borrowers(bob);
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

        (, , uint256 openDebt, , , ) = core.borrowers(bob);
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
        (, uint256 localScore, , uint256 completed, , ) = core.borrowers(bob);
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

        (, uint256 localScore, , uint256 completed, , ) = core.borrowers(bob);
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
        (, uint256 localScore, , , , ) = core.borrowers(bob);
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

        (, uint256 localScore, , , , ) = core.borrowers(bob);
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
        (, uint256 s1, , , , ) = core.borrowers(bob);
        assertEq(s1, 0);

        // exactly at the threshold — a quarter of the full score (MIN_HOLD = term/4)
        vm.prank(bob);
        uint256 id2 = core.borrow(4.5 ether);
        vm.roll(block.number + core.MIN_HOLD_BLOCKS());
        vm.prank(bob);
        core.repayInCTC{value: 4.725 ether}(id2);
        (, uint256 s2, , , , ) = core.borrowers(bob);
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
        demo.registerVerifiedSource(VAULT_ON_SEPOLIA);
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

        (, uint256 sProd, , , , ) = core.borrowers(bob);
        (, uint256 sDemo, , , , ) = demo.borrowers(bob);
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

        (, sProd, , , , ) = core.borrowers(bob);
        (, sDemo, , , , ) = demo.borrowers(bob);
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
        (, uint256 localScore, uint256 openDebt, uint256 completed, , ) = core.borrowers(bob);
        assertEq(localScore, 0);
        assertEq(completed, 0);
        assertEq(openDebt, 0);
        assertEq(core.openLoansOf(bob).length, 0);

        vm.prank(bob);
        core.borrow(1 ether); // passes
    }

    function test_unstakeBlockedByReservedLiquidity() public {
        // max demo-scale score: capped capital (1) + capped discipline (1) = 2 →
        // limit 5 + (2 − 0.01) × 10 = 24.9 CTC
        _proveDeposit(1 ether, 100);
        _execute(1, 101, _repayOnEthTx(LOANBOOK_ON_SEPOLIA, bob, 1, 9 ether));
        assertEq(core.creditLimit(bob), 24.9 ether);

        vm.prank(bob);
        core.borrow(20 ether); // 80 free CTC remain in the pool

        // alice owns 100% of the shares (assets 100), but only 80 are free
        vm.prank(alice);
        vm.expectRevert("liquidity reserved for open loans");
        pool.unstake(100 ether);

        // partial withdrawal within the free liquidity passes
        uint256 before = alice.balance;
        vm.prank(alice);
        pool.unstake(80 ether);
        assertEq(alice.balance - before, 80 ether);
    }

    // ---------- joint CAPITAL cap (double-counting guard) ----------

    function _registerCapitalSources() internal {
        core.registerVerifiedSource(ROCKET_POOL_SOURCE);
        core.registerVerifiedSource(EIGEN_SOURCE);
    }

    /// @notice The guard itself: every CAPITAL source draws from ONE shared cap.
    /// Capital proven through the vault, then Rocket Pool, then EigenLayer is
    /// counted once — the accumulated capital score can never exceed
    /// DEPOSIT_SCORE_CAP no matter how many protocols attest it.
    function test_jointCapitalCap_capitalCountedOnce() public {
        _registerCapitalSources();

        // Vault deposits fill 1.95 of the 2.0 cap
        _proveDeposit(1.95 ether, 100);
        assertEq(_ethScore(bob), 1.95 ether);
        assertEq(core.depositScoreOf(bob), 1.95 ether);

        // A proven 0.5 ETH Rocket Pool deposit only fills the remaining 0.05 room
        _execute(3, 101, _rocketDepositTx(ROCKET_POOL_SOURCE, bob, 0.5 ether));
        assertEq(_ethScore(bob), 2 ether);
        assertEq(core.depositScoreOf(bob), 2 ether);

        // A proven EigenLayer restake (huge share count) adds exactly zero:
        // that capital is already counted — restaked LSTs share the joint cap
        _execute(4, 102, _eigenDepositTx(EIGEN_SOURCE, bob, 1e24));
        assertEq(_ethScore(bob), 2 ether);
        assertEq(core.depositScoreOf(bob), 2 ether);

        // And another Rocket Pool deposit is also zero — the cap is global,
        // not per-source
        _execute(3, 103, _rocketDepositTx(ROCKET_POOL_SOURCE, bob, 1 ether));
        assertEq(_ethScore(bob), 2 ether);
    }

    /// @notice EigenLayer credit is flat per proven event, independent of the
    /// share amount (strategy shares are heterogeneous LST units — 1 wei of
    /// shares and 1e24 shares score identically); Rocket Pool credit is
    /// amount-based (native ETH is homogeneous).
    function test_eigenFlatVsRocketAmountBased() public {
        _registerCapitalSources();

        _execute(4, 200, _eigenDepositTx(EIGEN_SOURCE, bob, 1)); // dust shares
        assertEq(_ethScore(bob), 0.1 ether);
        _execute(4, 201, _eigenDepositTx(EIGEN_SOURCE, bob, 1e24)); // whale shares
        assertEq(_ethScore(bob), 0.2 ether); // same flat +0.1

        _execute(3, 202, _rocketDepositTx(ROCKET_POOL_SOURCE, bob, 0.3 ether));
        assertEq(_ethScore(bob), 0.5 ether); // amount-based +0.3
        assertEq(core.depositScoreOf(bob), 0.5 ether); // one shared accumulator
    }

    function test_capitalActions_unknownSourceCreditsZero() public {
        // v4 tier model: an unregistered capital source verifies + emits, zero weight
        _execute(3, 300, _rocketDepositTx(ROCKET_POOL_SOURCE, bob, 1 ether));
        _execute(4, 301, _eigenDepositTx(EIGEN_SOURCE, bob, 1e18));
        assertEq(_ethScore(bob), 0);
        assertEq(core.depositScoreOf(bob), 0);
    }

    // ---------- v4 pivot fix 1: tier field ----------

    /// @dev Aave v3 Repay layout: 4 topics (reserve, user, repayer indexed),
    /// data = abi.encode(amount, useATokens). Subject = user, NOT repayer.
    function _aaveRepayTx(address emitter, address user, address repayer, uint256 amount)
        internal
        pure
        returns (bytes memory)
    {
        LogTuple[] memory logs = new LogTuple[](1);
        logs[0].address_ = emitter;
        logs[0].topics = new bytes32[](4);
        logs[0].topics[0] = keccak256("Repay(address,address,address,uint256,bool)");
        logs[0].topics[1] = bytes32(uint256(uint160(address(0x0DA1)))); // reserve
        logs[0].topics[2] = bytes32(uint256(uint160(user)));
        logs[0].topics[3] = bytes32(uint256(uint160(repayer)));
        logs[0].data = abi.encode(amount, false);
        return _encodeTx(1, logs);
    }

    /// @dev Morpho Blue Repay layout: 4 topics (marketId, caller, onBehalf indexed),
    /// data = abi.encode(assets, shares). Subject = onBehalf, NOT caller.
    function _morphoRepayTx(address emitter, address caller, address onBehalf, uint256 assets)
        internal
        pure
        returns (bytes memory)
    {
        LogTuple[] memory logs = new LogTuple[](1);
        logs[0].address_ = emitter;
        logs[0].topics = new bytes32[](4);
        logs[0].topics[0] = keccak256("Repay(bytes32,address,address,uint256,uint256)");
        logs[0].topics[1] = bytes32(uint256(0x8DB3)); // marketId
        logs[0].topics[2] = bytes32(uint256(uint160(caller)));
        logs[0].topics[3] = bytes32(uint256(uint160(onBehalf)));
        logs[0].data = abi.encode(assets, uint256(5e13));
        return _encodeTx(1, logs);
    }

    address constant AAVE_POOL = address(0xAA7E);
    address constant MORPHO = address(0x304F0);

    function test_unknownSource_zeroWeightButNoRevert() public {
        _proveDeposit(1 ether, 700);
        uint256 limitBefore = core.creditLimit(bob);

        // Unknown-source repayment: verifies, contributes zero discipline
        _execute(1, 701, _repayOnEthTx(address(0xFA4E), bob, 1, 5 ether));
        assertEq(_discipline(bob), 0);

        // Unknown-source liquidation: verifies, inflicts zero penalty (griefing shield)
        _execute(2, 702, _liquidationTx(address(0xFA4E), bob, 500e6));
        (, , , , uint256 penalty, ) = core.borrowers(bob);
        assertEq(penalty, 0);
        assertEq(core.creditLimit(bob), limitBefore);
    }

    function test_verifiedExternalRepays_actions5and6() public {
        core.registerVerifiedSource(AAVE_POOL);
        core.registerVerifiedSource(MORPHO);
        _proveDeposit(1 ether, 710); // pass the capital gate

        // Aave Repay → flat DISCIPLINE credit to `user` (not the repayer)
        _execute(5, 711, _aaveRepayTx(AAVE_POOL, bob, address(0x9A9E4), 5_000e6));
        assertEq(_discipline(bob), core.EXTERNAL_REPAY_FLAT_SCORE());
        assertEq(_discipline(address(0x9A9E4)), 0);

        // Morpho Repay → flat DISCIPLINE credit to `onBehalf` (not the caller)
        _execute(6, 712, _morphoRepayTx(MORPHO, address(0xCA11E4), bob, 50e6));
        assertEq(_discipline(bob), 2 * core.EXTERNAL_REPAY_FLAT_SCORE());
        assertEq(_discipline(address(0xCA11E4)), 0);

        // flat, not amount-proportional: a whale repay credits the same +0.1
        _execute(6, 713, _morphoRepayTx(MORPHO, bob, bob, 1e30));
        assertEq(_discipline(bob), 3 * core.EXTERNAL_REPAY_FLAT_SCORE());

        // and the limit reflects the gated effective score
        assertEq(core.effectiveScoreOf(bob), 1 ether + 0.3 ether);
    }

    // ---------- v4 pivot fix 2: per-source bond-cap ----------

    address constant FAKE_LENDER = address(0xFA4E1);

    function test_bondCap_attributionClampedByBond() public {
        // a permissionless lender bonds 2 CTC → can write at most 2 CTC of limit
        vm.deal(address(this), 2 ether);
        core.registerBondedSource{value: 2 ether}(FAKE_LENDER);
        _proveDeposit(1 ether, 800); // gate passes; capital is from the Verified vault

        // repay base would be 0.6 score = 6 CTC of limit — clamped to the bond:
        // 2 CTC of limit = 0.2 score
        _execute(1, 801, _repayOnEthTx(FAKE_LENDER, bob, 1, 0.5 ether));
        assertEq(_discipline(bob), 0.2 ether);
        (, uint256 bond, uint256 attributed) = _sourceInfo(FAKE_LENDER);
        assertEq(bond, 2 ether);
        assertEq(attributed, 2 ether); // exactly at the bond — attack cost == extracted benefit

        // the source is exhausted: further records write nothing
        _execute(1, 802, _repayOnEthTx(FAKE_LENDER, bob, 2, 0.5 ether));
        assertEq(_discipline(bob), 0.2 ether);

        // topping up the bond re-opens exactly the added room
        vm.deal(address(this), 1 ether);
        core.registerBondedSource{value: 1 ether}(FAKE_LENDER);
        _execute(1, 803, _repayOnEthTx(FAKE_LENDER, bob, 3, 0.5 ether));
        assertEq(_discipline(bob), 0.3 ether); // +0.1 = the 1 CTC top-up / slope
    }

    function test_bondCap_penaltiesDrawFromSameRoom() public {
        vm.deal(address(this), 2 ether);
        core.registerBondedSource{value: 2 ether}(FAKE_LENDER);
        _proveDeposit(1 ether, 810);

        // first liquidation: −1 CTC of limit, attributed 1 of 2
        _execute(2, 811, _liquidationTx(FAKE_LENDER, bob, 500e6));
        (, , , , uint256 p1, ) = core.borrowers(bob);
        assertEq(p1, 1 ether);

        // second: escalation says −2, but only 1 CTC of bond room remains
        _execute(2, 812, _liquidationTx(FAKE_LENDER, bob, 500e6));
        (, , , , uint256 p2, ) = core.borrowers(bob);
        assertEq(p2, 2 ether);
        (, , uint256 attributed) = _sourceInfo(FAKE_LENDER);
        assertEq(attributed, 2 ether);

        // third: the bonded source can no longer damage anyone
        _execute(2, 813, _liquidationTx(FAKE_LENDER, bob, 500e6));
        (, , , , uint256 p3, ) = core.borrowers(bob);
        assertEq(p3, 2 ether);
    }

    function test_bondedSource_registrationRules() public {
        // below the minimum bond
        vm.deal(address(this), 10 ether);
        vm.expectRevert("bond below minimum");
        core.registerBondedSource{value: 0.5 ether}(FAKE_LENDER);

        // a Verified source cannot be re-registered through the bonded path
        vm.expectRevert("source already verified");
        core.registerBondedSource{value: 1 ether}(VAULT_ON_SEPOLIA);

        // zero top-up is rejected
        core.registerBondedSource{value: 1 ether}(FAKE_LENDER);
        vm.expectRevert("zero bond top-up");
        core.registerBondedSource(FAKE_LENDER);

        // permissionless: a non-owner can bond a source
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        core.registerBondedSource{value: 1 ether}(FAKE_LENDER);
        (, uint256 bond, ) = _sourceInfo(FAKE_LENDER);
        assertEq(bond, 2 ether);
    }

    function test_bondWithdrawal_demotesAndKeepsAttribution() public {
        vm.deal(address(this), 1 ether);
        core.registerBondedSource{value: 1 ether}(FAKE_LENDER);
        _proveDeposit(1 ether, 820);

        // fill the whole 1 CTC of attribution room (0.1 score = 1 CTC of limit)
        _execute(1, 821, _repayOnEthTx(FAKE_LENDER, bob, 1, 0.5 ether));
        assertEq(_discipline(bob), 0.1 ether);

        // owner-arbitrated withdrawal (v4; slashing is roadmap) → back to Unknown
        address payable sink = payable(address(0x51BB));
        core.withdrawSourceBond(FAKE_LENDER, sink);
        assertEq(sink.balance, 1 ether);
        (CreditCore.SourceTier tier, uint256 bond, uint256 attributed) = _sourceInfo(FAKE_LENDER);
        assertEq(uint8(tier), uint8(CreditCore.SourceTier.Unknown));
        assertEq(bond, 0);
        assertEq(attributed, 1 ether); // history survives the withdrawal

        // re-bonding does NOT launder the attribution: room = 1 − 1 = 0
        vm.deal(address(this), 1 ether);
        core.registerBondedSource{value: 1 ether}(FAKE_LENDER);
        _execute(1, 822, _repayOnEthTx(FAKE_LENDER, bob, 2, 0.5 ether));
        assertEq(_discipline(bob), 0.1 ether); // unchanged

        // only the owner arbitrates withdrawals
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        core.withdrawSourceBond(FAKE_LENDER, sink);
    }

    // ---------- v4 pivot fix 3: capital gate ----------

    function test_capitalGate_disciplineDarkUntilCapitalProven() public {
        // capital below the gate (but above MIN_ETH_SCORE): base limit works,
        // discipline is dark
        uint256 belowGate = core.CAPITAL_GATE_THRESHOLD() - 1;
        _proveDeposit(belowGate, 900);
        _execute(1, 901, _repayOnEthTx(LOANBOOK_ON_SEPOLIA, bob, 1, 0.5 ether));
        assertEq(_discipline(bob), 0.6 ether); // recorded...
        assertEq(core.effectiveScoreOf(bob), belowGate); // ...but not counted

        // one more wei of proven capital flips the gate — retroactively:
        // the discipline recorded while gated-out lights up
        _execute(0, 902, _depositTx(VAULT_ON_SEPOLIA, bob, 1, 2));
        assertEq(core.depositScoreOf(bob), core.CAPITAL_GATE_THRESHOLD());
        assertEq(core.effectiveScoreOf(bob), core.CAPITAL_GATE_THRESHOLD() + 0.6 ether);

        // and the limit follows the gated effective score
        uint256 expected = core.BASE_LIMIT()
            + ((core.CAPITAL_GATE_THRESHOLD() + 0.6 ether - core.MIN_ETH_SCORE()) * core.SCORE_SLOPE_NUM())
                / core.SCORE_SLOPE_DEN();
        assertEq(core.creditLimit(bob), expected);
    }

    /// @notice End-to-end vector from the REAL Morpho Blue Sepolia Repay that the
    /// live pipeline replays as the first external-protocol DISCIPLINE record:
    /// tx 0xf232bbd79c02655716e8f2ff983f7d67d7987b6be49cac9fb03586669396ee17
    /// (Sepolia block 11604843, TruthGate demo market, full close by shares).
    /// Topics and data are the byte-for-byte on-chain log; only the transaction
    /// envelope is synthesized (the precompile is mocked — proof verification is
    /// its job, log decoding is ours).
    function test_realMorphoSepoliaRepay_action6Vector() public {
        address morphoSepolia = 0xd011EE229E7459ba1ddd22631eF7bF528d424A14;
        address demoBorrower = 0x025A5616B35bd7D0B79d14DA58fa3e34CEd8a3d0;
        core.registerVerifiedSource(morphoSepolia);

        // the borrower proves capital first (mirrors the live replay order)
        _execute(0, 11_604_000, _depositTx(VAULT_ON_SEPOLIA, demoBorrower, 0.027 ether, 1));

        LogTuple[] memory logs = new LogTuple[](1);
        logs[0].address_ = morphoSepolia;
        logs[0].topics = new bytes32[](4);
        logs[0].topics[0] = 0x52acb05cebbd3cd39715469f22afbf5a17496295ef3bc9bb5944056c63ccaa09;
        logs[0].topics[1] = 0x8db3b66308de899b5dd81c0a9de5b423fbc8fe287e2f7d72e3b1e73250eaf722; // marketId
        logs[0].topics[2] = 0x000000000000000000000000025a5616b35bd7d0b79d14da58fa3e34ced8a3d0; // caller
        logs[0].topics[3] = 0x000000000000000000000000025a5616b35bd7d0b79d14da58fa3e34ced8a3d0; // onBehalf
        logs[0].data =
            hex"0000000000000000000000000000000000000000000000000000000002faf08000000000000000000000000000000000000000000000000000002d79883d2000";
        _execute(6, 11_604_843, _encodeTx(1, logs));

        // 50e6 tUSDC clears the dust floor by 5000× → flat +0.1 discipline
        assertEq(_discipline(demoBorrower), core.EXTERNAL_REPAY_FLAT_SCORE());
        // 0.027 proven capital ≥ 0.015 gate → the discipline counts
        assertEq(core.effectiveScoreOf(demoBorrower), 0.027 ether + 0.1 ether);
    }

    // ---------- v4 dust-repay floor ----------

    function test_disciplineDustFloor() public {
        _proveDeposit(1 ether, 950);

        // below the floor: verifies, emits, zero credit
        _execute(1, 951, _repayOnEthTx(LOANBOOK_ON_SEPOLIA, bob, 1, core.minDisciplineEventAmount() - 1));
        assertEq(_discipline(bob), 0);

        // at the floor: credited (amount + flat bonus)
        uint256 floor = core.minDisciplineEventAmount();
        _execute(1, 952, _repayOnEthTx(LOANBOOK_ON_SEPOLIA, bob, 2, floor));
        assertEq(_discipline(bob), floor + core.FLAT_REPAYMENT_BONUS());

        // external repays respect the same floor (Morpho, 1-wei dust repay)
        core.registerVerifiedSource(MORPHO);
        _execute(6, 953, _morphoRepayTx(MORPHO, bob, bob, 1));
        assertEq(_discipline(bob), floor + core.FLAT_REPAYMENT_BONUS());

        // the floor is an owner knob (an enumerated owner power)
        core.setMinDisciplineEventAmount(1e6);
        _execute(1, 954, _repayOnEthTx(LOANBOOK_ON_SEPOLIA, bob, 3, 1e4));
        assertEq(_discipline(bob), floor + core.FLAT_REPAYMENT_BONUS()); // unchanged

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        core.setMinDisciplineEventAmount(1);
    }
}
