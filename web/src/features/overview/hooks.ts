import { useQuery } from '@tanstack/react-query';
import { fetchScoreRecords } from '../../lib/contracts';

export function useScoreRecords(address: string) {
  return useQuery({
    queryKey: ['scoreRecords', address],
    queryFn: () => fetchScoreRecords(address),
    refetchInterval: 60_000, // full log walk over the public RPC — keep it infrequent
  });
}
