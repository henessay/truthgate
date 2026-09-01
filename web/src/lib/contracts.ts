import { Contract, type ContractRunner } from 'ethers';
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
}

/** Block shortly before the CC3 contracts were deployed — lower bound for queryFilters. */
export const CC3_DEPLOY_BLOCK = 5_362_097;

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

/** How many Sepolia transactions were proven into the borrower's score
 * (EthScoreIncreased = capital + DisciplineScoreIncreased = discipline, v4). */
export async function fetchScoreProofCount(address: string): Promise<number> {
  const [capital, discipline] = await Promise.all([
    creditCore.queryFilter(creditCore.filters.EthScoreIncreased(address), CC3_DEPLOY_BLOCK),
    creditCore.queryFilter(creditCore.filters.DisciplineScoreIncreased(address), CC3_DEPLOY_BLOCK),
  ]);
  return capital.length + discipline.length;
}

export interface PathBDelivery {
  count: number;
  lastCc3TxHash: string;
}

/** Repayments delivered through the bridge, per loan: ccLoanId → {count, CC3 tx hash}. */
export async function fetchPathBDeliveries(): Promise<Record<string, PathBDelivery>> {
  const logs = await repaymentBridge.queryFilter(
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
  const [borrowerRow, creditLimit, effectiveScore, depositScore, gateThreshold, baseLimit, minEth, slopeNum, slopeDen, localK] =
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
