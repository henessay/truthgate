// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {CreditCore} from "../src/cc3/CreditCore.sol";
import {RepaymentBridge} from "../src/cc3/RepaymentBridge.sol";
import {ScoringVault} from "../src/sepolia/ScoringVault.sol";
import {LoanBookSim} from "../src/sepolia/LoanBookSim.sol";
import {RepaymentVault} from "../src/sepolia/RepaymentVault.sol";
import {TestUSDC} from "../src/sepolia/TestUSDC.sol";

/// @notice Guarantees byte-for-byte parity between the Sepolia contract events and
/// what the CC3 contracts expect. Two levels:
///  1) the event signature hash == the CC3 contract constant;
///  2) live emission: the actual topic0, the topic count (indexed fields) and the data
///     layout match what CreditCore/_processAndEmitEvent and RepaymentBridge decode
///     (topics.length == 2, data == 64 bytes, field order).
contract EventParityTest is Test {
    ScoringVault vault;
    LoanBookSim loanBook;
    TestUSDC usdc;
    RepaymentVault repayVault;

    // The CC3 contracts are needed only for their signature constants; stub
    // addresses in the constructors suffice (their logic is never called)
    CreditCore core;
    RepaymentBridge bridge;

    address user = address(0xB0B);

    function setUp() public {
        vault = new ScoringVault();
        loanBook = new LoanBookSim();
        usdc = new TestUSDC();
        repayVault = new RepaymentVault(address(usdc));

        core = new CreditCore(payable(address(1)), 0, 0);
        bridge = new RepaymentBridge(address(core), payable(address(1)));
    }

    /// @dev The single log from the required emitter (recordLogs also captures ERC20 events).
    function _logFrom(Vm.Log[] memory logs, address emitter) internal pure returns (Vm.Log memory) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == emitter) return logs[i];
        }
        revert("no log from emitter");
    }

    // ---------- signature hashes == CC3 contract constants ----------

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
        // Aave v3 Pool's LiquidationCall — the known topic0 of the real deployment,
        // pinned as a literal so a typo in our signature string cannot self-confirm
        assertEq(
            keccak256("LiquidationCall(address,address,address,uint256,uint256,address,bool)"),
            core.LIQUIDATION_EVENT_SIGNATURE(),
            "LiquidationCall signature mismatch"
        );
        assertEq(
            core.LIQUIDATION_EVENT_SIGNATURE(),
            0xe413a321e8681d831f4dbccbca790d2952b56f977908e45be37335533e005286,
            "LiquidationCall topic0 differs from the real Aave v3 event"
        );
    }

    // ---------- live emission: topic0, indexed fields, data layout ----------

    function test_fundsDeposited_liveParity() public {
        vm.deal(user, 1 ether);
        vm.recordLogs();
        vm.prank(user);
        vault.deposit{value: 1 ether}();

        Vm.Log memory log = _logFrom(vm.getRecordedLogs(), address(vault));

        assertEq(log.topics[0], core.DEPOSIT_EVENT_SIGNATURE());
        // CreditCore._scoreDeposits: topics.length == 2, depositor from topics[1]
        assertEq(log.topics.length, 2);
        assertEq(address(uint160(uint256(log.topics[1]))), user);
        // data == abi.encode(amount, nonce), 64 bytes, amount first
        assertEq(log.data.length, 64);
        (uint256 amount, uint256 nonce) = abi.decode(log.data, (uint256, uint256));
        assertEq(amount, 1 ether);
        assertEq(nonce, 1); // incremental per depositor, starting at 1
    }

    function test_loanRepaidOnEth_liveParity() public {
        vm.recordLogs();
        loanBook.simulateRepayment(user, 42, 0.5 ether);

        Vm.Log memory log = _logFrom(vm.getRecordedLogs(), address(loanBook));

        assertEq(log.topics[0], core.REPAY_EVENT_SIGNATURE());
        // CreditCore._scoreRepayments: topics.length == 2, borrower from topics[1]
        assertEq(log.topics.length, 2);
        assertEq(address(uint160(uint256(log.topics[1]))), user);
        // data == abi.encode(loanId, amount), 64 bytes, loanId first
        assertEq(log.data.length, 64);
        (uint256 loanId, uint256 amount) = abi.decode(log.data, (uint256, uint256));
        assertEq(loanId, 42);
        assertEq(amount, 0.5 ether);
    }

    function test_liquidationCall_liveParity() public {
        address collateral = address(0xC01A);
        address debtAsset = address(0xDEB7);
        address liquidator = address(0x11C0);

        vm.recordLogs();
        loanBook.simulateLiquidation(collateral, debtAsset, user, 0.15 ether, 0.2 ether, liquidator, false);

        Vm.Log memory log = _logFrom(vm.getRecordedLogs(), address(loanBook));

        assertEq(log.topics[0], core.LIQUIDATION_EVENT_SIGNATURE());
        // CreditCore._scoreLiquidations: topics.length == 4 (Aave v3 indexes
        // collateralAsset, debtAsset, user), borrower taken from topics[3]
        assertEq(log.topics.length, 4);
        assertEq(address(uint160(uint256(log.topics[1]))), collateral);
        assertEq(address(uint160(uint256(log.topics[2]))), debtAsset);
        assertEq(address(uint160(uint256(log.topics[3]))), user);
        // data == abi.encode(debtToCover, liquidatedCollateralAmount, liquidator,
        // receiveAToken), 128 bytes, debtToCover first
        assertEq(log.data.length, 128);
        (uint256 debtToCover, uint256 liquidatedCollateral, address liq, bool receiveAToken) =
            abi.decode(log.data, (uint256, uint256, address, bool));
        assertEq(debtToCover, 0.15 ether);
        assertEq(liquidatedCollateral, 0.2 ether);
        assertEq(liq, liquidator);
        assertEq(receiveAToken, false);
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
        // RepaymentBridge._processAndEmitEvent: topics.length == 2, borrower from topics[1]
        assertEq(log.topics.length, 2);
        assertEq(address(uint160(uint256(log.topics[1]))), user);
        // data == abi.encode(ccLoanId, amount), 64 bytes, ccLoanId first;
        // amount in native 6-dec USDC — the bridge normalizes by ×1e12
        assertEq(log.data.length, 64);
        (uint256 ccLoanId, uint256 amount) = abi.decode(log.data, (uint256, uint256));
        assertEq(ccLoanId, 7);
        assertEq(amount, 3_000_000);

        // the USDC is actually locked
        assertEq(usdc.balanceOf(address(repayVault)), 3_000_000);
        assertEq(repayVault.totalLocked(), 3_000_000);
    }
}
