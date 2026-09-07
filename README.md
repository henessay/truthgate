# TruthGate

**An on-chain credit bureau built on Attestcoin (USC).** TruthGate records proven cross-chain financial facts — deposits, loan repayments, liquidations on Ethereum — as scoring state on Creditcoin CC3. Its only data source is Attestcoin inclusion proofs verified by the CC3 block-prover precompile: no oracle, no trusted indexer, no admin method that writes a score. On top of the proven-facts registry sit a reference scoring model and a live CTC credit line as the bureau's first data consumer. The deep dive — architecture, trust model, the boundary of provability, measurements — is the **[Integration Summary](docs/attestcoin-integration-summary.md)**.

## Three layers

1. **Proven-facts registry.** Every fact enters through one pipeline (`TruthGateBase.execute`): chainKey pin → freshness window → queryId anti-replay → precompile `verifyAndEmit` → receipt-status check → log parsing. Emitters carry an on-chain trust tier (VERIFIED canonical deployments / BONDED permissionless lenders staking CTC / UNKNOWN = zero weight) — the structural fix for the self-attestation problem: *a proof shows contract Y emitted an event, not that Y is an honest lender.*
2. **Reference scoring.** CAPITAL (amount-weighted, joint cap across protocols) + DISCIPLINE (flat per proven repayment, bond-capped, dark until the capital gate passes) + NEGATIVE (flat per proven liquidation, degrades but never hard-blocks) + local CC3 repayment history (risk-proportional). No cross-asset arithmetic without oracles — heterogeneous amounts are emit-only, by rule.
3. **Demo credit line.** A CTC loan book (LPPool) that prices limits off the bureau, with two repayment paths: native CTC on CC3, or USDC locked on Ethereum and delivered by proof (wUSDC mint + treasury swap). Deliberately thin — the first consumer of the data, not the product.

## Protocol coverage

Parsers pinned byte-for-byte against real historical mainnet transactions (`contracts/test/MainnetParity.t.sol`); machine-readable registry: [`docs/protocol-registry.json`](docs/protocol-registry.json). Covered TVL ≈ **$40.2B** (DefiLlama, 2026-08-31).

| Protocol | Category | Status |
|---|---|---|
| Aave v3 | DISCIPLINE, NEGATIVE | mainnet-pinned + Sepolia live (watcher armed) |
| Morpho Blue | DISCIPLINE, NEGATIVE | mainnet-pinned + **Sepolia live pipeline — real Repay delivered on-chain** |
| Spark (SparkLend) | DISCIPLINE, NEGATIVE | mainnet-pinned (byte-identical Aave fork, same parser) |
| Compound v3 (Comet) | NEGATIVE only | mainnet-pinned; DISCIPLINE [provably unprovable](docs/attestcoin-integration-summary.md#the-boundary-of-provability) |
| Rocket Pool | CAPITAL | mainnet-pinned (address resolved via RocketStorage) |
| EigenLayer | CAPITAL | mainnet-pinned (current slashing-era layout) |
| Maker/Sky, Euler v2, Fluid, Curve | — | roadmap |

## Live evidence

Everything below ran on live networks (CC3 Testnet + Sepolia); full transaction-level history in [`docs/live-run.md`](docs/live-run.md).

- **First real external-protocol DISCIPLINE record**: a `Repay` on the official Morpho Blue Sepolia singleton ([`0xf232bbd7…ee17`](https://sepolia.etherscan.io/tx/0xf232bbd79c02655716e8f2ff983f7d67d7987b6be49cac9fb03586669396ee17)) proven and delivered to CreditCore v4 ([`0x5d32a354…f38b`](https://creditcoin-testnet.blockscout.com/tx/0x5d32a354bc427a4f64c8d25701fe6e9ca3a9eb0dce196aa6abf31dfb71faf38b)).
- **Full credit cycle**: proven deposits → score → borrow → repay via both paths (including proof-delivered USDC) → treasury swap → pool made whole with LP profit, reconciled to the wei.
- **Protections that fired live**: queryId anti-replay, the 30% path-B cap (rejected free at estimateGas), tier-weighted zero credit for unknown sources.
- **Measured**: attestation ~470 s fresh / ~6 s attested, proof ~0.4–0.7 s, verify+execute ~10–12 s, ~670k gas per scoring delivery.

## Quickstart

Prerequisites: [pnpm](https://pnpm.io), [Foundry](https://getfoundry.sh). Copy `.env.example` to `.env` at the repo root and fill in `DEPLOYER_PRIVATE_KEY` and `SEPOLIA_RPC`.

```bash
pnpm install

# Contracts: 88 tests, incl. mainnet-parity parser pins and invariant tests
cd contracts && forge test

# Worker: watches Sepolia, builds proofs via the Prover API, delivers to CC3
cd worker && pnpm worker run --serve     # or: status | replay <txHash> | set-cursor <block>

# Web dashboard (read-only works without a wallet)
cd web && pnpm dev
```

Deploying to CC3 uses `contracts/script/deploy-cc3.sh` (forge create + cast), not `forge script` — the Substrate-EVM omits `prevRandao` and forge's fork simulation panics. The solc optimizer must stay enabled (`foundry.toml`): the v4 core exceeds CC3's 24,576-byte code limit without it.

## Deployed addresses (current)

Machine-readable source of truth: [`docs/deployments.json`](docs/deployments.json); historical generations annotated in [`docs/live-run.md`](docs/live-run.md).

| Contract | Chain | Address |
|---|---|---|
| CreditCore v4 (the bureau) | CC3 | `0x02501978888A9BedfED93F9665c7DDeA466f12F5` |
| RepaymentBridge v5 | CC3 | `0x1e9E90d0a47Cc3E080B37F986e1Bf7E946446713` |
| WrappedUSDC | CC3 | `0xF3663288a86BeeAD53Bf9C275E663bA9c247A7AC` |
| LPPool | CC3 | `0x1Cc00628a8590e4eFDA496242439d5d09e726C14` |
| EvmV1Decoder (linked library) | CC3 | `0xD694C9f83C6D8B9Ec4DCB7A54cD3305BB050deF1` |
| ScoringVault | Sepolia | `0xe5f1cb738ba279440565D7B46fFAb38a0E52AF37` |
| LoanBookSim (BONDED source, 10 CTC) | Sepolia | `0x6da1A10d236607224d49De19e69885BC1f1Ad7af` |
| RepaymentVault | Sepolia | `0xD694C9f83C6D8B9Ec4DCB7A54cD3305BB050deF1` |
| TestUSDC | Sepolia | `0x1Cc00628a8590e4eFDA496242439d5d09e726C14` |
| Morpho Blue singleton (VERIFIED source) | Sepolia | `0xd011EE229E7459ba1ddd22631eF7bF528d424A14` |
| Aave v3 Pool (VERIFIED source) | Sepolia | `0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951` |

## Repository map

```
contracts/   Foundry. src/cc3 — CreditCore (bureau + credit line), RepaymentBridge,
             LPPool, TruthGateBase, parsers; src/sepolia — ScoringVault, LoanBookSim,
             RepaymentVault; test/ — 88 tests incl. MainnetParity.t.sol
worker/      Off-chain worker (@gluwa/usc-sdk + ethers v6): event watcher,
             proof builder, free pre-check, delivery pipeline, replay CLI
web/         React dashboard (read-only without a wallet): bureau state,
             score breakdown, loans, pool
docs/        Integration Summary · live-run evidence · protocol-registry.json ·
             deployments.json · vendored Gluwa examples (docs/vendor)
```
