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

/**
 * Один проход поллинга: getLogs по трём контрактам от курсора до головы Sepolia
 * (чанками — бесплатные RPC режут широкие диапазоны). Дедуп по (txHash, logIndex)
 * против очереди и processedKeys. Возвращает число новых событий.
 */
export async function pollOnce(
  provider: JsonRpcProvider,
  watched: WatchedContract[],
  state: WorkerState,
): Promise<number> {
  const head = await provider.getBlockNumber();

  if (state.lastProcessedBlock === 0) {
    // Первый запуск: начинаем с текущей головы, историю не перевариваем
    // (ручной прогон истории — через `worker replay <txHash>`)
    state.lastProcessedBlock = head;
    log.info('watcher:cursor-initialized', { head });
    return 0;
  }
  if (head <= state.lastProcessedBlock) return 0;

  const known = new Set([...state.processedKeys, ...state.queue.map((e) => e.key)]);
  let added = 0;

  let from = state.lastProcessedBlock + 1;
  while (from <= head) {
    const to = Math.min(from + CONFIG.getLogsChunk - 1, head);

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

    from = to + 1;
    state.lastProcessedBlock = to;
  }

  return added;
}
