import { EventLog } from 'ethers';
import { CONFIG, loadDeployments } from './config.js';
import { log } from './logger.js';
import { loadState, saveState, loadFailed } from './state.js';
import { SepoliaRpcPool, pollOnce, toPendingEvent } from './watcher.js';
import { buildPipelineDeps, processEvent, handleFailure } from './pipeline.js';

let shuttingDown = false;
process.on('SIGINT', () => {
  log.info('worker:shutdown-requested');
  shuttingDown = true;
});
process.on('SIGTERM', () => {
  shuttingDown = true;
});

/** Основной цикл: watcher → очередь → конвейер (verifySingle, по одному proof'у). */
async function run(): Promise<void> {
  const deployments = loadDeployments();
  const pool = new SepoliaRpcPool(CONFIG.sepoliaRpcs, deployments);
  const deps = buildPipelineDeps(deployments);
  const state = loadState();

  log.info('worker:started', {
    chainKey: CONFIG.chainKey,
    workerAddress: deps.wallet.address,
    cursor: state.lastProcessedBlock,
    queued: state.queue.length,
    sepoliaRpcs: CONFIG.sepoliaRpcs.length,
    targets: { CreditCore: deployments.cc3.CreditCore, RepaymentBridge: deployments.cc3.RepaymentBridge },
  });

  while (!shuttingDown) {
    // 1. Новые события Sepolia → очередь. Ошибка poll'а НЕ прерывает цикл:
    // очередь ниже обрабатывается в любом случае, а провайдер ротируется.
    try {
      const added = await pollOnce(pool.provider, pool.watched, state);
      if (added > 0) log.info('watcher:enqueued', { added, queued: state.queue.length });
    } catch (err) {
      log.warn('watcher:poll-error', { error: (err as Error).message });
      pool.rotate((err as Error).message);
    } finally {
      // Частичный прогресс (чанки до ошибки) тоже сохраняем: события уже в очереди
      saveState(state);
    }

    // 2. Обработка очереди: строго по одному (verifySingle-режим, батчинг позже)
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
      saveState(state); // незавершённое переживает рестарт, завершённое не дублируется
    }

    await new Promise((r) => setTimeout(r, due ? 1_000 : CONFIG.pollIntervalMs));
  }

  saveState(state);
  pool.destroy();
  deps.cc3Provider.destroy();
  log.info('worker:stopped');
}

/** Статус: курсор, очередь, фейлы — человекочитаемо. */
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

/** Ручной перезапуск одного события по txHash: найти логи транзакции и поставить в очередь. */
async function replay(txHash: string): Promise<void> {
  const deployments = loadDeployments();
  const pool = new SepoliaRpcPool(CONFIG.sepoliaRpcs, deployments);

  // Receipt тянем с фолбэком по списку RPC
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

  const state = loadState();
  let enqueued = 0;

  for (const w of watched) {
    const address = (await w.contract.getAddress()).toLowerCase();
    for (const l of receipt.logs) {
      if (l.address.toLowerCase() !== address) continue;
      const parsed = w.contract.interface.parseLog({ topics: [...l.topics], data: l.data });
      if (!parsed || parsed.name !== w.eventName) continue;

      const ev = toPendingEvent(
        new EventLog(l, w.contract.interface, w.contract.interface.getEvent(w.eventName)!),
        w.eventName,
        w.argNames,
      );
      // replay — принудительный: убираем из processedKeys, если был.
      // Anti-replay контракта (queryId) — вторая линия: уже обработанный proof ревертнёт.
      state.processedKeys = state.processedKeys.filter((k) => k !== ev.key);
      if (!state.queue.some((e) => e.key === ev.key)) {
        state.queue.push(ev);
        enqueued += 1;
        log.info('replay:enqueued', { key: ev.key, eventName: ev.eventName });
      }
    }
  }

  if (enqueued === 0) log.warn('replay:no-matching-events', { txHash });
  saveState(state);
  pool.destroy();
}

const [, , command, arg] = process.argv;
const main =
  command === 'run' ? run()
  : command === 'status' ? status()
  : command === 'replay' && arg ? replay(arg)
  : Promise.reject(new Error('Usage: worker <run|status|replay <txHash>>'));

main.catch((err) => {
  log.error('worker:fatal', { error: (err as Error).message });
  process.exit(1);
});
