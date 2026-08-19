import type { WorkerFailedDto, WorkerLogEvent, WorkerQueueItem } from '../../lib/workerApi';

/**
 * Сборка карточек пайплайна из потока лог-событий worker'а.
 * Worker обрабатывает события строго по одному, поэтому события фаз без key
 * (attestation:*, proof-generation) привязываются к последнему phase:pipeline:start.
 */

export type CardStatus = 'queued' | 'attestation' | 'proof' | 'execute' | 'done' | 'retry' | 'failed';

export interface PipelineCard {
  key: string;
  txHash: string;
  eventName?: string;
  source?: string;
  args?: Record<string, string>;
  /** Sepolia-блок события — цель аттестации */
  blockNumber?: number;
  status: CardStatus;
  attempts?: number;
  /** attested-высота при первом наблюдении ожидания — базовая точка прогресса */
  attestBaseline?: number;
  attestLatest?: number;
  gapBlocks?: number;
  waitedMs?: number;
  proofMs?: number;
  proofCached?: boolean;
  continuityRoots?: number;
  cc3TxHash?: string;
  gasUsed?: string;
  cc3Event?: string;
  error?: string;
  errorClass?: string;
  /** Длительности завершённых фаз, мс: attestation / proof / execute / total */
  durations: Record<string, number | undefined>;
  updatedAt: string;
}

export interface FoldCtx {
  cards: Map<string, PipelineCard>;
  currentKey: string | null;
}

export function createFoldCtx(): FoldCtx {
  return { cards: new Map(), currentKey: null };
}

function card(ctx: FoldCtx, key: string, ts: string): PipelineCard {
  let c = ctx.cards.get(key);
  if (!c) {
    c = { key, txHash: key.split(':')[0], status: 'queued', durations: {}, updatedAt: ts };
    ctx.cards.set(key, c);
  }
  c.updatedAt = ts;
  return c;
}

function current(ctx: FoldCtx, ts: string): PipelineCard | null {
  return ctx.currentKey ? card(ctx, ctx.currentKey, ts) : null;
}

export function foldEvent(ctx: FoldCtx, ev: WorkerLogEvent): void {
  const f = ev as WorkerLogEvent & Record<string, unknown>;
  const key = typeof f.key === 'string' ? f.key : undefined;

  switch (ev.msg) {
    case 'event:detected':
    case 'replay:enqueued': {
      if (!key) return;
      const c = card(ctx, key, ev.ts);
      c.status = 'queued';
      c.eventName = f.eventName as string;
      c.source = f.source as string | undefined;
      c.args = f.args as Record<string, string> | undefined;
      c.blockNumber = f.blockNumber as number | undefined;
      return;
    }
    case 'phase:pipeline:start': {
      if (!key) return;
      ctx.currentKey = key;
      const c = card(ctx, key, ev.ts);
      c.attempts = f.attempt as number | undefined;
      if (typeof f.eventName === 'string') c.eventName = f.eventName;
      return;
    }
    case 'phase:attestation:start': {
      const c = current(ctx, ev.ts);
      if (!c) return;
      c.status = 'attestation';
      c.blockNumber ??= f.blockNumber as number | undefined;
      return;
    }
    case 'attestation:progress': {
      const c = current(ctx, ev.ts);
      if (!c) return;
      c.status = 'attestation';
      c.attestLatest = f.latestAttested as number;
      c.attestBaseline ??= f.latestAttested as number;
      c.gapBlocks = f.gapBlocks as number;
      c.waitedMs = f.waitedMs as number;
      return;
    }
    case 'phase:attestation:done': {
      const c = current(ctx, ev.ts);
      if (!c) return;
      c.durations.attestation = f.durationMs as number;
      c.status = 'proof';
      return;
    }
    case 'phase:proof-generation:start': {
      const c = current(ctx, ev.ts);
      if (c) c.status = 'proof';
      return;
    }
    case 'phase:proof-generation:done': {
      const c = current(ctx, ev.ts);
      if (!c) return;
      c.durations.proof = f.durationMs as number;
      c.proofMs = f.durationMs as number;
      c.proofCached = f.cached as boolean | undefined;
      c.continuityRoots = f.continuityRoots as number | undefined;
      c.status = 'execute';
      return;
    }
    case 'phase:execute-submit:start': {
      if (key) ctx.currentKey = key;
      const c = current(ctx, ev.ts);
      if (c) c.status = 'execute';
      return;
    }
    case 'execute:submitted': {
      if (!key) return;
      const c = card(ctx, key, ev.ts);
      c.cc3TxHash = f.cc3TxHash as string;
      return;
    }
    case 'event:finalized-on-cc3': {
      if (!key) return;
      const c = card(ctx, key, ev.ts);
      c.cc3Event = f.cc3Event as string;
      c.cc3TxHash = (f.cc3TxHash as string) ?? c.cc3TxHash;
      return;
    }
    case 'phase:execute-submit:done': {
      const c = current(ctx, ev.ts);
      if (!c) return;
      c.durations.execute = f.durationMs as number;
      c.gasUsed = f.gasUsed as string | undefined;
      return;
    }
    case 'phase:pipeline:done': {
      const c = current(ctx, ev.ts);
      if (c) c.durations.total = f.durationMs as number;
      return;
    }
    case 'event:completed': {
      if (!key) return;
      card(ctx, key, ev.ts).status = 'done';
      ctx.currentKey = null;
      return;
    }
    case 'event:waiting-attestation': {
      if (!key) return;
      const c = card(ctx, key, ev.ts);
      c.status = 'retry';
      c.errorClass = 'attestation-pending';
      c.error = 'ожидание аттестации, повтор через минуту';
      ctx.currentKey = null;
      return;
    }
    case 'event:retry-scheduled': {
      if (!key) return;
      const c = card(ctx, key, ev.ts);
      c.status = 'retry';
      c.attempts = f.attempt as number | undefined;
      c.errorClass = f.errorClass as string | undefined;
      c.error = f.error as string | undefined;
      ctx.currentKey = null;
      return;
    }
    case 'event:failed-execute-reverted':
    case 'event:failed-max-attempts': {
      if (!key) return;
      const c = card(ctx, key, ev.ts);
      c.status = 'failed';
      c.error = f.error as string | undefined;
      ctx.currentKey = null;
      return;
    }
    default:
      return;
  }
}

/** Короткая причина из полного revert-текста ethers. */
export function shortReason(full: string | undefined): string {
  if (!full) return 'ошибка';
  const m = /execution reverted: "([^"]+)"/.exec(full) ?? /reason="([^"]+)"/.exec(full);
  return m ? m[1] : full.slice(0, 120);
}

/** Очередь из state.json → карточки (для событий, ждущих до старта пайплайна / после рестарта worker'а). */
export function mergeQueue(ctx: FoldCtx, queue: WorkerQueueItem[]): void {
  for (const q of queue) {
    const existing = ctx.cards.get(q.key);
    if (existing && existing.status !== 'queued' && existing.status !== 'retry') continue;
    const c = card(ctx, q.key, existing?.updatedAt ?? q.firstSeenAt);
    c.eventName = q.eventName;
    c.source = q.source;
    c.args = q.args;
    c.blockNumber = q.blockNumber;
    c.attempts = q.attempts;
    if (q.lastError && c.status === 'queued') {
      c.status = 'retry';
      c.error = q.lastError;
    }
  }
}

/** failed.json → терминальные карточки (переживают рестарт worker'а). */
export function mergeFailed(ctx: FoldCtx, failed: WorkerFailedDto[]): void {
  for (const fEv of failed) {
    const c = card(ctx, fEv.key, fEv.failedAt);
    c.status = 'failed';
    c.eventName = fEv.eventName;
    c.source = fEv.source;
    c.args = fEv.args;
    c.blockNumber = fEv.blockNumber;
    c.error = fEv.fullError;
    c.errorClass = fEv.errorClass;
  }
}
