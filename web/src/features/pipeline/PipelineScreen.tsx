import { formatEther } from 'ethers';
import { shortHash } from '../../lib/format';
import type { AttestationDto } from '../../lib/workerApi';
import { shortReason, type CardStatus, type PipelineCard } from './fold';
import { useAttestation, useWorkerLive } from './hooks';
import './pipeline.css';

const CC3_EXPLORER = 'https://creditcoin-testnet.blockscout.com';
const SEPOLIA_EXPLORER = 'https://sepolia.etherscan.io';
const SEPOLIA_BLOCK_TIME_S = 12;

const STATUS_BADGE: Record<CardStatus, { cls: string; label: string }> = {
  queued: { cls: 'idle', label: 'queued' },
  attestation: { cls: 'pending', label: 'attestation' },
  proof: { cls: 'action', label: 'generating proof' },
  execute: { cls: 'action', label: 'delivering to CC3' },
  done: { cls: 'proven', label: 'proven' },
  retry: { cls: 'pending', label: 'retry' },
  failed: { cls: 'rejected', label: 'rejected' },
};

const STATUS_ORDER: Record<CardStatus, number> = {
  attestation: 0, proof: 0, execute: 0, queued: 1, retry: 1, done: 2, failed: 2,
};

export function PipelineScreen() {
  const live = useWorkerLive();
  const attestation = useAttestation();

  const cards = [...live.cards].sort((a, b) => {
    const byStage = STATUS_ORDER[a.status] - STATUS_ORDER[b.status];
    return byStage !== 0 ? byStage : b.updatedAt.localeCompare(a.updatedAt);
  });

  return (
    <div className="pipeline">
      <div className="pipe-top">
        <div className="neo-card pipe-worker-card">
          <div className="stat-title">Worker</div>
          {live.online === null ? (
            <div className="dim">connecting…</div>
          ) : live.online ? (
            <>
              <span className="badge proven">online</span>
              <div className="pipe-worker-meta num">
                Sepolia cursor {live.cursor?.toLocaleString('en-US') ?? '—'} · queued {live.queueLength}
              </div>
            </>
          ) : (
            <>
              <span className="badge rejected">offline</span>
              <div className="pipe-worker-meta">
                run <span className="mono">pnpm worker run --serve</span> — the screen will come alive on its own
              </div>
            </>
          )}
        </div>

        <AttestationWidget data={attestation.data ?? null} online={live.online === true} />
      </div>

      <section>
        <h2 className="pipe-h2">Events</h2>
        {cards.length === 0 && (
          <p className="dim">
            Nothing yet. Send a deposit or a USDC lock on Sepolia — the event will appear here and travel
            through attestation → proof → delivery to CC3.
          </p>
        )}
        <div className="pipe-feed">
          {cards.map((c) => (
            <EventCard key={c.key} card={c} attestation={attestation.data ?? null} />
          ))}
        </div>
      </section>
    </div>
  );
}

/** Attestation-lag widget: how much of Sepolia is already "proven" for CC3. */
function AttestationWidget({ data, online }: { data: AttestationDto | null; online: boolean }) {
  return (
    <div className="neo-card pipe-attest-card">
      <div className="stat-title">Attestation Sepolia → CC3 (Attestcoin)</div>
      {data ? (
        <>
          <div className="attest-gap num">
            <span className="attest-gap-num">{data.gapBlocks.toLocaleString('en-US')}</span> blocks behind head
            <span className="dim"> (~{Math.round((data.gapBlocks * SEPOLIA_BLOCK_TIME_S) / 60)} min — reorg protection)</span>
          </div>
          <div className="attest-heights num">
            <span title="Latest Sepolia block attested on-chain on CC3">
              attested <b className="proven-text">{data.latestAttestedHeight.toLocaleString('en-US')}</b>
            </span>
            <span className="dim">/</span>
            <span title="Sepolia head">
              head <b>{data.sepoliaHead.toLocaleString('en-US')}</b>
            </span>
          </div>
        </>
      ) : (
        <div className="dim">{online ? 'loading…' : 'no data — worker offline'}</div>
      )}
    </div>
  );
}

const PHASES: { id: string; label: string }[] = [
  { id: 'queued', label: 'detected' },
  { id: 'attestation', label: 'attestation' },
  { id: 'proof', label: 'proof' },
  { id: 'execute', label: 'delivery' },
  { id: 'done', label: 'final' },
];

function phaseIndex(status: CardStatus): number {
  switch (status) {
    case 'queued': return 0;
    case 'retry': return 1; // a retry almost always means waiting for attestation
    case 'attestation': return 1;
    case 'proof': return 2;
    case 'execute': return 3;
    case 'done': return 4;
    case 'failed': return 3; // failed at delivery/validation
  }
}

function EventCard({ card, attestation }: { card: PipelineCard; attestation: AttestationDto | null }) {
  const badge = STATUS_BADGE[card.status];
  const active = phaseIndex(card.status);

  return (
    <article className={`pipe-card ${card.status}`}>
      <header className="pipe-card-head">
        <div className="pipe-card-title">
          <span className="pipe-event-name">{card.eventName ?? '…'}</span>
          <span className="dim num">{describeArgs(card)}</span>
        </div>
        <div className="pipe-card-links num">
          <a href={`${SEPOLIA_EXPLORER}/tx/${card.txHash}`} target="_blank" rel="noreferrer" title="Source Sepolia transaction">
            Sepolia {shortHash(card.txHash)}
          </a>
          {card.cc3TxHash && (
            <a href={`${CC3_EXPLORER}/tx/${card.cc3TxHash}`} target="_blank" rel="noreferrer" title="Proof delivery on CC3">
              CC3 {shortHash(card.cc3TxHash)}
            </a>
          )}
          <span className={`badge ${badge.cls}`}>{badge.label}</span>
        </div>
      </header>

      <div className="pipe-steps">
        {PHASES.map((p, i) => {
          const state =
            card.status === 'failed' && i === active ? 'failed'
            : i < active ? 'done'
            : i === active && card.status !== 'done' ? 'active'
            : i === active ? 'done'
            : 'pending';
          return (
            <div key={p.id} className={`pipe-step ${state}`}>
              <i className="pipe-dot" />
              <span className="pipe-step-label">
                {p.label}
                {p.id === 'attestation' && card.durations.attestation !== undefined && (
                  <span className="dim num"> {fmtDur(card.durations.attestation)}</span>
                )}
                {p.id === 'proof' && card.durations.proof !== undefined && (
                  <span className="dim num"> {fmtDur(card.durations.proof)}{card.proofCached ? ' (cached)' : ''}</span>
                )}
                {p.id === 'execute' && card.durations.execute !== undefined && (
                  <span className="dim num"> {fmtDur(card.durations.execute)}</span>
                )}
              </span>
              {i < PHASES.length - 1 && <i className="pipe-link" />}
            </div>
          );
        })}
      </div>

      {card.status === 'attestation' && <AttestationProgress card={card} attestation={attestation} />}

      {(card.status === 'retry' || card.status === 'failed') && (
        <div className={`pipe-note ${card.status === 'failed' ? 'failed' : ''}`}>
          {card.status === 'failed' ? 'Rejected: ' : ''}
          {shortReason(card.error)}
          {card.attempts ? ` · attempt ${card.attempts}` : ''}
        </div>
      )}

      {card.status === 'done' && card.cc3Event && (
        <div className="pipe-note done num">
          {card.cc3Event} · gas {Number(card.gasUsed ?? 0).toLocaleString('en-US')}
          {card.durations.total !== undefined ? ` · end-to-end ${fmtDur(card.durations.total)}` : ''}
        </div>
      )}
    </article>
  );
}

/**
 * The demo's main scene: proof accumulation.
 * Progress = (attested − baseline) / (eventBlock − baseline); baseline is
 * the attested height when observation started, so the bar moves for the whole ~8 minutes.
 */
function AttestationProgress({ card, attestation }: { card: PipelineCard; attestation: AttestationDto | null }) {
  const eventBlock = card.blockNumber;
  const latest = Math.max(card.attestLatest ?? 0, attestation?.latestAttestedHeight ?? 0);
  if (!eventBlock || !latest) return null;

  const baseline = Math.min(card.attestBaseline ?? latest, eventBlock);
  const span = eventBlock - baseline;
  const gap = Math.max(eventBlock - latest, 0);
  const progress = span > 0 ? Math.min(Math.max((latest - baseline) / span, 0), 1) : 1;
  const etaMin = Math.max(Math.round((gap * SEPOLIA_BLOCK_TIME_S) / 60), 1);

  return (
    <div className="attest-progress">
      <div className="attest-progress-bar">
        <i style={{ width: `${(progress * 100).toFixed(2)}%` }} />
      </div>
      <div className="attest-progress-meta num">
        <span>
          attested <b>{latest.toLocaleString('en-US')}</b> → target{' '}
          <b>{eventBlock.toLocaleString('en-US')}</b>
        </span>
        <span className="amber-text">
          {gap.toLocaleString('en-US')} blocks left · ETA ~{etaMin} min
        </span>
      </div>
    </div>
  );
}

function describeArgs(card: PipelineCard): string {
  const a = card.args;
  if (!a) return '';
  try {
    switch (card.eventName) {
      case 'FundsDeposited':
        return `${short(a.depositor)} · ${formatEther(a.amount)} ETH`;
      case 'UsdcLockedForRepayment':
        return `${short(a.borrower)} · loan #${a.ccLoanId} · ${(Number(a.amount) / 1e6).toLocaleString('en-US')} USDC`;
      case 'LoanRepaidOnEth':
        return `${short(a.borrower)} · loan #${a.loanId} · ${formatEther(a.amount)} ETH`;
      default:
        return Object.values(a).map(short).join(' · ');
    }
  } catch {
    return '';
  }
}

function short(v: string | undefined): string {
  if (!v) return '';
  return v.startsWith('0x') && v.length === 42 ? `${v.slice(0, 6)}…${v.slice(-4)}` : v;
}

function fmtDur(ms: number): string {
  if (ms < 1_000) return `${ms} ms`;
  if (ms < 120_000) return `${(ms / 1000).toFixed(1)} s`;
  return `${Math.round(ms / 60_000)} min`;
}
