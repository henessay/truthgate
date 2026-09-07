import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import {
  fetchSwapDeskState,
  fetchSwapHistory,
  repaymentBridge,
  swapCtcRequired,
  withSigner,
  type SwapDeskState,
} from '../../lib/contracts';
import { useWallet } from '../../lib/wallet';

export function useSwapDesk() {
  return useQuery({
    queryKey: ['swapDesk'],
    queryFn: fetchSwapDeskState,
    refetchInterval: 12_000,
  });
}

export function useSwapHistory() {
  return useQuery({
    queryKey: ['swapHistory'],
    queryFn: fetchSwapHistory,
    refetchInterval: 60_000, // full log walk over the public RPC — keep it infrequent
  });
}

export function useSwap() {
  const { signer } = useWallet();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({ wusdcAmount, state }: { wusdcAmount: bigint; state: SwapDeskState }) => {
      if (!signer) throw new Error('Wallet not connected');
      const tx = await withSigner(repaymentBridge, signer).swapWusdcForCtc(wusdcAmount, {
        value: swapCtcRequired(wusdcAmount, state),
      });
      await tx.wait();
      return tx.hash as string;
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['swapDesk'] });
      void qc.invalidateQueries({ queryKey: ['swapHistory'] });
      void qc.invalidateQueries({ queryKey: ['poolStats'] });
    },
  });
}
