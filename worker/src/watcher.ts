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
 * Sepolia provider pool: the first URL is the primary; on a provider error the
 * cli calls rotate() and the next poll goes through a backup RPC.
 * Watched contracts are rebuilt against the current provider.
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
    // staticNetwork: skip the chainId fetch at startup (a dead first RPC does not block)
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

// eth_getLogs range-limit errors from free-tier providers
// (Alchemy: "up to a 10 block range", Infura: "query returned more than …",
// publicnode/BlastAPI: "limited to …" / "exceeds … range")
const RANGE_ERROR_RE = /block range|range is too|limited to|too many (logs|results)|exceed\w* .*range|response size/i;

// Current chunk size: starts at CONFIG.getLogsChunk; on range errors it is
// halved (down to 1) and stays learned for the process's entire uptime
let currentChunk = CONFIG.getLogsChunk;

/**
 * One polling pass: getLogs over the three contracts from the cursor to the
 * Sepolia head (in chunks — free RPCs reject wide ranges). Dedup by
 * (txHash, logIndex) against the queue and processedKeys. Returns the number
 * of new events.
 *
 * At most maxChunksPerPoll chunks are scanned per pass: a long backfill must
 * not block queue processing — the tail is picked up on subsequent ticks.
 */
export async function pollOnce(
  provider: JsonRpcProvider,
  watched: WatchedContract[],
  state: WorkerState,
): Promise<number> {
  const head = await provider.getBlockNumber();

  if (state.lastProcessedBlock === 0) {
    // First initialization: head − lookback, so an event sent before the
    // worker started is not lost (afterwards we scan as usual)
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
        // Provider rejects the range: shrink the chunk and retry the SAME from —
        // the cursor does not move; already-added events are filtered by `known`
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
