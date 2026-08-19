# Живой прогон TruthGate (Creditcoin CC3 Testnet + Ethereum Sepolia)

Доказательство работы полного цикла на живых сетях. Даты: 2026-08-15 … 2026-08-19 (UTC).
Explorer'ы: [Blockscout CC3](https://creditcoin-testnet.blockscout.com), [Etherscan Sepolia](https://sepolia.etherscan.io).
Все транзакции — от EOA `0x025A5616B35bd7D0B79d14DA58fa3e34CEd8a3d0` (deployer = borrower = worker, v1 identity-модель).

## Деплой

| Контракт | Чейн | Адрес | Tx создания |
|---|---|---|---|
| TestUSDC | Sepolia | `0x1Cc00628a8590e4eFDA496242439d5d09e726C14` | `0x9c8c845a376c4db553afca42dc8146db84252d3a5247ab97315ea885ba764dfa` |
| ScoringVault | Sepolia | `0xe5f1cb738ba279440565D7B46fFAb38a0E52AF37` | `0x40f81653cbbea723558c66b90ccc979ae3dbd7cbf02d33670bc8519c094b9844` |
| LoanBookSim | Sepolia | `0x77B4616343578526DCbE4580B70df6a40DFEb368` | `0xb3b0855382a171a7066588740e8820f961791a1e0332ae89fd8aba4b29ae98da` |
| RepaymentVault | Sepolia | `0xD694C9f83C6D8B9Ec4DCB7A54cD3305BB050deF1` | `0x58de33ea743fe149cb29bce45c86d2874e5098712d9b56a81c718f513cb6b3f4` |
| LPPool | CC3 | `0x1Cc00628a8590e4eFDA496242439d5d09e726C14` | `0xc4aa762e2cedb72c6f3fd6025ad30f9fff6fd17a6a413e4812cddd7c1b5ff5b4` |
| EvmV1Decoder (library) | CC3 | `0xD694C9f83C6D8B9Ec4DCB7A54cD3305BB050deF1` | `0x6a436437dc921def54a755df56b3150f4b2b3a0b64a2a6dc362cf16f2fcdc741` |
| CreditCore | CC3 | `0x62f0996Fe278321f7eF9701363830409021a3bB6` | `0x62918971d7be13ba7e248f8e2c598a504deef7095c3e39d3ca2334b5f2c0b641` |
| RepaymentBridge (v2) | CC3 | `0x179d6741664d546E059877eb43168FB11CE782AC` | `0x37e191c2565fd21f7ce9f0322f9e0cf14ac4ebea5fb612f24ff934016cbf377a` |
| WrappedUSDC | CC3 | `0x46aA13812cD7f568601A696558B213F525B1CC91` | — (создан конструктором RepaymentBridge) |

Совпадение адресов на разных чейнах (LPPool ↔ TestUSDC, EvmV1Decoder ↔ RepaymentVault) — CREATE-детерминизм: один деплойер, одинаковые nonce.

RepaymentBridge v1 (`0xEEd81A27df1D65E90B682264d23205E1ff03Aa8B`) выведен из эксплуатации 2026-08-19: живой прогон
вскрыл сравнение дедлайна CC3-шкалы с Sepolia-высотой (реверт `repayment past deadline` на любом погашении);
исправленный мост передеплоен с проверкой по `block.number` CC3, состояние CreditCore и займов сохранено.

## Демо-цикл: транзакции

| # | Шаг | Чейн | Tx | Результат |
|---|---|---|---|---|
| 1 | Депозит ETH №1 в ScoringVault (блок 11497006) | Sepolia | `0x1313698caef205679abf7b0bcb48cfde13a2217819badac851fdb81808fff4e1` | событие `FundsDeposited` |
| 2 | Депозит ETH №2 в ScoringVault (блок 11497087) | Sepolia | `0xfda6d362fdf8fd61d5bcde3ee09a952b23c266d05d45bc45ceb6e7e99a211355` | событие `FundsDeposited` |
| 3 | Доставка proof'а депозита №1 (execute → CreditCore) | CC3 | `0xf8a9bef8c0f77420beb4b2d08a22d9514b9824530a657b8ab99dc89d554026b5` | `EthScoreIncreased`, скор растёт |
| 4 | Доставка proof'а депозита №2 | CC3 | `0x2a9a56fa0216e5886931a337d28413aec82e05a6f2248d2a960548260f5b625c` | `EthScoreIncreased`, ethScore 0.015 |
| 5 | Заём №1 (borrow) | CC3 | `0xe243b6726bedfbbbab6644ef3db18ee7361060556f46627115385ae26c596b8d` | `LoanOpened`, пул фондирует |
| 6 | Погашение займа №1 целиком, путь А (repayInCTC) | CC3 | `0xdcddb3d7ee594261b41101e5e07961a51137bbb9fdccae9efae68017a81cbeb2` | `LoanRepaid`, localScore +1 |
| 7 | Заём №2 (borrow 5 CTC, дедлайн CC3-блок 5416511) | CC3 | `0xf4d37e6a404f47b95e44cdf2f4f9fdeb05a16bdb1f3b1b3dcc60c88f7b4c052a` | `LoanOpened` |
| 8 | Лок №1: 1.0 USDC в RepaymentVault (блок 11497229) | Sepolia | `0x7557839d95de44445e289ac8479b70fe45f50492af3ba68e7d24dedd955be7df` | событие `UsdcLockedForRepayment` |
| 9 | Путь Б, доставка лока №1 (execute → мост v2) | CC3 | `0x202d0e9bbe98a9779ac2e5c1f426649f234da972ab9953b10f352b59c687528a` | минт 1.0 wUSDC, `LoanPartiallyRepaid`, `UsdcRepaymentProcessed` |
| 10 | Путь А: добивка 3.75 CTC (repayInCTC) | CC3 | `0xf7c42a6d2606b639090794965a0e21b0fab94fe09574be4bfc83c1cc4693182c` | `LoanPartiallyRepaid`, остаток долга 0.5 |
| 11 | Лок №2: 0.5 USDC (блок 11522657) | Sepolia | `0xb05316676028d61c015ad0bb540a92a86e4bca64954f19ba49c82f91cad7cfb4` | событие `UsdcLockedForRepayment` |
| 11a | Путь Б, доставка лока №2 (автономно worker'ом) | CC3 | `0xb12e8797a43767ac67f8145abc5ae78c5c40c44a7a6c82e555a0d1c2164527f0` | займ №2 ЗАКРЫТ (status Repaid), usdcShare 1.5, localScore +1 |
| 12 | Лок №3: 0.2 USDC (блок 11522668) — НЕГАТИВНЫЙ СЦЕНАРИЙ | Sepolia | `0x4b77135fb92d5fb98cec196e54156abec9495a5a06a11ca88170481eceb046ce` | доставка отвергнута: `USDC share cap exceeded` (кап 30%: 1.5+0.2 > 1.575); on-chain транзакции нет — реверт пойман на estimateGas |
| 13 | Своп казны: swapWusdcForCtc(1.5e18), msg.value 1.425 CTC | CC3 | ⏳ | ожидается: `LPPool.settle`, высвобождение принципала 1.25, `outstandingPrincipal` → 0 |

## Негативные сценарии (защиты, сработавшие вживую)

- **Anti-replay по queryId**: повторная доставка лока №1 после успеха — реверт `Query already processed`
  (worker/failed.json, 2026-08-19T14:19:53Z). Инвариант №3.
- **Кап пути Б 30%**: лок №3 (шаг 12) — доставка отвергнута с `USDC share cap exceeded`. Запись worker/failed.json
  (2026-08-19T14:41:24Z): `errorClass: execute-reverted`, `reason: "USDC share cap exceeded"`, amount 200000 (0.2 USDC),
  target RepaymentBridge. Худший исход предотвращён дважды: контрактный require + worker не тратит газ (реверт на
  estimateGas, on-chain транзакция не отправлялась).
- **Исторический баг шкал высот** (исправлен): доставка лока №1 на мост v1 — реверт `repayment past deadline`
  (worker/failed.json, 2026-08-15T23:05:21Z); после фикса и передеплоя моста тот же proof прошёл (шаг 9).

## Аттестация (наблюдаемые метрики)

Лаг аттестации Sepolia → CC3 в прогоне: ~8 минут (соответствует заявленному дизайну Attestcoin — аттестация
намеренно позади головы источника). Proof по уже аттестованному блоку отдаётся prover'ом из кэша за секунды.
