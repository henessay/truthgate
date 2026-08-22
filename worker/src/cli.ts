import { EventLog } from 'ethers';
import { CONFIG, loadDeployments } from './config.js';
import { log } from './logger.js';
import { loadState, syncState, updateState, loadFailed, type PendingEvent } from './state.js';
import { SepoliaRpcPool, pollOnce, toPendingEvent } from './watcher.js';
import { buildPipelineDeps, processEvent, handleFailure } from './pipeline.js';
import { startServer } from './server.js';

let shuttingDown = false;
process.on('SIGINT', () => {
  log.info('worker:shutdown-requested');
  shuttingDown = true;
});
process.on('SIGTERM', () => {
  shuttingDown = true;
});

/** Main loop: watcher → queue → pipeline (verifySingle, one proof at a time). */
async function run(): Promise<void> {
  const deployments = loadDeployments();
  const pool = new SepoliaRpcPool(CONFIG.sepoliaRpcs, deployments);
  const deps = buildPipelineDeps(deployments);

  // --serve: HTTP facade for the web frontend (state, pipeline events, attestation lag)
  let server: ReturnType<typeof startServer> | null = null;
  if (process.argv.includes('--serve')) {
    server = startServer(Number(process.env.WORKER_SERVE_PORT ?? 8787), async () => {
      const [head, attested] = await Promise.all([
        pool.provider.getBlockNumber(),
        deps.info.getLatestAttestedHeightAndHash(CONFIG.chainKey),
      ]);
      const latestAttestedHeight = Number(attested.height);
      return {
        chainKey: CONFIG.chainKey,
        sepoliaHead: head,
        latestAttestedHeight,
        gapBlocks: head - latestAttestedHeight,
        ts: new Date().toISOString(),
      };
    });
  }
  // State discipline: memory syncs with disk ONLY via syncState (merge under
  // the lock) — a memory snapshot never clobbers external changes
  let state = loadState();
  let base = structuredClone(state);

  log.info('worker:started', {
    chainKey: CONFIG.chainKey,
    workerAddress: deps.wallet.address,
    cursor: state.lastProcessedBlock,
    queued: state.queue.length,
    sepoliaRpcs: CONFIG.sepoliaRpcs.length,
    targets: { CreditCore: deployments.cc3.CreditCore, RepaymentBridge: deployments.cc3.RepaymentBridge },
  });

  while (!shuttingDown) {
    // 1. New Sepolia events → queue. A poll error does NOT break the loop:
    // the queue below is processed regardless, and the provider rotates.
    try {
      const added = await pollOnce(pool.provider, pool.watched, state);
      if (added > 0) log.info('watcher:enqueued', { added, queued: state.queue.length });
    } catch (err) {
      log.warn('watcher:poll-error', { error: (err as Error).message });
      pool.rotate((err as Error).message);
    } finally {
      // Persist partial progress too (chunks scanned before the error): events are already queued.
      // The merge picks up external set-cursor/replay changes made between ticks.
      ({ state, base } = syncState(state, base));
    }

    // 2. Queue processing: strictly one at a time (verifySingle mode, batching later)
    const now = Date.now();
    const due = state.queue.find((e) => e.notBeforeMs <= now);
    if (due) {
      try {
        await processEvent(deps, due);
        state.queue = state.queue.filter((e) => e.key !== due.key);
        state.processedKeys.push(due.key);
        log.info('event:completed', { key: due.key });
      } catch (err) {
        const finished = handleFailure(due, err);
        if (finished) {
          state.queue = state.queue.filter((e) => e.key !== due.key);
          state.processedKeys.push(due.key);
        }
      }
      // unfinished work survives a restart, finished work is not duplicated
      ({ state, base } = syncState(state, base));
    }

    await new Promise((r) => setTimeout(r, due ? 1_000 : CONFIG.pollIntervalMs));
  }

  ({ state, base } = syncState(state, base));
  server?.close();
  pool.destroy();
  deps.cc3Provider.destroy();
  log.info('worker:stopped');
}

/** Status: cursor, queue, failures — human-readable. */
async function status(): Promise<void> {
  const state = loadState();
  const failed = loadFailed();
  console.log(
    JSON.stringify(
      {
        cursor: state.lastProcessedBlock,
        queued: state.queue.map((e) => ({
          key: e.key,
          eventName: e.eventName,
          attempts: e.attempts,
          notBefore: e.notBeforeMs > Date.now() ? new Date(e.notBeforeMs).toISOString() : 'due',
          lastError: e.lastError,
        })),
        failedCount: failed.length,
        failed: failed.map((f) => ({ key: f.key, errorClass: f.errorClass, failedAt: f.failedAt })),
      },
      null,
      2,
    ),
  );
}

/** Manual replay of one event by txHash: find the transaction logs and enqueue them. */
async function replay(txHash: string): Promise<void> {
  const deployments = loadDeployments();
  const pool = new SepoliaRpcPool(CONFIG.sepoliaRpcs, deployments);

  // Fetch the receipt with fallback across the RPC list
  let receipt = null;
  for (let i = 0; ; i++) {
    try {
      receipt = await pool.provider.getTransactionReceipt(txHash);
      break;
    } catch (err) {
      if (i >= CONFIG.sepoliaRpcs.length - 1) throw err;
      pool.rotate((err as Error).message);
    }
  }
  if (!receipt) throw new Error(`Transaction ${txHash} not found on Sepolia`);
  const watched = pool.watched;

  // First collect the events (network), then ONE exclusive read-modify-write:
  // updateState reads the fresh state.json under the lock and writes synchronously
  // before returning — the replay result is visible in the file immediately and
  // cannot be clobbered by a memory snapshot.
  const pending: PendingEvent[] = [];
  for (const w of watched) {
    const address = (await w.contract.getAddress()).toLowerCase();
    for (const l of receipt.logs) {
      if (l.address.toLowerCase() !== address) continue;
      const parsed = w.contract.interface.parseLog({ topics: [...l.topics], data: l.data });
      if (!parsed || parsed.name !== w.eventName) continue;

      pending.push(
        toPendingEvent(
          new EventLog(l, w.contract.interface, w.contract.interface.getEvent(w.eventName)!),
          w.eventName,
          w.argNames,
        ),
      );
    }
  }

  if (pending.length === 0) {
    log.warn('replay:no-matching-events', { txHash });
    pool.destroy();
    return;
  }

  let enqueued = 0;
  const result = updateState((s) => {
    for (const ev of pending) {
      // replay is forced: remove from processedKeys if present.
      // The contract's anti-replay (queryId) is the second line of defense: an already processed proof reverts.
      s.processedKeys = s.processedKeys.filter((k) => k !== ev.key);
      if (!s.queue.some((e) => e.key === ev.key)) {
        s.queue.push(ev);
        enqueued += 1;
        log.info('replay:enqueued', { key: ev.key, eventName: ev.eventName });
      }
    }
  });
  log.info('replay:persisted', {
    enqueued,
    cursor: result.lastProcessedBlock,
    queuedKeys: result.queue.map((e) => e.key),
  });
  pool.destroy();
}

/** Sanctioned way to move the watcher cursor (instead of hand-editing state.json). */
async function setCursor(arg: string): Promise<void> {
  const block = Number(arg);
  if (!Number.isInteger(block) || block < 0) {
    throw new Error(`Invalid block number: ${arg}`);
  }
  let from = 0;
  const result = updateState((s) => {
    from = s.lastProcessedBlock;
    s.lastProcessedBlock = block;
  });
  log.info('cursor:set', { from, to: block, queued: result.queue.length });
}

const [, , command, arg] = process.argv;
const main =
  command === 'run' ? run()
  : command === 'status' ? status()
  : command === 'replay' && arg ? replay(arg)
  : command === 'set-cursor' && arg ? setCursor(arg)
  : Promise.reject(new Error('Usage: worker <run [--serve]|status|replay <txHash>|set-cursor <block>>'));

main.catch((err) => {
  log.error('worker:fatal', { error: (err as Error).message });
  process.exit(1);
});
