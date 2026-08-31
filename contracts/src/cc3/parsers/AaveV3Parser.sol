// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";

/// @title AaveV3Parser
/// @notice Single implementation of the Aave v3 Pool event layouts consumed by the
/// TruthGate credit bureau: Repay (DISCIPLINE, positive) and LiquidationCall
/// (negative signal). The layouts are Aave's real ones, byte-for-byte — one parser
/// is valid against the simulator (LoanBookSim), the live Aave v3 Sepolia Pool and
/// the live Aave v3 mainnet Pool.
/// @dev Also covers SparkLend: the fork emits byte-identical Repay/LiquidationCall
/// (verified against live logs of the verified mainnet Pool — see MainnetParity.t.sol),
/// so SparkLend registers with this parser and no code of its own.
/// The topic0 constants are mirrored in CreditCore (LIQUIDATION_EVENT_SIGNATURE);
/// the parity test asserts they stay equal.
library AaveV3Parser {
    // keccak256("Repay(address,address,address,uint256,bool)")
    // event Repay(address indexed reserve, address indexed user, address indexed repayer,
    //             uint256 amount, bool useATokens)
    bytes32 internal constant REPAY_TOPIC0 =
        0xa534c8dbe71f871f9f3530e97a74601fea17b426cae02e1c5aee42c96c784051;

    // keccak256("LiquidationCall(address,address,address,uint256,uint256,address,bool)")
    // event LiquidationCall(address indexed collateralAsset, address indexed debtAsset,
    //             address indexed user, uint256 debtToCover,
    //             uint256 liquidatedCollateralAmount, address liquidator, bool receiveAToken)
    bytes32 internal constant LIQUIDATION_CALL_TOPIC0 =
        0xe413a321e8681d831f4dbccbca790d2952b56f977908e45be37335533e005286;

    struct Repay {
        address reserve;
        /// @dev The credit-bureau subject: the borrower whose debt shrinks.
        address user;
        address repayer;
        /// @dev Denominated in the reserve token's native decimals — heterogeneous
        /// across reserves; MUST NOT enter scoring arithmetic without an oracle.
        uint256 amount;
        bool useATokens;
    }

    struct LiquidationCall {
        address collateralAsset;
        address debtAsset;
        /// @dev The credit-bureau subject: the liquidated borrower.
        address user;
        /// @dev Reserve-token denominated — emit-only, never enters formulas.
        uint256 debtToCover;
        uint256 liquidatedCollateralAmount;
        address liquidator;
        bool receiveAToken;
    }

    function parseRepay(EvmV1Decoder.LogEntry memory log) internal pure returns (Repay memory r) {
        require(log.topics.length == 4, "Invalid Repay topics");
        require(log.data.length == 64, "Invalid Repay data");
        r.reserve = address(uint160(uint256(log.topics[1])));
        r.user = address(uint160(uint256(log.topics[2])));
        r.repayer = address(uint160(uint256(log.topics[3])));
        (r.amount, r.useATokens) = abi.decode(log.data, (uint256, bool));
    }

    function parseLiquidationCall(EvmV1Decoder.LogEntry memory log)
        internal
        pure
        returns (LiquidationCall memory l)
    {
        require(log.topics.length == 4, "Invalid LiquidationCall topics");
        require(log.data.length == 128, "Invalid LiquidationCall data");
        l.collateralAsset = address(uint160(uint256(log.topics[1])));
        l.debtAsset = address(uint160(uint256(log.topics[2])));
        l.user = address(uint160(uint256(log.topics[3])));
        (l.debtToCover, l.liquidatedCollateralAmount, l.liquidator, l.receiveAToken) =
            abi.decode(log.data, (uint256, uint256, address, bool));
    }
}
