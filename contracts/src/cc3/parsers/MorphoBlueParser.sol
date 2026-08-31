// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";

/// @title MorphoBlueParser
/// @notice Morpho Blue singleton event layouts consumed by the TruthGate credit
/// bureau: Repay (DISCIPLINE, positive) and Liquidate (negative signal). Event
/// declarations from the canonical morpho-org/morpho-blue EventsLib (the Id
/// user-defined type is bytes32 in the ABI signature); both topic0s and layouts
/// verified against live logs of the mainnet singleton — see MainnetParity.t.sol.
/// @dev Bureau subjects: for Repay the subject is `onBehalf` (the borrower whose
/// debt shrinks), NOT `caller` (who merely paid); for Liquidate it is `borrower`.
/// All amounts are denominated in the market's loan token (heterogeneous across
/// markets) — emit-only, never scoring arithmetic.
library MorphoBlueParser {
    // keccak256("Repay(bytes32,address,address,uint256,uint256)")
    // event Repay(Id indexed id, address indexed caller, address indexed onBehalf,
    //             uint256 assets, uint256 shares)
    bytes32 internal constant REPAY_TOPIC0 =
        0x52acb05cebbd3cd39715469f22afbf5a17496295ef3bc9bb5944056c63ccaa09;

    // keccak256("Liquidate(bytes32,address,address,uint256,uint256,uint256,uint256,uint256)")
    // event Liquidate(Id indexed id, address indexed caller, address indexed borrower,
    //             uint256 repaidAssets, uint256 repaidShares, uint256 seizedAssets,
    //             uint256 badDebtAssets, uint256 badDebtShares)
    bytes32 internal constant LIQUIDATE_TOPIC0 =
        0xa4946ede45d0c6f06a0f5ce92c9ad3b4751452d2fe0e25010783bcab57a67e41;

    struct Repay {
        bytes32 marketId;
        address caller;
        /// @dev The credit-bureau subject: the borrower whose debt shrinks.
        address onBehalf;
        /// @dev Loan-token denominated — heterogeneous across markets; emit-only.
        uint256 assets;
        uint256 shares;
    }

    struct Liquidate {
        bytes32 marketId;
        address caller;
        /// @dev The credit-bureau subject: the liquidated borrower.
        address borrower;
        /// @dev Loan-token denominated — emit-only, never enters formulas.
        uint256 repaidAssets;
        uint256 repaidShares;
        /// @dev Collateral-token denominated.
        uint256 seizedAssets;
        uint256 badDebtAssets;
        uint256 badDebtShares;
    }

    function parseRepay(EvmV1Decoder.LogEntry memory log) internal pure returns (Repay memory r) {
        require(log.topics.length == 4, "Invalid Morpho Repay topics");
        require(log.data.length == 64, "Invalid Morpho Repay data");
        r.marketId = log.topics[1];
        r.caller = address(uint160(uint256(log.topics[2])));
        r.onBehalf = address(uint160(uint256(log.topics[3])));
        (r.assets, r.shares) = abi.decode(log.data, (uint256, uint256));
    }

    function parseLiquidate(EvmV1Decoder.LogEntry memory log)
        internal
        pure
        returns (Liquidate memory l)
    {
        require(log.topics.length == 4, "Invalid Morpho Liquidate topics");
        require(log.data.length == 160, "Invalid Morpho Liquidate data");
        l.marketId = log.topics[1];
        l.caller = address(uint160(uint256(log.topics[2])));
        l.borrower = address(uint160(uint256(log.topics[3])));
        (l.repaidAssets, l.repaidShares, l.seizedAssets, l.badDebtAssets, l.badDebtShares) =
            abi.decode(log.data, (uint256, uint256, uint256, uint256, uint256));
    }
}
