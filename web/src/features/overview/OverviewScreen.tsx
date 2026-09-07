import { DEMO_BORROWER, type BorrowerOverview, type ScoreRecord, type ScoreRecordKind } from '../../lib/contracts';
import { fmtCtc, shortAddr, shortHash } from '../../lib/format';
import { useWallet } from '../../lib/wallet';
import { useBorrowerOverview } from '../borrower/hooks';
import { useScoreRecords } from './hooks';
import './overview.css';

const CC3_EXPLORER = 'https://creditcoin-testnet.blockscout.com';

const KIND_BADGE: Record<ScoreRecordKind, { cls: string; label: string }> = {
  capital: { cls: 'action', label: 'CAPITAL' },
  discipline: { cls: 'proven', label: 'DISCIPLINE' },
  negative: { cls: 'rejected', label: 'NEGATIVE' },
};

/** effectiveScore mapped onto 0–1000 against the on-chain maximum (DEPOSIT + DISCIPLINE caps). */
function gaugeValue(o: BorrowerOverview): number {
  if (o.scoreCapTotal === 0n) return 0;
  return Number((o.effectiveScore * 1000n) / o.scoreCapTotal);
}

function ScoreGauge({ overview }: { overview: BorrowerOverview | undefined }) {
  const value = overview ? gaugeValue(overview) : 0;
  // Semicircle r=80 centered at (100,100): arc length = π·80
  const ARC = Math.PI * 80;
  const filled = (Math.min(value, 1000) / 1000) * ARC;
  return (
    <div className="gauge">
      <svg viewBox="0 0 200 112" className="gauge-svg" role="img" aria-label={`Bureau score ${value} of 1000`}>
        <path d="M 20 100 A 80 80 0 0 1 180 100" fill="none" stroke="var(--line)" strokeWidth="12" strokeLinecap="round" />
        <path
          d="M 20 100 A 80 80 0 0 1 180 100"
          fill="none"
          stroke="var(--accent)"
          strokeWidth="12"
          strokeLinecap="round"
          strokeDasharray={`${filled} ${ARC}`}
          style={{ filter: 'drop-shadow(0 0 6px var(--accent-glow))', transition: 'stroke-dasharray 0.6s ease' }}
        />
        <text x="100" y="88" textAnchor="middle" className="gauge-num">
          {overview ? value : '…'}
        </text>
        <text x="100" y="106" textAnchor="middle" className="gauge-sub">
          / 1000
        </text>
      </svg>
      {overview && (
        <div className="gauge-caption num">
          effective score {fmtCtc(overview.effectiveScore, 3)} of {fmtCtc(overview.scoreCapTotal, 1)} provable max
        </div>
      )}
    </div>
  );
}

function CompositionCard({ overview, recordCount }: { overview: BorrowerOverview | undefined; recordCount: number | undefined }) {
  if (!overview) return <div className="neo-card comp-card dim">Loading score from CC3…</div>;
  return (
    <div className="neo-card comp-card">
      <div className="stat-title">Score composition</div>
      <div className="comp-row">
        <span className="badge action">CAPITAL</span>
        <span className="num">{fmtCtc(overview.ethScore, 3)}</span>
        <span className="dim">proven deposits &amp; staking (amount-weighted, capped)</span>
      </div>
      <div className="comp-row">
        <span className="badge proven">DISCIPLINE</span>
        <span className="num">{fmtCtc(overview.disciplineScore, 3)}</span>
        {overview.capitalGatePassed ? (
          <span className="dim">
            proven repayments · capital gate <b className="gate-ok">passed</b>
          </span>
        ) : (
          <span className="gate-warn">
            gated — prove capital ≥ {fmtCtc(overview.capitalGateThreshold)} ETH to count it
          </span>
        )}
      </div>
      <div className="comp-row">
        <span className="badge idle">LOCAL</span>
        <span className="num">{fmtCtc(overview.localScore, 2)}</span>
        <span className="dim">CC3 repayment history ({overview.loansCompleted.toString()} loans completed)</span>
      </div>
      <div className="comp-row">
        <span className="badge rejected">NEGATIVE</span>
        <span className="num">{overview.liquidationPenalty > 0n ? `−${fmtCtc(overview.liquidationPenalty)}` : '0'}</span>
        <span className="dim">
          {overview.liquidationPenalty > 0n
            ? 'limit reduction from proven liquidations (never eats the base)'
            : 'no negative signals on file'}
        </span>
      </div>
      <div className="attest-line">
        every component sourced from <b>{recordCount ?? '…'} proven Sepolia transactions</b> — USC block proofs, no
        oracle, no indexer
      </div>
    </div>
  );
}

function RecordsTable({ records }: { records: ScoreRecord[] }) {
  return (
    <table className="data-table">
      <thead>
        <tr>
          <th>Category</th>
          <th>Source</th>
          <th>Effect</th>
          <th>CC3 block</th>
          <th>Proof</th>
        </tr>
      </thead>
      <tbody>
        {records.map((r) => {
          const badge = KIND_BADGE[r.kind];
          return (
            <tr key={`${r.cc3TxHash}-${r.queryId}`}>
              <td>
                <span className={`badge ${badge.cls}`}>{badge.label}</span>
              </td>
              <td>{r.source}</td>
              <td className="num">
                {r.kind === 'negative' ? (
                  <span style={{ color: 'var(--red)' }}>−{fmtCtc(r.delta)} limit</span>
                ) : (
                  <span style={{ color: 'var(--green)' }}>+{fmtCtc(r.delta, 3)} score</span>
                )}
              </td>
              <td className="num dim">{r.blockNumber.toLocaleString('en-US')}</td>
              <td>
                <a
                  className="proof-link num"
                  href={`${CC3_EXPLORER}/tx/${r.cc3TxHash}`}
                  target="_blank"
                  rel="noreferrer"
                  title={`Proof delivery on CC3 · queryId ${r.queryId}`}
                >
                  {shortHash(r.cc3TxHash)} ↗
                </a>
              </td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}

export function OverviewScreen() {
  const { address } = useWallet();
  const viewAddress = address ?? DEMO_BORROWER;

  const overview = useBorrowerOverview(viewAddress);
  const records = useScoreRecords(viewAddress);

  const negatives = records.data?.filter((r) => r.kind === 'negative') ?? [];
  const emptyFile = records.data !== undefined && records.data.length === 0;

  return (
    <div className="overview">
      {!address && (
        <p className="demo-note">
          Read-only mode: showing demo borrower <span className="mono">{shortAddr(DEMO_BORROWER)}</span>. Connect a
          wallet to see your own file.
        </p>
      )}

      <div className="overview-top">
        <div className="neo-card gauge-card">
          <div className="stat-title">Bureau score</div>
          <ScoreGauge overview={overview.data} />
        </div>
        <CompositionCard overview={overview.data} recordCount={records.data?.length} />
      </div>

      <div className="neo-card negative-strip">
        <span className="stat-title">Negative signals</span>
        {records.isLoading ? (
          <span className="dim">…</span>
        ) : negatives.length === 0 ? (
          <span className="dim">None on file — no proven liquidations for this address.</span>
        ) : (
          <span style={{ color: 'var(--red)' }} className="num">
            {negatives.length} proven liquidation{negatives.length > 1 ? 's' : ''} · −
            {fmtCtc(negatives.reduce((s, r) => s + r.delta, 0n))} CTC limit
          </span>
        )}
      </div>

      <section className="records-section">
        <h2>Proven records</h2>
        {records.isLoading && <p className="dim">Loading the file from CC3…</p>}
        {emptyFile && (
          <p className="dim">No proven history yet — deposit on Sepolia to start building your file.</p>
        )}
        {records.data && records.data.length > 0 && <RecordsTable records={records.data} />}
      </section>
    </div>
  );
}
