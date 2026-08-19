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

/** Демо-заёмщик (identity v1: deployer == borrower == worker) — режим чтения без кошелька. */
export const DEMO_BORROWER = '0x025A5616B35bd7D0B79d14DA58fa3e34CEd8a3d0';

// Read-only инстансы на CC3-провайдере
export const creditCore = new Contract(ADDR.cc3.CreditCore, CreditCoreAbi, cc3Provider);
export const repaymentBridge = new Contract(ADDR.cc3.RepaymentBridge, RepaymentBridgeAbi, cc3Provider);
export const lpPool = new Contract(ADDR.cc3.LPPool, LPPoolAbi, cc3Provider);
export const wrappedUsdc = new Contract(ADDR.cc3.WrappedUSDC, WrappedUSDCAbi, cc3Provider);

/** Контракт с подписантом — для действий через MetaMask. */
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
  /** Валовая цена займа с учётом штрафа (totalDueFor) */
  totalDue: bigint;
  /** Нетто-остаток: totalDue − repaidAmount (клампится в 0) */
  outstanding: bigint;
  /** Потолок пути Б: 30% от principal + interestDue */
  usdcCap: bigint;
}

export interface BorrowerOverview {
  address: string;
  ethScore: bigint;
  localScore: bigint;
  openDebt: bigint;
  loansCompleted: bigint;
  creditLimit: bigint;
  available: bigint;
  /* разложение лимита: BASE + slope×(ethScore−min) + K×localScore */
  baseLimit: bigint;
  fromEthScore: bigint;
  fromLocalScore: bigint;
}

export async function fetchBorrowerOverview(address: string): Promise<BorrowerOverview> {
  const [[ethScore, localScore, openDebt, loansCompleted], creditLimit, baseLimit, minEth, slopeNum, slopeDen, localK] =
    await Promise.all([
      creditCore.borrowers(address) as Promise<[bigint, bigint, bigint, bigint]>,
      creditCore.creditLimit(address) as Promise<bigint>,
      creditCore.BASE_LIMIT() as Promise<bigint>,
      creditCore.MIN_ETH_SCORE() as Promise<bigint>,
      creditCore.SCORE_SLOPE_NUM() as Promise<bigint>,
      creditCore.SCORE_SLOPE_DEN() as Promise<bigint>,
      creditCore.LOCAL_SCORE_K() as Promise<bigint>,
    ]);

  const fromEthScore = ethScore >= minEth ? ((ethScore - minEth) * slopeNum) / slopeDen : 0n;
  const fromLocalScore = localScore * localK;
  const available = creditLimit > openDebt ? creditLimit - openDebt : 0n;

  return {
    address,
    ethScore,
    localScore,
    openDebt,
    loansCompleted,
    creditLimit,
    available,
    baseLimit: creditLimit > 0n ? baseLimit : 0n,
    fromEthScore,
    fromLocalScore,
  };
}

/** Все займы заёмщика (закрытые тоже — история важна для демо). Масштаб демо: единицы займов. */
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
