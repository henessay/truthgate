import { Contract, EventLog, JsonRpcProvider } from 'ethers';
import { CONFIG, type Deployments } from './config.js';
import { log } from './logger.js';
import { EVENT_ROUTES, LOAN_BOOK_ABI, REPAYMENT_VAULT_ABI, SCORING_VAULT_ABI } from './abi.js';
import type { PendingEvent, WorkerState } from './state.js';

interface WatchedContract {
  name: keyof typeof EVENT_ROUTES extends never ? never : string;
  contract: Contract;
  eventName: keyof typeof EVENT_ROUTES;
  argNames: string[];
}

/**
 * Пул Sepolia-провайдеров: первый URL — основной, при ошибке провайдера
 * cli зовёт rotate() и следующий poll идёт через запасной RPC.
 * Watched-контракты пересоздаются под текущий провайдер.
 */
export class SepoliaRpcPool {
  private index = 0;
  private readonly providers: JsonRpcProvider[];
  private watchedCache: WatchedContract[];

  constructor(
    urls: string[],
    private readonly deployments: Deployments,
  ) {
    if (urls.length === 0) throw new Error('SEPOLIA_RPC: empty RPC list');
    // staticNetwork: не ходить за chainId при старте (мертвый первый RPC не блокирует)
    this.providers = urls.map((u) => new JsonRpcProvider(u, 11_155_111, { staticNetwork: true }));
    this.watchedCache = buildWatchedContracts(this.provider, deployments);
  }

  get provider(): JsonRpcProvider {
    return this.providers[this.index];
  }

  get watched(): WatchedContract[] {
    return this.watchedCache;
  }

  rotate(reason: string): void {
    if (this.providers.length < 2) return;
    this.index = (this.index + 1) % this.providers.length;
    this.watchedCache = buildWatchedContracts(this.provider, this.deployments);
    log.warn('watcher:rpc-fallback', { rpcIndex: this.index, of: this.providers.length, reason });
  }

  destroy(): void {
    for (const p of this.providers) p.destroy();
  }
}

export function buildWatchedContracts(provider: JsonRpcProvider, d: Deployments): WatchedContract[] {
  return [
    {
      name: 'ScoringVault',
      contract: new Contract(d.sepolia.ScoringVault, SCORING_VAULT_ABI, provider),
      eventName: 'FundsDeposited',
      argNames: ['depositor', 'amount', 'nonce'],
    },
    {
      name: 'LoanBookSim',
      contract: new Contract(d.sepolia.LoanBookSim, LOAN_BOOK_ABI, provider),
      eventName: 'LoanRepaidOnEth',
      argNames: ['borrower', 'loanId', 'amount'],
    },
    {
      name: 'RepaymentVault',
      contract: new Contract(d.sepolia.RepaymentVault, REPAYMENT_VAULT_ABI, provider),
      eventName: 'UsdcLockedForRepayment',
      argNames: ['borrower', 'ccLoanId', 'amount'],
    },
  ];
}

export function toPendingEvent(ev: EventLog, eventName: keyof typeof EVENT_ROUTES, argNames: string[]): PendingEvent {
  const route = EVENT_ROUTES[eventName];
  const args: Record<string, string> = {};
  argNames.forEach((n, i) => (args[n] = String(ev.args[i])));

  return {
    key: `${ev.transactionHash}:${ev.index}`,
    txHash: ev.transactionHash,
    logIndex: ev.index,
    blockNumber: ev.blockNumber,
    source: route.source,
    eventName,
    args,
    target: route.target,
    action: route.action,
    attempts: 0,
    firstSeenAt: new Date().toISOString(),
    notBeforeMs: 0,
  };
}

// Ошибки лимита диапазона eth_getLogs у бесплатных провайдеров
// (Alchemy: "up to a 10 block range", Infura: "query returned more than …",
// publicnode/BlastAPI: "limited to …" / "exceeds … range")
const RANGE_ERROR_RE = /block range|range is too|limited to|too many (logs|results)|exceed\w* .*range|response size/i;

// Текущий размер чанка: стартует с CONFIG.getLogsChunk, при ошибках диапазона
// ужимается вдвое (до 1) и остаётся выученным на весь аптайм процесса
let currentChunk = CONFIG.getLogsChunk;

/**
 * Один проход поллинга: getLogs по трём контрактам от курсора до головы Sepolia
 * (чанками — бесплатные RPC режут широкие диапазоны). Дедуп по (txHash, logIndex)
 * против очереди и processedKeys. Возвращает число новых событий.
 *
 * За проход сканируется не больше maxChunksPerPoll чанков: длинный бэкфилл
 * не должен блокировать обработку очереди — хвост доберётся на следующих тиках.
 */
export async function pollOnce(
  provider: JsonRpcProvider,
  watched: WatchedContract[],
  state: WorkerState,
): Promise<number> {
  const head = await provider.getBlockNumber();

  if (state.lastProcessedBlock === 0) {
    // Первая инициализация: head − lookback, чтобы событие, отправленное
    // до запуска worker'а, не потерялось (дальше сканируем как обычно)
    state.lastProcessedBlock = Math.max(head - CONFIG.startLookbackBlocks, 0);
    log.info('watcher:cursor-initialized', {
      head,
      lookbackBlocks: CONFIG.startLookbackBlocks,
      cursor: state.lastProcessedBlock,
    });
  }
  if (head <= state.lastProcessedBlock) return 0;

  const known = new Set([...state.processedKeys, ...state.queue.map((e) => e.key)]);
  let added = 0;
  let chunksScanned = 0;

  let from = state.lastProcessedBlock + 1;
  while (from <= head && chunksScanned < CONFIG.maxChunksPerPoll) {
    const to = Math.min(from + currentChunk - 1, head);

    try {
      for (const w of watched) {
        const events = await w.contract.queryFilter(w.eventName, from, to);
        for (const ev of events) {
          if (!(ev instanceof EventLog)) continue;
          const pending = toPendingEvent(ev, w.eventName, w.argNames);
          if (known.has(pending.key)) continue;

          known.add(pending.key);
          state.queue.push(pending);
          added += 1;
          log.info('event:detected', {
            key: pending.key,
            source: pending.source,
            eventName: pending.eventName,
            blockNumber: pending.blockNumber,
            args: pending.args,
            target: pending.target,
            action: pending.action,
          });
        }
      }
    } catch (err) {
      const message = (err as Error)?.message ?? String(err);
      if (RANGE_ERROR_RE.test(message) && currentChunk > 1) {
        // Провайдер режет диапазон: ужимаем чанк и повторяем ТОТ ЖЕ from —
        // курсор не двигается, уже добавленные события отфильтрует known
        currentChunk = Math.max(1, Math.floor(currentChunk / 2));
        log.warn('watcher:chunk-reduced', { newChunk: currentChunk, from, to, reason: message });
        continue;
      }
      throw err;
    }

    from = to + 1;
    state.lastProcessedBlock = to;
    chunksScanned += 1;
  }

  if (from <= head) {
    log.info('watcher:poll-truncated', { cursor: state.lastProcessedBlock, head, remainingBlocks: head - from + 1 });
  }

  return added;
}
