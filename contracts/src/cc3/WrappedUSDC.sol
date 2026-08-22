// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title WrappedUSDC
/// @notice Wrapper for USDC locked in the RepaymentVault on Sepolia. Minted ONLY
/// by the RepaymentBridge against a proven UsdcLockedForRepayment.
/// 18 decimals: native USDC carries 6; the ×1e12 normalization is done by
/// RepaymentBridge (USDC_DECIMALS_SCALING) — amounts here are already in the
/// 18-dec units of the CC3 world.
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
