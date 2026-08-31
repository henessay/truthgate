// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";
import {EigenLayerParser} from "../src/cc3/parsers/EigenLayerParser.sol";

/// @notice Layout tests for the EigenLayer StrategyManager Deposit parser (the
/// CURRENT 3-parameter, nothing-indexed layout). Parity against a real mainnet
/// transaction lives in MainnetParity.t.sol.
contract EigenLayerParserTest is Test {
    function _log(bytes32[] memory topics, bytes memory data)
        internal
        pure
        returns (EvmV1Decoder.LogEntry memory l)
    {
        l.address_ = address(0);
        l.topics = topics;
        l.data = data;
    }

    function _oneTopic() internal pure returns (bytes32[] memory topics) {
        topics = new bytes32[](1);
        topics[0] = EigenLayerParser.DEPOSIT_TOPIC0;
    }

    function test_topic0MatchesSignatureStringAndLiteral() public pure {
        assertEq(EigenLayerParser.DEPOSIT_TOPIC0, keccak256("Deposit(address,address,uint256)"));
        // Literal pinned so a typo in the signature string cannot self-confirm;
        // verified against a live mainnet StrategyManager emission (MainnetParity.t.sol)
        assertEq(
            EigenLayerParser.DEPOSIT_TOPIC0,
            0x5548c837ab068cf56a2c2479df0882a4922fd203edb7517321831d95078c5f62
        );
    }

    function test_parseDeposit_decodesAllFields_stakerFromData() public pure {
        address staker = address(0x57A4E);
        address strategy = address(0x5717);

        EigenLayerParser.Deposit memory d = EigenLayerParser.parseDeposit(
            _log(_oneTopic(), abi.encode(staker, strategy, uint256(3e18)))
        );

        // Nothing is indexed in this event — the subject comes from data, not topics
        assertEq(d.staker, staker);
        assertEq(d.strategy, strategy);
        assertEq(d.shares, 3e18);
    }

    function test_parseDeposit_rejectsMalformedShapes() public {
        // The pre-slashing 4-parameter layout carried (staker, token, strategy, shares)
        // = 128 bytes of data; it must NOT decode through the current parser
        vm.expectRevert(bytes("Invalid EigenLayer Deposit data"));
        this.parseExternal(
            _log(_oneTopic(), abi.encode(address(0x1), address(0x2), address(0x3), uint256(1)))
        );

        bytes32[] memory twoTopics = new bytes32[](2);
        twoTopics[0] = EigenLayerParser.DEPOSIT_TOPIC0;
        vm.expectRevert(bytes("Invalid EigenLayer Deposit topics"));
        this.parseExternal(_log(twoTopics, abi.encode(address(0x1), address(0x2), uint256(1))));
    }

    // expectRevert needs an external call frame for library reverts
    function parseExternal(EvmV1Decoder.LogEntry memory log) external pure {
        EigenLayerParser.parseDeposit(log);
    }
}
