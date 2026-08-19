import { readFileSync, writeFileSync, renameSync, existsSync, rmSync, statSync } from 'node:fs';
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

// ---------- межпроцессная дисциплина записи ----------
// state.json пишут несколько акторов: живой `run`, короткие команды (replay,
// set-cursor) и руки оператора. Писать снапшот памяти целиком нельзя — умирающий
// процесс затирает чужие изменения. Поэтому: каждая запись идёт под lock-файлом
// и мёржится со СВЕЖИМ содержимым файла, а не заменяет его.

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
      // Lock занят. Протухший (упавший процесс) снимаем, живой — ждём.
      try {
        if (Date.now() - statSync(lockFile).mtimeMs > LOCK_STALE_MS) {
          rmSync(lockFile, { force: true });
          continue;
        }
      } catch {
        continue; // lock исчез между проверками — новая попытка захвата
      }
      if (Date.now() > deadline) throw new Error(`state lock busy: ${lockFile}`);
      sleepSync(LOCK_RETRY_MS); // state-операции — миллисекунды, ждать недолго
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
 * Эксклюзивное read-modify-write для короткоживущих команд (replay, set-cursor):
 * под lock'ом читается СВЕЖИЙ файл, мутируется и синхронно пишется на диск до
 * возврата — результат виден в state.json сразу после команды.
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
 * Трёхсторонний мёрж для долгоживущего `run`: base — что процесс видел на диске
 * при прошлой синхронизации, mem — его текущая память, disk — свежий файл.
 * Внешние изменения (disk≠base) приоритетнее собственных:
 *  - курсор, сдвинутый снаружи (set-cursor/руки), не откатывается;
 *  - событие, добавленное в очередь снаружи (replay), не теряется;
 *  - ключ, снаружи вычищенный из processedKeys (replay), не воскресает.
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
 * Синхронизация памяти `run` с диском: мёрж под lock'ом, запись, и возврат
 * нового (state, base) — процесс продолжает работать с результатом мёржа,
 * т.е. подхватывает внешние изменения.
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
