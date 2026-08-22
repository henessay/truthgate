import { formatEther } from 'ethers';
import { CC3_BLOCK_TIME_S } from './providers';

/** 18-dec → string with trailing zeros trimmed: "5.25", "100.355", "0.015" */
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

/** Deadline countdown in CC3 blocks: "≈ 3 d 4 h (79,378 blocks)" */
export function fmtDeadline(deadlineBlock: bigint, headBlock: bigint): { text: string; overdue: boolean } {
  const diff = deadlineBlock - headBlock;
  if (diff <= 0n) {
    return { text: `overdue by ${fmtBlocks(-diff)} blocks`, overdue: true };
  }
  const secs = Number(diff) * CC3_BLOCK_TIME_S;
  return { text: `≈ ${fmtDuration(secs)} (${fmtBlocks(diff)} blocks)`, overdue: false };
}

function fmtBlocks(n: bigint): string {
  return n.toLocaleString('en-US');
}

function fmtDuration(secs: number): string {
  const d = Math.floor(secs / 86_400);
  const h = Math.floor((secs % 86_400) / 3_600);
  const m = Math.floor((secs % 3_600) / 60);
  if (d > 0) return `${d} d ${h} h`;
  if (h > 0) return `${h} h ${m} min`;
  return `${m} min`;
}
