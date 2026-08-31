// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";

/// @title CompoundV3Parser
/// @notice Compound v3 (Comet) event layout consumed by the TruthGate credit
/// bureau: AbsorbDebt (negative signal — the protocol absorbed the borrower's
/// underwater debt). Declaration from the canonical compound-finance/comet
/// CometMainInterface; layout verified against a live log of the mainnet
/// cUSDCv3 proxy — see MainnetParity.t.sol. Comet deploys one proxy per market
/// (cUSDCv3, cWETHv3, ...); the event is identical on each instance.
/// @dev NEGATIVE only, by design: Comet has no repayment event. Repaying debt is
/// supply() of the base asset into a negative balance, which emits the same
/// Supply event as a lender's deposit — the meaning depends on the sign of the
/// account's principal BEFORE the transaction, i.e. on contract state, which an
/// inclusion proof of the transaction + receipt cannot attest. DISCIPLINE from
/// Comet is therefore unprovable in this model, not merely unimplemented (see
/// docs/attestcoin-integration-summary.md).
library CompoundV3Parser {
    // keccak256("AbsorbDebt(address,address,uint256,uint256)")
    // event AbsorbDebt(address indexed absorber, address indexed borrower,
    //             uint256 basePaidOut, uint256 usdValue)
    bytes32 internal constant ABSORB_DEBT_TOPIC0 =
        0x1547a878dc89ad3c367b6338b4be6a65a5dd74fb77ae044da1e8747ef1f4f62f;

    struct AbsorbDebt {
        address absorber;
        /// @dev The credit-bureau subject: the borrower whose debt was absorbed.
        address borrower;
        /// @dev Denominated in the market's base token (native decimals,
        /// per-market heterogeneous) — emit-only, never scoring arithmetic.
        uint256 basePaidOut;
        /// @dev Comet's own 8-decimal USD estimate at absorb time; still an
        /// oracle-derived amount — emit-only as well.
        uint256 usdValue;
    }

    function parseAbsorbDebt(EvmV1Decoder.LogEntry memory log)
        internal
        pure
        returns (AbsorbDebt memory a)
    {
        require(log.topics.length == 3, "Invalid AbsorbDebt topics");
        require(log.data.length == 64, "Invalid AbsorbDebt data");
        a.absorber = address(uint160(uint256(log.topics[1])));
        a.borrower = address(uint160(uint256(log.topics[2])));
        (a.basePaidOut, a.usdValue) = abi.decode(log.data, (uint256, uint256));
    }
}
