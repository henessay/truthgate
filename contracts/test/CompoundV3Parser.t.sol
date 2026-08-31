// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";
import {CompoundV3Parser} from "../src/cc3/parsers/CompoundV3Parser.sol";

/// @notice Layout tests for the Compound v3 (Comet) AbsorbDebt parser: signature
/// pinning, happy-path decoding, malformed-shape rejection. Parity against a real
/// mainnet transaction lives in MainnetParity.t.sol.
contract CompoundV3ParserTest is Test {
    function _log(bytes32[] memory topics, bytes memory data)
        internal
        pure
        returns (EvmV1Decoder.LogEntry memory l)
    {
        l.address_ = address(0);
        l.topics = topics;
        l.data = data;
    }

    function _topics3(bytes32 t0, bytes32 t1, bytes32 t2)
        internal
        pure
        returns (bytes32[] memory topics)
    {
        topics = new bytes32[](3);
        topics[0] = t0;
        topics[1] = t1;
        topics[2] = t2;
    }

    function test_topic0MatchesSignatureStringAndLiteral() public pure {
        // Literal pinned so a typo in the signature string cannot self-confirm;
        // verified against a live mainnet cUSDCv3 emission (MainnetParity.t.sol)
        assertEq(
            CompoundV3Parser.ABSORB_DEBT_TOPIC0,
            keccak256("AbsorbDebt(address,address,uint256,uint256)")
        );
        assertEq(
            CompoundV3Parser.ABSORB_DEBT_TOPIC0,
            0x1547a878dc89ad3c367b6338b4be6a65a5dd74fb77ae044da1e8747ef1f4f62f
        );
    }

    function test_parseAbsorbDebt_decodesAllFields() public pure {
        address absorber = address(0xAB50);
        address borrower = address(0xBAD);

        CompoundV3Parser.AbsorbDebt memory a = CompoundV3Parser.parseAbsorbDebt(
            _log(
                _topics3(
                    CompoundV3Parser.ABSORB_DEBT_TOPIC0,
                    bytes32(uint256(uint160(absorber))),
                    bytes32(uint256(uint160(borrower)))
                ),
                abi.encode(uint256(500e6), uint256(501e8))
            )
        );

        assertEq(a.absorber, absorber);
        assertEq(a.borrower, borrower);
        assertEq(a.basePaidOut, 500e6); // base-token units (6-dec for cUSDCv3)
        assertEq(a.usdValue, 501e8); // Comet's 8-dec USD estimate
    }

    function test_parseAbsorbDebt_rejectsMalformedShapes() public {
        // 4 topics (the Aave/Morpho liquidation shape) must not pass for Comet's 3
        bytes32[] memory fourTopics = new bytes32[](4);
        fourTopics[0] = CompoundV3Parser.ABSORB_DEBT_TOPIC0;
        vm.expectRevert(bytes("Invalid AbsorbDebt topics"));
        this.parseAbsorbDebtExternal(_log(fourTopics, abi.encode(uint256(1), uint256(1))));

        vm.expectRevert(bytes("Invalid AbsorbDebt data"));
        this.parseAbsorbDebtExternal(
            _log(
                _topics3(CompoundV3Parser.ABSORB_DEBT_TOPIC0, bytes32(0), bytes32(0)),
                abi.encode(uint256(1)) // 32 bytes, not 64
            )
        );
    }

    // expectRevert needs an external call frame for library reverts
    function parseAbsorbDebtExternal(EvmV1Decoder.LogEntry memory log) external pure {
        CompoundV3Parser.parseAbsorbDebt(log);
    }
}
