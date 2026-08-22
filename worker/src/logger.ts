/**
 * Structured JSON logs: every stage of an event's life, with timestamps.
 * These logs feed the future agent view and the demo — keep the format machine-readable.
 */

type Fields = Record<string, unknown>;

export interface LogEvent {
  seq: number;
  ts: string;
  level: 'info' | 'warn' | 'error';
  msg: string;
  [k: string]: unknown;
}

// Ring buffer of recent events — the pipeline view for web (--serve).
// Stores the already-serialized (bigint-safe) form.
const BUFFER_MAX = 500;
const buffer: LogEvent[] = [];
let seqCounter = 0;

/** Events with seq > since (for frontend polling with a cursor). */
export function getLogEvents(since = 0): { latestSeq: number; events: LogEvent[] } {
  return { latestSeq: seqCounter, events: buffer.filter((e) => e.seq > since) };
}

function emit(level: 'info' | 'warn' | 'error', msg: string, fields: Fields = {}): void {
  // BigInt is not JSON-serializable — convert to string
  const line = JSON.stringify(
    { ts: new Date().toISOString(), level, msg, ...fields },
    (_k, v) => (typeof v === 'bigint' ? v.toString() : v),
  );
  console.log(line);

  const parsed = JSON.parse(line) as { ts: string; level: 'info' | 'warn' | 'error'; msg: string };
  buffer.push({ ...parsed, seq: ++seqCounter });
  if (buffer.length > BUFFER_MAX) buffer.splice(0, buffer.length - BUFFER_MAX);
}

export const log = {
  info: (msg: string, fields?: Fields) => emit('info', msg, fields),
  warn: (msg: string, fields?: Fields) => emit('warn', msg, fields),
  error: (msg: string, fields?: Fields) => emit('error', msg, fields),
};

/** Phase timing: const done = phase('attestation', {...}); ...; done({extra}) */
export function phase(name: string, fields: Fields = {}): (extra?: Fields) => number {
  const startedAt = Date.now();
  log.info(`phase:${name}:start`, fields);
  return (extra: Fields = {}) => {
    const durationMs = Date.now() - startedAt;
    log.info(`phase:${name}:done`, { ...fields, ...extra, durationMs });
    return durationMs;
  };
}
