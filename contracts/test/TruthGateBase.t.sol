// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TruthGateBase} from "../src/cc3/TruthGateBase.sol";
import {INativeQueryVerifier, NativeQueryVerifierLib} from "../src/cc3/INativeQueryVerifier.sol";
import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";

/// @dev Mock of the block-prover precompile. Its runtime code is etched at the real
/// precompile address (0x…0FD2), so storage reads/writes below happen at that address.
/// The revert flags let tests prove that a revert happened BEFORE any precompile call.
contract MockNativeQueryVerifier {
    bool public revertOnCalculate;
    bool public revertOnVerify;
    uint64 public txIndex;

    function setRevertOnCalculate(bool v) external { revertOnCalculate = v; }
    function setRevertOnVerify(bool v) external { revertOnVerify = v; }
    function setTxIndex(uint64 v) external { txIndex = v; }

    function calculateTxIndex(INativeQueryVerifier.MerkleProof calldata) external view returns (uint64) {
        require(!revertOnCalculate, "mock: calculateTxIndex reached");
        return txIndex;
    }

    function verifyAndEmit(
        uint64,
        uint64,
        bytes calldata,
        INativeQueryVerifier.MerkleProof calldata,
        INativeQueryVerifier.ContinuityProof calldata
    ) external view returns (bool) {
        require(!revertOnVerify, "mock: verifyAndEmit reached");
        return true;
    }
}

/// @dev Concrete child exposing what reached _processAndEmitEvent and running the
/// shared log validator the way a real TruthGate module would.
contract TruthGateHarness is TruthGateBase {
    bytes32 public immutable EVENT_SIGNATURE;
    address public expectedSource;
    bool public freshnessEnforced = true;

    uint8 public lastAction;
    bytes32 public lastQueryId;
    uint64 public lastSourceHeight;
    uint256 public lastLogCount;
    bytes32 public lastTopic1;

    constructor(address _expectedSource, bytes32 _eventSignature) {
        expectedSource = _expectedSource;
        EVENT_SIGNATURE = _eventSignature;
    }

    function setFreshnessEnforced(bool v) external { freshnessEnforced = v; }

    function _isFreshnessEnforced(uint8) internal view override returns (bool) {
        return freshnessEnforced;
    }

    function _processAndEmitEvent(uint8 action, bytes32 queryId, uint64 sourceHeight, bytes memory encodedTransaction)
        internal
        override
    {
        EvmV1Decoder.LogEntry[] memory logs =
            _validateAndExtractLogs(encodedTransaction, EVENT_SIGNATURE, expectedSource);
        lastAction = action;
        lastQueryId = queryId;
        lastSourceHeight = sourceHeight;
        lastLogCount = logs.length;
        lastTopic1 = logs[0].topics[1];
    }
}

contract TruthGateBaseTest is Test {
    address constant PRECOMPILE = 0x0000000000000000000000000000000000000FD2;
    // keccak256("LoanFunded(uint256)") — same event shape the Gluwa loan example consumes
    bytes32 constant EVENT_SIG = 0x9e71d2fb732e68272b7e74ecfd14638673c1d77e19a5d390a3ffff054d57c44b;
    address constant SOURCE_CONTRACT = address(0xBEEF);
    uint64 constant HEIGHT = 8_600_000;
    uint64 constant TX_INDEX = 7;

    MockNativeQueryVerifier mock;
    TruthGateHarness gate;

    // Layout-identical to EvmV1Decoder.LogEntryTuple: (address, bytes32[], bytes)
    struct LogTuple {
        address address_;
        bytes32[] topics;
        bytes data;
    }

    function setUp() public {
        vm.etch(PRECOMPILE, address(new MockNativeQueryVerifier()).code);
        mock = MockNativeQueryVerifier(PRECOMPILE);
        mock.setTxIndex(TX_INDEX);
        gate = new TruthGateHarness(SOURCE_CONTRACT, EVENT_SIG);
    }

    // ---------- encoding helpers (EvmV1 format: abi.encode(uint8 txType, bytes[] chunks)) ----------

    function _makeLog(address emitter, uint256 loanId) internal pure returns (LogTuple memory log_) {
        log_.address_ = emitter;
        log_.topics = new bytes32[](2);
        log_.topics[0] = EVENT_SIG;
        log_.topics[1] = bytes32(loanId);
        log_.data = "";
    }

    function _encodeTx(uint8 receiptStatus, LogTuple[] memory logs) internal pure returns (bytes memory) {
        // chunk 0: common tx fields (nonce, gasLimit, from, toIsNull, to, value, data)
        bytes memory chunk0 =
            abi.encode(uint64(1), uint64(100_000), address(0xA11CE), false, SOURCE_CONTRACT, uint256(0), bytes(""));
        // chunk 1: type-specific fields — never decoded on our path, any bytes are fine
        bytes memory chunk1 = "";
        // chunk 2 (receipt for types 0-2): (receiptStatus, gasUsed, LogEntryTuple[], logsBloom)
        bytes memory chunk2 = abi.encode(receiptStatus, uint64(50_000), logs, bytes(""));

        bytes[] memory chunks = new bytes[](3);
        chunks[0] = chunk0;
        chunks[1] = chunk1;
        chunks[2] = chunk2;
        return abi.encode(uint8(2), chunks);
    }

    function _happyTx() internal pure returns (bytes memory) {
        LogTuple[] memory logs = new LogTuple[](1);
        logs[0] = _makeLog(SOURCE_CONTRACT, 42);
        return _encodeTx(1, logs);
    }

    function _execute(uint64 chainKey, uint64 height, bytes memory encodedTx) internal returns (bool) {
        INativeQueryVerifier.MerkleProofEntry[] memory siblings = new INativeQueryVerifier.MerkleProofEntry[](0);
        bytes32[] memory continuityRoots = new bytes32[](0);
        return gate.execute(0, chainKey, height, encodedTx, bytes32("root"), siblings, bytes32("digest"), continuityRoots);
    }

    function _expectedQueryId(uint64 chainKey, uint64 height, uint256 txIndex) internal pure returns (bytes32) {
        // Mirrors the assembly packing: uint256(chainKey) ‖ uint64(height) ‖ uint256(txIndex), 72 bytes
        return keccak256(abi.encodePacked(uint256(chainKey), height, txIndex));
    }

    // ---------- (д) happy path reaches _processAndEmitEvent ----------

    function test_happyPath_reachesProcessAndEmitEvent() public {
        bool ok = _execute(1, HEIGHT, _happyTx());

        assertTrue(ok);
        assertEq(gate.lastAction(), 0);
        assertEq(gate.lastLogCount(), 1);
        assertEq(gate.lastTopic1(), bytes32(uint256(42)));

        bytes32 queryId = _expectedQueryId(1, HEIGHT, TX_INDEX);
        assertEq(gate.lastQueryId(), queryId);
        assertTrue(gate.processedQueries(queryId));
    }

    // ---------- (а) replay of the same proof reverts ----------

    function test_replayReverts() public {
        _execute(1, HEIGHT, _happyTx());

        vm.expectRevert("Query already processed");
        _execute(1, HEIGHT, _happyTx());
    }

    // ---------- (б) wrong chainKey reverts before any precompile call ----------

    function test_wrongChainKey_revertsBeforeVerify() public {
        // If execute touched the precompile at all, these flags would surface the
        // mock's own revert reason instead of "wrong source chain".
        mock.setRevertOnCalculate(true);
        mock.setRevertOnVerify(true);

        vm.expectRevert("wrong source chain");
        _execute(2, HEIGHT, _happyTx());
    }

    // ---------- (в) receiptStatus == 0 reverts ----------

    function test_failedSourceTxReverts() public {
        LogTuple[] memory logs = new LogTuple[](1);
        logs[0] = _makeLog(SOURCE_CONTRACT, 42);
        bytes memory revertedTx = _encodeTx(0, logs);

        vm.expectRevert("Transaction did not succeed");
        _execute(1, HEIGHT, revertedTx);
    }

    // ---------- (г) log emitted by a foreign contract reverts ----------

    function test_logFromWrongSourceReverts() public {
        LogTuple[] memory logs = new LogTuple[](1);
        logs[0] = _makeLog(address(0xDEAD), 42); // right signature, wrong emitter

        vm.expectRevert("log from unexpected source contract");
        _execute(1, HEIGHT, _encodeTx(1, logs));
    }

    function test_mixedSourceLogsRevert() public {
        // A genuine log does not launder a forged one riding in the same tx:
        // every extracted log must come from the expected source.
        LogTuple[] memory logs = new LogTuple[](2);
        logs[0] = _makeLog(SOURCE_CONTRACT, 42);
        logs[1] = _makeLog(address(0xDEAD), 43);

        vm.expectRevert("log from unexpected source contract");
        _execute(1, HEIGHT, _encodeTx(1, logs));
    }

    // ---------- freshness window (TRUTHGATE addition) ----------

    function test_minAcceptedHeight_gatesStaleProofs() public {
        gate.setMinAcceptedHeight(HEIGHT);
        mock.setRevertOnCalculate(true); // prove the gate fires before precompile calls

        vm.expectRevert("proof below min accepted height");
        _execute(1, HEIGHT - 1, _happyTx());

        mock.setRevertOnCalculate(false);
        assertTrue(_execute(1, HEIGHT, _happyTx()));
    }

    function test_freshnessHook_canDisableGatePerAction() public {
        gate.setMinAcceptedHeight(HEIGHT);
        gate.setFreshnessEnforced(false);

        assertTrue(_execute(1, HEIGHT - 1, _happyTx()));
    }

    function test_setMinAcceptedHeight_onlyOwner() public {
        vm.prank(address(0xABBA));
        vm.expectRevert();
        gate.setMinAcceptedHeight(1);
    }
}
