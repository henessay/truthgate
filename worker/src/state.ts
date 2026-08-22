import { readFileSync, writeFileSync, renameSync, existsSync, rmSync, statSync } from 'node:fs';
import { CONFIG } from './config.js';

export type EventSource = 'ScoringVault' | 'LoanBookSim' | 'RepaymentVault';
export type TargetContract = 'CreditCore' | 'RepaymentBridge';

export interface PendingEvent {
  /** Dedup key: `${txHash}:${logIndex}` */
  key: string;
  txHash: string;
  logIndex: number;
  blockNumber: number;
  source: EventSource;
  eventName: string;
  /** Event arguments (for logs/failed.json), values as strings */
  args: Record<string, string>;
  target: TargetContract;
  action: number;
  attempts: number;
  firstSeenAt: string;
  /** Do not pick up before this time (backoff / waiting for attestation) */
  notBeforeMs: number;
  lastError?: string;
}

export interface WorkerState {
  /** Sepolia cursor: the last block FULLY processed by the watcher */
  lastProcessedBlock: number;
  queue: PendingEvent[];
  /** Recently completed keys — dedup across overlapping getLogs ranges */
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
  renameSync(tmp, path); // atomic: state survives a crash mid-write
}

export function loadState(): WorkerState {
  if (!existsSync(CONFIG.stateFile)) {
    return { lastProcessedBlock: 0, queue: [], processedKeys: [] };
  }
  return JSON.parse(readFileSync(CONFIG.stateFile, 'utf8')) as WorkerState;
}

// ---------- cross-process write discipline ----------
// state.json is written by several actors: the live `run`, short-lived commands
// (replay, set-cursor) and the operator's hands. Writing a full memory snapshot
// is forbidden — a dying process would clobber others' changes. Therefore every
// write happens under a lock file and is merged with the FRESH file contents
// instead of replacing them.

const LOCK_STALE_MS = 10_000;
const LOCK_TIMEOUT_MS = 5_000;
const LOCK_RETRY_MS = 50;

function sleepSync(ms: number): void {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

export function withStateLock<T>(fn: () => T): T {
  const lockFile = `${CONFIG.stateFile}.lock`;
  const deadline = Date.now() + LOCK_TIMEOUT_MS;
  for (;;) {
    try {
      writeFileSync(lockFile, String(process.pid), { flag: 'wx' });
      break;
    } catch {
      // Lock is held. Remove a stale one (crashed process); wait on a live one.
      try {
        if (Date.now() - statSync(lockFile).mtimeMs > LOCK_STALE_MS) {
          rmSync(lockFile, { force: true });
          continue;
        }
      } catch {
        continue; // lock vanished between checks — retry acquisition
      }
      if (Date.now() > deadline) throw new Error(`state lock busy: ${lockFile}`);
      sleepSync(LOCK_RETRY_MS); // state operations take milliseconds — the wait is short
    }
  }
  try {
    return fn();
  } finally {
    rmSync(lockFile, { force: true });
  }
}

function capProcessedKeys(state: WorkerState): void {
  if (state.processedKeys.length > MAX_PROCESSED_KEYS) {
    state.processedKeys = state.processedKeys.slice(-MAX_PROCESSED_KEYS);
  }
}

/**
 * Exclusive read-modify-write for short-lived commands (replay, set-cursor):
 * under the lock, the FRESH file is read, mutated, and synchronously written to
 * disk before returning — the result is visible in state.json right after the command.
 */
export function updateState(mutate: (s: WorkerState) => void): WorkerState {
  return withStateLock(() => {
    const s = loadState();
    mutate(s);
    capProcessedKeys(s);
    atomicWrite(CONFIG.stateFile, s);
    return s;
  });
}

/**
 * Three-way merge for the long-lived `run`: base — what the process saw on disk
 * at the last sync, mem — its current memory, disk — the fresh file.
 * External changes (disk≠base) take priority over the process's own:
 *  - a cursor moved externally (set-cursor / by hand) is not rolled back;
 *  - an event enqueued externally (replay) is not lost;
 *  - a key externally removed from processedKeys (replay) is not resurrected.
 */
export function mergeStates(base: WorkerState, mem: WorkerState, disk: WorkerState): WorkerState {
  const lastProcessedBlock =
    disk.lastProcessedBlock !== base.lastProcessedBlock ? disk.lastProcessedBlock : mem.lastProcessedBlock;

  const baseQueueKeys = new Set(base.queue.map((e) => e.key));
  const memQueueKeys = new Set(mem.queue.map((e) => e.key));
  const queue = [
    ...mem.queue,
    ...disk.queue.filter((e) => !baseQueueKeys.has(e.key) && !memQueueKeys.has(e.key)),
  ];

  const baseKeys = new Set(base.processedKeys);
  const diskKeys = new Set(disk.processedKeys);
  const externallyRemoved = new Set([...baseKeys].filter((k) => !diskKeys.has(k)));
  const memKeys = mem.processedKeys.filter((k) => !externallyRemoved.has(k));
  const memKeySet = new Set(memKeys);
  const externallyAdded = disk.processedKeys.filter((k) => !baseKeys.has(k) && !memKeySet.has(k));
  const processedKeys = [...memKeys, ...externallyAdded];

  return { lastProcessedBlock, queue, processedKeys };
}

/**
 * Sync of the `run` process memory with disk: merge under the lock, write, and
 * return the new (state, base) — the process continues with the merge result,
 * i.e. it picks up external changes.
 */
export function syncState(mem: WorkerState, base: WorkerState): { state: WorkerState; base: WorkerState } {
  return withStateLock(() => {
    const merged = mergeStates(base, mem, loadState());
    capProcessedKeys(merged);
    atomicWrite(CONFIG.stateFile, merged);
    return { state: merged, base: structuredClone(merged) };
  });
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
