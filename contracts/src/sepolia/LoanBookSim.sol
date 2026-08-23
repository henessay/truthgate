// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title LoanBookSim
/// @notice SIMULATOR of an external credit history on Sepolia — demo only.
/// In production this slot is a real credit protocol (an Aave-like order book etc.)
/// whose repayment events TruthGate proves via USC proofs. The simulator exists to
/// demonstrate onboarding a borrower with pre-existing history: the owner "replays"
/// repayments, and the worker proves them into CreditCore (action ScoreRepayment).
/// IMPORTANT: the event signature must match CreditCore.REPAY_EVENT_SIGNATURE
/// byte-for-byte (see test/EventParity.t.sol).
contract LoanBookSim is Ownable {
    /// @dev keccak256("LoanRepaidOnEth(address,uint256,uint256)") ==
    /// CreditCore.REPAY_EVENT_SIGNATURE. CreditCore expects: topics.length == 2
    /// (only borrower indexed), data == abi.encode(loanId, amount) (64 bytes).
    event LoanRepaidOnEth(address indexed borrower, uint256 loanId, uint256 amount);

    /// @dev Aave v3 Pool's real LiquidationCall event, byte-for-byte — NOT a custom
    /// signature. keccak256 == CreditCore.LIQUIDATION_EVENT_SIGNATURE. The layout is
    /// mirrored exactly so the liquidation parser has a single implementation that is
    /// valid against both this simulator and a real Aave deployment (zero divergence).
    /// CreditCore expects: topics.length == 4 (collateralAsset, debtAsset, user
    /// indexed), data == abi.encode(debtToCover, liquidatedCollateralAmount,
    /// liquidator, receiveAToken) (128 bytes).
    event LiquidationCall(
        address indexed collateralAsset,
        address indexed debtAsset,
        address indexed user,
        uint256 debtToCover,
        uint256 liquidatedCollateralAmount,
        address liquidator,
        bool receiveAToken
    );

    constructor() Ownable(msg.sender) {}

    function simulateRepayment(address borrower, uint256 loanId, uint256 amount) external onlyOwner {
        require(borrower != address(0), "zero borrower");
        require(amount > 0, "zero amount");

        emit LoanRepaidOnEth(borrower, loanId, amount);
    }

    /// @notice Simulates a liquidation of `user` as a real Aave v3 pool would emit it.
    function simulateLiquidation(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        uint256 liquidatedCollateralAmount,
        address liquidator,
        bool receiveAToken
    ) external onlyOwner {
        require(user != address(0), "zero user");
        require(debtToCover > 0, "zero debt");

        emit LiquidationCall(
            collateralAsset, debtAsset, user, debtToCover, liquidatedCollateralAmount, liquidator, receiveAToken
        );
    }
}
