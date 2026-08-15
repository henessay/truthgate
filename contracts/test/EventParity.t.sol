// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {CreditCore} from "../src/cc3/CreditCore.sol";
import {RepaymentBridge} from "../src/cc3/RepaymentBridge.sol";
import {ScoringVault} from "../src/sepolia/ScoringVault.sol";
import {LoanBookSim} from "../src/sepolia/LoanBookSim.sol";
import {RepaymentVault} from "../src/sepolia/RepaymentVault.sol";
import {TestUSDC} from "../src/sepolia/TestUSDC.sol";

/// @notice Гарантия побайтового совпадения событий Sepolia-контрактов с тем, что
/// ожидают CC3-контракты. Два уровня:
///  1) хэш сигнатуры события == константа CC3-контракта;
///  2) live-эмиссия: реальный topic0, число топиков (indexed-поля) и layout data
///     совпадают с тем, что декодируют CreditCore/_processAndEmitEvent и
///     RepaymentBridge (topics.length == 2, data == 64 байта, порядок полей).
contract EventParityTest is Test {
    ScoringVault vault;
    LoanBookSim loanBook;
    TestUSDC usdc;
    RepaymentVault repayVault;

    // CC3-контракты нужны только ради констант-сигнатур; адреса-заглушки в
    // конструкторах достаточно (логика не вызывается)
    CreditCore core;
    RepaymentBridge bridge;

    address user = address(0xB0B);

    function setUp() public {
        vault = new ScoringVault();
        loanBook = new LoanBookSim();
        usdc = new TestUSDC();
        repayVault = new RepaymentVault(address(usdc));

        core = new CreditCore(payable(address(1)));
        bridge = new RepaymentBridge(address(core), payable(address(1)));
    }

    /// @dev Единственный лог с нужным эмитентом (recordLogs ловит и ERC20-события).
    function _logFrom(Vm.Log[] memory logs, address emitter) internal pure returns (Vm.Log memory) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == emitter) return logs[i];
        }
        revert("no log from emitter");
    }

    // ---------- хэши сигнатур == константы CC3-контрактов ----------

    function test_signatureHashesMatchCC3Constants() public view {
        assertEq(
            keccak256("FundsDeposited(address,uint256,uint256)"),
            core.DEPOSIT_EVENT_SIGNATURE(),
            "FundsDeposited signature mismatch"
        );
        assertEq(
            keccak256("LoanRepaidOnEth(address,uint256,uint256)"),
            core.REPAY_EVENT_SIGNATURE(),
            "LoanRepaidOnEth signature mismatch"
        );
        assertEq(
            keccak256("UsdcLockedForRepayment(address,uint256,uint256)"),
            bridge.LOCK_EVENT_SIGNATURE(),
            "UsdcLockedForRepayment signature mismatch"
        );
    }

    // ---------- live-эмиссия: topic0, indexed-поля, layout data ----------

    function test_fundsDeposited_liveParity() public {
        vm.deal(user, 1 ether);
        vm.recordLogs();
        vm.prank(user);
        vault.deposit{value: 1 ether}();

        Vm.Log memory log = _logFrom(vm.getRecordedLogs(), address(vault));

        assertEq(log.topics[0], core.DEPOSIT_EVENT_SIGNATURE());
        // CreditCore._scoreDeposits: topics.length == 2, depositor из topics[1]
        assertEq(log.topics.length, 2);
        assertEq(address(uint160(uint256(log.topics[1]))), user);
        // data == abi.encode(amount, nonce), 64 байта, amount первым
        assertEq(log.data.length, 64);
        (uint256 amount, uint256 nonce) = abi.decode(log.data, (uint256, uint256));
        assertEq(amount, 1 ether);
        assertEq(nonce, 1); // инкрементальный per-depositor, с 1
    }

    function test_loanRepaidOnEth_liveParity() public {
        vm.recordLogs();
        loanBook.simulateRepayment(user, 42, 0.5 ether);

        Vm.Log memory log = _logFrom(vm.getRecordedLogs(), address(loanBook));

        assertEq(log.topics[0], core.REPAY_EVENT_SIGNATURE());
        // CreditCore._scoreRepayments: topics.length == 2, borrower из topics[1]
        assertEq(log.topics.length, 2);
        assertEq(address(uint160(uint256(log.topics[1]))), user);
        // data == abi.encode(loanId, amount), 64 байта, loanId первым
        assertEq(log.data.length, 64);
        (uint256 loanId, uint256 amount) = abi.decode(log.data, (uint256, uint256));
        assertEq(loanId, 42);
        assertEq(amount, 0.5 ether);
    }

    function test_usdcLockedForRepayment_liveParity() public {
        usdc.mint(user, 3_000_000); // 3 USDC (6 decimals)
        vm.prank(user);
        usdc.approve(address(repayVault), 3_000_000);

        vm.recordLogs();
        vm.prank(user);
        repayVault.lockRepayment(7, 3_000_000);

        Vm.Log memory log = _logFrom(vm.getRecordedLogs(), address(repayVault));

        assertEq(log.topics[0], bridge.LOCK_EVENT_SIGNATURE());
        // RepaymentBridge._processAndEmitEvent: topics.length == 2, borrower из topics[1]
        assertEq(log.topics.length, 2);
        assertEq(address(uint160(uint256(log.topics[1]))), user);
        // data == abi.encode(ccLoanId, amount), 64 байта, ccLoanId первым;
        // amount в нативных 6-dec USDC — мост нормализует ×1e12
        assertEq(log.data.length, 64);
        (uint256 ccLoanId, uint256 amount) = abi.decode(log.data, (uint256, uint256));
        assertEq(ccLoanId, 7);
        assertEq(amount, 3_000_000);

        // USDC реально заперт
        assertEq(usdc.balanceOf(address(repayVault)), 3_000_000);
        assertEq(repayVault.totalLocked(), 3_000_000);
    }
}
