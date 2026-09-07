# TruthGate × Attestcoin/USC: Integration Summary

TruthGate is an **on-chain credit bureau** built on the USC (Attestcoin) protocol: a registry of proven cross-chain financial facts on Creditcoin CC3, fed exclusively by Attestcoin proofs of Ethereum (Sepolia) events, with a reference scoring model and a live CTC credit line as the bureau's first data consumer.

This document is the integration summary: how the proofs are consumed, what is measured, where the boundary of provability lies, and what evidence exists on live networks. Companion documents: [`live-run.md`](live-run.md) (full transaction-level evidence), [`protocol-registry.json`](protocol-registry.json) (machine-readable protocol coverage), [`deployments.json`](deployments.json) (current addresses).

## Why the integration is load-bearing

Remove the proofs and the product ceases to exist. TruthGate has **no other data source**: no oracle feed, no off-chain indexer whose word is trusted, no admin method that writes a score. Every unit of every score component traces to a `verifyAndEmit` call on the CC3 block-prover precompile:

- **CAPITAL** (`ethScore`) — grows only from proven `FundsDeposited` / staking events on Sepolia.
- **DISCIPLINE** (`disciplineScore`) — grows only from proven repayment events, including a real Morpho Blue Sepolia `Repay` delivered on-chain.
- **NEGATIVE** (liquidation penalty) — applied only from proven `LiquidationCall` events; a third party can permissionlessly prove a borrower's liquidation.
- **Path B repayments** — wUSDC is minted on CC3 only against a proven `UsdcLockedForRepayment` on Sepolia; the bridge holds no other mint path.

The credit line (borrow/repay in CTC against the LPPool) is deliberately thin: it is the first consumer of the bureau's data, not the product. The product is the registry of proven facts plus the trust model that makes them mean something (see "the self-attestation problem" below) — both are Attestcoin-native and neither can be emulated by a conventional bridge or an oracle without reintroducing exactly the trust the design removes.

## Architecture

### The proof loop (Sepolia event → CC3 state change)

1. A financial event fires on Sepolia — e.g. `Repay` on the official Morpho Blue singleton.
2. Attestcoin attests the Sepolia block on CC3. Measured: **~470 s (~8 min)** for a fresh block — the lag is Attestcoin's design (attestation deliberately trails the source head as reorg protection); **~6 s** if the block is already attested.
3. The off-chain worker builds the proof via the Prover API (`ProofBuilder.getProof(txHash)` from `@gluwa/usc-sdk`) → `{txBytes, MerkleProof, ContinuityProof}`. Measured: **~0.4–0.7 s** for an attested block (prover cache).
4. Optional free pre-check: the same proof through `verify` as an `eth_call` (staticCall) — the worker spends zero gas on proofs that would revert. This fired live: an over-cap repayment was rejected at estimateGas, no on-chain transaction was ever sent.
5. The worker submits `execute(chainKey, height, txBytes, merkleProof, continuityProof)` to the consumer contract (CreditCore or RepaymentBridge), which calls the precompile verifier `0x…0FD2`: `verifyAndEmit(...)`. Measured end-to-end (verify + decode + business logic): **~10–12 s**, **~670k gas** for a scoring delivery, **~1.0M gas** for a Path B repayment (mint + accounting).
6. The precompile proves *inclusion in a finalized Sepolia block* — nothing more. Everything after that is our contract: receipt-status check, log extraction, registry tier weighting, scoring.

### The base contract (`TruthGateBase`)

Every proof enters through one audited pipeline, in this order:

1. **chainKey pin** — `require(chainKey == 1)` (Sepolia's attested-chain key on CC3).
2. **Freshness window** — `height ≥ minAcceptedHeight` where scoring semantics require it (stale-event pushing).
3. **Anti-replay** — `queryId = keccak256(chainKey ‖ height ‖ txIndex)`; `processedQueries[queryId]` is required-unset *before* any processing (invariant #3).
4. **Verification** — `VERIFIER.verifyAndEmit(...)`; the precompile reverts on an invalid proof.
5. **Receipt status** — the precompile does **not** check whether the source transaction succeeded, only that it is included. `EvmV1Decoder.decodeReceiptFields` → `require(receiptStatus == 1)` is our check, mandatory before any business logic (invariant #1).
6. **Log extraction** — filtered by event signature (topic0). Two variants: `_validateAndExtractLogsAnySource` (CreditCore — the emitter's trust level is decided by the registry, per log) and the pinned-emitter `_validateAndExtractLogs` (RepaymentBridge — money movement accepts exactly one registered vault).
7. **Atomicity** (invariant #4) — no `try/catch`, no unchecked low-level calls anywhere in `execute → handlers`: any failure reverts the whole transaction including the `processedQueries` mark. Guarantee: *queryId marked ⟺ all effects applied* — otherwise a partially-executed proof with a burned queryId would be an unrecoverable hole. Locked by `test_invariant_queryIdMarkedIffEffectsApplied`.

### The source registry with tiers (the self-attestation problem, fixed structurally)

Attestcoin's proof answers exactly one question: *was this event emitted by contract Y in a finalized source-chain block?* It cannot answer whether Y is an honest lender. Without a second layer, anyone could deploy a contract that emits `Repay` events and write themselves a credit history — the self-attestation problem, and the central design problem of a proof-fed bureau. CreditCore v4 closes it with three structural fixes:

**1. Tier field.** Every event emitter carries an on-chain trust tier in the source registry (`sources` mapping):

- **VERIFIED** — canonical protocol deployments pinned against mainnet (Aave, Morpho, Spark, Comet, Rocket Pool, EigenLayer) plus the ScoringVault (its deposit events are intrinsically backed by `msg.value` — it is the capital anchor, and gating capital by bonds would make the capital gate circular). Full weight. Registration is owner-only.
- **BONDED** — any lender contract may join **permissionlessly** via `registerBondedSource() payable`, staking a CTC bond (≥ 1 CTC) behind its records. Weight is capped by the bond (fix 2). Our own LoanBookSim runs at this tier with a real 10 CTC bond posted on-chain — the simulator is no longer silently trusted.
- **UNKNOWN** — everything else (the mapping default). Events still verify and emit (visible history), but contribute **zero** to every score. Negative signals are tier-weighted too: an unregistered contract cannot degrade anyone's score (griefing shield).

**2. Per-source bond-cap.** For a BONDED source, the total credit-limit influence attributable to its records — positive score deltas converted through the limit slope, and liquidation penalties as-is — is clamped at its staked bond (`attributedLimit ≤ bond`, linear, constant ratio = the existing `SCORE_SLOPE`). The invariant is literal: *a fake lender cannot write more reputation than it has capital at risk* — attack cost ≥ extracted benefit — and symmetrically cannot inflict more limit damage than its bond. Attribution history is never reset: withdrawing and re-posting a bond does not launder it. Bond withdrawal is owner-arbitrated in v4; slashing/challenge of dishonest bonded sources is roadmap, stated as such.

**3. Capital gate.** DISCIPLINE contributes to a borrower's limit only while that borrower has independently proven CAPITAL of at least `CAPITAL_GATE_THRESHOLD` (0.015 ETH) — an indicator multiplier evaluated at read time, retroactive in both directions. A self-made lender cannot farm score for a wallet that has no real skin in the game. The threshold is a demo-scale constant; production pools calibrate to their loan sizes.

**Dust-repay floor and the discipline cap.** External repayments earn a flat `EXTERNAL_REPAY_FLAT_SCORE` (0.1) per proven event — amounts are heterogeneous loan-token units and stay emit-only (see the boundary section). Flat credits invite dust spam (1-wei repays on a permissionless market), so two bounds apply: a per-event floor `minDisciplineEventAmount` (default 1e4 raw loan-token units — a deliberately decimals-unaware heuristic; it kills literal-wei spam, nothing more) and the per-borrower `DISCIPLINE_SCORE_CAP` (1.0 = at most +10 CTC of limit from discipline) as the economic bound. Stated honestly: an attacker who passes the capital gate can still farm gas-price repays on a verified permissionless protocol **up to the cap** — bounded, not eliminated; elimination needs oracle-weighted amounts (roadmap).

## Consumed events (live pipeline on Sepolia → CC3)

| Event | Source & tier | Consumer (action) | Effect |
|---|---|---|---|
| `FundsDeposited(address indexed depositor, uint256 amount, uint256 nonce)` | ScoringVault — **Verified** | CreditCore (`ScoreDeposit`) | ethScore += amount, joint CAPITAL cap `DEPOSIT_SCORE_CAP` (2 ETH) |
| `LoanRepaidOnEth(address indexed borrower, uint256 loanId, uint256 amount)` | LoanBookSim — **Bonded, 10 CTC** | CreditCore (`ScoreRepayment`) | disciplineScore += amount + `FLAT_REPAYMENT_BONUS`, bond-capped |
| `LiquidationCall(...)` — Aave v3's real layout, byte-for-byte | LoanBookSim — **Bonded, 10 CTC** | CreditCore (`ScoreLiquidation`) | flat per-event penalty 1 / 2 CTC, cap 5 CTC; burns earned bonus only, bond-capped |
| `Repay(address indexed reserve, address indexed user, address indexed repayer, uint256 amount, bool useATokens)` | Aave v3 Sepolia Pool — **Verified** | CreditCore (`ScoreAaveRepay`) | disciplineScore += 0.1 flat (action live, watcher armed) |
| `Repay(bytes32 indexed id, address indexed caller, address indexed onBehalf, uint256 assets, uint256 shares)` | Morpho Blue Sepolia singleton — **Verified** | CreditCore (`ScoreMorphoRepay`) | disciplineScore += 0.1 flat — **delivered live**, the bureau's first real external-protocol DISCIPLINE record |
| `UsdcLockedForRepayment(address indexed borrower, uint256 ccLoanId, uint256 amount)` | RepaymentVault — pinned emitter | RepaymentBridge (`UsdcRepayment`) | mint wUSDC to the bridge treasury + repayment accounting (≤30% of the debt; deadline in CC3 blocks at delivery time) |

## Scoring model and score-farming protection

Credit limit: `limit = BASE_LIMIT + slope×(effectiveScore − MIN_ETH_SCORE) + K×localScore − liquidationPenalty` (bonus floor 0, base capped at MAX_BASE_LIMIT), where `effectiveScore = capital + gate(capital ≥ CAPITAL_GATE_THRESHOLD)×discipline`. Each component has its own source of truth and its own farming protection — the answer to "what stops someone from buying the limit cheaply":

**CAPITAL (`ethScore`)** grows only from Attestcoin-proven Sepolia events:

- *Deposits* (`FundsDeposited`, Rocket Pool `DepositReceived`, EigenLayer `Deposit`) — a weak signal: the same funds can be cycled deposit→withdraw→deposit, or the same capital restaked across protocols. Therefore **all CAPITAL sources draw from one shared accumulator** (`depositScoreOf`) against the single `DEPOSIT_SCORE_CAP` (2 ETH) per address — capital is counted once, not once per protocol that attests it (`test_jointCapitalCap_capitalCountedOnce`). Beyond the cap a deposit still verifies and emits, but the score does not grow.
- Replay of a single event is cut off by queryId anti-replay; source forgery — by the tier registry; stale-event pushing — by the `minAcceptedHeight` freshness window.

**DISCIPLINE (`disciplineScore`)** grows only from proven repayment events — sim repayments amount-weighted from the bonded source, external-protocol repayments flat-weighted from verified sources — bounded by the dust floor, `DISCIPLINE_SCORE_CAP`, the bond-cap, and dark until the capital gate passes (all above).

**localScore (reputation earned on CC3 itself)** grows for repaid CreditCore loans — proportionally to the risk the pool actually took on, not to the mere fact of repayment:

```
localScoreDelta = principal × min(heldBlocks, LOAN_DURATION_BLOCKS) / LOAN_DURATION_BLOCKS
                  / LOCAL_SCORE_NORM_PRINCIPAL
```

- `heldBlocks` — CC3 blocks from issuance to the closing payment; `MIN_HOLD_BLOCKS = LOAN_DURATION_BLOCKS/4` — repayment before the threshold goes through normally but accrues no score; normalization 4.5 CTC — a demo-scale loan held full-term yields ~1 unit (= +1 CTC of limit).
- **The time parameters are constructor-set (immutable), and on the demo deploy they are compressed — stated openly.** Production defaults are hardcoded: term 100,000 CC3 blocks (~17 days), hold threshold 25,000. The demo deploy uses ~240 blocks (~1 hour) / 60 — otherwise the "reputation → more credit" flywheel cannot be shown live. The reward depends on the **fraction** of the term held, so proportional compression preserves the economics (locked by `test_scoreScaleInvariantUnderCompressedSchedule`). This is time-scale compression for observability, not a slowed-down or faked model.
- Why the "borrow-and-repay cycle" attack fails: an instant cycle yields exactly 0 (hold threshold + zero-time proportion); above the threshold, gaining +1 CTC of limit requires holding ~4.5 CTC for the full term and paying ~0.225 CTC of interest — the limit costs ≥ ~22.5% of its value in paid interest, however it is split across loans. The only way to farm localScore is to actually use credit and pay for it — exactly the behavior being measured.

**Liquidation penalty (negative signal).** A proven liquidation degrades the limit but can never weaponize into a lockout:

- **Per-event, not amount-proportional** — `debtToCover` values are heterogeneous reserve tokens (see the boundary section); the amount is parsed and emitted for transparency but never enters the formula. First proven liquidation: 1 CTC of earned bonus; each subsequent: 2 CTC (repeat offenses escalate); accumulated total capped at 5 CTC.
- The penalty burns **only the earned bonus** — `BASE_LIMIT` (5 CTC) always survives: a liquidated borrower is degraded, never hard-blocked (`test_liquidationNeverHardBlocks_baseLimitAndBorrowSurvive`). `ethScore` itself is untouched, so the `MIN_ETH_SCORE` gate cannot be weaponized by liquidation proofs.
- The consumed event is Aave v3's **real** `LiquidationCall` layout byte-for-byte — one parser implementation, tested against the simulator and against real mainnet logs with zero divergence.

## Credit bureau: protocol coverage beyond the live pipeline

The bureau's parser library extends past the contracts wired into the live Sepolia pipeline. `docs/protocol-registry.json` is the machine-readable registry; `contracts/test/MainnetParity.t.sol` pins every parser against **real historical transactions of the verified live mainnet contracts** — raw log bytes decoded through our parsers with every field asserted, source tx hash cited. A topic0 match alone cannot catch data-layout drift when a fork keeps the signature string but changes field assumptions; decoding real bytes can.

Parsers cover protocols totaling **≈ $40.2B TVL** (per-protocol figures from DefiLlama, 2026-08-31):

| Protocol | Events | Category | Tier | Parser | TVL |
|---|---|---|---|---|---|
| Aave v3 | `Repay`, `LiquidationCall` | DISCIPLINE, NEGATIVE | mainnet verified + **Sepolia live** (`ScoreAaveRepay` action live, watcher armed) | `AaveV3Parser` | $17.2B |
| Spark (SparkLend) | `Repay`, `LiquidationCall` | DISCIPLINE, NEGATIVE | mainnet verified (Aave fork, byte-identical against live mainnet logs; pool identity checked on-chain: `getMarketId() == "Spark Protocol"` — same parser, no code of its own) | `AaveV3Parser` | $4.4B |
| Morpho Blue | `Repay`, `Liquidate` | DISCIPLINE, NEGATIVE | mainnet singleton verified + **Sepolia LIVE PIPELINE**: the real demo-market Repay is delivered on-chain as a DISCIPLINE record | `MorphoBlueParser` | $9.5B |
| Compound v3 (Comet) | `AbsorbDebt` (3-topic shape, unlike 4-topic Aave/Morpho liquidations) | NEGATIVE only — DISCIPLINE is unprovable, see the boundary section | mainnet verified | `CompoundV3Parser` | $1.4B |
| Rocket Pool | `DepositReceived` | CAPITAL (native ETH — the one external CAPITAL source homogeneous with vault deposits, enters the capped formula directly) | mainnet verified (address resolved live from `RocketStorage` — Rocket Pool contracts are upgradeable) | `RocketPoolParser` | $1.3B |
| EigenLayer | `Deposit` (current slashing-era layout: *nothing indexed*, staker read from data; the remembered 4-param layout produced zero logs in a 100k-block scan of the live proxy and is deliberately unsupported — exactly why every parser pins against real emissions) | CAPITAL (flat — shares are heterogeneous LST strategy units; joint cap) | mainnet verified + official Sepolia deployment | `EigenLayerParser` | $6.4B |
| Maker / Sky | — | — | roadmap: LogNote/DSNote anonymous-event model needs a calldata-decoding adapter, not a log parser | — | — |
| Euler v2, Fluid, Curve (crvUSD/LlamaLend) | — | — | roadmap: registered targets; layouts to be live-verified before implementation | — | — |

Morpho's DISCIPLINE subject is `onBehalf` — the borrower whose debt shrinks — not the paying `caller`. For the live pipeline, TruthGate created its own permissionless market on the official Morpho Blue Sepolia singleton (tUSDC loan / DAI collateral, IRM `address(0)`, enabled LLTV); its `FixedPriceOracle` serves Morpho's internal LLTV mechanics only — the bureau records the `Repay` event as fact, amounts emit-only.

## The boundary of provability

Attestcoin proves one class of statement: *this transaction, with this receipt and these logs, is included in a finalized source-chain block.* Three consequences shape the bureau's design; each is documented rather than papered over.

### 1. State-dependent event meaning: why Comet DISCIPLINE is unprovable

Compound v3 has **no repayment event**. Repaying debt is `supply()` of the base asset into an account whose principal is negative; the contract emits the same `Supply(address indexed from, address indexed dst, uint256 amount)` whether the caller is a lender depositing or a borrower repaying. Which one it was is determined by the **sign of the account's principal before the transaction** — contract *state*, not transaction content.

USC proves a transaction's inclusion and with it the receipt — its events. It does not (and cannot, in this model) attest arbitrary historical contract state at that block. So a proven `Supply` cannot be trustlessly classified as a repayment: doing so would require trusting an archive-node lookup or an oracle for the pre-transaction balance sign — exactly the trust assumption the bureau exists to avoid. The failure mode of guessing would be score farming: any lender deposit would mint DISCIPLINE for free. `AbsorbDebt` has no such ambiguity — it fires only when the protocol absorbs an underwater account — so Comet contributes NEGATIVE only. This is a semantic property of Comet's event design, not a parser gap: it is documented as unprovable rather than left as silent non-coverage.

### 2. Existence, never absence: wallet age is only provable as a lower bound

An inclusion proof is an existential statement. It can establish *"this wallet had already transacted at height H"* — which lower-bounds the wallet's age — but it can never establish *"this was the wallet's first transaction"* or *"this wallet has never been liquidated"*: those are universally-quantified claims over **all** source-chain history, and no finite set of inclusion proofs expresses them.

The bureau's consequence is structural: it scores the **presence of proven good facts** and the **presence of proven bad facts**, never a certified *absence* of bad ones. A borrower can prove they deposited, repaid, or recovered after a liquidation; nobody can prove a clean history — and the design does not pretend otherwise. The honest complement is that negative facts are third-party-provable: anyone can deliver a proof of your liquidation (tier-weighted, so only registered sources count). A production "wallet age" signal would follow the same rule: credit the proven lower bound (age ≥ now − H of the earliest proven transaction), never a claimed exact age.

### 3. No cross-asset arithmetic without oracles

Event amounts across protocols are denominated in heterogeneous tokens: 500 USDC (6 decimals) and 500 DAI (18 decimals) differ by 1e12 as raw values while representing the same economics; Morpho amounts are per-market loan-token units; EigenLayer shares are per-strategy LST units. Comparing or summing them trustlessly requires price oracles — a trust dependency the v1 bureau refuses. The design rule, applied uniformly: **heterogeneous amounts are parsed and emitted for transparency but never enter scoring arithmetic.** Liquidation penalties are flat per-event; external repays earn a flat 0.1; EigenLayer deposits credit flat. The two exceptions are principled: native-ETH amounts (vault deposits, Rocket Pool — one homogeneous unit) are amount-weighted under the joint cap, and the dust floor is an explicitly decimals-unaware heuristic that kills literal-wei spam and claims nothing more. Oracle-weighted amounts are roadmap, and would relax exactly this rule, consciously.

## Trust assumptions (owner powers / decentralization roadmap)

We enumerate our own trust assumptions. The contract owner can, today: register VERIFIED sources (curation of canonical deployments), arbitrate bonded-source bond withdrawal (no slashing/challenge mechanism yet), tune the dust floor `setMinDisciplineEventAmount`, set the freshness window `setMinAcceptedHeight`, and mark loans expired. Each is a v4 pragmatism, not a design endpoint: the roadmap replaces curation with on-chain verification proofs where possible, bond arbitration with a challenge game, and the knobs with governance.

Everything else is trust-minimized by construction: scores have no admin setter, the bridge has no mint path without a proof, and the AI agent's authority is limited to submit/defer/escalate decisions on proofs — it never holds keys to money (invariant #2).

## Measured performance (live networks)

| Metric | Value |
|---|---|
| Attestation of a fresh Sepolia block on CC3 | ~470 s (~8 min; the lag is Attestcoin's design — reorg protection) |
| Wait for an already-attested block | ~6 s |
| Proof generation (Prover API, attested block) | ~0.4–0.7 s (cache) |
| Verification + execute on CC3, end-to-end | ~10–12 s |
| Gas: scoring delivery (execute → CreditCore) | ~670k (669,340 / 669,788) |
| Gas: repayment delivery (execute → RepaymentBridge, mint + accounting) | ~1.0M (1,008,350 / 986,174) |
| Gas: treasury swap `swapWusdcForCtc` | 401,282 |

## Live evidence

Full transaction-level history (including three earlier generations of the core and the negative scenarios) is in [`live-run.md`](live-run.md). Current deployment (CC3): CreditCore v4 `0x02501978888A9BedfED93F9665c7DDeA466f12F5`, RepaymentBridge v5 `0x1e9E90d0a47Cc3E080B37F986e1Bf7E946446713`, WrappedUSDC `0xF3663288a86BeeAD53Bf9C275E663bA9c247A7AC`, LPPool `0x1Cc00628a8590e4eFDA496242439d5d09e726C14`; Sepolia: ScoringVault `0xe5f1cb738ba279440565D7B46fFAb38a0E52AF37`, LoanBookSim `0x6da1A10d236607224d49De19e69885BC1f1Ad7af`, RepaymentVault `0xD694C9f83C6D8B9Ec4DCB7A54cD3305BB050deF1`, plus the official Morpho Blue and Aave v3 Sepolia deployments.

**v4 go-live (2026-09-01): all nine historical Sepolia proofs replayed with fresh proof deliveries, plus the real Morpho Repay as the tenth — zero failures:**

| # | Replayed Sepolia event | CC3 delivery tx | Result |
|---|---|---|---|
| 1–6 | six ScoringVault deposits | `0xdc6ae575…15e3`, `0x350e4505…a64f`, `0xe4f38752…dcdb`, `0xcc66cb58…fa4c`, `0x5a256def…ae12`, `0xd0e44cd4…c0d8` | `EthScoreIncreased` ×6, capital 0.027 restored |
| 7 | LoanBookSim repayment sim | `0x0e26ee28584b3b8446d295cedc9199f10bca947417c6503b804086ece7d3194c` | `DisciplineScoreIncreased` +0.35 (bonded source: 3.5 CTC attributed against the 10 CTC bond) |
| 8–9 | two LoanBookSim liquidations | `0x1bc80bdd…85ab`, `0x0c8374fd…6133` | `LiquidationPenaltyApplied` 1 + 2 CTC (bonded: penalties drew 3 more CTC of attribution — 6.5/10 total) |
| 10 | **Morpho Blue Sepolia Repay `0xf232bbd79c02655716e8f2ff983f7d67d7987b6be49cac9fb03586669396ee17`** | **`0x5d32a354bc427a4f64c8d25701fe6e9ca3a9eb0dce196aa6abf31dfb71faf38b`** | **`DisciplineScoreIncreased` +0.1 — the first REAL external-protocol DISCIPLINE record in the bureau (Verified-tier singleton; 50e6 assets clear the dust floor by 5000×)** |

**Post-replay bureau state** (read from CreditCore v4, reconciled against the arithmetic):

| Quantity | Value | Reconciliation |
|---|---|---|
| capital (ethScore / depositScoreOf) | 0.027 | six proven deposits, joint cap untouched ✓ |
| disciplineScore | 0.45 | 0.35 (sim repay) + 0.1 (Morpho flat) ✓ |
| capital gate (threshold 0.015) | PASSED at 1.8× | 0.027 ≥ 0.015 → discipline counts ✓ |
| effectiveScore | 0.477 | 0.027 + 0.45 ✓ |
| liquidationPenalty | 3.0 | 1 (first) + 2 (repeat) ✓ |
| creditLimit | **6.67 CTC** | 5 (BASE) + (0.477 − 0.01)×10 − 3 ✓ |
| sources[LoanBookSim] | Bonded, bond 10, attributed 6.5 | 3.5 (discipline×slope) + 3.0 (penalties) ≤ bond ✓ |

**Protections that fired on live networks** (details and worker-log timestamps in `live-run.md`):

- **Anti-replay by queryId**: re-delivery of an already-processed lock — revert `Query already processed` (invariant #3).
- **Path B 30% cap**: an over-cap repayment rejected with `USDC share cap exceeded` — twice over: the contract require, and the worker spent no gas (revert caught at estimateGas; no on-chain transaction sent).
- **Height-scale bug caught by the live run** (fixed): a CC3-block deadline was once compared against a Sepolia height — every repayment reverted `repayment past deadline`; the bridge was redeployed checking against CC3 `block.number`, and the same proof then went through. Kept in the record deliberately: the live run is a test, not a demo reel.
- **CC3 code-size limit**: the v4 core exceeded the 24,576-byte runtime limit (`CreateContractLimit`); the solc optimizer (200 runs) brought it to 17,928 bytes with the full 88-test suite passing identically.

## v1 limitations

- **Identity model: a single EOA on both chains.** A participant's Sepolia address must match their CC3 address — the borrower is identified by the address in the proven event's indexed topic. Smart-contract wallets and differing cross-chain addresses are unsupported; on a mismatch the bridge reverts (`borrower mismatch`).
- Loan deadlines are in CC3 blocks, checked against CC3 `block.number` at proof delivery time (+buffer). Sepolia heights take no part in deadline checks — the scales are incomparable.
- The wUSDC/CTC rate is a constant 1:1 (production: an oracle).

## Off-chain roles

- **Worker** (`@gluwa/usc-sdk`): watches source events (with a subject filter on public singletons — proving strangers' transactions costs gas; the contracts accept any subject), builds proofs (`ProofBuilder` → Prover API), pre-checks them for free (`verify` via eth_call), and submits them to `execute`.
- **AI agent**: submit/defer/escalate decisions on proofs only. It never signs money transactions and has no access to funded keys (invariant #2).
