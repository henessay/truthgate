# TruthGate × Attestcoin/USC: Integration Summary

How TruthGate consumes proven Sepolia events via the USC (Attestcoin) protocol on Creditcoin CC3 Testnet.

## Mechanics

- Verification — precompile `0x…0FD2` (chainKey Sepolia = 1): `verifyAndEmit(chainKey, height, encodedTx, MerkleProof, ContinuityProof)`. The precompile only proves the transaction's inclusion in a finalized block; success (`RxStatus == 1`) is checked by us via `EvmV1Decoder.decodeReceiptFields`.
- Proof intake — `TruthGateBase.execute`: pin chainKey == 1 → freshness window (for scoring) → anti-replay by `queryId = keccak256(chainKey ‖ height ‖ txIndex)` → verify → log decoding with a mandatory emitter-address check (`_validateAndExtractLogs`).

## Consumed Sepolia events

| Event | Source (owner-registered) | Consumer | Effect |
|---|---|---|---|
| `FundsDeposited(address indexed depositor, uint256 amount, uint256 nonce)` | vaultOnSepolia | CreditCore (action ScoreDeposit) | ethScore += amount, cumulatively capped at DEPOSIT_SCORE_CAP |
| `LoanRepaidOnEth(address indexed borrower, uint256 loanId, uint256 amount)` | loanBookOnSepolia | CreditCore (action ScoreRepayment) | ethScore += amount + FLAT_REPAYMENT_BONUS |
| `LiquidationCall(address indexed collateralAsset, address indexed debtAsset, address indexed user, uint256 debtToCover, uint256 liquidatedCollateralAmount, address liquidator, bool receiveAToken)` | loanBookOnSepolia | CreditCore (action ScoreLiquidation) | liquidationPenalty += min(debtToCover × slope, LIQUIDATION_PENALTY_CAP) — reduces the limit's earned bonus, never the base |
| `UsdcLockedForRepayment(address indexed borrower, uint256 ccLoanId, uint256 amount)` | repaymentVaultOnSepolia | RepaymentBridge (action UsdcRepayment) | mint wUSDC to the bridge treasury + repayment accounting in CreditCore (≤30% of the debt, deadline — CC3 `block.number` at proof delivery time + DELIVERY_BUFFER_BLOCKS) |

## Scoring model and score-farming protection

Credit limit: `limit = BASE_LIMIT + slope×(ethScore − MIN_ETH_SCORE) + K×localScore` (base capped at MAX_BASE_LIMIT). Two independent scores, each with its own source of truth and its own score-farming protection — the answer to "what stops someone from buying the limit cheaply":

**ethScore (reputation from Ethereum)** grows only from Attestcoin-proven Sepolia events:

- *Deposits* (`FundsDeposited`) — a weak signal: the same funds can be cycled deposit→withdraw→deposit. Therefore the cumulative deposit contribution is capped at `DEPOSIT_SCORE_CAP` (2 ETH) per address; beyond the cap a deposit still verifies, but the score does not grow.
- *Repayments on Ethereum* (`LoanRepaidOnEth`) — the main weight: `+amount + FLAT_REPAYMENT_BONUS`. Farming this requires actually repaying loans in an external system, i.e. paying its interest.
- Replay of a single event is cut off by anti-replay on `queryId`; source forgery — by the log emitter-address check; pushing stale events — by the `minAcceptedHeight` freshness window.

**localScore (reputation on CC3)** grows for repaid CreditCore loans — proportionally to the risk the pool actually took on, not to the mere fact of repayment:

```
localScoreDelta = principal × min(heldBlocks, LOAN_DURATION_BLOCKS) / LOAN_DURATION_BLOCKS
                  / LOCAL_SCORE_NORM_PRINCIPAL
```

- `heldBlocks` — CC3 blocks from issuance to the closing payment (for path B — the block of proof delivery by the bridge; same scale).
- Normalization `LOCAL_SCORE_NORM_PRINCIPAL = 4.5 CTC`: a demo-scale loan (4–5 CTC) held for the full term yields ~1 unit (= +1 CTC to the limit) — the limit scale of the previous model is preserved.
- `MIN_HOLD_BLOCKS = LOAN_DURATION_BLOCKS/4`: repayment before the threshold goes through normally (principal + interest), but accrues no score.
- **The time parameters are constructor-set (immutable), and on the demo deploy they are compressed — we state this openly.** Production values are hardcoded as the constructor defaults: loan term 100,000 CC3 blocks (~17 days), hold threshold 25,000 (~4.3 days). The demo deploy uses a term of ~240 blocks (~1 hour) and a threshold of ~60 (~15 minutes) — otherwise the "reputation → more credit" flywheel cannot be shown live. The formula and normalization do not change: the reward depends on the **fraction** of the term held, so under proportional compression the economics are preserved (locked in by the test `test_scoreScaleInvariantUnderCompressedSchedule` — an identical hold fraction yields an identical score on demo and production parameters). This is a compression of the time scale for observability, not a slowed-down or faked model.
- Overdue loans (`Expired` / past deadline) accrued no score before either — late "rehabilitation" closes the loan with a penalty, but does not grow reputation.

**Liquidation penalty (negative signal).** A proven liquidation of the borrower on the source chain reduces the credit limit. The consumed event is Aave v3's **real** `LiquidationCall` layout, byte-for-byte — not a custom signature — so the parser has exactly one implementation, tested against both the simulator (`LoanBookSim.simulateLiquidation`) and valid against a real Aave deployment with zero divergence. Penalty mechanics, designed so a third-party proof can degrade but never weaponize into a lockout:

- `penalty = debtToCover × slope` — symmetric with how deposits earn limit — **capped at `LIQUIDATION_PENALTY_CAP` (2 CTC of limit) per proof**: one massive liquidation costs at most 2 CTC of limit.
- The penalty accumulates in a separate counter and burns **only the earned bonus** (the slope part above the base plus the localScore part). `creditLimit` clamps it: the penalized bonus floors at 0 and `BASE_LIMIT` (5 CTC) always survives — a liquidated borrower is degraded, never hard-blocked (test `test_liquidationNeverHardBlocks_baseLimitAndBorrowSurvive`).
- `ethScore` itself is untouched, so the `MIN_ETH_SCORE` gate cannot be weaponized by liquidation proofs; anti-replay (`queryId`), emitter-address check, and the freshness window apply exactly as for positive events.
- v1 assumes an 18-decimal debt asset (the simulator emits wei); production would normalize `debtToCover` by the debt asset's decimals.

Why the "borrow-and-repay cycle" attack no longer works: previously any full repayment gave a fixed `+1` (= +1 CTC of limit), and a cycle of minimal loans bought the limit for roughly 0.005% of its value (only the interest on a micro-loan). Now an instant cycle yields exactly 0 (both by the hold threshold and by the proportion `heldBlocks = 0`), and above the threshold the reward is proportional to `principal × time` — to gain +1 CTC of limit you must hold ~4.5 CTC for the full term and pay ~0.225 CTC of interest (5%), i.e. the limit costs ≥ ~22.5% of its value in paid interest, regardless of how it is split across loans. The only way to "farm" localScore is to actually use credit and pay for it — which is exactly the behavior being measured.

## v1 limitations

- **Identity model: a single EOA on both chains.** A participant's Sepolia address must match their CC3 address — the borrower is identified by the address from the indexed topic of the proven event. Smart-contract wallets and different addresses on different chains are not supported; if the event's borrower does not match the loan's borrower, the bridge rejects it (`borrower mismatch`).
- Loan deadlines are in CC3 blocks; path B checks them against the CC3 `block.number` at proof delivery time (+buffer). Sepolia heights take no part in deadline checks — the scales are incomparable.
- The wUSDC/CTC rate is a constant 1:1 (in production — an oracle).

## Off-chain roles

- Worker (`@gluwa/usc-sdk`): builds proofs (`ProofBuilder` → prover API), can pre-check them for free (`verifySingle`/`verifyBatch` via eth_call), and submits them to `execute`.
- The AI agent never signs money transactions — only submit/defer/escalate decisions on proofs (invariant #2 of CLAUDE.md).
