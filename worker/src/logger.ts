/**
 * Структурированные JSON-логи: каждый этап жизни события с таймстампами.
 * Эти логи — будущая витрина агента и демо, формат держим машиночитаемым.
 */

type Fields = Record<string, unknown>;

function emit(level: 'info' | 'warn' | 'error', msg: string, fields: Fields = {}): void {
  // BigInt в JSON не сериализуется — приводим к строке
  const line = JSON.stringify(
    { ts: new Date().toISOString(), level, msg, ...fields },
    (_k, v) => (typeof v === 'bigint' ? v.toString() : v),
  );
  console.log(line);
}

export const log = {
  info: (msg: string, fields?: Fields) => emit('info', msg, fields),
  warn: (msg: string, fields?: Fields) => emit('warn', msg, fields),
  error: (msg: string, fields?: Fields) => emit('error', msg, fields),
};

/** Замер фазы: const done = phase('attestation', {...}); ...; done({extra}) */
export function phase(name: string, fields: Fields = {}): (extra?: Fields) => number {
  const startedAt = Date.now();
  log.info(`phase:${name}:start`, fields);
  return (extra: Fields = {}) => {
    const durationMs = Date.now() - startedAt;
    log.info(`phase:${name}:done`, { ...fields, ...extra, durationMs });
    return durationMs;
  };
}
