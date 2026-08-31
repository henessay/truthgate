// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title FixedPriceOracle
/// @notice Constant-price oracle for the TruthGate demo market on Morpho Blue
/// Sepolia. Implements Morpho's IOracle: price() returns the price of one unit
/// of collateral token in loan-token units, scaled by 1e36 (adjusted for both
/// tokens' decimals). E.g. 18-dec DAI collateral vs 6-dec tUSDC loan at 1:1
/// economics → 1e36 × 1e6 / 1e18 = 1e24.
/// @dev Scope: this oracle serves Morpho's INTERNAL LLTV mechanics only — the
/// health check at borrow time inside the demo market. The credit bureau records
/// the resulting Repay event as fact, with amounts emit-only; the bureau's
/// no-hardcoded-prices rule applies to scoring, not to the demo market's
/// internal plumbing. Sepolia only — never a production pricing source.
contract FixedPriceOracle {
    uint256 public immutable PRICE;

    constructor(uint256 fixedPrice) {
        require(fixedPrice > 0, "zero price");
        PRICE = fixedPrice;
    }

    /// @notice Morpho Blue IOracle entrypoint.
    function price() external view returns (uint256) {
        return PRICE;
    }
}
