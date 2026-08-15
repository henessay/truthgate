// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title LoanBookSim
/// @notice СИМУЛЯТОР внешней кредитной истории на Sepolia — только для демо.
/// В проде на этом месте реальный кредитный протокол (Aave-подобный ордербук и т.п.),
/// чьи события погашений TruthGate доказывает через USC-proof. Симулятор нужен,
/// чтобы демонстрировать онбординг заёмщика с уже существующей историей: owner
/// «проигрывает» погашения, worker доказывает их в CreditCore (action ScoreRepayment).
/// ВАЖНО: сигнатура события обязана побайтово совпадать с
/// CreditCore.REPAY_EVENT_SIGNATURE (см. test/EventParity.t.sol).
contract LoanBookSim is Ownable {
    /// @dev keccak256("LoanRepaidOnEth(address,uint256,uint256)") ==
    /// CreditCore.REPAY_EVENT_SIGNATURE. CreditCore ожидает: topics.length == 2
    /// (только borrower indexed), data == abi.encode(loanId, amount) (64 байта).
    event LoanRepaidOnEth(address indexed borrower, uint256 loanId, uint256 amount);

    constructor() Ownable(msg.sender) {}

    function simulateRepayment(address borrower, uint256 loanId, uint256 amount) external onlyOwner {
        require(borrower != address(0), "zero borrower");
        require(amount > 0, "zero amount");

        emit LoanRepaidOnEth(borrower, loanId, amount);
    }
}
