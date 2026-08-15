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
    address bob = address(0xB0B); // заёмщик (тот же адрес на Sepolia и CC3)

    MockNativeQueryVerifier mock;
    LPPool pool;
    CreditCore core;

    // Локальные копии сигнатур: хелперы не должны делать внешних вызовов к core,
    // иначе vm.expectRevert цепляется за вызов геттера, а не за execute.
    bytes32 constant DEPOSIT_SIG = keccak256("FundsDeposited(address,uint256,uint256)");
    bytes32 constant REPAY_SIG = keccak256("LoanRepaidOnEth(address,uint256,uint256)");

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
        core = new CreditCore(payable(address(pool)));
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

    function _execute(uint8 action, uint64 height, bytes memory encodedTx) internal returns (bool) {
        INativeQueryVerifier.MerkleProofEntry[] memory siblings = new INativeQueryVerifier.MerkleProofEntry[](0);
        bytes32[] memory roots = new bytes32[](0);
        return core.execute(action, 1, height, encodedTx, bytes32("root"), siblings, bytes32("digest"), roots);
    }

    function _proveDeposit(uint256 amount, uint64 height) internal {
        _execute(0, height, _depositTx(VAULT_ON_SEPOLIA, bob, amount, 1));
    }

    function _ethScore(address who) internal view returns (uint256 s) {
        (s, , , ) = core.borrowers(who);
    }

    // ---------- скоринг ----------

    function test_eventSignatureConstants() public view {
        assertEq(core.DEPOSIT_EVENT_SIGNATURE(), keccak256("FundsDeposited(address,uint256,uint256)"));
        assertEq(core.REPAY_EVENT_SIGNATURE(), keccak256("LoanRepaidOnEth(address,uint256,uint256)"));
    }

    function test_scoreGrowsOnlyViaValidProof() public {
        assertEq(_ethScore(bob), 0);

        // событие с правильной сигнатурой, но от чужого контракта — не засчитывается
        vm.expectRevert("log from unexpected source contract");
        _execute(0, 100, _depositTx(address(0xDEAD00), bob, 1 ether, 1));
        assertEq(_ethScore(bob), 0);

        // событие погашения, засабмиченное под action=ScoreDeposit — сигнатура не совпадёт
        vm.expectRevert("No events of required type found");
        _execute(0, 101, _repayOnEthTx(LOANBOOK_ON_SEPOLIA, bob, 1, 1 ether));
        assertEq(_ethScore(bob), 0);

        // валидный proof депозита
        _proveDeposit(1 ether, 102);
        assertEq(_ethScore(bob), 1 ether);

        // валидный proof погашения на Sepolia: score += amount + плоский бонус
        _execute(1, 103, _repayOnEthTx(LOANBOOK_ON_SEPOLIA, bob, 7, 0.5 ether));
        assertEq(_ethScore(bob), 1.6 ether); // 1 + 0.5 + 0.1
    }

    function test_depositCirculationCappedByScoreCap() public {
        // накрутка циркуляцией: три депозита одного и того же объёма (депозит →
        // вывод → депозит) — суммарный вклад депозитов не превышает DEPOSIT_SCORE_CAP
        _proveDeposit(1 ether, 300);
        _proveDeposit(1 ether, 301);
        _proveDeposit(1 ether, 302); // сверх кэпа: верифицируется, но скор не растит
        assertEq(_ethScore(bob), core.DEPOSIT_SCORE_CAP());
        assertEq(core.depositScoreOf(bob), core.DEPOSIT_SCORE_CAP());

        // погашения кэпом не ограничены
        _execute(1, 303, _repayOnEthTx(LOANBOOK_ON_SEPOLIA, bob, 7, 1 ether));
        assertEq(_ethScore(bob), core.DEPOSIT_SCORE_CAP() + 1.1 ether);
    }

    function test_replayedScoreProofDoesNotDoubleScore() public {
        mock.setTxIndex(5);
        _proveDeposit(1 ether, 200);
        assertEq(_ethScore(bob), 1 ether);

        // тот же height + тот же txIndex → тот же queryId → реплей отбит базой
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

    // ---------- borrow ----------

    function test_borrowOverLimitReverts() public {
        // ethScore = 1 ETH → лимит = 5 + 9.9 = 14.9 CTC
        _proveDeposit(1 ether, 100);
        assertEq(core.creditLimit(bob), 14.9 ether);

        // 15 CTC + 5% процентов = 15.75 > 14.9
        vm.prank(bob);
        vm.expectRevert("over credit limit");
        core.borrow(15 ether);

        // без скоринга лимит нулевой
        vm.prank(alice);
        vm.expectRevert("over credit limit");
        core.borrow(1);
    }

    function test_fullCycle_pathA_withBurn() public {
        _proveDeposit(1 ether, 100);

        vm.prank(bob);
        uint256 loanId = core.borrow(10 ether);

        // CTC дошёл до заёмщика, пул зарезервировал тело
        assertEq(bob.balance, 10 ether);
        assertEq(address(pool).balance, 90 ether);
        assertEq(pool.outstandingPrincipal(), 10 ether);
        (, , uint256 openDebt, ) = core.borrowers(bob);
        assertEq(openDebt, 10.5 ether); // тело + 5%

        // полное погашение путём А
        vm.deal(bob, 10.5 ether);
        vm.prank(bob);
        core.repayInCTC{value: 10.5 ether}(loanId);

        // burn: 10% от процентной части 0.5 = 0.05; пул: 90 + 10 + 0.45
        assertEq(BURN.balance, 0.05 ether);
        assertEq(address(pool).balance, 100.45 ether);
        assertEq(pool.outstandingPrincipal(), 0);

        (, , , uint256 repaid, , , CreditCore.LoanStatus status, ) = core.loans(loanId);
        assertEq(repaid, 10.5 ether);
        assertEq(uint8(status), uint8(CreditCore.LoanStatus.Repaid));

        (, uint256 localScore, uint256 debtAfter, uint256 completed) = core.borrowers(bob);
        assertEq(localScore, 1);
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
        assertEq(pool.outstandingPrincipal(), 6 ether); // тело гасится первым

        vm.prank(bob);
        core.repayInCTC{value: 6.5 ether}(loanId);
        (, , , uint256 repaid2, , , CreditCore.LoanStatus st2, ) = core.loans(loanId);
        assertEq(repaid2, 10.5 ether);
        assertEq(uint8(st2), uint8(CreditCore.LoanStatus.Repaid));
        assertEq(pool.outstandingPrincipal(), 0);
        assertEq(BURN.balance, 0.05 ether); // сожжено только из процентной части

        // переплата сверх остатка ревертит
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert("invalid loan status");
        core.repayInCTC{value: 1 ether}(loanId);
    }

    // ---------- путь Б ----------

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

        // CTC не двигался: баланс пула и outstanding не изменились. Outstanding
        // высвобождается позже — через LPPool.settle при продаже wUSDC SwapDesk'ом
        // (см. RepaymentBridge.t.sol)
        assertEq(address(pool).balance, 90 ether);
        assertEq(pool.outstandingPrincipal(), 10 ether);

        (, , uint256 openDebt, ) = core.borrowers(bob);
        assertEq(openDebt, 7.5 ether);
    }

    function test_bridgeRepayment_completesLoanAndGrowsLocalScore() public {
        _proveDeposit(1 ether, 100);
        vm.prank(bob);
        uint256 loanId = core.borrow(10 ether);

        vm.deal(bob, 8 ether);
        vm.prank(bob);
        core.repayInCTC{value: 8 ether}(loanId);

        vm.prank(BRIDGE);
        core.creditRepaymentFromBridge(loanId, 2.5 ether);

        (, , , uint256 repaid, uint256 usdcShare, , CreditCore.LoanStatus status, ) = core.loans(loanId);
        assertEq(repaid, 10.5 ether);
        assertEq(usdcShare, 2.5 ether);
        assertEq(uint8(status), uint8(CreditCore.LoanStatus.Repaid));

        (, uint256 localScore, , uint256 completed) = core.borrowers(bob);
        assertEq(localScore, 1);
        assertEq(completed, 1);
    }

    // ---------- LP-пул ----------

    function test_expiredLoanRehabilitation() public {
        _proveDeposit(1 ether, 100);
        vm.prank(bob);
        uint256 loanId = core.borrow(10 ether);

        // просрочка: дедлайн пройден, owner помечает займ Expired
        vm.roll(block.number + core.LOAN_DURATION_BLOCKS() + 1);
        core.markLoanAsExpired(loanId);

        // Expired-займ блокирует новый borrow
        vm.prank(bob);
        vm.expectRevert("overdue loan outstanding");
        core.borrow(1 ether);

        // штрафная ставка: interestDue 0.5 * 1.5 = 0.75 → totalDue 10.75
        assertEq(core.totalDueFor(loanId), 10.75 ether);

        // погашение без штрафа не закрывает займ (остаётся Expired)
        vm.deal(bob, 10.75 ether);
        vm.prank(bob);
        core.repayInCTC{value: 10.5 ether}(loanId);
        (, , , , , , CreditCore.LoanStatus stMid, ) = core.loans(loanId);
        assertEq(uint8(stMid), uint8(CreditCore.LoanStatus.Expired));

        // доплата штрафа закрывает займ
        vm.prank(bob);
        core.repayInCTC{value: 0.25 ether}(loanId);
        (, , , uint256 repaid, , , CreditCore.LoanStatus st, ) = core.loans(loanId);
        assertEq(repaid, 10.75 ether);
        assertEq(uint8(st), uint8(CreditCore.LoanStatus.Repaid));

        // реабилитация: borrow разблокирован, но localScore/loansCompleted не выросли
        (, uint256 localScore, uint256 openDebt, uint256 completed) = core.borrowers(bob);
        assertEq(localScore, 0);
        assertEq(completed, 0);
        assertEq(openDebt, 0);
        assertEq(core.openLoansOf(bob).length, 0);

        vm.prank(bob);
        core.borrow(1 ether); // проходит
    }

    function test_unstakeBlockedByReservedLiquidity() public {
        // большой score через погашения (депозиты капятся): 1 + (9 + 0.1) = 10.1 ETH
        _proveDeposit(1 ether, 100);
        _execute(1, 101, _repayOnEthTx(LOANBOOK_ON_SEPOLIA, bob, 1, 9 ether));

        vm.prank(bob);
        core.borrow(95 ether); // в пуле остаётся 5 свободных

        // alice владеет 100% долей (активы 100), но свободно только 5
        vm.prank(alice);
        vm.expectRevert("liquidity reserved for open loans");
        pool.unstake(100 ether);

        // частичный вывод в пределах свободной ликвидности проходит
        uint256 before = alice.balance;
        vm.prank(alice);
        pool.unstake(5 ether);
        assertEq(alice.balance - before, 5 ether);
    }
}
