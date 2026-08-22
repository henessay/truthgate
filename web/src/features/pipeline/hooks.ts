import { useEffect, useRef, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import {
  fetchAttestation,
  fetchWorkerEvents,
  fetchWorkerFailed,
  fetchWorkerState,
  type AttestationDto,
} from '../../lib/workerApi';
import { createFoldCtx, foldEvent, mergeFailed, mergeQueue, type PipelineCard } from './fold';

/** Fast polling: the attestation wait must move VISIBLY. */
const FAST_POLL_MS = 3_000;

export function useAttestation() {
  return useQuery<AttestationDto | null>({
    queryKey: ['attestation'],
    queryFn: fetchAttestation,
    refetchInterval: FAST_POLL_MS,
  });
}

export interface WorkerLive {
  online: boolean | null; // null = not known yet
  cards: PipelineCard[];
  cursor: number | null;
  queueLength: number;
}

/**
 * Live pipeline feed: /api/events is polled with a seq cursor and folded
 * into cards; state.json provides the queue (and pre-restart events), failed.json —
 * terminal failures. Worker offline → online:false, cards from the latest data.
 */
export function useWorkerLive(): WorkerLive {
  const ctxRef = useRef(createFoldCtx());
  const sinceRef = useRef(0);
  const [live, setLive] = useState<WorkerLive>({ online: null, cards: [], cursor: null, queueLength: 0 });

  useEffect(() => {
    let stopped = false;

    async function tick() {
      const [events, state, failed] = await Promise.all([
        fetchWorkerEvents(sinceRef.current),
        fetchWorkerState(),
        fetchWorkerFailed(),
      ]);
      if (stopped) return;

      const online = events !== null || state !== null;
      const ctx = ctxRef.current;

      if (events) {
        for (const ev of events.events) foldEvent(ctx, ev);
        sinceRef.current = events.latestSeq;
      }
      if (state) mergeQueue(ctx, state.queue);
      if (failed) mergeFailed(ctx, failed);

      setLive({
        online,
        cards: [...ctx.cards.values()],
        cursor: state?.lastProcessedBlock ?? null,
        queueLength: state?.queue.length ?? 0,
      });
    }

    void tick();
    const id = setInterval(() => void tick(), FAST_POLL_MS);
    return () => {
      stopped = true;
      clearInterval(id);
    };
  }, []);

  return live;
}
