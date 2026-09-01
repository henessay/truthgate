import { Contract, JsonRpcProvider, Wallet } from 'ethers';
import { proofProvider, chainInfo } from '@gluwa/usc-sdk';
import { CONFIG, type Deployments } from './config.js';
import { log, phase } from './logger.js';
import { TRUTHGATE_EXECUTE_ABI } from './abi.js';
import { appendFailed, type PendingEvent } from './state.js';

/** Pipeline error classes — they determine the retry policy. */
export type ErrorClass =
  | 'attestation-pending' // block not yet attested — wait, no attempts consumed
  | 'prover-unavailable' // prover API / network — retry with backoff
  | 'execute-reverted' // contract reverted — do NOT retry, goes to failed.json
  | 'unknown'; // anything else — retry with backoff

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
    // Cast: the SDK declares its own copy of the ethers types; the runtime instance is the same
    info: new chainInfo.PrecompileChainInfoProvider(cc3Provider as never),
  };
}

export function classifyError(err: unknown): ErrorClass {
  const e = err as { code?: string; message?: string; shortMessage?: string };
  const msg = `${e?.shortMessage ?? ''} ${e?.message ?? ''}`.toLowerCase();

  if (msg.includes('not yet attested') || msg.includes('attestation timeout')) return 'attestation-pending';
  // Target contract revert: ethers CALL_EXCEPTION (estimateGas or execution)
  if (e?.code === 'CALL_EXCEPTION' || msg.includes('execution reverted')) return 'execute-reverted';
  // Network/prover: any transport error is retryable
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
 * Wait for attestation of the source block on CC3 with progress logging (real
 * attestation time is a critical demo metric). On top of the on-chain check we
 * also wait for the prover cache to be ready (waitUntilHeightAttested).
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

  // The prover cache may lag behind on-chain attestation — a short extra wait
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

  // Argument order matches TruthGateBase.execute (verified against the contract)
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

  // Gas: estimate + 35% buffer; estimates for precompile calls can be flaky —
  // fallback based on continuity proof size (pattern from the Gluwa examples)
  let gasLimit: bigint;
  try {
    const estimated = await contract.execute.estimateGas(...args);
    gasLimit = (estimated * 135n) / 100n;
  } catch (err) {
    // IMPORTANT: estimateGas reverted — this may be a genuine contract revert.
    // Classify: CALL_EXCEPTION with a reason → rethrow (do not retry).
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

  // Finalization: look for the target event (EthScoreIncreased /
  // DisciplineScoreIncreased / LiquidationPenaltyApplied / UsdcRepaymentProcessed)
  let queryId: string | undefined;
  for (const l of receipt.logs) {
    try {
      const parsed = contract.interface.parseLog({ topics: [...l.topics], data: l.data });
      if (
        parsed &&
        (parsed.name === 'EthScoreIncreased' ||
          parsed.name === 'DisciplineScoreIncreased' ||
          parsed.name === 'LiquidationPenaltyApplied' ||
          parsed.name === 'UsdcRepaymentProcessed')
      ) {
        queryId = String(parsed.args.queryId);
        log.info('event:finalized-on-cc3', { key: ev.key, cc3Event: parsed.name, queryId, cc3TxHash: tx.hash });
      }
    } catch {
      /* foreign log — skip */
    }
  }

  done({ cc3TxHash: tx.hash, gasUsed: receipt.gasUsed });
  return { cc3TxHash: tx.hash, queryId };
}

/** Full pipeline for a single event: attestation → proof → execute. Throws on error. */
export async function processEvent(deps: PipelineDeps, ev: PendingEvent): Promise<void> {
  const done = phase('pipeline', { key: ev.key, eventName: ev.eventName, attempt: ev.attempts + 1 });
  await waitForAttestation(deps, ev.blockNumber);
  const proof = await generateProof(deps, ev.txHash);
  await submitProof(deps, ev, proof);
  done();
}

/** Failure handling: policy by error class. Returns true if the event is finished (failed). */
export function handleFailure(ev: PendingEvent, err: unknown): boolean {
  const errorClass = classifyError(err);
  const message = (err as Error)?.message ?? String(err);

  if (errorClass === 'attestation-pending') {
    // Not an error — waiting for attestation, no attempts consumed
    ev.notBeforeMs = Date.now() + 60_000;
    log.info('event:waiting-attestation', { key: ev.key, retryInMs: 60_000 });
    return false;
  }

  if (errorClass === 'execute-reverted') {
    // "Query already processed" is success, not failure: the contract marks the
    // queryId only after ALL effects are applied (invariant #4), so this revert
    // proves the proof was already delivered — typically by an earlier send of ours
    // whose RPC response was lost (the tx still mined), then re-sent on retry.
    if (message.includes('Query already processed')) {
      log.info('event:completed', { key: ev.key, note: 'already processed on-chain (duplicate send absorbed by queryId anti-replay)' });
      return true;
    }
    // Do NOT retry: the revert is deterministic. Full context saved — a candidate for agent triage.
    log.error('event:failed-execute-reverted', { key: ev.key, error: message });
    appendFailed({ ...stripQueueFields(ev), failedAt: new Date().toISOString(), errorClass, fullError: message });
    return true;
  }

  // prover-unavailable / unknown: exponential backoff, up to maxAttempts
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
