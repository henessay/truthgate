// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";
import {CreditCore} from "../src/cc3/CreditCore.sol";
import {AaveV3Parser} from "../src/cc3/parsers/AaveV3Parser.sol";

/// @notice Pins every bureau parser against REAL historical transactions of the
/// live, verified mainnet contracts — raw topics and data bytes copied verbatim
/// from Ethereum mainnet logs, decoded through our parsers, every field asserted.
/// A topic0 match alone cannot catch data-layout drift when an event keeps its
/// signature string but a fork reorders or re-indexes fields; decoding real bytes
/// can. Each pin cites the source tx hash.
///
/// Verified emitters (identity checked on-chain: ADDRESSES_PROVIDER round-trip +
/// getMarketId, 2026-08-31):
///  - Aave v3 Pool (mainnet), "Aave Ethereum Market":
///    0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2
///  - SparkLend Pool (mainnet), "Spark Protocol":
///    0xC13e21B648A5Ee794902342038FF3aDAB66BE987
contract MainnetParityTest is Test {
    // Signature constants only; logic never called (stub constructor args).
    CreditCore core;

    function setUp() public {
        core = new CreditCore(payable(address(1)), 0, 0);
    }

    function _log(bytes32[] memory topics, bytes memory data)
        internal
        pure
        returns (EvmV1Decoder.LogEntry memory l)
    {
        l.address_ = address(0); // emitter checks live in the consuming contract, not the parser
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

    // ---------- library ↔ deployed-core constant parity ----------

    function test_parserConstantsMatchCreditCore() public view {
        assertEq(
            AaveV3Parser.LIQUIDATION_CALL_TOPIC0,
            core.LIQUIDATION_EVENT_SIGNATURE(),
            "parser library and CreditCore disagree on LiquidationCall topic0"
        );
        assertEq(
            AaveV3Parser.REPAY_TOPIC0,
            keccak256("Repay(address,address,address,uint256,bool)"),
            "Repay topic0 differs from its signature string"
        );
        // Pinned literals so a typo in a signature string cannot self-confirm
        assertEq(
            AaveV3Parser.REPAY_TOPIC0,
            0xa534c8dbe71f871f9f3530e97a74601fea17b426cae02e1c5aee42c96c784051
        );
        assertEq(
            AaveV3Parser.LIQUIDATION_CALL_TOPIC0,
            0xe413a321e8681d831f4dbccbca790d2952b56f977908e45be37335533e005286
        );
    }

    // ---------- Aave v3 mainnet ----------

    /// @dev Real Aave v3 mainnet Repay: 76F3..5b1a repays ~153,253 USDT for itself.
    /// tx 0x0a3e7e61076ca8614fb1a102e5fc1b498ec2c5109d4bb29ba8bb8f80dad67b67, block 25863704.
    function test_aaveV3Mainnet_repay_realTx() public pure {
        EvmV1Decoder.LogEntry memory log = _log(
            _topics4(
                AaveV3Parser.REPAY_TOPIC0,
                0x000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec7,
                0x00000000000000000000000076f30e3f75437fb862b8d2c4d80a671bceba5b1a,
                0x00000000000000000000000076f30e3f75437fb862b8d2c4d80a671bceba5b1a
            ),
            hex"00000000000000000000000000000000000000000000000000000023a00e4cdd"
            hex"0000000000000000000000000000000000000000000000000000000000000000"
        );

        AaveV3Parser.Repay memory r = AaveV3Parser.parseRepay(log);
        assertEq(r.reserve, 0xdAC17F958D2ee523a2206206994597C13D831ec7); // USDT
        assertEq(r.user, 0x76f30e3f75437fB862B8D2C4D80a671bCeBA5b1A);
        assertEq(r.repayer, 0x76f30e3f75437fB862B8D2C4D80a671bCeBA5b1A);
        assertEq(r.amount, 0x23a00e4cdd); // 6-dec USDT raw units
        assertEq(r.useATokens, false);
    }

    /// @dev Real Aave v3 mainnet LiquidationCall: user 6C59..5fF1, WETH debt covered,
    /// USDT collateral seized.
    /// tx 0x738c332fdc9b7024868036b70b1abf9004dece0585516da3388d5d1703dffbde, block 25868099.
    function test_aaveV3Mainnet_liquidationCall_realTx() public view {
        EvmV1Decoder.LogEntry memory log = _log(
            _topics4(
                core.LIQUIDATION_EVENT_SIGNATURE(),
                0x000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec7,
                0x000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2,
                0x0000000000000000000000006c59f64be01617f4979ec9a75834a9c4ca915ff1
            ),
            hex"0000000000000000000000000000000000000000000000000001e9b9d3aa10cd"
            hex"000000000000000000000000000000000000000000000000000000000015239e"
            hex"000000000000000000000000271e33ab5c2d152c74a89841173c0de419f4c83e"
            hex"0000000000000000000000000000000000000000000000000000000000000000"
        );

        AaveV3Parser.LiquidationCall memory l = AaveV3Parser.parseLiquidationCall(log);
        assertEq(l.collateralAsset, 0xdAC17F958D2ee523a2206206994597C13D831ec7); // USDT
        assertEq(l.debtAsset, 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // WETH
        assertEq(l.user, 0x6C59f64Be01617F4979eC9A75834A9C4CA915ff1);
        assertEq(l.debtToCover, 0x0001e9b9d3aa10cd); // WETH wei
        assertEq(l.liquidatedCollateralAmount, 0x15239e); // 6-dec USDT raw units
        assertEq(l.liquidator, 0x271e33Ab5C2d152c74a89841173C0De419F4c83E);
        assertEq(l.receiveAToken, false);
    }

    // ---------- SparkLend (Aave v3 fork — same parsers, zero divergence) ----------

    /// @dev Real SparkLend mainnet Repay: Ed0C..4312 repays exactly 5,000,000 USDS
    /// for itself. Layout byte-identical to Aave v3 — this is the fork-divergence guard.
    /// tx 0xde138405e078d7e25ea862e0a76259e5b9e758b906090b4f856381fa218e8b38, block 25873126.
    function test_sparkLend_repay_realTx() public pure {
        EvmV1Decoder.LogEntry memory log = _log(
            _topics4(
                AaveV3Parser.REPAY_TOPIC0,
                0x000000000000000000000000dc035d45d973e3ec169d2276ddab16f1e407384f,
                0x000000000000000000000000ed0c6079229e2d407672a117c22b62064f4a4312,
                0x000000000000000000000000ed0c6079229e2d407672a117c22b62064f4a4312
            ),
            hex"0000000000000000000000000000000000000000000422ca8b0a00a425000000"
            hex"0000000000000000000000000000000000000000000000000000000000000000"
        );

        AaveV3Parser.Repay memory r = AaveV3Parser.parseRepay(log);
        assertEq(r.reserve, 0xdC035D45d973E3EC169d2276DDab16f1e407384F); // USDS
        assertEq(r.user, 0xEd0C6079229E2d407672a117c22b62064f4a4312);
        assertEq(r.repayer, 0xEd0C6079229E2d407672a117c22b62064f4a4312);
        assertEq(r.amount, 5_000_000 ether); // 18-dec USDS: exactly 5M
        assertEq(r.useATokens, false);
    }

    /// @dev Real SparkLend mainnet LiquidationCall: user a01D..F940, DAI debt covered,
    /// WETH collateral seized.
    /// tx 0x99b9105290b5c768a13b8e8b84810eb9d4fd622ffc7340ca65bd2b3764480720, block 25873216.
    function test_sparkLend_liquidationCall_realTx() public view {
        EvmV1Decoder.LogEntry memory log = _log(
            _topics4(
                core.LIQUIDATION_EVENT_SIGNATURE(),
                0x000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2,
                0x0000000000000000000000006b175474e89094c44da98b954eedeac495271d0f,
                0x000000000000000000000000a01d1c65a61a0560591e8ec3ee7ce377b491f940
            ),
            hex"000000000000000000000000000000000000000000000000060d8d70b4d461ab"
            hex"0000000000000000000000000000000000000000000000000000aa174f43cd66"
            hex"000000000000000000000000e08d97e151473a848c3d9ca3f323cb720472d015"
            hex"0000000000000000000000000000000000000000000000000000000000000000"
        );

        AaveV3Parser.LiquidationCall memory l = AaveV3Parser.parseLiquidationCall(log);
        assertEq(l.collateralAsset, 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // WETH
        assertEq(l.debtAsset, 0x6B175474E89094C44Da98b954EedeAC495271d0F); // DAI
        assertEq(l.user, 0xA01d1C65A61a0560591e8ec3eE7cE377b491F940);
        assertEq(l.debtToCover, 0x060d8d70b4d461ab); // DAI wei
        assertEq(l.liquidatedCollateralAmount, 0xaa174f43cd66); // WETH wei
        assertEq(l.liquidator, 0xE08D97e151473A848C3d9CA3f323Cb720472D015);
        assertEq(l.receiveAToken, false);
    }
}
