// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CreditCore} from "../src/cc3/CreditCore.sol";
import {LPPool} from "../src/cc3/LPPool.sol";
import {RepaymentBridge} from "../src/cc3/RepaymentBridge.sol";
import {WrappedUSDC} from "../src/cc3/WrappedUSDC.sol";
import {INativeQueryVerifier} from "../src/cc3/INativeQueryVerifier.sol";
import {MockNativeQueryVerifier} from "./TruthGateBase.t.sol";

contract RepaymentBridgeTest is Test {
    address constant PRECOMPILE = 0x0000000000000000000000000000000000000FD2;
    address constant CREDIT_VAULT_ON_SEPOLIA = address(0x5EF0);
    address constant REPAYMENT_VAULT_ON_SEPOLIA = address(0x5AFE);

    address alice = address(0xA11CE); // LP
    address bob = address(0xB0B); // заёмщик
    address carol = address(0xCA401); // покупатель wUSDC

    MockNativeQueryVerifier mock;
    LPPool pool;
    CreditCore core;
    RepaymentBridge bridge;
    WrappedUSDC wusdc;

    uint256 loanId;
    uint256 constant USDC_1 = 1e6; // 1 USDC в нативных 6-dec единицах
    uint256 deadline; // CC3_HEAD + LOAN_DURATION_BLOCKS

    // Реалистичные головы ОБЕИХ шкал (значения живого тестнета на момент бага
    // «repayment past deadline»). Sepolia на ~6М блоков впереди CC3 — тесты с
    // сопоставимыми высотами не ловят смешение шкал, поэтому вся сьюта работает
    // на этих величинах.
    uint256 constant CC3_HEAD = 5_337_133;
    uint64 constant SEPOLIA_LOCK_HEIGHT = 11_497_229;

    bytes32 constant DEPOSIT_SIG = keccak256("FundsDeposited(address,uint256,uint256)");
    bytes32 constant LOCK_SIG = keccak256("UsdcLockedForRepayment(address,uint256,uint256)");

    struct LogTuple {
        address address_;
        bytes32[] topics;
        bytes data;
    }

    function setUp() public {
        vm.roll(CC3_HEAD); // CC3-шкала должна радикально отличаться от Sepolia-шкалы

        vm.etch(PRECOMPILE, address(new MockNativeQueryVerifier()).code);
        mock = MockNativeQueryVerifier(PRECOMPILE);

        pool = new LPPool();
        core = new CreditCore(payable(address(pool)));
        bridge = new RepaymentBridge(address(core), payable(address(pool)));
        wusdc = bridge.WUSDC();

        pool.setCreditCore(address(core));
        pool.setBridge(address(bridge));
        core.setRepaymentBridge(address(bridge));
        core.registerVaultOnSepolia(CREDIT_VAULT_ON_SEPOLIA);
        core.registerLoanBookOnSepolia(address(0x10AB));
        bridge.registerRepaymentVault(REPAYMENT_VAULT_ON_SEPOLIA);

        vm.deal(alice, 1000 ether);
        vm.prank(alice);
        pool.stake{value: 100 ether}();

        // скоринг bob'а и займ 10 CTC (interestDue 0.5, cap пути Б = 10.5 * 30% = 3.15)
        _executeOnCore(0, SEPOLIA_LOCK_HEIGHT - 1000, _depositTx(bob, 1 ether));
        vm.prank(bob);
        loanId = core.borrow(10 ether);
        (, , , , , deadline, , ) = core.loans(loanId);
    }

    // ---------- encoding helpers ----------

    function _encodeTx(LogTuple[] memory logs) internal pure returns (bytes memory) {
        bytes memory chunk0 =
            abi.encode(uint64(1), uint64(100_000), address(0x1), false, address(0x2), uint256(0), bytes(""));
        bytes memory chunk2 = abi.encode(uint8(1), uint64(50_000), logs, bytes(""));

        bytes[] memory chunks = new bytes[](3);
        chunks[0] = chunk0;
        chunks[1] = "";
        chunks[2] = chunk2;
        return abi.encode(uint8(2), chunks);
    }

    function _depositTx(address depositor, uint256 amount) internal pure returns (bytes memory) {
        LogTuple[] memory logs = new LogTuple[](1);
        logs[0].address_ = CREDIT_VAULT_ON_SEPOLIA;
        logs[0].topics = new bytes32[](2);
        logs[0].topics[0] = DEPOSIT_SIG;
        logs[0].topics[1] = bytes32(uint256(uint160(depositor)));
        logs[0].data = abi.encode(amount, uint256(1));
        return _encodeTx(logs);
    }

    function _lockTx(address emitter, address borrower, uint256 ccLoanId, uint256 amount)
        internal
        pure
        returns (bytes memory)
    {
        LogTuple[] memory logs = new LogTuple[](1);
        logs[0].address_ = emitter;
        logs[0].topics = new bytes32[](2);
        logs[0].topics[0] = LOCK_SIG;
        logs[0].topics[1] = bytes32(uint256(uint160(borrower)));
        logs[0].data = abi.encode(ccLoanId, amount);
        return _encodeTx(logs);
    }

    function _executeOnCore(uint8 action, uint64 height, bytes memory encodedTx) internal {
        INativeQueryVerifier.MerkleProofEntry[] memory siblings = new INativeQueryVerifier.MerkleProofEntry[](0);
        bytes32[] memory roots = new bytes32[](0);
        core.execute(action, 1, height, encodedTx, bytes32("root"), siblings, bytes32("digest"), roots);
    }

    function _executeOnBridge(uint64 height, bytes memory encodedTx) internal {
        INativeQueryVerifier.MerkleProofEntry[] memory siblings = new INativeQueryVerifier.MerkleProofEntry[](0);
        bytes32[] memory roots = new bytes32[](0);
        bridge.execute(0, 1, height, encodedTx, bytes32("root"), siblings, bytes32("digest"), roots);
    }

    function _proveLock(uint64 height, uint256 amount) internal {
        _executeOnBridge(height, _lockTx(REPAYMENT_VAULT_ON_SEPOLIA, bob, loanId, amount));
    }

    // ---------- путь Б ----------

    function test_lockEventSignatureConstant() public view {
        assertEq(bridge.LOCK_EVENT_SIGNATURE(), LOCK_SIG);
    }

    function test_happyPath_proofMintsWusdcAndReducesDebt() public {
        _proveLock(100, 3 * USDC_1);

        // wUSDC в казне моста
        assertEq(wusdc.balanceOf(address(bridge)), 3 ether);

        // долг уменьшен в CreditCore, доля пути Б помечена
        (, , , uint256 repaid, uint256 usdcShare, , CreditCore.LoanStatus status, ) = core.loans(loanId);
        assertEq(repaid, 3 ether);
        assertEq(usdcShare, 3 ether);
        assertEq(uint8(status), uint8(CreditCore.LoanStatus.PartlyRepaid));

        (, , uint256 openDebt, ) = core.borrowers(bob);
        assertEq(openDebt, 7.5 ether);

        // CTC не двигался: пул нетронут до сеттлмента SwapDesk'ом
        assertEq(address(pool).balance, 90 ether);
        assertEq(pool.outstandingPrincipal(), 10 ether);
    }

    function test_usdcShareCapExceededReverts() public {
        _proveLock(100, 3 * USDC_1); // ровно под кэпом 3.15

        // 3 + 0.2 = 3.2 > 3.15
        vm.expectRevert("USDC share cap exceeded");
        _proveLock(101, USDC_1 / 5);
    }

    function test_foreignVaultReverts() public {
        bytes memory txData = _lockTx(address(0xDEAD00), bob, loanId, 1 * USDC_1);
        vm.expectRevert("log from unexpected source contract");
        _executeOnBridge(100, txData);
    }

    function test_borrowerMismatchReverts() public {
        bytes memory txData = _lockTx(REPAYMENT_VAULT_ON_SEPOLIA, carol, loanId, 1 * USDC_1);
        vm.expectRevert("borrower mismatch");
        _executeOnBridge(100, txData);
    }

    // ---------- дедлайн пути Б: CC3-шкала на момент доставки ----------
    // Регрессия на баг «repayment past deadline»: старый код сравнивал Sepolia-
    // sourceHeight (~11.5М) с CC3-дедлайном (~5.44М) — ревертило ВСЕГДА.

    function test_freshBridgeRepayment_realisticScales_passes() public {
        // Sepolia-высота лока на ~6М больше CC3-дедлайна: при старой семантике
        // этот тест ревертит, при новой (block.number CC3) — проходит
        assertGt(uint256(SEPOLIA_LOCK_HEIGHT), deadline + bridge.DELIVERY_BUFFER_BLOCKS());
        assertLe(block.number, deadline);

        _proveLock(SEPOLIA_LOCK_HEIGHT, 1 * USDC_1);
        (, , , uint256 repaid, , , , ) = core.loans(loanId);
        assertEq(repaid, 1 ether);
    }

    function test_overdueDelivery_realisticScales_reverts() public {
        // Доставка за пределами дедлайн + буфер (CC3-шкала) — различимый текст
        // «протух по доставке», не совпадающий с честной просрочкой
        vm.roll(deadline + bridge.DELIVERY_BUFFER_BLOCKS() + 1);

        bytes memory lateTx = _lockTx(REPAYMENT_VAULT_ON_SEPOLIA, bob, loanId, 1 * USDC_1);
        vm.expectRevert("repayment delivery window exceeded");
        _executeOnBridge(SEPOLIA_LOCK_HEIGHT, lateTx);
    }

    function test_deliveryAtExactBufferBoundary_passes() public {
        // Ровно deadlineBlock + DELIVERY_BUFFER_BLOCKS — ещё проходит
        vm.roll(deadline + bridge.DELIVERY_BUFFER_BLOCKS());

        _proveLock(SEPOLIA_LOCK_HEIGHT, 1 * USDC_1);
        (, , , uint256 repaid, , , , ) = core.loans(loanId);
        assertEq(repaid, 1 ether);
    }

    // ---------- инвариант №4 (CLAUDE.md): queryId помечен ⟺ все эффекты применены ----------

    /// @dev Реплика TruthGateBase._computeQueryId: keccak256(chainKey ‖ height ‖ txIndex),
    /// txIndex мока = 0. Ломается при изменении формулы queryId — это намеренно.
    function _queryId(uint64 height) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(uint256(1), uint64(height), uint256(0)));
    }

    function test_invariant_queryIdMarkedIffEffectsApplied() public {
        // ⟹ успех: queryId помечен И эффекты применены в той же транзакции
        _proveLock(SEPOLIA_LOCK_HEIGHT, 1 * USDC_1);
        assertTrue(bridge.processedQueries(_queryId(SEPOLIA_LOCK_HEIGHT)));
        (, , , uint256 repaid, , , , ) = core.loans(loanId);
        assertEq(repaid, 1 ether);
        assertEq(wusdc.totalSupply(), 1 ether);

        // Попутно — семантика view'ов: totalDueFor ВАЛОВЫЙ (погашение его не меняет),
        // outstandingDueFor — нетто-остаток
        assertEq(core.totalDueFor(loanId), 10.5 ether);
        assertEq(core.outstandingDueFor(loanId), 9.5 ether);

        // ⟸ реверт ГЛУБОКО в обработчике, уже ПОСЛЕ минта wUSDC: гасим займ
        // полностью путём А и доставляем ещё один лок — мост его пропустит
        // (status Repaid ≠ Expired, кап не превышен), минт выполнится, а
        // CreditCore.creditRepaymentFromBridge ревертнёт "invalid loan status"
        vm.deal(bob, 9.5 ether);
        vm.prank(bob);
        core.repayInCTC{value: 9.5 ether}(loanId);
        assertEq(core.outstandingDueFor(loanId), 0);

        uint64 h2 = SEPOLIA_LOCK_HEIGHT + 1;
        uint256 supplyBefore = wusdc.totalSupply();
        bytes memory tx2 = _lockTx(REPAYMENT_VAULT_ON_SEPOLIA, bob, loanId, USDC_1 / 2);
        vm.expectRevert("invalid loan status");
        _executeOnBridge(h2, tx2);

        // Атомарный откат: ни queryId, ни минта, ни кредитного учёта
        assertFalse(bridge.processedQueries(_queryId(h2)));
        assertEq(wusdc.totalSupply(), supplyBefore);
        (, , , uint256 repaidAfter, , , , ) = core.loans(loanId);
        assertEq(repaidAfter, 10.5 ether);
    }

    function test_expiredLoan_distinctRevert() public {
        // Честная просрочка, зафиксированная протоколом, — свой текст реверта
        vm.roll(deadline + 1);
        core.markLoanAsExpired(loanId);

        bytes memory txData = _lockTx(REPAYMENT_VAULT_ON_SEPOLIA, bob, loanId, 1 * USDC_1);
        vm.expectRevert("loan expired");
        _executeOnBridge(SEPOLIA_LOCK_HEIGHT, txData);
    }

    function test_replayedProofReverts() public {
        _proveLock(100, 1 * USDC_1);

        vm.expectRevert("Query already processed");
        _proveLock(100, 1 * USDC_1); // тот же height + txIndex → тот же queryId
    }

    // ---------- SwapDesk ----------

    function test_treasuryFacesTrackInterestFirstSplit() public {
        _proveLock(100, 3 * USDC_1);

        // разбиение процент-первым: из 3 wUSDC процент 0.5 (весь interestDue), тело 2.5
        assertEq(bridge.treasuryInterestFace(), 0.5 ether);
        assertEq(bridge.treasuryPrincipalFace(), 2.5 ether);
        assertEq(
            bridge.treasuryPrincipalFace() + bridge.treasuryInterestFace(), wusdc.balanceOf(address(bridge))
        );
    }

    function test_swapWusdcForCtc_settlesPool() public {
        _proveLock(100, 3 * USDC_1); // казна: тело 2.5, процент 0.5

        // carol покупает всю казну (3 wUSDC): платит 3 * 95% = 2.85 CTC
        vm.deal(carol, 2.85 ether);
        vm.prank(carol);
        bridge.swapWusdcForCtc{value: 2.85 ether}(3 ether);

        // wUSDC у покупателя, казна пуста
        assertEq(wusdc.balanceOf(carol), 3 ether);
        assertEq(wusdc.balanceOf(address(bridge)), 0);
        assertEq(bridge.treasuryPrincipalFace(), 0);
        assertEq(bridge.treasuryInterestFace(), 0);

        // CTC ушёл в пул целиком, мост ничего не оставил себе
        assertEq(address(pool).balance, 92.85 ether);
        assertEq(address(bridge).balance, 0);

        // принципал высвобожден РОВНО на проданный номинал тела (2.5, полностью
        // покрыт cash'ем); дисконт 0.15 съела процентная часть (0.5 → 0.35 cash)
        assertEq(pool.outstandingPrincipal(), 7.5 ether);
    }

    function test_lpShareNotDilutedByFullPathB_cycle() public {
        // цена доли до выдачи займа: пул 100 CTC на 100 долей = 1e18
        // (займ из setUp ещё не менял активы: 90 баланс + 10 outstanding = 100)
        uint256 priceBefore = (pool.totalAssets() * 1e18) / pool.totalShares();
        assertEq(priceBefore, 1e18);

        // полный цикл: максимум долга через мост (3 из 10.5, под кэпом 30%),
        // остаток 7.5 путём А, затем полный своп казны
        _proveLock(100, 3 * USDC_1);
        vm.deal(bob, 7.5 ether);
        vm.prank(bob);
        core.repayInCTC{value: 7.5 ether}(loanId);

        vm.deal(carol, 2.85 ether);
        vm.prank(carol);
        bridge.swapWusdcForCtc{value: 2.85 ether}(3 ether);

        // весь принципал восстановлен: 7.5 путём А + 2.5 через settle
        assertEq(pool.outstandingPrincipal(), 0);

        // LP-доля не дешевле, чем до выдачи: процентная маржа (0.5) перекрыла
        // дисконт (0.15) → активы 100.35 на 100 долей
        uint256 priceAfter = (pool.totalAssets() * 1e18) / pool.totalShares();
        assertGe(priceAfter, priceBefore);
        assertEq(pool.totalAssets(), 100.35 ether);
    }

    function test_swapPartialAmount() public {
        _proveLock(100, 3 * USDC_1);

        // частичный своп 2 wUSDC: платит 1.9 CTC
        vm.deal(carol, 1.9 ether);
        vm.prank(carol);
        bridge.swapWusdcForCtc{value: 1.9 ether}(2 ether);

        // wUSDC у покупателя, казна уменьшилась
        assertEq(wusdc.balanceOf(carol), 2 ether);
        assertEq(wusdc.balanceOf(address(bridge)), 1 ether);

        // CTC ушёл в пул, мост ничего не оставил себе
        assertEq(address(pool).balance, 91.9 ether);
        assertEq(address(bridge).balance, 0);

        // пропорциональное списание: продано тела 2 * 2.5/3 = 1.666…, ровно на него
        // высвобожден принципал (cash-покрытие: 1.9 >= 1.666…)
        uint256 principalFaceSold = (2 ether * 2.5 ether) / uint256(3 ether);
        assertEq(bridge.treasuryPrincipalFace(), 2.5 ether - principalFaceSold);
        assertEq(pool.outstandingPrincipal(), 10 ether - principalFaceSold);
    }

    function test_swapWrongCtcAmountReverts() public {
        _proveLock(100, 3 * USDC_1);

        vm.deal(carol, 2 ether);
        vm.prank(carol);
        vm.expectRevert("wrong CTC amount");
        bridge.swapWusdcForCtc{value: 2 ether}(2 ether); // без дисконта — неверная сумма
    }
}
