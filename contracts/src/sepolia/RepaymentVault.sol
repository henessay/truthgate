// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title RepaymentVault
/// @notice Sepolia USDC receiver for TruthGate's repayment path B: the borrower
/// locks USDC, the worker proves the event into RepaymentBridge on CC3.
/// HONEST v1 limitation: the accumulated USDC is locked here FOREVER — there is no
/// reverse writability (CC3 → Sepolia) in v1; nobody and nothing can withdraw it.
/// The economics closes on the CC3 side (wUSDC + SwapDesk), not by returning this USDC.
/// IMPORTANT: the event signature must match RepaymentBridge.LOCK_EVENT_SIGNATURE
/// byte-for-byte (see test/EventParity.t.sol).
contract RepaymentVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Test USDC (6 decimals) — event amounts are in native USDC units;
    /// normalization to 18 decimals is done by RepaymentBridge on CC3.
    IERC20 public immutable USDC;

    uint256 public totalLocked;

    /// @dev keccak256("UsdcLockedForRepayment(address,uint256,uint256)") ==
    /// RepaymentBridge.LOCK_EVENT_SIGNATURE. The bridge expects: topics.length == 2
    /// (only borrower indexed), data == abi.encode(ccLoanId, amount) (64 bytes);
    /// borrower must match the loan's borrower on CC3 (identity v1: a single EOA).
    event UsdcLockedForRepayment(address indexed borrower, uint256 ccLoanId, uint256 amount);

    constructor(address usdc_) {
        require(usdc_ != address(0), "zero USDC");
        USDC = IERC20(usdc_);
    }

    function lockRepayment(uint256 ccLoanId, uint256 amount) external nonReentrant {
        require(amount > 0, "zero amount");

        USDC.safeTransferFrom(msg.sender, address(this), amount);
        totalLocked += amount;

        emit UsdcLockedForRepayment(msg.sender, ccLoanId, amount);
    }
}
