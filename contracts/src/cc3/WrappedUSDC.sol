// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title WrappedUSDC
/// @notice Обёртка USDC, запертого в RepaymentVault на Sepolia. Минтится ТОЛЬКО
/// RepaymentBridge'ем против доказанного UsdcLockedForRepayment.
/// 18 decimals: нативный USDC несёт 6, нормализацию ×1e12 делает RepaymentBridge
/// (USDC_DECIMALS_SCALING) — здесь суммы уже в 18-dec единицах CC3-мира.
contract WrappedUSDC is ERC20 {
    address public immutable MINTER;

    constructor(address minter) ERC20("TruthGate Wrapped USDC", "wUSDC") {
        MINTER = minter;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == MINTER, "not minter");
        _mint(to, amount);
    }
}
