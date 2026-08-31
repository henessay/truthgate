// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";

/// @title RocketPoolParser
/// @notice Rocket Pool deposit-pool event layout consumed by the TruthGate credit
/// bureau: DepositReceived (CAPITAL, positive — proven ETH staked into the
/// protocol). Declaration from the canonical rocket-pool/rocketpool
/// RocketDepositPool (`emit DepositReceived(msg.sender, msg.value, block.timestamp)`);
/// layout verified against a live log of the current mainnet deposit pool —
/// see MainnetParity.t.sol.
/// @dev Rocket Pool contracts are upgradeable through RocketStorage: the live
/// deposit-pool address is `RocketStorage.getAddress(keccak256("contract.address"
/// ‖ "rocketDepositPool"))` and changes across protocol upgrades — a registered
/// source must be re-resolved after Rocket Pool upgrades. The amount is native
/// ETH (msg.value), i.e. homogeneous with the bureau's other ETH-denominated
/// CAPITAL sources — it MAY enter the capped CAPITAL formula directly.
library RocketPoolParser {
    // keccak256("DepositReceived(address,uint256,uint256)")
    // event DepositReceived(address indexed from, uint256 amount, uint256 time)
    bytes32 internal constant DEPOSIT_RECEIVED_TOPIC0 =
        0x7aa1a8eb998c779420645fc14513bf058edb347d95c2fc2e6845bdc22f888631;

    struct DepositReceived {
        /// @dev The credit-bureau subject: the depositor (msg.sender of deposit()).
        address from;
        /// @dev Native ETH wei (msg.value) — homogeneous, formula-eligible.
        uint256 amount;
        uint256 time;
    }

    function parseDepositReceived(EvmV1Decoder.LogEntry memory log)
        internal
        pure
        returns (DepositReceived memory d)
    {
        require(log.topics.length == 2, "Invalid DepositReceived topics");
        require(log.data.length == 64, "Invalid DepositReceived data");
        d.from = address(uint160(uint256(log.topics[1])));
        (d.amount, d.time) = abi.decode(log.data, (uint256, uint256));
    }
}
