import { formatEther } from 'ethers';
import { CC3_BLOCK_TIME_S } from './providers';

/** 18-dec → строка с обрезкой хвостовых нулей: "5.25", "100.355", "0.015" */
export function fmtCtc(wei: bigint, maxDecimals = 4): string {
  const s = formatEther(wei);
  const [int, frac = ''] = s.split('.');
  const trimmed = frac.slice(0, maxDecimals).replace(/0+$/, '');
  return trimmed ? `${int}.${trimmed}` : int;
}

export function shortAddr(a: string): string {
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

export function shortHash(h: string): string {
  return `${h.slice(0, 10)}…`;
}

/** Обратный отсчёт дедлайна в CC3-блоках: "≈ 3 дн 4 ч (79 378 блоков)" */
export function fmtDeadline(deadlineBlock: bigint, headBlock: bigint): { text: string; overdue: boolean } {
  const diff = deadlineBlock - headBlock;
  if (diff <= 0n) {
    return { text: `просрочен на ${fmtBlocks(-diff)} блоков`, overdue: true };
  }
  const secs = Number(diff) * CC3_BLOCK_TIME_S;
  return { text: `≈ ${fmtDuration(secs)} (${fmtBlocks(diff)} блоков)`, overdue: false };
}

function fmtBlocks(n: bigint): string {
  return n.toLocaleString('ru-RU');
}

function fmtDuration(secs: number): string {
  const d = Math.floor(secs / 86_400);
  const h = Math.floor((secs % 86_400) / 3_600);
  const m = Math.floor((secs % 3_600) / 60);
  if (d > 0) return `${d} дн ${h} ч`;
  if (h > 0) return `${h} ч ${m} мин`;
  return `${m} мин`;
}
