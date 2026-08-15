import { Contract, JsonRpcProvider, Wallet } from 'ethers';
import { proofProvider, chainInfo } from '@gluwa/usc-sdk';
import { CONFIG, type Deployments } from './config.js';
import { log, phase } from './logger.js';
import { TRUTHGATE_EXECUTE_ABI } from './abi.js';
import { appendFailed, type PendingEvent } from './state.js';

/** Классы ошибок конвейера — определяют политику ретраев. */
export type ErrorClass =
  | 'attestation-pending' // блок ещё не аттестован — ждать, попытки не тратим
  | 'prover-unavailable' // prover API / сеть — ретрай с backoff
  | 'execute-reverted' // контракт ревертнул — НЕ ретраить, в failed.json
  | 'unknown'; // прочее — ретрай с backoff

export interface PipelineDeps {
  cc3Provider: JsonRpcProvider;
  wallet: Wallet;
  targets: Record<'CreditCore' | 'RepaymentBridge', Contract>;
  proofBuilder: proofProvider.service.ProofBuilder;
  info: chainInfo.PrecompileChainInfoProvider;
}

export function buildPipelineDeps(d: Deployments): PipelineDeps {
  const cc3Provider = new JsonRpcProvider(CONFIG.cc3Rpc);
  const wallet = new Wallet(CONFIG.privateKey, cc3Provider);
  return {
    cc3Provider,
    wallet,
    targets: {
      CreditCore: new Contract(d.cc3.CreditCore, TRUTHGATE_EXECUTE_ABI, wallet),
      RepaymentBridge: new Contract(d.cc3.RepaymentBridge, TRUTHGATE_EXECUTE_ABI, wallet),
    },
    proofBuilder: new proofProvider.service.ProofBuilder(CONFIG.chainKey, CONFIG.proverApiUrl),
    // Каст: SDK декларирует свой экземпляр типов ethers; рантайм-инстанс один и тот же
    info: new chainInfo.PrecompileChainInfoProvider(cc3Provider as never),
  };
}

export function classifyError(err: unknown): ErrorClass {
  const e = err as { code?: string; message?: string; shortMessage?: string };
  const msg = `${e?.shortMessage ?? ''} ${e?.message ?? ''}`.toLowerCase();

  if (msg.includes('not yet attested') || msg.includes('attestation timeout')) return 'attestation-pending';
  // Реверт целевого контракта: ethers CALL_EXCEPTION (estimateGas или исполнение)
  if (e?.code === 'CALL_EXCEPTION' || msg.includes('execution reverted')) return 'execute-reverted';
  // Сеть/prover: любые транспортные ошибки — ретраябельны
  if (
    e?.code === 'NETWORK_ERROR' ||
    e?.code === 'TIMEOUT' ||
    e?.code === 'SERVER_ERROR' ||
    msg.includes('econnrefused') ||
    msg.includes('fetch failed') ||
    msg.includes('timeout') ||
    msg.includes('50')
  ) {
    return 'prover-unavailable';
  }
  return 'unknown';
}

/**
 * Ожидание аттестации source-блока на CC3 с логированием прогресса (реальное
 * время аттестации — критичная метрика демо). Поверх on-chain проверки ждём
 * готовность кэша prover'а (waitUntilHeightAttested).
 */
async function waitForAttestation(deps: PipelineDeps, blockNumber: number): Promise<void> {
  const done = phase('attestation', { blockNumber });
  const startedAt = Date.now();

  for (;;) {
    const latest = await deps.info.getLatestAttestedHeightAndHash(CONFIG.chainKey);
    const gap = blockNumber - Number(latest.height);
    if (gap <= 0) break;

    log.info('attestation:progress', {
      blockNumber,
      latestAttested: Number(latest.height),
      gapBlocks: gap,
      waitedMs: Date.now() - startedAt,
    });

    if (Date.now() - startedAt > CONFIG.attestTimeoutMs) {
      throw new Error(`attestation timeout: block ${blockNumber} not attested after ${CONFIG.attestTimeoutMs}ms`);
    }
    await new Promise((r) => setTimeout(r, CONFIG.attestPollMs));
  }

  // Кэш prover'а может отставать от on-chain аттестации — короткое доожидание
  await deps.proofBuilder.waitUntilHeightAttested(CONFIG.chainKey, blockNumber, 5_000, 120_000);

  done();
}

async function generateProof(deps: PipelineDeps, txHash: string): Promise<proofProvider.ContinuityResponse> {
  const done = phase('proof-generation', { txHash });
  const result = await deps.proofBuilder.getProof(txHash);
  if (!result.success || !result.data) {
    throw new Error(`prover API proof generation failed: ${result.error ?? 'no data'}`);
  }
  done({ cached: result.data.cached, continuityRoots: result.data.continuityProof.roots.length });
  return result.data;
}

async function submitProof(
  deps: PipelineDeps,
  ev: PendingEvent,
  proof: proofProvider.ContinuityResponse,
): Promise<{ cc3TxHash: string; queryId?: string }> {
  const done = phase('execute-submit', { key: ev.key, target: ev.target });
  const contract = deps.targets[ev.target];

  // Порядок аргументов — TruthGateBase.execute (сверено с контрактом)
  const args = [
    ev.action,
    proof.chainKey,
    proof.headerNumber,
    proof.txBytes,
    proof.merkleProof.root,
    proof.merkleProof.siblings,
    proof.continuityProof.lowerEndpointDigest,
    proof.continuityProof.roots,
  ] as const;

  // Gas: estimate + 35% буфер; у precompile-вызовов estimate бывает нестабилен —
  // fallback по размеру continuity-proof'а (паттерн из примеров Gluwa)
  let gasLimit: bigint;
  try {
    const estimated = await contract.execute.estimateGas(...args);
    gasLimit = (estimated * 135n) / 100n;
  } catch (err) {
    // ВАЖНО: estimateGas ревертнулся — это может быть и настоящий реверт контракта.
    // Классифицируем: CALL_EXCEPTION с reason → наверх (не ретраить).
    if (classifyError(err) === 'execute-reverted' && (err as { reason?: string })?.reason) {
      throw err;
    }
    const fallback = BigInt(21_000 + proof.continuityProof.roots.length * 5_000 + 500_000);
    log.warn('execute:gas-estimate-failed-using-fallback', { key: ev.key, gasLimit: fallback });
    gasLimit = fallback;
  }

  const tx = await contract.execute(...args, { gasLimit });
  log.info('execute:submitted', { key: ev.key, cc3TxHash: tx.hash });

  const receipt = await tx.wait();
  if (!receipt || receipt.status !== 1) {
    const err = new Error(`execute reverted on-chain, tx ${tx.hash}`);
    (err as { code?: string }).code = 'CALL_EXCEPTION';
    throw err;
  }

  // Финализация: ищем целевое событие (EthScoreIncreased / UsdcRepaymentProcessed)
  let queryId: string | undefined;
  for (const l of receipt.logs) {
    try {
      const parsed = contract.interface.parseLog({ topics: [...l.topics], data: l.data });
      if (parsed && (parsed.name === 'EthScoreIncreased' || parsed.name === 'UsdcRepaymentProcessed')) {
        queryId = String(parsed.args.queryId);
        log.info('event:finalized-on-cc3', { key: ev.key, cc3Event: parsed.name, queryId, cc3TxHash: tx.hash });
      }
    } catch {
      /* чужой лог — пропускаем */
    }
  }

  done({ cc3TxHash: tx.hash, gasUsed: receipt.gasUsed });
  return { cc3TxHash: tx.hash, queryId };
}

/** Полный конвейер одного события: attestation → proof → execute. Бросает при ошибке. */
export async function processEvent(deps: PipelineDeps, ev: PendingEvent): Promise<void> {
  const done = phase('pipeline', { key: ev.key, eventName: ev.eventName, attempt: ev.attempts + 1 });
  await waitForAttestation(deps, ev.blockNumber);
  const proof = await generateProof(deps, ev.txHash);
  await submitProof(deps, ev, proof);
  done();
}

/** Обработка ошибки: политика по классу. Возвращает true, если событие завершено (failed). */
export function handleFailure(ev: PendingEvent, err: unknown): boolean {
  const errorClass = classifyError(err);
  const message = (err as Error)?.message ?? String(err);

  if (errorClass === 'attestation-pending') {
    // Не ошибка — ждём аттестацию, попытки не тратим
    ev.notBeforeMs = Date.now() + 60_000;
    log.info('event:waiting-attestation', { key: ev.key, retryInMs: 60_000 });
    return false;
  }

  if (errorClass === 'execute-reverted') {
    // НЕ ретраим: реверт детерминирован. Полный контекст — кандидат на разбор агентом.
    log.error('event:failed-execute-reverted', { key: ev.key, error: message });
    appendFailed({ ...stripQueueFields(ev), failedAt: new Date().toISOString(), errorClass, fullError: message });
    return true;
  }

  // prover-unavailable / unknown: экспоненциальный backoff, максимум maxAttempts
  ev.attempts += 1;
  ev.lastError = message;
  if (ev.attempts >= CONFIG.maxAttempts) {
    log.error('event:failed-max-attempts', { key: ev.key, attempts: ev.attempts, errorClass, error: message });
    appendFailed({ ...stripQueueFields(ev), failedAt: new Date().toISOString(), errorClass, fullError: message });
    return true;
  }
  const delay = CONFIG.retryBaseDelayMs * 2 ** (ev.attempts - 1);
  ev.notBeforeMs = Date.now() + delay;
  log.warn('event:retry-scheduled', { key: ev.key, attempt: ev.attempts, errorClass, retryInMs: delay, error: message });
  return false;
}

function stripQueueFields(ev: PendingEvent): Omit<PendingEvent, 'notBeforeMs'> {
  const { notBeforeMs: _n, ...rest } = ev;
  return rest;
}
