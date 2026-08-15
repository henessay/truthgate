// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";
import {INativeQueryVerifier, NativeQueryVerifierLib} from "./INativeQueryVerifier.sol";

/// @title TruthGateBase
/// @notice TruthGate fork of Gluwa's USCBase pattern (docs/vendor/sol/examples/USCBase.sol):
/// proof intake with chainKey pinning, replay protection by queryId, optional freshness
/// window, and a shared log validator that enforces the emitting contract address.
abstract contract TruthGateBase is Ownable {
    /// @notice The Native Query Verifier precompile instance
    /// @dev Address: 0x0000000000000000000000000000000000000FD2 (4050 decimal)
    INativeQueryVerifier public immutable VERIFIER;

    // TRUTHGATE: chainKey закреплён константой. USCBase принимает proof'ы с любого
    // attested-чейна (chainKey приходит из calldata и не проверяется) — мы принимаем
    // только Ethereum Sepolia, чей chainKey в сети Creditcoin равен 1.
    uint64 public constant EXPECTED_CHAIN_KEY = 1;

    // TRUTHGATE: окно свежести. Proof'ы с blockHeight ниже этой отметки отклоняются
    // для action'ов, у которых наследник оставил проверку включённой (см.
    // _isFreshnessEnforced). По умолчанию 0 — проверка ничего не отсекает.
    uint64 public minAcceptedHeight;

    mapping(bytes32 => bool) public processedQueries;

    event MinAcceptedHeightUpdated(uint64 newMinAcceptedHeight);

    constructor() Ownable(msg.sender) {
        // Get the precompile instance using the helper library
        VERIFIER = NativeQueryVerifierLib.getVerifier();
    }

    // TRUTHGATE: в отличие от USCBase, наследнику передаётся и sourceHeight — высота
    // блока source-чейна из proof'а. Нужна модулям, сверяющим дедлайны с моментом
    // события на source-чейне (RepaymentBridge), а не с block.number CC3.
    function _processAndEmitEvent(uint8 action, bytes32 queryId, uint64 sourceHeight, bytes memory encodedTransaction)
        internal
        virtual;

    // TRUTHGATE: хук окна свежести — наследник решает, применять ли minAcceptedHeight
    // к конкретному action. По умолчанию проверка включена для всех action'ов.
    function _isFreshnessEnforced(uint8 action) internal view virtual returns (bool) {
        action; // silence unused-parameter warning in the default implementation
        return true;
    }

    // TRUTHGATE: owner-сеттер окна свежести.
    function setMinAcceptedHeight(uint64 newMinAcceptedHeight) external onlyOwner {
        minAcceptedHeight = newMinAcceptedHeight;
        emit MinAcceptedHeightUpdated(newMinAcceptedHeight);
    }

    function execute(
        uint8 action,
        uint64 chainKey,
        uint64 blockHeight,
        bytes calldata encodedTransaction,
        bytes32 merkleRoot,
        INativeQueryVerifier.MerkleProofEntry[] calldata siblings,
        bytes32 lowerEndpointDigest,
        bytes32[] calldata continuityRoots
    ) external returns (bool success) {
        // TRUTHGATE: первая проверка — источник proof'а. До вычисления queryId и до
        // verify: proof с чужого чейна отсекается ещё до вызовов precompile.
        require(chainKey == EXPECTED_CHAIN_KEY, "wrong source chain");

        // TRUTHGATE: окно свежести (если включено для этого action) — тоже до
        // дорогостоящих вызовов precompile.
        if (_isFreshnessEnforced(action)) {
            require(blockHeight >= minAcceptedHeight, "proof below min accepted height");
        }

        bytes32 queryId = _computeQueryId(chainKey, blockHeight, merkleRoot, siblings);

        require(!processedQueries[queryId], "Query already processed");

        // First we verify the proof
        bool verified = _verifyProof(
            chainKey, blockHeight, encodedTransaction, merkleRoot, siblings, lowerEndpointDigest, continuityRoots
        );
        require(verified, "Proof of inclusion verification failed");

        // Mark the query as processed
        processedQueries[queryId] = true;

        _processAndEmitEvent(action, queryId, blockHeight, encodedTransaction);

        return true;
    }

    function _verifyProof(
        uint64 chainKey,
        uint64 blockHeight,
        bytes calldata encodedTransaction,
        bytes32 merkleRoot,
        INativeQueryVerifier.MerkleProofEntry[] calldata siblings,
        bytes32 lowerEndpointDigest,
        bytes32[] calldata continuityRoots
    ) internal returns (bool verified) {
        INativeQueryVerifier.MerkleProof memory merkleProof =
            INativeQueryVerifier.MerkleProof({root: merkleRoot, siblings: siblings});

        INativeQueryVerifier.ContinuityProof memory continuityProof =
            INativeQueryVerifier.ContinuityProof({lowerEndpointDigest: lowerEndpointDigest, roots: continuityRoots});

        // Verify inclusion proof
        verified = VERIFIER.verifyAndEmit(chainKey, blockHeight, encodedTransaction, merkleProof, continuityProof);

        return verified;
    }

    function _computeQueryId(
        uint64 chainKey,
        uint64 blockHeight,
        bytes32 merkleRoot,
        INativeQueryVerifier.MerkleProofEntry[] calldata siblings
    ) internal view returns (bytes32 queryId) {
        INativeQueryVerifier.MerkleProof memory merkle_proof =
            INativeQueryVerifier.MerkleProof({ root: merkleRoot, siblings: siblings });

        uint256 txIndex = VERIFIER.calculateTxIndex(merkle_proof);

        assembly {
            let ptr := mload(0x40)
            mstore(ptr, chainKey)
            mstore(add(ptr, 32), shl(192, blockHeight))
            mstore(add(ptr, 40), txIndex)
            queryId := keccak256(ptr, 72)
        }
    }

    // TRUTHGATE: общий валидатор содержимого транзакции. Объединяет
    // USCLoanManager._validateTransactionContents (тип транзакции, receiptStatus == 1,
    // фильтр логов по сигнатуре) с обязательной проверкой адреса-эмитента для КАЖДОГО
    // извлечённого лога — у Gluwa эта проверка была отдельным шагом и только для
    // первого лога. Инвариант №1 проекта (RxStatus == 1) живёт здесь.
    function _validateAndExtractLogs(
        bytes memory encodedTransaction,
        bytes32 eventSignature,
        address expectedSource
    ) internal pure returns (EvmV1Decoder.LogEntry[] memory selectedEventLogs) {
        require(expectedSource != address(0), "source contract not set");

        // Validate transaction type
        uint8 txType = EvmV1Decoder.getTransactionType(encodedTransaction);
        require(EvmV1Decoder.isValidTransactionType(txType), "Unsupported transaction type");

        // Decode and validate receipt status
        EvmV1Decoder.ReceiptFields memory receipt = EvmV1Decoder.decodeReceiptFields(encodedTransaction);
        require(receipt.receiptStatus == 1, "Transaction did not succeed");

        // Find events and validate
        selectedEventLogs = EvmV1Decoder.getLogsByEventSignature(receipt, eventSignature);
        require(selectedEventLogs.length > 0, "No events of required type found");

        // TRUTHGATE: каждое извлекаемое событие обязано быть эмитировано ожидаемым
        // контрактом-источником — иначе любой контракт на source-чейне мог бы
        // подделать событие с нужной сигнатурой.
        for (uint256 i; i < selectedEventLogs.length; i++) {
            require(selectedEventLogs[i].address_ == expectedSource, "log from unexpected source contract");
        }

        return selectedEventLogs;
    }
}
