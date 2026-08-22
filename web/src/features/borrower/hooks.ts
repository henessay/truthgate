import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { parseEther } from 'ethers';
import {
  creditCore,
  fetchBorrowerOverview,
  fetchLoans,
  fetchPathBDeliveries,
  fetchPoolStats,
  fetchScoreProofCount,
  withSigner,
} from '../../lib/contracts';
import { cc3Provider } from '../../lib/providers';
import { useWallet } from '../../lib/wallet';

const POLL_MS = 12_000;

export function useCc3Head() {
  return useQuery({
    queryKey: ['cc3Head'],
    queryFn: () => cc3Provider.getBlockNumber().then(BigInt),
    refetchInterval: POLL_MS,
  });
}

export function useBorrowerOverview(address: string) {
  return useQuery({
    queryKey: ['borrower', address],
    queryFn: () => fetchBorrowerOverview(address),
    refetchInterval: POLL_MS,
  });
}

export function useLoans(address: string) {
  return useQuery({
    queryKey: ['loans', address],
    queryFn: () => fetchLoans(address),
    refetchInterval: POLL_MS,
  });
}

export function usePoolStats() {
  return useQuery({
    queryKey: ['poolStats'],
    queryFn: fetchPoolStats,
    refetchInterval: POLL_MS,
  });
}

export function useScoreProofCount(address: string) {
  return useQuery({
    queryKey: ['scoreProofs', address],
    queryFn: () => fetchScoreProofCount(address),
    refetchInterval: 60_000, // historical events — change rarely
  });
}

export function usePathBDeliveries() {
  return useQuery({
    queryKey: ['pathBDeliveries'],
    queryFn: fetchPathBDeliveries,
    refetchInterval: 30_000,
  });
}

/** After a successful transaction, refetch everything that could have changed. */
function useInvalidateAll() {
  const qc = useQueryClient();
  return () => {
    void qc.invalidateQueries({ queryKey: ['borrower'] });
    void qc.invalidateQueries({ queryKey: ['loans'] });
  };
}

export function useBorrow() {
  const { signer } = useWallet();
  const invalidate = useInvalidateAll();
  return useMutation({
    mutationFn: async (amountCtc: string) => {
      if (!signer) throw new Error('Wallet not connected');
      const tx = await withSigner(creditCore, signer).borrow(parseEther(amountCtc));
      await tx.wait();
      return tx.hash as string;
    },
    onSuccess: invalidate,
  });
}

export function useRepay() {
  const { signer } = useWallet();
  const invalidate = useInvalidateAll();
  return useMutation({
    mutationFn: async ({ loanId, outstanding }: { loanId: bigint; outstanding: bigint }) => {
      if (!signer) throw new Error('Wallet not connected');
      const tx = await withSigner(creditCore, signer).repayInCTC(loanId, { value: outstanding });
      await tx.wait();
      return tx.hash as string;
    },
    onSuccess: invalidate,
  });
}
