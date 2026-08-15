import { readFileSync, writeFileSync, renameSync, existsSync } from 'node:fs';
import { CONFIG } from './config.js';

export type EventSource = 'ScoringVault' | 'LoanBookSim' | 'RepaymentVault';
export type TargetContract = 'CreditCore' | 'RepaymentBridge';

export interface PendingEvent {
  /** Ключ дедупа: `${txHash}:${logIndex}` */
  key: string;
  txHash: string;
  logIndex: number;
  blockNumber: number;
  source: EventSource;
  eventName: string;
  /** Аргументы события (для логов/failed.json), значения — строки */
  args: Record<string, string>;
  target: TargetContract;
  action: number;
  attempts: number;
  firstSeenAt: string;
  /** Не раньше этого времени брать в работу (backoff/ожидание аттестации) */
  notBeforeMs: number;
  lastError?: string;
}

export interface WorkerState {
  /** Курсор Sepolia: последний ПОЛНОСТЬЮ обработанный watcher'ом блок */
  lastProcessedBlock: number;
  queue: PendingEvent[];
  /** Недавно завершённые ключи — дедуп при перекрытии диапазонов getLogs */
  processedKeys: string[];
}

export interface FailedEvent extends Omit<PendingEvent, 'notBeforeMs'> {
  failedAt: string;
  errorClass: string;
  fullError: string;
}

const MAX_PROCESSED_KEYS = 2000;

function atomicWrite(path: string, data: unknown): void {
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(data, null, 2));
  renameSync(tmp, path); // атомарно: state переживает падение посреди записи
}

export function loadState(): WorkerState {
  if (!existsSync(CONFIG.stateFile)) {
    return { lastProcessedBlock: 0, queue: [], processedKeys: [] };
  }
  return JSON.parse(readFileSync(CONFIG.stateFile, 'utf8')) as WorkerState;
}

export function saveState(state: WorkerState): void {
  if (state.processedKeys.length > MAX_PROCESSED_KEYS) {
    state.processedKeys = state.processedKeys.slice(-MAX_PROCESSED_KEYS);
  }
  atomicWrite(CONFIG.stateFile, state);
}

export function loadFailed(): FailedEvent[] {
  if (!existsSync(CONFIG.failedFile)) return [];
  return JSON.parse(readFileSync(CONFIG.failedFile, 'utf8')) as FailedEvent[];
}

export function appendFailed(entry: FailedEvent): void {
  const all = loadFailed();
  all.push(entry);
  atomicWrite(CONFIG.failedFile, all);
}
