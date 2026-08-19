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
  queued: { cls: 'idle', label: 'в очереди' },
  attestation: { cls: 'pending', label: 'аттестация' },
  proof: { cls: 'action', label: 'генерация proof’а' },
  execute: { cls: 'action', label: 'доставка на CC3' },
  done: { cls: 'proven', label: 'доказано' },
  retry: { cls: 'pending', label: 'повтор' },
  failed: { cls: 'rejected', label: 'отклонено' },
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
            <div className="dim">подключение…</div>
          ) : live.online ? (
            <>
              <span className="badge proven">online</span>
              <div className="pipe-worker-meta num">
                курсор Sepolia {live.cursor?.toLocaleString('ru-RU') ?? '—'} · в очереди {live.queueLength}
              </div>
            </>
          ) : (
            <>
              <span className="badge rejected">offline</span>
              <div className="pipe-worker-meta">
                запустите <span className="mono">pnpm worker run --serve</span> — экран оживёт сам
              </div>
            </>
          )}
        </div>

        <AttestationWidget data={attestation.data ?? null} online={live.online === true} />
      </div>

      <section>
        <h2 className="pipe-h2">События</h2>
        {cards.length === 0 && (
          <p className="dim">
            Пока пусто. Отправьте депозит или лок USDC на Sepolia — событие появится здесь и пройдёт путь
            аттестация → proof → доставка на CC3.
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

/** Виджет лага аттестации: сколько Sepolia уже «доказано» для CC3. */
function AttestationWidget({ data, online }: { data: AttestationDto | null; online: boolean }) {
  return (
    <div className="neo-card pipe-attest-card">
      <div className="stat-title">Аттестация Sepolia → CC3 (Attestcoin)</div>
      {data ? (
        <>
          <div className="attest-gap num">
            <span className="attest-gap-num">{data.gapBlocks.toLocaleString('ru-RU')}</span> блоков позади головы
            <span className="dim"> (~{Math.round((data.gapBlocks * SEPOLIA_BLOCK_TIME_S) / 60)} мин — защита от реоргов)</span>
          </div>
          <div className="attest-heights num">
            <span title="Последний аттестованный Sepolia-блок on-chain на CC3">
              аттестовано <b className="proven-text">{data.latestAttestedHeight.toLocaleString('ru-RU')}</b>
            </span>
            <span className="dim">/</span>
            <span title="Голова Sepolia">
              голова <b>{data.sepoliaHead.toLocaleString('ru-RU')}</b>
            </span>
          </div>
        </>
      ) : (
        <div className="dim">{online ? 'загрузка…' : 'нет данных — worker offline'}</div>
      )}
    </div>
  );
}

const PHASES: { id: string; label: string }[] = [
  { id: 'queued', label: 'обнаружено' },
  { id: 'attestation', label: 'аттестация' },
  { id: 'proof', label: 'proof' },
  { id: 'execute', label: 'доставка' },
  { id: 'done', label: 'финал' },
];

function phaseIndex(status: CardStatus): number {
  switch (status) {
    case 'queued': return 0;
    case 'retry': return 1; // повтор почти всегда — ожидание аттестации
    case 'attestation': return 1;
    case 'proof': return 2;
    case 'execute': return 3;
    case 'done': return 4;
    case 'failed': return 3; // упало на доставке/валидации
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
          <a href={`${SEPOLIA_EXPLORER}/tx/${card.txHash}`} target="_blank" rel="noreferrer" title="Исходная Sepolia-транзакция">
            Sepolia {shortHash(card.txHash)}
          </a>
          {card.cc3TxHash && (
            <a href={`${CC3_EXPLORER}/tx/${card.cc3TxHash}`} target="_blank" rel="noreferrer" title="Доставка proof'а на CC3">
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
                  <span className="dim num"> {fmtDur(card.durations.proof)}{card.proofCached ? ' (кэш)' : ''}</span>
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
          {card.status === 'failed' ? 'Отклонено: ' : ''}
          {shortReason(card.error)}
          {card.attempts ? ` · попытка ${card.attempts}` : ''}
        </div>
      )}

      {card.status === 'done' && card.cc3Event && (
        <div className="pipe-note done num">
          {card.cc3Event} · газ {Number(card.gasUsed ?? 0).toLocaleString('ru-RU')}
          {card.durations.total !== undefined ? ` · конец-в-конец ${fmtDur(card.durations.total)}` : ''}
        </div>
      )}
    </article>
  );
}

/**
 * Главная сцена демо: накопление доказательства.
 * Прогресс = (attested − baseline) / (eventBlock − baseline); baseline —
 * attested-высота в момент начала наблюдения, поэтому бар двигается все ~8 минут.
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
          аттестовано <b>{latest.toLocaleString('ru-RU')}</b> → цель{' '}
          <b>{eventBlock.toLocaleString('ru-RU')}</b>
        </span>
        <span className="amber-text">
          осталось {gap.toLocaleString('ru-RU')} блоков · ETA ~{etaMin} мин
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
        return `${short(a.borrower)} · заём #${a.ccLoanId} · ${(Number(a.amount) / 1e6).toLocaleString('ru-RU')} USDC`;
      case 'LoanRepaidOnEth':
        return `${short(a.borrower)} · заём #${a.loanId} · ${formatEther(a.amount)} ETH`;
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
  if (ms < 1_000) return `${ms} мс`;
  if (ms < 120_000) return `${(ms / 1000).toFixed(1)} с`;
  return `${Math.round(ms / 60_000)} мин`;
}
