import { Contract, zeroPadValue, type ContractRunner } from 'ethers';
import deployments from '../../../docs/deployments.json';
import CreditCoreAbi from './abi/CreditCore.json';
import RepaymentBridgeAbi from './abi/RepaymentBridge.json';
import LPPoolAbi from './abi/LPPool.json';
import WrappedUSDCAbi from './abi/WrappedUSDC.json';
import { cc3Provider } from './providers';

export const ADDR = {
  cc3: deployments.cc3,
  sepolia: deployments.sepolia,
} as const;

/** Demo borrower (identity v1: deployer == borrower == worker) — read-only mode without a wallet. */
export const DEMO_BORROWER = '0x025A5616B35bd7D0B79d14DA58fa3e34CEd8a3d0';

// Read-only instances on the CC3 provider
export const creditCore = new Contract(ADDR.cc3.CreditCore, CreditCoreAbi, cc3Provider);
export const repaymentBridge = new Contract(ADDR.cc3.RepaymentBridge, RepaymentBridgeAbi, cc3Provider);
export const lpPool = new Contract(ADDR.cc3.LPPool, LPPoolAbi, cc3Provider);
export const wrappedUsdc = new Contract(ADDR.cc3.WrappedUSDC, WrappedUSDCAbi, cc3Provider);

/** Contract with a signer attached — for actions via MetaMask. */
export function withSigner(c: Contract, runner: ContractRunner): Contract {
  return c.connect(runner) as Contract;
}

export const LOAN_STATUS = ['None', 'Created', 'Funded', 'PartlyRepaid', 'Repaid', 'Expired'] as const;
export type LoanStatusName = (typeof LOAN_STATUS)[number];

export interface LoanView {
  id: bigint;
  borrower: string;
  principal: bigint;
  interestDue: bigint;
  repaidAmount: bigint;
  usdcRepaidShare: bigint;
  deadlineBlock: bigint;
  status: LoanStatusName;
  principalRepaid: bigint;
  /** Gross loan cost including the penalty (totalDueFor) */
  totalDue: bigint;
  /** Net outstanding: totalDue − repaidAmount (clamped at 0) */
  outstanding: bigint;
  /** Path B cap: 30% of principal + interestDue */
  usdcCap: bigint;
}

export interface BorrowerOverview {
  address: string;
  /** CAPITAL component (v4 split: proven deposits/staking only). */
  ethScore: bigint;
  localScore: bigint;
  openDebt: bigint;
  loansCompleted: bigint;
  /** DISCIPLINE component (v4): proven repayments, sim + external protocols. */
  disciplineScore: bigint;
  /** Capital gate (v4 pivot fix 3): discipline counts only while proven capital ≥ threshold. */
  capitalGatePassed: boolean;
  capitalGateThreshold: bigint;
  creditLimit: bigint;
  available: bigint;
  /* limit breakdown: BASE + slope×(effective−min) + K×localScore/1e18 */
  baseLimit: bigint;
  fromEthScore: bigint;
  /** Slope part attributable to (gated) discipline. */
  fromDiscipline: bigint;
  fromLocalScore: bigint;
  /** Limit reduction from proven liquidations, clamped to the earned bonus (never eats the base). */
  liquidationPenalty: bigint;
  /** capital + gated discipline — the score the limit slope runs over. */
  effectiveScore: bigint;
  /** DEPOSIT_SCORE_CAP + DISCIPLINE_SCORE_CAP — the on-chain maximum of effectiveScore (gauge denominator). */
  scoreCapTotal: bigint;
}

/** Block shortly before the CC3 contracts were deployed — lower bound for queryFilters.
 * v4 core created in block 5411029 (tx 0xa8df4ddf…a39f). */
export const CC3_DEPLOY_BLOCK = 5_411_028;

export interface PoolStats {
  balance: bigint;
  totalAssets: bigint;
  totalShares: bigint;
  /** LP share price ×1e18 (1e18 = 1.0) */
  sharePrice: bigint;
  outstandingPrincipal: bigint;
}

export async function fetchPoolStats(): Promise<PoolStats> {
  const [balance, totalAssets, totalShares, outstandingPrincipal] = await Promise.all([
    cc3Provider.getBalance(ADDR.cc3.LPPool),
    lpPool.totalAssets() as Promise<bigint>,
    lpPool.totalShares() as Promise<bigint>,
    lpPool.outstandingPrincipal() as Promise<bigint>,
  ]);
  const sharePrice = totalShares > 0n ? (totalAssets * 10n ** 18n) / totalShares : 10n ** 18n;
  return { balance, totalAssets, totalShares, sharePrice, outstandingPrincipal };
}

/** The public CC3 RPC enforces a 10 s timeout on eth_getLogs and scans ~2k blocks/s
 * (measured: 20k blocks times out, 2.7k takes 1.3 s) — the deploy→head span must be
 * walked in small windows. Concurrency is capped at 3 so a burst of parallel windows
 * (ethers batches them into one JSON-RPC batch) can't pile past the node's timeout. */
const LOG_CHUNK_BLOCKS = 5_000;
const LOG_WALK_CONCURRENCY = 3;

async function walkWindows<T>(fromBlock: number, fetchWindow: (from: number, to: number) => Promise<T[]>): Promise<T[]> {
  const head = await cc3Provider.getBlockNumber();
  const windows: [number, number][] = [];
  for (let f = fromBlock; f <= head; f += LOG_CHUNK_BLOCKS) {
    windows.push([f, Math.min(f + LOG_CHUNK_BLOCKS - 1, head)]);
  }
  const results: T[][] = new Array(windows.length);
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(LOG_WALK_CONCURRENCY, windows.length) }, async () => {
      while (next < windows.length) {
        const idx = next++;
        results[idx] = await fetchWindow(windows[idx][0], windows[idx][1]);
      }
    }),
  );
  return results.flat();
}

type QueryFilterArgs = Parameters<Contract['queryFilter']>;

function chunkedQueryFilter(contract: Contract, filter: QueryFilterArgs[0], fromBlock: number) {
  return walkWindows(fromBlock, (from, to) => contract.queryFilter(filter, from, to));
}

/** How many Sepolia transactions were proven into the borrower's score
 * (EthScoreIncreased = capital + DisciplineScoreIncreased = discipline, v4). */
export async function fetchScoreProofCount(address: string): Promise<number> {
  const [capital, discipline] = await Promise.all([
    chunkedQueryFilter(creditCore, creditCore.filters.EthScoreIncreased(address), CC3_DEPLOY_BLOCK),
    chunkedQueryFilter(creditCore, creditCore.filters.DisciplineScoreIncreased(address), CC3_DEPLOY_BLOCK),
  ]);
  return capital.length + discipline.length;
}

export interface PathBDelivery {
  count: number;
  lastCc3TxHash: string;
}

/** Repayments delivered through the bridge, per loan: ccLoanId → {count, CC3 tx hash}. */
export async function fetchPathBDeliveries(): Promise<Record<string, PathBDelivery>> {
  const logs = await chunkedQueryFilter(
    repaymentBridge,
    repaymentBridge.filters.UsdcRepaymentProcessed(),
    CC3_DEPLOY_BLOCK,
  );
  const out: Record<string, PathBDelivery> = {};
  for (const l of logs) {
    const loanId = (l as { args?: { ccLoanId?: bigint } }).args?.ccLoanId?.toString();
    if (!loanId) continue;
    out[loanId] = { count: (out[loanId]?.count ?? 0) + 1, lastCc3TxHash: l.transactionHash };
  }
  return out;
}

export async function fetchBorrowerOverview(address: string): Promise<BorrowerOverview> {
  const [borrowerRow, creditLimit, effectiveScore, depositScore, gateThreshold, baseLimit, minEth, slopeNum, slopeDen, localK, capitalCap, disciplineCap] =
    await Promise.all([
      creditCore.borrowers(address) as Promise<bigint[]>,
      creditCore.creditLimit(address) as Promise<bigint>,
      creditCore.effectiveScoreOf(address) as Promise<bigint>,
      creditCore.depositScoreOf(address) as Promise<bigint>,
      creditCore.CAPITAL_GATE_THRESHOLD() as Promise<bigint>,
      creditCore.BASE_LIMIT() as Promise<bigint>,
      creditCore.MIN_ETH_SCORE() as Promise<bigint>,
      creditCore.SCORE_SLOPE_NUM() as Promise<bigint>,
      creditCore.SCORE_SLOPE_DEN() as Promise<bigint>,
      creditCore.LOCAL_SCORE_K() as Promise<bigint>,
      creditCore.DEPOSIT_SCORE_CAP() as Promise<bigint>,
      creditCore.DISCIPLINE_SCORE_CAP() as Promise<bigint>,
    ]);

  const [ethScore, localScore, openDebt, loansCompleted] = borrowerRow;
  // 5th/6th fields appended in v3/v4 — tolerate an older ABI/deployment
  const rawPenalty = borrowerRow[4] ?? 0n;
  const disciplineScore = borrowerRow[5] ?? 0n;
  const capitalGatePassed = depositScore >= gateThreshold;

  // Slope decomposition mirrors creditLimit(): the total slope bonus runs over the
  // GATED effective score; the capital part is what ethScore alone would earn,
  // the discipline part is the gated remainder
  const totalSlope = effectiveScore >= minEth ? ((effectiveScore - minEth) * slopeNum) / slopeDen : 0n;
  const fromEthScore = ethScore >= minEth ? ((ethScore - minEth) * slopeNum) / slopeDen : 0n;
  const fromDiscipline = totalSlope > fromEthScore ? totalSlope - fromEthScore : 0n;
  // localScore is stored in 1e18 units (1e18 = one score unit = +LOCAL_SCORE_K to the limit)
  const fromLocalScore = (localScore * localK) / 10n ** 18n;
  // Mirror the on-chain clamp: the penalty burns only the earned bonus, base survives
  const bonus = totalSlope + fromLocalScore;
  const liquidationPenalty = rawPenalty > bonus ? bonus : rawPenalty;
  const available = creditLimit > openDebt ? creditLimit - openDebt : 0n;

  return {
    address,
    ethScore,
    localScore,
    openDebt,
    loansCompleted,
    disciplineScore,
    capitalGatePassed,
    capitalGateThreshold: gateThreshold,
    creditLimit,
    available,
    baseLimit: creditLimit > 0n ? baseLimit : 0n,
    fromEthScore,
    fromDiscipline,
    fromLocalScore,
    liquidationPenalty,
    effectiveScore,
    scoreCapTotal: capitalCap + disciplineCap,
  };
}

/** All of the borrower's loans (closed ones too — history matters for the demo). Demo scale: a handful of loans. */
export async function fetchLoans(address: string): Promise<LoanView[]> {
  const [nextId, capBps] = await Promise.all([
    creditCore.nextLoanId() as Promise<bigint>,
    repaymentBridge.USDC_SHARE_CAP_BPS() as Promise<bigint>,
  ]);

  const ids = Array.from({ length: Number(nextId) - 1 }, (_, i) => BigInt(i + 1));
  const rows = await Promise.all(
    ids.map(async (id) => {
      const [loan, totalDue] = await Promise.all([
        creditCore.loans(id) as Promise<[string, bigint, bigint, bigint, bigint, bigint, bigint, bigint]>,
        creditCore.totalDueFor(id) as Promise<bigint>,
      ]);
      const [borrower, principal, interestDue, repaidAmount, usdcRepaidShare, deadlineBlock, status, principalRepaid] =
        loan;
      return {
        id,
        borrower,
        principal,
        interestDue,
        repaidAmount,
        usdcRepaidShare,
        deadlineBlock,
        status: LOAN_STATUS[Number(status)] ?? 'None',
        principalRepaid,
        totalDue,
        outstanding: totalDue > repaidAmount ? totalDue - repaidAmount : 0n,
        usdcCap: ((principal + interestDue) * capBps) / 10_000n,
      } satisfies LoanView;
    }),
  );

  return rows.filter((l) => l.borrower.toLowerCase() === address.toLowerCase());
}

// ---------- Overview: the proven-record file ----------

export type ScoreRecordKind = 'capital' | 'discipline' | 'negative';

export interface ScoreRecord {
  kind: ScoreRecordKind;
  /** Human name of the proven source protocol (decoded from the delivery tx's action id). */
  source: string;
  /** Score delta (capital/discipline) or penalty (negative), 1e18 units. */
  delta: bigint;
  /** Negative only: debt covered by the liquidator in the proven LiquidationCall. */
  debtToCover?: bigint;
  queryId: string;
  cc3TxHash: string;
  blockNumber: number;
}

/** ScoreActions enum in CreditCore.sol — action id → source protocol shown in the file. */
const ACTION_SOURCE: Record<number, string> = {
  0: 'ScoringVault deposit',
  1: 'LoanBookSim repayment',
  2: 'Aave-style liquidation',
  3: 'Rocket Pool deposit',
  4: 'EigenLayer restake',
  5: 'Aave v3 repay',
  6: 'Morpho Blue repay',
};

const KIND_FALLBACK: Record<ScoreRecordKind, string> = {
  capital: 'proven deposit',
  discipline: 'proven repayment',
  negative: 'proven liquidation',
};

/**
 * The borrower's full proven-record file: every score event with its delivery tx
 * and the source protocol recovered from execute(action, …) calldata.
 * Demo scale: a handful of events, one getTransaction per unique delivery tx.
 */
export async function fetchScoreRecords(address: string): Promise<ScoreRecord[]> {
  // All three events index the borrower as topic[1] — one OR-topics walk instead of three
  const iface = creditCore.interface;
  const kindBySig = new Map<string, ScoreRecordKind>([
    [iface.getEvent('EthScoreIncreased')!.topicHash, 'capital'],
    [iface.getEvent('DisciplineScoreIncreased')!.topicHash, 'discipline'],
    [iface.getEvent('LiquidationPenaltyApplied')!.topicHash, 'negative'],
  ]);
  const logs = await walkWindows(CC3_DEPLOY_BLOCK, (fromBlock, toBlock) =>
    cc3Provider.getLogs({
      address: ADDR.cc3.CreditCore,
      fromBlock,
      toBlock,
      topics: [[...kindBySig.keys()], zeroPadValue(address, 32)],
    }),
  );

  const tagged = logs.flatMap((log) => {
    const kind = kindBySig.get(log.topics[0]);
    const parsed = iface.parseLog({ topics: [...log.topics], data: log.data });
    if (!kind || !parsed) return [];
    return [{ kind, log, args: parsed.args.toObject() as Record<string, unknown> }];
  });

  // Source protocol lives in the delivery tx calldata: execute(uint8 action, …)
  const txHashes = [...new Set(tagged.map((t) => t.log.transactionHash))];
  const actionByTx = new Map<string, number>();
  await Promise.all(
    txHashes.map(async (hash) => {
      try {
        const tx = await cc3Provider.getTransaction(hash);
        if (!tx) return;
        const parsed = creditCore.interface.parseTransaction({ data: tx.data });
        if (parsed?.name === 'execute') actionByTx.set(hash, Number(parsed.args[0]));
      } catch {
        // leave unmapped — the record falls back to a generic source label
      }
    }),
  );

  return tagged
    .map(({ kind, log, args }) => {
      const action = actionByTx.get(log.transactionHash);
      return {
        kind,
        source: (action !== undefined && ACTION_SOURCE[action]) || KIND_FALLBACK[kind],
        delta: (kind === 'negative' ? args.penalty : args.delta) as bigint,
        debtToCover: kind === 'negative' ? (args.debtToCover as bigint) : undefined,
        queryId: args.queryId as string,
        cc3TxHash: log.transactionHash,
        blockNumber: log.blockNumber,
      } satisfies ScoreRecord;
    })
    .sort((a, b) => b.blockNumber - a.blockNumber);
}

// ---------- SwapDesk: bridge treasury → CTC ----------

export interface SwapDeskState {
  /** wUSDC held by the bridge treasury (18-dec, = principalFace + interestFace). */
  treasuryWusdc: bigint;
  /** Face value attributed to loan principal (owed to the pool via settle). */
  principalFace: bigint;
  /** Face value attributed to interest margin — the discount is paid out of it. */
  interestFace: bigint;
  discountBps: bigint;
  /** CTC per wUSDC ×1e18 (v1: 1e18 = 1:1). */
  rate: bigint;
}

export async function fetchSwapDeskState(): Promise<SwapDeskState> {
  const [treasuryWusdc, principalFace, interestFace, discountBps, rate] = await Promise.all([
    wrappedUsdc.balanceOf(ADDR.cc3.RepaymentBridge) as Promise<bigint>,
    repaymentBridge.treasuryPrincipalFace() as Promise<bigint>,
    repaymentBridge.treasuryInterestFace() as Promise<bigint>,
    repaymentBridge.DISCOUNT_BPS() as Promise<bigint>,
    repaymentBridge.CTC_PER_WUSDC_RATE() as Promise<bigint>,
  ]);
  return { treasuryWusdc, principalFace, interestFace, discountBps, rate };
}

/** Exact integer replica of swapWusdcForCtc's price check — msg.value must equal this. */
export function swapCtcRequired(wusdcAmount: bigint, state: SwapDeskState): bigint {
  return (((wusdcAmount * state.rate) / 10n ** 18n) * (10_000n - state.discountBps)) / 10_000n;
}

export interface SwapRecord {
  buyer: string;
  wusdcAmount: bigint;
  ctcPaid: bigint;
  cc3TxHash: string;
  blockNumber: number;
}

export async function fetchSwapHistory(): Promise<SwapRecord[]> {
  const logs = await chunkedQueryFilter(repaymentBridge, repaymentBridge.filters.WusdcSwapped(), CC3_DEPLOY_BLOCK);
  return logs
    .map((log) => {
      const args = (log as { args?: { buyer: string; wusdcAmount: bigint; ctcPaid: bigint } }).args;
      return {
        buyer: args?.buyer ?? '',
        wusdcAmount: args?.wusdcAmount ?? 0n,
        ctcPaid: args?.ctcPaid ?? 0n,
        cc3TxHash: log.transactionHash,
        blockNumber: log.blockNumber,
      } satisfies SwapRecord;
    })
    .sort((a, b) => b.blockNumber - a.blockNumber);
}
