// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";
import {RocketPoolParser} from "../src/cc3/parsers/RocketPoolParser.sol";

/// @notice Layout tests for the Rocket Pool DepositReceived parser. Parity against
/// a real mainnet transaction lives in MainnetParity.t.sol.
contract RocketPoolParserTest is Test {
    function _log(bytes32[] memory topics, bytes memory data)
        internal
        pure
        returns (EvmV1Decoder.LogEntry memory l)
    {
        l.address_ = address(0);
        l.topics = topics;
        l.data = data;
    }

    function test_topic0MatchesSignatureStringAndLiteral() public pure {
        assertEq(
            RocketPoolParser.DEPOSIT_RECEIVED_TOPIC0,
            keccak256("DepositReceived(address,uint256,uint256)")
        );
        // Literal pinned so a typo in the signature string cannot self-confirm;
        // verified against a live mainnet deposit-pool emission (MainnetParity.t.sol)
        assertEq(
            RocketPoolParser.DEPOSIT_RECEIVED_TOPIC0,
            0x7aa1a8eb998c779420645fc14513bf058edb347d95c2fc2e6845bdc22f888631
        );
    }

    function test_parseDepositReceived_decodesAllFields() public pure {
        address from = address(0xF00D);
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = RocketPoolParser.DEPOSIT_RECEIVED_TOPIC0;
        topics[1] = bytes32(uint256(uint160(from)));

        RocketPoolParser.DepositReceived memory d = RocketPoolParser.parseDepositReceived(
            _log(topics, abi.encode(uint256(2 ether), uint256(1_777_000_000)))
        );

        assertEq(d.from, from);
        assertEq(d.amount, 2 ether); // native ETH wei (msg.value)
        assertEq(d.time, 1_777_000_000);
    }

    function test_parseDepositReceived_rejectsMalformedShapes() public {
        bytes32[] memory threeTopics = new bytes32[](3);
        threeTopics[0] = RocketPoolParser.DEPOSIT_RECEIVED_TOPIC0;
        vm.expectRevert(bytes("Invalid DepositReceived topics"));
        this.parseExternal(_log(threeTopics, abi.encode(uint256(1), uint256(1))));

        bytes32[] memory twoTopics = new bytes32[](2);
        twoTopics[0] = RocketPoolParser.DEPOSIT_RECEIVED_TOPIC0;
        vm.expectRevert(bytes("Invalid DepositReceived data"));
        this.parseExternal(_log(twoTopics, abi.encode(uint256(1)))); // 32 bytes, not 64
    }

    // expectRevert needs an external call frame for library reverts
    function parseExternal(EvmV1Decoder.LogEntry memory log) external pure {
        RocketPoolParser.parseDepositReceived(log);
    }
}
