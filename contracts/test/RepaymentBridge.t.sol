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
    address bob = address(0xB0B); // borrower
    address carol = address(0xCA401); // wUSDC buyer

    MockNativeQueryVerifier mock;
    LPPool pool;
    CreditCore core;
    RepaymentBridge bridge;
    WrappedUSDC wusdc;

    uint256 loanId;
    uint256 constant USDC_1 = 1e6; // 1 USDC in native 6-dec units
    uint256 deadline; // CC3_HEAD + LOAN_DURATION_BLOCKS

    // Realistic heads of BOTH scales (live-testnet values at the time of the
    // "repayment past deadline" bug). Sepolia is ~6M blocks ahead of CC3 — tests
    // with comparable heights would not catch scale mixing, so the whole suite
    // runs on these magnitudes.
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
        vm.roll(CC3_HEAD); // the CC3 scale must differ radically from the Sepolia scale

        vm.etch(PRECOMPILE, address(new MockNativeQueryVerifier()).code);
        mock = MockNativeQueryVerifier(PRECOMPILE);

        pool = new LPPool();
        core = new CreditCore(payable(address(pool)), 0, 0);
        bridge = new RepaymentBridge(address(core), payable(address(pool)));
        wusdc = bridge.WUSDC();

        pool.setCreditCore(address(core));
        pool.setBridge(address(bridge));
        core.setRepaymentBridge(address(bridge));
        core.registerVerifiedSource(CREDIT_VAULT_ON_SEPOLIA);
        bridge.registerRepaymentVault(REPAYMENT_VAULT_ON_SEPOLIA);

        vm.deal(alice, 1000 ether);
        vm.prank(alice);
        pool.stake{value: 100 ether}();

        // score bob and take a 10 CTC loan (interestDue 0.5, path B cap = 10.5 * 30% = 3.15)
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

    // ---------- path B ----------

    function test_lockEventSignatureConstant() public view {
        assertEq(bridge.LOCK_EVENT_SIGNATURE(), LOCK_SIG);
    }

    function test_happyPath_proofMintsWusdcAndReducesDebt() public {
        _proveLock(100, 3 * USDC_1);

        // wUSDC in the bridge treasury
        assertEq(wusdc.balanceOf(address(bridge)), 3 ether);

        // debt reduced in CreditCore, the path B share is marked
        (, , , uint256 repaid, uint256 usdcShare, , CreditCore.LoanStatus status, ) = core.loans(loanId);
        assertEq(repaid, 3 ether);
        assertEq(usdcShare, 3 ether);
        assertEq(uint8(status), uint8(CreditCore.LoanStatus.PartlyRepaid));

        (, , uint256 openDebt, , , ) = core.borrowers(bob);
        assertEq(openDebt, 7.5 ether);

        // no CTC moved: the pool is untouched until the SwapDesk settlement
        assertEq(address(pool).balance, 90 ether);
        assertEq(pool.outstandingPrincipal(), 10 ether);
    }

    function test_usdcShareCapExceededReverts() public {
        _proveLock(100, 3 * USDC_1); // just under the 3.15 cap

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

    // ---------- path B deadline: CC3 scale at delivery time ----------
    // Regression for the "repayment past deadline" bug: the old code compared the
    // Sepolia sourceHeight (~11.5M) against the CC3 deadline (~5.44M) — it ALWAYS reverted.

    function test_freshBridgeRepayment_realisticScales_passes() public {
        // The Sepolia lock height is ~6M above the CC3 deadline: under the old
        // semantics this test reverts, under the new one (CC3 block.number) it passes
        assertGt(uint256(SEPOLIA_LOCK_HEIGHT), deadline + bridge.DELIVERY_BUFFER_BLOCKS());
        assertLe(block.number, deadline);

        _proveLock(SEPOLIA_LOCK_HEIGHT, 1 * USDC_1);
        (, , , uint256 repaid, , , , ) = core.loans(loanId);
        assertEq(repaid, 1 ether);
    }

    function test_overdueDelivery_realisticScales_reverts() public {
        // Delivery beyond deadline + buffer (CC3 scale) — a distinct "stale on
        // delivery" revert text, different from a genuine overdue loan
        vm.roll(deadline + bridge.DELIVERY_BUFFER_BLOCKS() + 1);

        bytes memory lateTx = _lockTx(REPAYMENT_VAULT_ON_SEPOLIA, bob, loanId, 1 * USDC_1);
        vm.expectRevert("repayment delivery window exceeded");
        _executeOnBridge(SEPOLIA_LOCK_HEIGHT, lateTx);
    }

    function test_deliveryAtExactBufferBoundary_passes() public {
        // Exactly deadlineBlock + DELIVERY_BUFFER_BLOCKS — still passes
        vm.roll(deadline + bridge.DELIVERY_BUFFER_BLOCKS());

        _proveLock(SEPOLIA_LOCK_HEIGHT, 1 * USDC_1);
        (, , , uint256 repaid, , , , ) = core.loans(loanId);
        assertEq(repaid, 1 ether);
    }

    // ---------- invariant #4 (CLAUDE.md): queryId marked ⟺ all effects applied ----------

    /// @dev Replica of TruthGateBase._computeQueryId: keccak256(chainKey ‖ height ‖ txIndex),
    /// the mock's txIndex = 0. Breaks if the queryId formula changes — intentionally so.
    function _queryId(uint64 height) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(uint256(1), uint64(height), uint256(0)));
    }

    function test_invariant_queryIdMarkedIffEffectsApplied() public {
        // ⟹ success: queryId marked AND effects applied in the same transaction
        _proveLock(SEPOLIA_LOCK_HEIGHT, 1 * USDC_1);
        assertTrue(bridge.processedQueries(_queryId(SEPOLIA_LOCK_HEIGHT)));
        (, , , uint256 repaid, , , , ) = core.loans(loanId);
        assertEq(repaid, 1 ether);
        assertEq(wusdc.totalSupply(), 1 ether);

        // Along the way — view semantics: totalDueFor is GROSS (repayment does not
        // change it), outstandingDueFor is the net remainder
        assertEq(core.totalDueFor(loanId), 10.5 ether);
        assertEq(core.outstandingDueFor(loanId), 9.5 ether);

        // ⟸ a revert DEEP inside the handler, AFTER the wUSDC mint: repay the loan
        // in full via path A and deliver one more lock — the bridge lets it through
        // (status Repaid ≠ Expired, cap not exceeded), the mint executes, and
        // CreditCore.creditRepaymentFromBridge reverts with "invalid loan status"
        vm.deal(bob, 9.5 ether);
        vm.prank(bob);
        core.repayInCTC{value: 9.5 ether}(loanId);
        assertEq(core.outstandingDueFor(loanId), 0);

        uint64 h2 = SEPOLIA_LOCK_HEIGHT + 1;
        uint256 supplyBefore = wusdc.totalSupply();
        bytes memory tx2 = _lockTx(REPAYMENT_VAULT_ON_SEPOLIA, bob, loanId, USDC_1 / 2);
        vm.expectRevert("invalid loan status");
        _executeOnBridge(h2, tx2);

        // Atomic rollback: no queryId, no mint, no credit accounting
        assertFalse(bridge.processedQueries(_queryId(h2)));
        assertEq(wusdc.totalSupply(), supplyBefore);
        (, , , uint256 repaidAfter, , , , ) = core.loans(loanId);
        assertEq(repaidAfter, 10.5 ether);
    }

    function test_expiredLoan_distinctRevert() public {
        // A genuine overdue loan, recorded by the protocol, has its own revert text
        vm.roll(deadline + 1);
        core.markLoanAsExpired(loanId);

        bytes memory txData = _lockTx(REPAYMENT_VAULT_ON_SEPOLIA, bob, loanId, 1 * USDC_1);
        vm.expectRevert("loan expired");
        _executeOnBridge(SEPOLIA_LOCK_HEIGHT, txData);
    }

    function test_replayedProofReverts() public {
        _proveLock(100, 1 * USDC_1);

        vm.expectRevert("Query already processed");
        _proveLock(100, 1 * USDC_1); // same height + txIndex → same queryId
    }

    // ---------- SwapDesk ----------

    function test_treasuryFacesTrackInterestFirstSplit() public {
        _proveLock(100, 3 * USDC_1);

        // interest-first split: out of 3 wUSDC, interest 0.5 (the whole interestDue), principal 2.5
        assertEq(bridge.treasuryInterestFace(), 0.5 ether);
        assertEq(bridge.treasuryPrincipalFace(), 2.5 ether);
        assertEq(
            bridge.treasuryPrincipalFace() + bridge.treasuryInterestFace(), wusdc.balanceOf(address(bridge))
        );
    }

    function test_swapWusdcForCtc_settlesPool() public {
        _proveLock(100, 3 * USDC_1); // treasury: principal 2.5, interest 0.5

        // carol buys the whole treasury (3 wUSDC): pays 3 * 95% = 2.85 CTC
        vm.deal(carol, 2.85 ether);
        vm.prank(carol);
        bridge.swapWusdcForCtc{value: 2.85 ether}(3 ether);

        // wUSDC with the buyer, treasury empty
        assertEq(wusdc.balanceOf(carol), 3 ether);
        assertEq(wusdc.balanceOf(address(bridge)), 0);
        assertEq(bridge.treasuryPrincipalFace(), 0);
        assertEq(bridge.treasuryInterestFace(), 0);

        // all CTC went to the pool, the bridge kept nothing for itself
        assertEq(address(pool).balance, 92.85 ether);
        assertEq(address(bridge).balance, 0);

        // principal released for EXACTLY the sold principal face value (2.5, fully
        // covered by cash); the 0.15 discount was absorbed by the interest part (0.5 → 0.35 cash)
        assertEq(pool.outstandingPrincipal(), 7.5 ether);
    }

    function test_lpShareNotDilutedByFullPathB_cycle() public {
        // share price before loan origination: pool of 100 CTC over 100 shares = 1e18
        // (the setUp loan has not changed the assets yet: 90 balance + 10 outstanding = 100)
        uint256 priceBefore = (pool.totalAssets() * 1e18) / pool.totalShares();
        assertEq(priceBefore, 1e18);

        // full cycle: maximum debt via the bridge (3 out of 10.5, under the 30% cap),
        // the remaining 7.5 via path A, then a full treasury swap
        _proveLock(100, 3 * USDC_1);
        vm.deal(bob, 7.5 ether);
        vm.prank(bob);
        core.repayInCTC{value: 7.5 ether}(loanId);

        vm.deal(carol, 2.85 ether);
        vm.prank(carol);
        bridge.swapWusdcForCtc{value: 2.85 ether}(3 ether);

        // all principal recovered: 7.5 via path A + 2.5 via settle
        assertEq(pool.outstandingPrincipal(), 0);

        // the LP share is no cheaper than before origination: the interest margin (0.5)
        // outweighed the discount (0.15) → assets 100.35 over 100 shares
        uint256 priceAfter = (pool.totalAssets() * 1e18) / pool.totalShares();
        assertGe(priceAfter, priceBefore);
        assertEq(pool.totalAssets(), 100.35 ether);
    }

    function test_swapPartialAmount() public {
        _proveLock(100, 3 * USDC_1);

        // partial swap of 2 wUSDC: pays 1.9 CTC
        vm.deal(carol, 1.9 ether);
        vm.prank(carol);
        bridge.swapWusdcForCtc{value: 1.9 ether}(2 ether);

        // wUSDC with the buyer, treasury reduced
        assertEq(wusdc.balanceOf(carol), 2 ether);
        assertEq(wusdc.balanceOf(address(bridge)), 1 ether);

        // CTC went to the pool, the bridge kept nothing for itself
        assertEq(address(pool).balance, 91.9 ether);
        assertEq(address(bridge).balance, 0);

        // pro-rata accounting: principal sold 2 * 2.5/3 = 1.666…, principal released
        // for exactly that amount (cash coverage: 1.9 >= 1.666…)
        uint256 principalFaceSold = (2 ether * 2.5 ether) / uint256(3 ether);
        assertEq(bridge.treasuryPrincipalFace(), 2.5 ether - principalFaceSold);
        assertEq(pool.outstandingPrincipal(), 10 ether - principalFaceSold);
    }

    function test_swapWrongCtcAmountReverts() public {
        _proveLock(100, 3 * USDC_1);

        vm.deal(carol, 2 ether);
        vm.prank(carol);
        vm.expectRevert("wrong CTC amount");
        bridge.swapWusdcForCtc{value: 2 ether}(2 ether); // discount not applied — wrong amount
    }
}
