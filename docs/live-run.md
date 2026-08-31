# TruthGate live run (Creditcoin CC3 Testnet + Ethereum Sepolia)

Proof of the full cycle working on live networks. Dates: 2026-08-15 … 2026-08-19 (UTC).
Explorers: [Blockscout CC3](https://creditcoin-testnet.blockscout.com), [Etherscan Sepolia](https://sepolia.etherscan.io).
All transactions are from EOA `0x025A5616B35bd7D0B79d14DA58fa3e34CEd8a3d0` (deployer = borrower = worker, v1 identity model).

## Deployment

| Contract | Chain | Address | Creation tx |
|---|---|---|---|
| TestUSDC | Sepolia | `0x1Cc00628a8590e4eFDA496242439d5d09e726C14` | `0x9c8c845a376c4db553afca42dc8146db84252d3a5247ab97315ea885ba764dfa` |
| ScoringVault | Sepolia | `0xe5f1cb738ba279440565D7B46fFAb38a0E52AF37` | `0x40f81653cbbea723558c66b90ccc979ae3dbd7cbf02d33670bc8519c094b9844` |
| LoanBookSim v1 (historical) | Sepolia | `0x77B4616343578526DCbE4580B70df6a40DFEb368` | `0xb3b0855382a171a7066588740e8820f961791a1e0332ae89fd8aba4b29ae98da` |
| LoanBookSim v2 (current) | Sepolia | `0x6da1A10d236607224d49De19e69885BC1f1Ad7af` | `0xa986bc9d38c91a1e5d26a9ff28ddb53231430d9e553e7802cba2eb7fe67b3775` |
| RepaymentVault | Sepolia | `0xD694C9f83C6D8B9Ec4DCB7A54cD3305BB050deF1` | `0x58de33ea743fe149cb29bce45c86d2874e5098712d9b56a81c718f513cb6b3f4` |
| LPPool | CC3 | `0x1Cc00628a8590e4eFDA496242439d5d09e726C14` | `0xc4aa762e2cedb72c6f3fd6025ad30f9fff6fd17a6a413e4812cddd7c1b5ff5b4` |
| EvmV1Decoder (library) | CC3 | `0xD694C9f83C6D8B9Ec4DCB7A54cD3305BB050deF1` | `0x6a436437dc921def54a755df56b3150f4b2b3a0b64a2a6dc362cf16f2fcdc741` |
| CreditCore v1 (historical) | CC3 | `0x62f0996Fe278321f7eF9701363830409021a3bB6` | `0x62918971d7be13ba7e248f8e2c598a504deef7095c3e39d3ca2334b5f2c0b641` |
| RepaymentBridge v2 (historical) | CC3 | `0x179d6741664d546E059877eb43168FB11CE782AC` | `0x37e191c2565fd21f7ce9f0322f9e0cf14ac4ebea5fb612f24ff934016cbf377a` |
| WrappedUSDC (historical) | CC3 | `0x46aA13812cD7f568601A696558B213F525B1CC91` | — (created by the RepaymentBridge constructor) |
| CreditCore v2 (historical) | CC3 | `0xC689F574b9Ab4A5008d87d307285F2179a825C05` | `0x836c02b14a6ba3c5c48ab28983241f4fdb1283631be058986675499c4c4b1b05` |
| RepaymentBridge v3 (historical) | CC3 | `0x6CF65BefF04fD95e5fe8cf5C021CEd16d18A61CA` | `0xc754ff0a9f8b69c916683b2ead45520826a0dbd18da94f633f92c80f536c1682` |
| WrappedUSDC v2 (historical) | CC3 | `0x1f8461328635e337e8202D14bde1CfF159b5A5e3` | — (created by the RepaymentBridge constructor) |
| CreditCore v3 (current) | CC3 | `0xD8710f1d5AA5e091529899566e0990365E864131` | `0x7df20281864ee1a038b613db812812ac04f1adce85e45b740899e2e1ac52e340` |
| RepaymentBridge v4 (current) | CC3 | `0xcD0C3c2985Aa4881957A383eD6C855d6Bc18A4a1` | `0x7baa5403e682548b2569088250309617911c1bdbc6b064b176c520a98c0cd8e9` |
| WrappedUSDC v3 (current) | CC3 | `0x30bB00344cd3c726372A053b8eA3Eac2b5E1d661` | — (created by the RepaymentBridge constructor) |

The matching addresses across chains (LPPool ↔ TestUSDC, EvmV1Decoder ↔ RepaymentVault) are CREATE determinism: same deployer, same nonces.

RepaymentBridge v1 (`0xEEd81A27df1D65E90B682264d23205E1ff03Aa8B`) was decommissioned on 2026-08-19: the live run
exposed a comparison of a CC3-scale deadline against a Sepolia height (revert `repayment past deadline` on every repayment);
the fixed bridge was redeployed with the check against CC3 `block.number`, with CreditCore and loan state preserved.

CreditCore v1 and RepaymentBridge v2 were decommissioned on 2026-08-23 with the switch to the risk-proportional
localScore model (score ∝ principal × held-time fraction, MIN_HOLD threshold, schedule in constructor parameters).
The current demo deployment uses the compressed schedule `LOAN_DURATION_BLOCKS=240` (~1 hour), `MIN_HOLD_BLOCKS=60`
(~15 minutes) — a time-scale compression for observability, not a change to the model (production defaults are
100,000 / 25,000). Loan #4 was fully repaid on v1 before the pool was repointed (`outstandingPrincipal` returned
to 0), and the three proven scoring deposits were replayed to the new core, restoring ethScore 0.017 with fresh
proofs of the same Sepolia transactions. Every transaction hash in the tables below predates the redeploy and
remains verifiable against the **historical** v1/v2 addresses above; loan history (loans #1–4) lives on the
historical CreditCore, the new core starts from loan #1.

CreditCore v2, RepaymentBridge v3 and LoanBookSim v1 were decommissioned later on 2026-08-23 with the addition
of the liquidation penalty (negative scoring signal): LoanBookSim v2 emits Aave v3's real `LiquidationCall`
layout byte-for-byte, and CreditCore v3 consumes it as action ScoreLiquidation — a flat per-event penalty
(1 CTC for the first proven liquidation, 2 CTC each subsequent, total capped at 5 CTC) that burns only the
earned bonus above BASE_LIMIT. The demo schedule (240/60 blocks) is unchanged. All six proven scoring deposits
were replayed to CreditCore v3 with fresh proofs (ethScore 0.027 restored); one loan (2 CTC, held 64 blocks,
repaid) lives on the historical v2 core.

## Demo cycle: transactions

| # | Step | Chain | Tx | Result |
|---|---|---|---|---|
| 1 | ETH deposit #1 into ScoringVault (block 11497006) | Sepolia | `0x1313698caef205679abf7b0bcb48cfde13a2217819badac851fdb81808fff4e1` | `FundsDeposited` event |
| 2 | ETH deposit #2 into ScoringVault (block 11497087) | Sepolia | `0xfda6d362fdf8fd61d5bcde3ee09a952b23c266d05d45bc45ceb6e7e99a211355` | `FundsDeposited` event |
| 3 | Proof delivery for deposit #1 (execute → CreditCore) | CC3 | `0xf8a9bef8c0f77420beb4b2d08a22d9514b9824530a657b8ab99dc89d554026b5` | `EthScoreIncreased`, score grows |
| 4 | Proof delivery for deposit #2 | CC3 | `0x2a9a56fa0216e5886931a337d28413aec82e05a6f2248d2a960548260f5b625c` | `EthScoreIncreased`, ethScore 0.015 |
| 5 | Loan #1 (borrow) | CC3 | `0xe243b6726bedfbbbab6644ef3db18ee7361060556f46627115385ae26c596b8d` | `LoanOpened`, pool funds it |
| 6 | Loan #1 repaid in full, path A (repayInCTC) | CC3 | `0xdcddb3d7ee594261b41101e5e07961a51137bbb9fdccae9efae68017a81cbeb2` | `LoanRepaid`, localScore +1 |
| 7 | Loan #2 (borrow 5 CTC, deadline CC3 block 5416511) | CC3 | `0xf4d37e6a404f47b95e44cdf2f4f9fdeb05a16bdb1f3b1b3dcc60c88f7b4c052a` | `LoanOpened` |
| 8 | Lock #1: 1.0 USDC into RepaymentVault (block 11497229) | Sepolia | `0x7557839d95de44445e289ac8479b70fe45f50492af3ba68e7d24dedd955be7df` | `UsdcLockedForRepayment` event |
| 9 | Path B, delivery of lock #1 (execute → bridge v2) | CC3 | `0x202d0e9bbe98a9779ac2e5c1f426649f234da972ab9953b10f352b59c687528a` | mint 1.0 wUSDC, `LoanPartiallyRepaid`, `UsdcRepaymentProcessed` |
| 10 | Path A: top-up of 3.75 CTC (repayInCTC) | CC3 | `0xf7c42a6d2606b639090794965a0e21b0fab94fe09574be4bfc83c1cc4693182c` | `LoanPartiallyRepaid`, remaining debt 0.5 |
| 11 | Lock #2: 0.5 USDC (block 11522657) | Sepolia | `0xb05316676028d61c015ad0bb540a92a86e4bca64954f19ba49c82f91cad7cfb4` | `UsdcLockedForRepayment` event |
| 11a | Path B, delivery of lock #2 (autonomously by the worker) | CC3 | `0xb12e8797a43767ac67f8145abc5ae78c5c40c44a7a6c82e555a0d1c2164527f0` | loan #2 CLOSED (status Repaid), usdcShare 1.5, localScore +1 |
| 12 | Lock #3: 0.2 USDC (block 11522668) — NEGATIVE SCENARIO | Sepolia | `0x4b77135fb92d5fb98cec196e54156abec9495a5a06a11ca88170481eceb046ce` | delivery rejected: `USDC share cap exceeded` (30% cap: 1.5+0.2 > 1.575); no on-chain transaction — revert caught at estimateGas |
| 13 | Treasury swap: swapWusdcForCtc(1.5e18), msg.value 1.425 CTC (5% discount) | CC3 | `0xc13efd5b198d7aa3a5aa8e74966a54c3f975e963c4026e831a98f06a28d16490` | `WusdcSwapped` + `LPPool.settle`: principal 1.25 released, `outstandingPrincipal` → 0, buyer received 1.5 wUSDC |

## Final state (after step 13, reconciled against the arithmetic)

| Quantity | Value | Reconciliation |
|---|---|---|
| LPPool: balance | 100.355 CTC | 100 (stake) − 4 − 5 (fundings) + 4.18 (absorb #1: 4.2 − burn 0.02) + 3.75 (absorb #2) + 1.425 (settle) ✓ |
| LPPool: outstandingPrincipal | 0 | all issued principal (9) recovered: 4 + 3.75 via path A, 1.25 via settle ✓ |
| LPPool: LP share price | 1.00355 (totalAssets 100.355 / totalShares 100) | LP income 0.355 = 0.18 (interest #1 minus burn) + 0.175 (interest #2 minus swap discount 0.075) ✓ |
| Bridge treasury | principalFace 0, interestFace 0, wUSDC balance 0 | fully bought out; 1.5 wUSDC held by buyer `0x025A…a3d0` ✓ |
| Burned to 0xdEaD | 0.02 CTC | 10% (BURN_BPS) of the path-A interest portion of loan #1 (0.2); path B has no burn — its interest carries the swap discount. (0xdEaD also holds someone else's 0.01 from 2026-08-13 — not ours.) ✓ |
| borrowers(0x025A…): ethScore | 0.015 | from the two proven deposits ✓ |
| borrowers: localScore / loansCompleted | 2 / 2 | loans #1 and #2 repaid in full ✓ |
| borrowers: openDebt | 0 | ✓ |
| creditLimit | 7.05 CTC | 5 (BASE) + (0.015 − 0.01)×10 + 2×1 (localScore) ✓ |

## Measurements (Integration Summary)

| Metric | Value |
|---|---|
| Attestation of a fresh Sepolia block on CC3 | ~470 s (~8 min; the lag is Attestcoin's design, reorg protection) |
| Wait for an already-attested block | ~6 s (prover cache readiness) |
| Proof generation (Prover API) | ~0.4–0.7 s (for an attested block — from cache) |
| Verification + execute on CC3 (end-to-end) | ~10–12 s |
| Gas: scoring delivery (execute → CreditCore) | ~670k (669,340 / 669,788) |
| Gas: repayment delivery (execute → RepaymentBridge, mint + accounting) | ~1.0M (1,008,350 / 986,174) |
| Gas: swapWusdcForCtc | 401,282 |

## Negative scenarios (protections that fired live)

- **Anti-replay by queryId**: re-delivery of lock #1 after success — revert `Query already processed`
  (worker/failed.json, 2026-08-19T14:19:53Z). Invariant #3.
- **Path B 30% cap**: lock #3 (step 12) — delivery rejected with `USDC share cap exceeded`. worker/failed.json record
  (2026-08-19T14:41:24Z): `errorClass: execute-reverted`, `reason: "USDC share cap exceeded"`, amount 200000 (0.2 USDC),
  target RepaymentBridge. The worst outcome was prevented twice over: the contract require + the worker spends no gas (revert at
  estimateGas, no on-chain transaction was sent).
- **Historical height-scale bug** (fixed): delivery of lock #1 to bridge v1 — revert `repayment past deadline`
  (worker/failed.json, 2026-08-15T23:05:21Z); after the fix and bridge redeploy the same proof went through (step 9).

## Attestation (observed metrics)

Sepolia → CC3 attestation lag in the run: ~8 minutes (matches Attestcoin's stated design — attestation
deliberately trails the source head). A proof for an already-attested block is served by the prover from cache within seconds.

## Real external-protocol Repay on Morpho Blue Sepolia (2026-08-31, pending v4 pipeline)

TruthGate's own permissionless market on the official Morpho Blue Sepolia singleton
`0xd011EE229E7459ba1ddd22631eF7bF528d424A14` — a REAL external protocol producing the
DISCIPLINE event, replacing the simulator for this category once CreditCore v4 (action
`ScoreMorphoRepay`) is deployed. Proofs are of history: the transaction below replays
through the pipeline at any time after v4.

| Step | Tx | Notes |
|---|---|---|
| FixedPriceOracle deployed (`0x62a87bA957f07E70877EEB741eD5e0441Acc15b5`, price 1e24) | `0xf071f8e24b4b97764ab26c442323004cb6969cf3041b3b9521f21b1203f9a5d8` | serves Morpho's internal LLTV mechanics only — the bureau records the Repay event as fact, amounts emit-only |
| createMarket (tUSDC loan / DAI collateral, IRM `address(0)` = zero interest, LLTV 77%) | `0x5fb6f1ae95791ff73ec701ff4745ac67e5df6ee945c9c004b0825e999fa15a36` | marketId `0x8db3b66308de899b5dd81c0a9de5b423fbc8fe287e2f7d72e3b1e73250eaf722` = keccak256(abi.encode(params)), verified |
| supply 100 tUSDC liquidity | `0xca3dc07fe6d2e0d36c63966d843c60ba4efed630b0123e567c41a6af96b64492` | market state verified: totalSupplyAssets 100e6 |
| faucet DAI → supplyCollateral 100 → borrow 50 tUSDC → **repay by shares** (`contracts/script/morpho-demo.sh`) | **`0xf232bbd79c02655716e8f2ff983f7d67d7987b6be49cac9fb03586669396ee17`** | **the pending DISCIPLINE proof.** Receipt verified: status 1, block 11604843; `Repay` from the singleton with our pinned topic0, marketId `0x8db3..f722`, caller = onBehalf = borrower `0x025A..a3d0`, assets exactly 50e6, shares 5e13 — exact full close (zero-interest market), zero reverts in the whole cycle |
