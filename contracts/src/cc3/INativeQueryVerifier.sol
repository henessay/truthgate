// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title INativeQueryVerifier
/// @notice Interface of the Creditcoin block-prover precompile at 0x…0FD2 (4050).
/// Vendored from Gluwa's usc-testnet-bridge-examples VerifierInterface.sol; struct
/// layouts and signatures must stay byte-identical with the canonical precompile ABI
/// (docs/vendor/sol/abi/block_prover.json).
interface INativeQueryVerifier {
    struct MerkleProofEntry {
        bytes32 hash;
        bool isLeft;
    }

    struct MerkleProof {
        bytes32 root;
        MerkleProofEntry[] siblings;
    }

    struct ContinuityProof {
        bytes32 lowerEndpointDigest;
        bytes32[] roots;
    }

    function verifyAndEmit(
        uint64 chainKey,
        uint64 height,
        bytes calldata encodedTransaction,
        MerkleProof calldata merkleProof,
        ContinuityProof calldata continuityProof
    ) external returns (bool);

    function calculateTxIndex(
        MerkleProof calldata merkle_proof
    ) external view returns (uint64);
}

library NativeQueryVerifierLib {
    address constant PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000FD2;

    function getVerifier() internal pure returns (INativeQueryVerifier) {
        return INativeQueryVerifier(PRECOMPILE_ADDRESS);
    }
}
