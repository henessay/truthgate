// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ScoringVault
/// @notice Sepolia-эмиттер доказуемых фактов для скоринга TruthGate на CC3.
/// Никакой лишней логики: депозит ETH → событие, которое worker доказывает через
/// USC-proof в CreditCore (action ScoreDeposit).
/// ВАЖНО: сигнатура события обязана побайтово совпадать с
/// CreditCore.DEPOSIT_EVENT_SIGNATURE (см. test/EventParity.t.sol).
contract ScoringVault {
    mapping(address => uint256) public balanceOf;
    /// @notice Инкрементальный per-depositor счётчик депозитов (нумерация с 1).
    mapping(address => uint256) public depositNonceOf;

    /// @dev keccak256("FundsDeposited(address,uint256,uint256)") ==
    /// CreditCore.DEPOSIT_EVENT_SIGNATURE. CreditCore ожидает: topics.length == 2
    /// (только depositor indexed), data == abi.encode(amount, nonce) (64 байта).
    event FundsDeposited(address indexed depositor, uint256 amount, uint256 nonce);

    function deposit() external payable {
        require(msg.value > 0, "zero deposit");

        balanceOf[msg.sender] += msg.value;
        uint256 nonce = ++depositNonceOf[msg.sender];

        emit FundsDeposited(msg.sender, msg.value, nonce);
    }

    /// @notice Вывод без события для скоринга: вывод скор не растит, но и не
    /// отнимает (v1) — накрутку циркуляцией гасит DEPOSIT_SCORE_CAP на CC3-стороне.
    function withdraw(uint256 amount) external {
        require(amount > 0, "zero amount");
        require(amount <= balanceOf[msg.sender], "insufficient balance");

        balanceOf[msg.sender] -= amount;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "ETH transfer failed");
    }
}
