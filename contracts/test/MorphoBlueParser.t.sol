// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";
import {MorphoBlueParser} from "../src/cc3/parsers/MorphoBlueParser.sol";

/// @notice Layout tests for the Morpho Blue parsers: signature pinning, happy-path
/// decoding of forged well-formed logs, and rejection of malformed shapes. Parity
/// against real mainnet transactions lives in MainnetParity.t.sol.
contract MorphoBlueParserTest is Test {
    function _log(bytes32[] memory topics, bytes memory data)
        internal
        pure
        returns (EvmV1Decoder.LogEntry memory l)
    {
        l.address_ = address(0);
        l.topics = topics;
        l.data = data;
    }

    function _topics4(bytes32 t0, bytes32 t1, bytes32 t2, bytes32 t3)
        internal
        pure
        returns (bytes32[] memory topics)
    {
        topics = new bytes32[](4);
        topics[0] = t0;
        topics[1] = t1;
        topics[2] = t2;
        topics[3] = t3;
    }

    // ---------- signature pinning ----------

    function test_topic0MatchesSignatureStringsAndLiterals() public pure {
        // The Id user-defined type is bytes32 in the canonical ABI signature.
        // Literals pinned so a typo in a signature string cannot self-confirm;
        // both verified against live mainnet singleton emissions (MainnetParity.t.sol).
        assertEq(
            MorphoBlueParser.REPAY_TOPIC0, keccak256("Repay(bytes32,address,address,uint256,uint256)")
        );
        assertEq(
            MorphoBlueParser.REPAY_TOPIC0,
            0x52acb05cebbd3cd39715469f22afbf5a17496295ef3bc9bb5944056c63ccaa09
        );
        assertEq(
            MorphoBlueParser.LIQUIDATE_TOPIC0,
            keccak256("Liquidate(bytes32,address,address,uint256,uint256,uint256,uint256,uint256)")
        );
        assertEq(
            MorphoBlueParser.LIQUIDATE_TOPIC0,
            0xa4946ede45d0c6f06a0f5ce92c9ad3b4751452d2fe0e25010783bcab57a67e41
        );
    }

    // ---------- Repay ----------

    function test_parseRepay_decodesAllFields() public pure {
        bytes32 marketId = bytes32(uint256(0x1234));
        address caller = address(0xCA11);
        address onBehalf = address(0xB0B);

        MorphoBlueParser.Repay memory r = MorphoBlueParser.parseRepay(
            _log(
                _topics4(
                    MorphoBlueParser.REPAY_TOPIC0,
                    marketId,
                    bytes32(uint256(uint160(caller))),
                    bytes32(uint256(uint160(onBehalf)))
                ),
                abi.encode(uint256(500e6), uint256(490e6))
            )
        );

        assertEq(r.marketId, marketId);
        assertEq(r.caller, caller);
        // The bureau subject is onBehalf, not caller — a third party repaying FOR
        // the borrower credits the borrower
        assertEq(r.onBehalf, onBehalf);
        assertEq(r.assets, 500e6);
        assertEq(r.shares, 490e6);
    }

    function test_parseRepay_rejectsMalformedShapes() public {
        bytes32[] memory threeTopics = new bytes32[](3);
        threeTopics[0] = MorphoBlueParser.REPAY_TOPIC0;
        vm.expectRevert(bytes("Invalid Morpho Repay topics"));
        this.parseRepayExternal(_log(threeTopics, abi.encode(uint256(1), uint256(1))));

        vm.expectRevert(bytes("Invalid Morpho Repay data"));
        this.parseRepayExternal(
            _log(
                _topics4(MorphoBlueParser.REPAY_TOPIC0, bytes32(0), bytes32(0), bytes32(0)),
                abi.encode(uint256(1)) // 32 bytes, not 64
            )
        );
    }

    // ---------- Liquidate ----------

    function test_parseLiquidate_decodesAllFields() public pure {
        bytes32 marketId = bytes32(uint256(0x5678));
        address caller = address(0x11C0);
        address borrower = address(0xBAD);

        MorphoBlueParser.Liquidate memory l = MorphoBlueParser.parseLiquidate(
            _log(
                _topics4(
                    MorphoBlueParser.LIQUIDATE_TOPIC0,
                    marketId,
                    bytes32(uint256(uint160(caller))),
                    bytes32(uint256(uint160(borrower)))
                ),
                abi.encode(uint256(100e18), uint256(99e18), uint256(1e18), uint256(3), uint256(2))
            )
        );

        assertEq(l.marketId, marketId);
        assertEq(l.caller, caller);
        assertEq(l.borrower, borrower);
        assertEq(l.repaidAssets, 100e18);
        assertEq(l.repaidShares, 99e18);
        assertEq(l.seizedAssets, 1e18);
        assertEq(l.badDebtAssets, 3);
        assertEq(l.badDebtShares, 2);
    }

    function test_parseLiquidate_rejectsMalformedShapes() public {
        bytes32[] memory threeTopics = new bytes32[](3);
        threeTopics[0] = MorphoBlueParser.LIQUIDATE_TOPIC0;
        vm.expectRevert(bytes("Invalid Morpho Liquidate topics"));
        this.parseLiquidateExternal(
            _log(threeTopics, abi.encode(uint256(1), uint256(1), uint256(1), uint256(0), uint256(0)))
        );

        // 128 bytes (the Aave LiquidationCall shape) must not pass for Morpho's 160
        vm.expectRevert(bytes("Invalid Morpho Liquidate data"));
        this.parseLiquidateExternal(
            _log(
                _topics4(MorphoBlueParser.LIQUIDATE_TOPIC0, bytes32(0), bytes32(0), bytes32(0)),
                abi.encode(uint256(1), uint256(1), uint256(1), uint256(0))
            )
        );
    }

    // expectRevert needs an external call frame for library reverts
    function parseRepayExternal(EvmV1Decoder.LogEntry memory log) external pure {
        MorphoBlueParser.parseRepay(log);
    }

    function parseLiquidateExternal(EvmV1Decoder.LogEntry memory log) external pure {
        MorphoBlueParser.parseLiquidate(log);
    }
}
