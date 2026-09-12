/**
 * Worker API client (worker run --serve, planned: http://127.0.0.1:8787).
 * Graceful degradation: worker offline → null, NEVER throws —
 * every screen must keep working without the worker.
 */

const env = (import.meta as { env?: Record<string, string | boolean> }).env;
// Localhost default only in dev; a production build without VITE_WORKER_API is a
// chain-only deploy — polling the VIEWER'S own 127.0.0.1 would be nonsense.
const BASE: string | null =
  (env?.VITE_WORKER_API as string | undefined) ?? (env?.PROD ? null : 'http://127.0.0.1:8787');

/** No worker API configured (hosted chain-only mode): the Pipeline screen
 * renders proven deliveries read from CC3 instead of the live feed. */
export const CHAIN_ONLY = BASE === null;

export interface WorkerQueueItem {
  key: string;
  txHash: string;
  blockNumber: number;
  source: string;
  eventName: string;
  args: Record<string, string>;
  target: string;
  attempts: number;
  lastError?: string;
  notBeforeMs: number;
  firstSeenAt: string;
}

export interface WorkerStateDto {
  lastProcessedBlock: number;
  queue: WorkerQueueItem[];
  processedKeys: string[];
}

export interface WorkerFailedDto extends Omit<WorkerQueueItem, 'notBeforeMs'> {
  failedAt: string;
  errorClass: string;
  fullError: string;
}

async function get<T>(path: string): Promise<T | null> {
  if (BASE === null) return null;
  try {
    const res = await fetch(`${BASE}${path}`, { signal: AbortSignal.timeout(3_000) });
    if (!res.ok) return null;
    return (await res.json()) as T;
  } catch {
    return null; // worker offline is a normal UI state
  }
}

export interface WorkerLogEvent {
  seq: number;
  ts: string;
  level: 'info' | 'warn' | 'error';
  msg: string;
  [k: string]: unknown;
}

export interface WorkerEventsDto {
  latestSeq: number;
  events: WorkerLogEvent[];
}

export interface AttestationDto {
  chainKey: number;
  sepoliaHead: number;
  latestAttestedHeight: number;
  gapBlocks: number;
  ts: string;
}

export function fetchWorkerState(): Promise<WorkerStateDto | null> {
  return get<WorkerStateDto>('/api/state');
}

export function fetchWorkerFailed(): Promise<WorkerFailedDto[] | null> {
  return get<WorkerFailedDto[]>('/api/failed');
}

export function fetchWorkerEvents(since: number): Promise<WorkerEventsDto | null> {
  return get<WorkerEventsDto>(`/api/events?since=${since}`);
}

export function fetchAttestation(): Promise<AttestationDto | null> {
  return get<AttestationDto>('/api/attestation');
}

export async function workerOnline(): Promise<boolean> {
  return (await fetchWorkerState()) !== null;
}
