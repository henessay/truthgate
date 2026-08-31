// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";

/// @title EigenLayerParser
/// @notice EigenLayer StrategyManager event layout consumed by the TruthGate
/// credit bureau: Deposit (CAPITAL, positive — proven restaked capital).
/// @dev This is the CURRENT (slashing-era, v1.x) layout, verified against live
/// logs of the mainnet StrategyManager proxy: `Deposit(address staker,
/// IStrategy strategy, uint256 shares)` with NO indexed parameters — one topic,
/// all three fields in data. The pre-slashing releases emitted a 4-parameter
/// `Deposit(staker, token, strategy, shares)`; that layout no longer appears on
/// mainnet (0 logs in a 100k-block scan) and is deliberately NOT supported —
/// a live-log check, not the interface from memory, is what caught this drift
/// (see MainnetParity.t.sol).
/// `shares` are strategy-share units of an arbitrary LST — heterogeneous across
/// strategies and not 1:1 with ETH — so per the bureau's design rule the amount
/// is emit-only: EigenLayer CAPITAL credit is flat per proven event and draws
/// from the same joint CAPITAL cap as ETH deposits (capital counted once).
library EigenLayerParser {
    // keccak256("Deposit(address,address,uint256)")
    // event Deposit(address staker, IStrategy strategy, uint256 shares) — nothing indexed
    bytes32 internal constant DEPOSIT_TOPIC0 =
        0x5548c837ab068cf56a2c2479df0882a4922fd203edb7517321831d95078c5f62;

    struct Deposit {
        /// @dev The credit-bureau subject: the restaker. NOT indexed — read from data.
        address staker;
        address strategy;
        /// @dev Strategy-share units (heterogeneous per strategy) — emit-only.
        uint256 shares;
    }

    function parseDeposit(EvmV1Decoder.LogEntry memory log)
        internal
        pure
        returns (Deposit memory d)
    {
        require(log.topics.length == 1, "Invalid EigenLayer Deposit topics");
        require(log.data.length == 96, "Invalid EigenLayer Deposit data");
        (d.staker, d.strategy, d.shares) = abi.decode(log.data, (address, address, uint256));
    }
}
