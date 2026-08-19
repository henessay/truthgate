# TruthGate

Кросс-чейн кредитная платформа (хакатон): Creditcoin CC3 Testnet + Ethereum Sepolia, протокол USC (Universal Smart Contracts, aka Attestcoin) от Gluwa.

## Стек и структура (pnpm workspace)

- `contracts/` — Foundry (solc 0.8.24). `src/cc3/` — контракты для CC3, `src/sepolia/` — для Sepolia.
- `worker/` — off-chain worker: `@gluwa/usc-sdk` (proof generation/validation), `@gluwa/usc-contracts` (Solidity-библиотеки Gluwa), `ethers@6`.
- `agent/` — AI-агент (Anthropic API).
- `web/` — фронтенд.
- `docs/vendor/` — склонированные примеры Gluwa (`usc-testnet-bridge-examples` — актуальное поколение USC; `ccnext-testnet-bridge-examples` — старое поколение, только как справка). `docs/vendor/sol/` — вендоренные Solidity-исходники и ABI.

## Git

- Репозиторий: приватный GitHub `truthgate`. **Коммитить после каждой принятой сессии** (когда результат сессии одобрен — сразу commit + push).
- `broadcast/` коммитится намеренно (история деплоев — в сабмит); `.env`, `node_modules/`, `out/`, `cache/`, `worker/state.json`, `worker/failed.json` — в `.gitignore`.

## Сети

| Сеть | chainId | RPC |
|---|---|---|
| Creditcoin CC3 Testnet | 102031 | https://rpc.cc3-testnet.creditcoin.network |
| Ethereum Sepolia | 11155111 | `$SEPOLIA_RPC` из `.env` |

- **chainKey Sepolia = 1** (идентификатор attested-чейна внутри сети Creditcoin; НЕ путать с chainId).
- Prover API: https://prover.cc3-testnet.creditcoin.network
- `.env` (не коммитить): `DEPLOYER_PRIVATE_KEY`, `SEPOLIA_RPC`, `ANTHROPIC_API_KEY`.

## Precompile-верификатор (block prover)

Адрес: `0x0000000000000000000000000000000000000FD2` (4050). Интерфейс: `docs/vendor/sol/usc-contracts/INativeQueryVerifier.sol`, полный ABI: `docs/vendor/sol/abi/block_prover.json`.

```solidity
struct MerkleProofEntry { bytes32 hash; bool isLeft; }
struct MerkleProof      { bytes32 root; MerkleProofEntry[] siblings; }
struct ContinuityProof  { bytes32 lowerEndpointDigest; bytes32[] roots; }

// single (view / eth_call):
verify(uint64 chainKey, uint64 height, bytes encodedTransaction, MerkleProof, ContinuityProof) → bool
// single, state-changing, эмитит TransactionVerified(uint64,uint64,uint64):
verifyAndEmit(uint64 chainKey, uint64 height, bytes encodedTransaction, MerkleProof, ContinuityProof) → bool
// batch (перегрузки; общий ContinuityProof на весь батч) — on-chain батч ЕСТЬ:
verify(uint64 chainKey, uint64[] heights, bytes[] encodedTransactions, MerkleProof[], ContinuityProof) → bool
verifyAndEmit(uint64 chainKey, uint64[] heights, bytes[] encodedTransactions, MerkleProof[], ContinuityProof) → bool

calculateTxIndex(MerkleProof) → uint64   // для вычисления queryId
```

Precompile реверта́ет при невалидном proof'е и возвращает true при успехе. Паттерн контракта-приёмника — `docs/vendor/sol/examples/USCBase.sol`: `execute()` → анти-replay по queryId → `VERIFIER.verifyAndEmit(...)` → декодирование → бизнес-логика. `queryId = keccak256(chainKey ‖ blockHeight ‖ txIndex)` (см. `USCBase._computeQueryId`).

## Декодирование транзакции (EvmV1Decoder)

`docs/vendor/sol/usc-contracts/EvmV1Decoder.sol` (импорт: `@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol`). `encodedTransaction` = abi.encode(uint8 txType, bytes[] chunks).

```solidity
EvmV1Decoder.getTransactionType(bytes) → uint8            // 0–4
EvmV1Decoder.decodeCommonTxFields(bytes) → CommonTxFields // nonce,gasLimit,from,toIsNull,to,value,data
EvmV1Decoder.decodeReceiptFields(bytes) → ReceiptFields   // receiptStatus,receiptGasUsed,receiptLogs,receiptLogsBloom
EvmV1Decoder.getLogsByEventSignature(receipt, bytes32 sig) → LogEntry[]  // LogEntry: address_, topics, data
```

Статус транзакции: `receipt.receiptStatus == 1` (uint8). Это НАШ require, см. инварианты.

## Off-chain (worker, @gluwa/usc-sdk 0.18)

`PrecompileBlockProver` (адрес 0x0FD2 через eth_call): `verifySingle`, `verifyBatch` (staticCall — бесплатная проверка), `verifyAndEmitSingle`, `verifyAndEmitBatch` (подписанные транзакции). Proof'ы строятся `ProofBuilder(chainKey, proverApiUrl).getProof(txHash)` → `{chainKey, headerNumber, txBytes, merkleProof, continuityProof}`; батчевый continuity — `ContinuityProofBuilder.mergeProofs`.

## Легаси (ccnext, только справка — НЕ использовать в новом коде)

Старое поколение: prover-контракт с `submitQuery`/`submitQueryProof(queryId, proof) → ResultSegment[]`, `struct ResultSegment { uint256 offset; bytes32 abiBytes; }`, событие `QueryProofVerified(QueryId, ResultSegment[], QueryState)`. Порядок сегментов задаётся QueryBuilder'ом (типовой ERC-20-запрос: [0]=RxStatus, [1]=TxFrom, [2]=TxTo, [3]=адрес контракта события, [4]=сигнатура события, [5..7]=топики/данные Transfer). ABI: `docs/vendor/sol/abi/ccnext-prover.json`. Файлов `UniversalSmartContract_Core.sol` / `Types.sol` в открытых исходниках нет — только ABI.

## Известные особенности CC3

- **`EvmV1Decoder` — deployed library, требует линковки.** У библиотеки public-функции, поэтому она деплоится отдельным контрактом, а CreditCore и RepaymentBridge создаются с `--libraries node_modules/@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol:EvmV1Decoder:<адрес>` (LPPool и WrappedUSDC линковки не требуют — проверяется по `linkReferences` в артефактах). Сопутствующий баг forge: при передаче полного node_modules-пути как таргета `forge create`/`forge inspect` паникуют (`StripPrefixError`, crates/common/src/contracts.rs) — таргет надо задавать голым именем `EvmV1Decoder`.
- **`forge script` несовместим с CC3.** Substrate-EVM CC3 отдаёт заголовки блоков без поля `prevRandao`, и forge (проверено на 1.7.1) падает с паникой `header validation error: prevrandao not set` (crates/script/src/runner.rs) при попытке форкнуть состояние — даже без `--broadcast` и со `--skip-simulation`. При этом `forge create` и `cast` работают с CC3 нормально. Решение: деплой на CC3 делается ручным скриптом `contracts/script/deploy-cc3.sh` (forge create + cast send, с обратной верификацией всех связок через cast call); `DeployCC3.s.sol` остаётся как эталон порядка деплоя, но не запускается. На Sepolia forge script работает как обычно.

## Ограничения v1

- **Identity-модель: один EOA на обоих чейнах.** Sepolia-адрес заёмщика == его CC3-адрес: скоринговые события и погашения пути Б матчатся на заёмщика по адресу из топика события. Смарт-контракт-волеты (Safe и т.п.) и разные адреса на чейнах НЕ поддерживаются; RepaymentBridge дополнительно ревертит `borrower mismatch`, если borrower из события не совпадает с заёмщиком займа.
- Дедлайн займа выражен в блоках CC3; RepaymentBridge проверяет его против `block.number` CC3 на момент доставки proof'а (+ DELIVERY_BUFFER_BLOCKS, тоже CC3-блоки). Sepolia-`sourceHeight` в проверке дедлайна НЕ участвует — шкалы несравнимы (исторический баг «repayment past deadline»), а аттестованной «текущей высоты» Sepolia на CC3 нет как примитива (Attestcoin намеренно держит аттестацию позади головы источника). Поздний лок отсекается транзитивно: доставка не бывает раньше лока. Различимые реверты: `loan expired` (просрочка, зафиксированная markLoanAsExpired) и `repayment delivery window exceeded` (доставка за дедлайн+буфер).
- Курс wUSDC/CTC — константа 1:1 (тестнет, реальной цены нет); в проде — оракул.
- Погашения пути Б высвобождают принципал LPPool не сразу, а через SwapDesk: продажа wUSDC из казны моста за CTC с дисконтом → `LPPool.settle`. Дисконт покрывается процентной частью пути Б (путь Б гасит долг процентом-первым, путь А — телом-первым; трек `Loan.principalRepaid`); гарантия покрытия — constant-check в конструкторе RepaymentBridge: `RATE·1e8 >= DISCOUNT·CAP·(1e4+RATE)`.

## ИНВАРИАНТЫ (обязательны, проверять в каждом ревью)

1. **Precompile НЕ проверяет успешность исходной транзакции** — он доказывает только включение в финализированный блок. Проверка `receipt.receiptStatus == 1` (RxStatus) ОБЯЗАНА выполняться в нашем контракте после `EvmV1Decoder.decodeReceiptFields`, до любой бизнес-логики.
2. **AI-агент никогда не подписывает денежные транзакции.** Его полномочия — только решения `submit` / `defer` / `escalate` по proof'ам. Ключи с деньгами агенту недоступны.
3. **Replay-protection по queryId обязателен во всех точках приёма** (контракты на CC3 и Sepolia, worker): `mapping(bytes32 => bool) processedQueries` + require ДО обработки, как в `USCBase.execute`.
