# TruthGate × Attestcoin/USC: интеграционная сводка

Как TruthGate потребляет доказанные Sepolia-события через протокол USC (Attestcoin) на Creditcoin CC3 Testnet.

## Механика

- Верификация — precompile `0x…0FD2` (chainKey Sepolia = 1): `verifyAndEmit(chainKey, height, encodedTx, MerkleProof, ContinuityProof)`. Precompile доказывает только включение транзакции в финализированный блок; успешность (`RxStatus == 1`) проверяем сами через `EvmV1Decoder.decodeReceiptFields`.
- Приём proof'ов — `TruthGateBase.execute`: пиновка chainKey == 1 → окно свежести (для скоринга) → anti-replay по `queryId = keccak256(chainKey ‖ height ‖ txIndex)` → verify → декодирование логов с обязательной проверкой адреса-эмитента (`_validateAndExtractLogs`).

## Потребляемые события Sepolia

| Событие | Источник (owner-регистрируемый) | Потребитель | Эффект |
|---|---|---|---|
| `FundsDeposited(address indexed depositor, uint256 amount, uint256 nonce)` | vaultOnSepolia | CreditCore (action ScoreDeposit) | ethScore += amount, суммарно капится DEPOSIT_SCORE_CAP |
| `LoanRepaidOnEth(address indexed borrower, uint256 loanId, uint256 amount)` | loanBookOnSepolia | CreditCore (action ScoreRepayment) | ethScore += amount + FLAT_REPAYMENT_BONUS |
| `UsdcLockedForRepayment(address indexed borrower, uint256 ccLoanId, uint256 amount)` | repaymentVaultOnSepolia | RepaymentBridge (action UsdcRepayment) | mint wUSDC в казну моста + учёт погашения в CreditCore (≤30% долга, дедлайн по source-height + буфер) |

## Ограничения v1

- **Identity-модель: один EOA на обоих чейнах.** Sepolia-адрес участника обязан совпадать с его CC3-адресом — заёмщик идентифицируется адресом из indexed-топика доказанного события. Смарт-контракт-волеты и разные адреса на разных чейнах не поддерживаются; несовпадение borrower'а события с заёмщиком займа мост отклоняет (`borrower mismatch`).
- Сравнение source-height (Sepolia) с дедлайном в блоках CC3 — прямое, демо-условность.
- Курс wUSDC/CTC константный 1:1 (в проде — оракул).

## Роли off-chain

- Worker (`@gluwa/usc-sdk`): строит proof'ы (`ProofBuilder` → prover API), может предварительно проверять их бесплатно (`verifySingle`/`verifyBatch` через eth_call) и сабмитит в `execute`.
- AI-агент не подписывает денежные транзакции — только решения submit/defer/escalate по proof'ам (инвариант №2 CLAUDE.md).
