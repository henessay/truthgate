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

    // TRUTHGATE: chainKey is pinned as a constant. USCBase accepts proofs from any
    // attested chain (chainKey comes from calldata and is not checked) — we accept
    // only Ethereum Sepolia, whose chainKey in the Creditcoin network is 1.
    uint64 public constant EXPECTED_CHAIN_KEY = 1;

    // TRUTHGATE: freshness window (SOURCE-chain scale, i.e. Sepolia height — checked
    // against the proof's blockHeight). Proofs with blockHeight below this mark are
    // rejected for actions where the subclass left the check enabled (see
    // _isFreshnessEnforced). Default 0 — the check filters nothing.
    uint64 public minAcceptedHeight;

    mapping(bytes32 => bool) public processedQueries;

    event MinAcceptedHeightUpdated(uint64 newMinAcceptedHeight);

    constructor() Ownable(msg.sender) {
        // Get the precompile instance using the helper library
        VERIFIER = NativeQueryVerifierLib.getVerifier();
    }

    // TRUTHGATE: unlike USCBase, the subclass also receives sourceHeight — the
    // source-chain block height (Sepolia scale) from the proof. WARNING: it is
    // incomparable with the CC3 block.number — it may only be compared against other
    // source heights (like minAcceptedHeight); deadlines in CC3 blocks are checked
    // against block.number.
    function _processAndEmitEvent(uint8 action, bytes32 queryId, uint64 sourceHeight, bytes memory encodedTransaction)
        internal
        virtual;

    // TRUTHGATE: freshness-window hook — the subclass decides whether to apply
    // minAcceptedHeight to a particular action. By default the check is enabled for
    // all actions.
    function _isFreshnessEnforced(uint8 action) internal view virtual returns (bool) {
        action; // silence unused-parameter warning in the default implementation
        return true;
    }

    // TRUTHGATE: owner setter for the freshness window.
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
        // TRUTHGATE: first check — the proof's source. Before computing the queryId
        // and before verify: a proof from a foreign chain is rejected before any
        // precompile calls.
        require(chainKey == EXPECTED_CHAIN_KEY, "wrong source chain");

        // TRUTHGATE: freshness window (if enabled for this action) — also before the
        // expensive precompile calls.
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

    // TRUTHGATE: shared transaction-content validator. Combines
    // USCLoanManager._validateTransactionContents (transaction type, receiptStatus == 1,
    // log filtering by signature) with a mandatory emitter-address check for EVERY
    // extracted log — in Gluwa's code that check was a separate step and applied only
    // to the first log. Project invariant #1 (CLAUDE.md) (RxStatus == 1) lives here.
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

        // TRUTHGATE: every extracted event must have been emitted by the expected
        // source contract — otherwise any contract on the source chain could forge
        // an event with the required signature.
        for (uint256 i; i < selectedEventLogs.length; i++) {
            require(selectedEventLogs[i].address_ == expectedSource, "log from unexpected source contract");
        }

        return selectedEventLogs;
    }
}
