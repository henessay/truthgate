// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title RepaymentVault
/// @notice Sepolia-приёмник USDC для пути Б погашения займов TruthGate: заёмщик
/// запирает USDC, worker доказывает событие в RepaymentBridge на CC3.
/// ЧЕСТНОЕ v1-ограничение: накопленные USDC заперты здесь НАВСЕГДА — обратной
/// Writability (CC3 → Sepolia) в v1 нет, вывести их некому и нечем. Экономика
/// закрывается на CC3-стороне (wUSDC + SwapDesk), а не возвратом этих USDC.
/// ВАЖНО: сигнатура события обязана побайтово совпадать с
/// RepaymentBridge.LOCK_EVENT_SIGNATURE (см. test/EventParity.t.sol).
contract RepaymentVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Тестовый USDC (6 decimals) — суммы события в нативных единицах USDC;
    /// нормализацию к 18 decimals делает RepaymentBridge на CC3.
    IERC20 public immutable USDC;

    uint256 public totalLocked;

    /// @dev keccak256("UsdcLockedForRepayment(address,uint256,uint256)") ==
    /// RepaymentBridge.LOCK_EVENT_SIGNATURE. Мост ожидает: topics.length == 2
    /// (только borrower indexed), data == abi.encode(ccLoanId, amount) (64 байта);
    /// borrower обязан совпадать с заёмщиком займа на CC3 (identity v1: один EOA).
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
