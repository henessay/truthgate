// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ScoringVault
/// @notice Sepolia emitter of provable facts for TruthGate scoring on CC3.
/// No extra logic: an ETH deposit → an event, which the worker proves via a
/// USC proof into CreditCore (action ScoreDeposit).
/// IMPORTANT: the event signature must match CreditCore.DEPOSIT_EVENT_SIGNATURE
/// byte-for-byte (see test/EventParity.t.sol).
contract ScoringVault {
    mapping(address => uint256) public balanceOf;
    /// @notice Incremental per-depositor deposit counter (numbering starts at 1).
    mapping(address => uint256) public depositNonceOf;

    /// @dev keccak256("FundsDeposited(address,uint256,uint256)") ==
    /// CreditCore.DEPOSIT_EVENT_SIGNATURE. CreditCore expects: topics.length == 2
    /// (only depositor indexed), data == abi.encode(amount, nonce) (64 bytes).
    event FundsDeposited(address indexed depositor, uint256 amount, uint256 nonce);

    function deposit() external payable {
        require(msg.value > 0, "zero deposit");

        balanceOf[msg.sender] += msg.value;
        uint256 nonce = ++depositNonceOf[msg.sender];

        emit FundsDeposited(msg.sender, msg.value, nonce);
    }

    /// @notice Withdrawal without a scoring event: withdrawing neither grows nor
    /// (in v1) reduces the score — score farming by circulation is countered by
    /// DEPOSIT_SCORE_CAP on the CC3 side.
    function withdraw(uint256 amount) external {
        require(amount > 0, "zero amount");
        require(amount <= balanceOf[msg.sender], "insufficient balance");

        balanceOf[msg.sender] -= amount;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "ETH transfer failed");
    }
}
