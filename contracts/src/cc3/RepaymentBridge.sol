// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";
import {TruthGateBase} from "./TruthGateBase.sol";
import {CreditCore} from "./CreditCore.sol";
import {LPPool} from "./LPPool.sol";
import {WrappedUSDC} from "./WrappedUSDC.sol";

/// @title RepaymentBridge
/// @notice Repayment path B: the sole handler of the UsdcLockedForRepayment event
/// from the Sepolia RepaymentVault contract. On a proven USDC lock it mints wUSDC
/// into its own treasury and credits the repayment in CreditCore (no CTC moves).
/// The built-in SwapDesk sells wUSDC from the treasury for native CTC at a discount
/// and immediately forwards the proceeds to LPPool.settle, releasing pool principal.
contract RepaymentBridge is TruthGateBase {
    enum BridgeActions {
        UsdcRepayment // 0
    }
    error InvalidAction(uint8 action);

    // keccak256("UsdcLockedForRepayment(address,uint256,uint256)")
    // event: UsdcLockedForRepayment(address indexed borrower, uint256 ccLoanId, uint256 amount)
    bytes32 public constant LOCK_EVENT_SIGNATURE =
        0xea18a20e09e48db6df74548f86c639bc49cf7f16771a510a49aa6b161bbc3f87;

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Path B share cap: total USDC repayments per loan ≤ 30% of the full
    /// amount due (principal + interestDue). The remainder must arrive via path A.
    uint256 public constant USDC_SHARE_CAP_BPS = 3000;

    /// @notice Proof delivery buffer on top of the loan deadline, in CC3 blocks:
    /// a repayment is credited as long as the CC3 block.number at delivery time has
    /// not passed deadlineBlock + buffer. The lock moment on Sepolia (sourceHeight)
    /// is NOT part of the check: the Sepolia and CC3 height scales are incomparable,
    /// and an attested "current height" of the source does not exist on CC3 as a
    /// primitive (Attestcoin deliberately keeps attestation behind the source head).
    /// A late lock is filtered out transitively: real-time delivery never precedes
    /// the lock, so a lock past the deadline cannot pass the delivery-time check.
    /// The cost of this semantics: a timely lock whose proof was delivered after the
    /// buffer also reverts ("stale on delivery").
    uint64 public constant DELIVERY_BUFFER_BLOCKS = 1000;

    /// @notice v1 rate: 1 wUSDC = 1 CTC (18 decimals on both sides). A constant,
    /// because this is a testnet and the pair has no real price; in production this
    /// is an oracle.
    uint256 public constant CTC_PER_WUSDC_RATE = 1e18;

    /// @notice Decimals normalization: the UsdcLockedForRepayment event carries
    /// amounts in native USDC units (6 decimals), while internal accounting (CTC
    /// debt, wUSDC, treasury) uses 18 decimals. The only place aware of 6 decimals.
    uint256 public constant USDC_DECIMALS_SCALING = 1e12;

    /// @notice SwapDesk discount: the buyer pays 5% below face value — a premium for
    /// converting the treasury into CTC for the pool. The discount is covered by the
    /// INTEREST part of the path B treasury, not the principal (see the constant-check
    /// in the constructor and swapWusdcForCtc).
    uint256 public constant DISCOUNT_BPS = 500;

    CreditCore public immutable CREDIT_CORE;
    LPPool public immutable POOL;
    WrappedUSDC public immutable WUSDC;

    /// @notice Source of the UsdcLockedForRepayment event on Sepolia.
    address public repaymentVaultOnSepolia;

    /// @notice Face value of the wUSDC treasury attributed to loan principal (per the
    /// CreditCore.creditRepaymentFromBridge split). Invariant:
    /// treasuryPrincipalFace + treasuryInterestFace == WUSDC.balanceOf(address(this)).
    uint256 public treasuryPrincipalFace;
    /// @notice Face value of the wUSDC treasury attributed to the interest part
    /// (margin; the SwapDesk discount is paid out of it).
    uint256 public treasuryInterestFace;

    event RepaymentVaultRegistered(address indexed vault);
    event UsdcRepaymentProcessed(
        uint256 indexed ccLoanId, address indexed borrower, uint256 amount, bytes32 indexed queryId
    );
    event WusdcSwapped(address indexed buyer, uint256 wusdcAmount, uint256 ctcPaid);

    constructor(address creditCore_, address payable pool_) {
        require(creditCore_ != address(0), "zero CreditCore");
        require(pool_ != address(0), "zero pool");
        CREDIT_CORE = CreditCore(creditCore_);
        POOL = LPPool(pool_);
        WUSDC = new WrappedUSDC(address(this));

        // Path B economics consistency: the SwapDesk discount must be covered by the
        // path B interest margin (the spread over path A, which carries no discount).
        // Path B repays debt interest-first, so the worst-case interest share in the
        // treasury belongs to a loan that bridged the maximum: B_max = CAP·(P + I), I = P·r.
        //   interest share s = I / B_max = r / (CAP·(1 + r))
        // We require s >= d (d = DISCOUNT_BPS), in bps arithmetic:
        //   R·1e8 >= D·C·(1e4 + R)
        // Current values: 500·1e8 = 5.0e10 >= 500·3000·10500 = 1.575e10 ✓ — i.e. the
        // minimum interest share of the treasury is ~15.9% at a 5% discount.
        uint256 rate = CREDIT_CORE.INTEREST_RATE_BPS();
        require(
            rate * 1e8 >= DISCOUNT_BPS * USDC_SHARE_CAP_BPS * (BPS_DENOMINATOR + rate),
            "discount not covered by path B interest margin"
        );
    }

    function registerRepaymentVault(address vault) external onlyOwner {
        require(vault != address(0), "zero vault");
        repaymentVaultOnSepolia = vault;
        emit RepaymentVaultRegistered(vault);
    }

    // The freshness window does not apply to repayments (CreditCore/CLAUDE.md policy):
    // timeliness here is checked via the loan deadline at delivery time
    // (CC3 scale, see DELIVERY_BUFFER_BLOCKS).
    function _isFreshnessEnforced(uint8) internal pure override returns (bool) {
        return false;
    }

    // sourceHeight (Sepolia scale) is deliberately unused: comparing it against
    // deadlineBlock (CC3 scale) is invalid — exactly the bug fixed in this revision.
    function _processAndEmitEvent(uint8 action, bytes32 queryId, uint64, /* sourceHeight */ bytes memory encodedTransaction)
        internal
        override
    {
        if (action != uint8(BridgeActions.UsdcRepayment)) {
            revert InvalidAction(action);
        }

        // Transaction type, receiptStatus == 1 (invariant #1 (CLAUDE.md)), signature,
        // every log must come from the registered RepaymentVault
        EvmV1Decoder.LogEntry[] memory logs =
            _validateAndExtractLogs(encodedTransaction, LOCK_EVENT_SIGNATURE, repaymentVaultOnSepolia);

        for (uint256 i; i < logs.length; i++) {
            require(logs[i].topics.length == 2, "Invalid UsdcLockedForRepayment topics");
            require(logs[i].data.length == 64, "Invalid UsdcLockedForRepayment data");

            address borrower = address(uint160(uint256(logs[i].topics[1])));
            (uint256 ccLoanId, uint256 amount) = abi.decode(logs[i].data, (uint256, uint256));
            require(amount > 0, "zero repayment amount");

            // Event is in native 6-dec USDC → debt/wUSDC are 18-dec
            _processRepayment(queryId, borrower, ccLoanId, amount * USDC_DECIMALS_SCALING);
        }
    }

    function _processRepayment(bytes32 queryId, address borrower, uint256 ccLoanId, uint256 amount) internal {
        (
            address loanBorrower,
            uint256 principal,
            uint256 interestDue,
            ,
            uint256 usdcRepaidShare,
            uint256 deadlineBlock,
            CreditCore.LoanStatus status,
        ) = CREDIT_CORE.loans(ccLoanId);

        // Identity v1: only the loan's borrower may pay via the bridge (same EOA on
        // both chains) — someone else's lock with someone else's loanId is not credited
        require(loanBorrower == borrower, "borrower mismatch");

        // Two distinguishable time-based rejection reasons (for worker/failed.json):
        // 1) an honest overdue recorded by the protocol (markLoanAsExpired);
        require(status != CreditCore.LoanStatus.Expired, "loan expired");
        // 2) proof delivery beyond deadline + buffer — "stale on delivery"
        //    (or the lock was late: delivery never precedes the lock). Both sides of
        //    the comparison are on the CC3 scale: deadlineBlock is written by
        //    CreditCore.borrow from the CC3 block.number.
        require(block.number <= deadlineBlock + DELIVERY_BUFFER_BLOCKS, "repayment delivery window exceeded");

        // Path B share cap: no more than 30% of the full amount due via USDC
        uint256 expectedRepayment = principal + interestDue;
        require(
            usdcRepaidShare + amount <= (expectedRepayment * USDC_SHARE_CAP_BPS) / BPS_DENOMINATOR,
            "USDC share cap exceeded"
        );

        // wUSDC goes to the bridge treasury (address(this)); SwapDesk converts it into CTC for the pool
        WUSDC.mint(address(this), amount);

        // CreditCore splits the repayment interest-first and returns the split —
        // we track the treasury face values by it for the subsequent swap
        (uint256 principalPart, uint256 interestPart) = CREDIT_CORE.creditRepaymentFromBridge(ccLoanId, amount);
        treasuryPrincipalFace += principalPart;
        treasuryInterestFace += interestPart;

        emit UsdcRepaymentProcessed(ccLoanId, borrower, amount, queryId);
    }

    // ---------- SwapDesk ----------

    /// @notice Buy wUSDC from the bridge treasury for native CTC at the fixed rate
    /// with the DISCOUNT_BPS discount. The proceeds go immediately to LPPool.settle.
    /// The face value sold is deducted from the treasury pro rata to its composition
    /// (principal/interest); principal is released for EXACTLY the sold principal face —
    /// it is fully covered by the incoming CTC, because the discount falls entirely on
    /// the interest part of the proceeds (guaranteed by the constant-check in the constructor).
    function swapWusdcForCtc(uint256 wusdcAmount) external payable {
        require(wusdcAmount > 0, "zero amount");

        uint256 totalFace = treasuryPrincipalFace + treasuryInterestFace;
        require(wusdcAmount <= totalFace, "insufficient treasury");

        uint256 ctcRequired =
            (((wusdcAmount * CTC_PER_WUSDC_RATE) / 1e18) * (BPS_DENOMINATOR - DISCOUNT_BPS)) / BPS_DENOMINATOR;
        require(ctcRequired > 0, "amount too small");
        require(msg.value == ctcRequired, "wrong CTC amount");

        // Pro-rata face deduction (rounding down favors interest — the safe side:
        // principal is never overstated)
        uint256 principalFaceSold = (wusdcAmount * treasuryPrincipalFace) / totalFace;
        uint256 interestFaceSold = wusdcAmount - principalFaceSold;
        treasuryPrincipalFace -= principalFaceSold;
        treasuryInterestFace -= interestFaceSold;

        // Incoming CTC covers the principal first; the discount shortfall is absorbed
        // by the interest part of the proceeds. Belt-and-braces on top of the constructor check.
        require(msg.value >= principalFaceSold, "discount exceeds interest margin");

        POOL.settle{value: msg.value}(principalFaceSold);

        require(WUSDC.transfer(msg.sender, wusdcAmount), "wUSDC transfer failed");

        emit WusdcSwapped(msg.sender, wusdcAmount, msg.value);
    }
}
