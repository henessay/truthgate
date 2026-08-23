import { useState } from 'react';
import { DEMO_BORROWER, type LoanView, type LoanStatusName, type PathBDelivery } from '../../lib/contracts';
import { fmtCtc, fmtDeadline, shortAddr } from '../../lib/format';
import { useWallet } from '../../lib/wallet';
import {
  useBorrow,
  useBorrowerOverview,
  useCc3Head,
  useLoans,
  usePathBDeliveries,
  usePoolStats,
  useRepay,
  useScoreProofCount,
} from './hooks';
import './borrower.css';

const EXPLORER = 'https://creditcoin-testnet.blockscout.com';

const STATUS_BADGE: Record<LoanStatusName, { cls: string; label: string }> = {
  None: { cls: 'idle', label: '—' },
  Created: { cls: 'idle', label: 'created' },
  Funded: { cls: 'action', label: 'active' },
  PartlyRepaid: { cls: 'pending', label: 'partly repaid' },
  Repaid: { cls: 'proven', label: 'repaid' },
  Expired: { cls: 'rejected', label: 'expired' },
};

export function BorrowerScreen() {
  const { address } = useWallet();
  const viewAddress = address ?? DEMO_BORROWER;

  const overview = useBorrowerOverview(viewAddress);
  const loans = useLoans(viewAddress);
  const head = useCc3Head();
  const pool = usePoolStats();
  const proofCount = useScoreProofCount(viewAddress);
  const deliveries = usePathBDeliveries();

  return (
    <div className="borrower">
      {!address && (
        <p className="demo-note">
          Read-only mode: showing demo borrower <span className="mono">{shortAddr(DEMO_BORROWER)}</span>. Connect a
          wallet to act from your own address.
        </p>
      )}

      <div className="stat-row">
        {/* Dominant credit-limit card */}
        <div className="neo-card stat-card stat-card--hero">
          <div className="stat-title">Credit limit</div>
          <div className="stat-value stat-value--hero num" style={{ color: 'var(--accent)' }}>
            {overview.data ? `${fmtCtc(overview.data.creditLimit)} CTC` : '…'}
          </div>
          {overview.data && (
            <div className="stat-sub num" style={{ color: 'var(--green)' }}>
              available {fmtCtc(overview.data.available)} CTC
            </div>
          )}
          {overview.data && overview.data.creditLimit > 0n && (
            <div className="limit-breakdown num">
              <span>base {fmtCtc(overview.data.baseLimit)}</span>
              <span className="sep">+</span>
              <span>ETH score {fmtCtc(overview.data.fromEthScore)}</span>
              <span className="sep">+</span>
              <span>local {fmtCtc(overview.data.fromLocalScore)}</span>
            </div>
          )}
          {overview.data?.creditLimit === 0n && (
            <div className="limit-breakdown">ethScore below minimum — prove a deposit on Sepolia</div>
          )}
          <div className="attest-line">
            ETH score {overview.data ? fmtCtc(overview.data.ethScore) : '…'} from{' '}
            <b>{proofCount.data ?? '…'} proven Sepolia transactions</b> (USC block proof)
          </div>
        </div>

        <div className="neo-card stat-card">
          <div className="stat-title">Liquidity pool</div>
          <div className="stat-value num" style={{ color: 'var(--accent-cyan)' }}>
            {pool.data ? `${fmtCtc(pool.data.balance)} CTC` : '…'}
          </div>
          {pool.data && (
            <div className="limit-breakdown num">
              <span>LP share {fmtCtc(pool.data.sharePrice, 5)}</span>
              <span className="sep">·</span>
              <span>in loans {fmtCtc(pool.data.outstandingPrincipal)} CTC</span>
            </div>
          )}
        </div>

        <div className="neo-card stat-card">
          <div className="stat-title">Open debt</div>
          <div
            className="stat-value num"
            style={{ color: overview.data && overview.data.openDebt > 0n ? 'var(--amber)' : 'var(--text-dim)' }}
          >
            {overview.data ? `${fmtCtc(overview.data.openDebt)} CTC` : '…'}
          </div>
          {overview.data && (
            <div className="limit-breakdown num">
              localScore {fmtCtc(overview.data.localScore, 2)} · loans repaid{' '}
              {overview.data.loansCompleted.toString()}
            </div>
          )}
        </div>
      </div>

      <div className="bottom-row">
        <BorrowCard maxAmount={overview.data?.available ?? 0n} />
        <section className="loans-section">
          <h2>Loans</h2>
          {loans.isLoading && <p className="dim">Loading loans from CC3…</p>}
          {loans.data && loans.data.length === 0 && <p className="dim">This address has no loans yet.</p>}
          {loans.data && loans.data.length > 0 && (
            <LoanTable loans={loans.data} headBlock={head.data ?? 0n} deliveries={deliveries.data ?? {}} />
          )}
        </section>
      </div>
    </div>
  );
}

function BorrowCard({ maxAmount }: { maxAmount: bigint }) {
  const { address, hasWallet, connecting, connect } = useWallet();
  const borrow = useBorrow();
  const [amount, setAmount] = useState('');

  const parsedOk = /^\d+(\.\d{1,18})?$/.test(amount) && Number(amount) > 0;
  const disabledReason = !address
    ? hasWallet
      ? 'Connect a wallet to borrow'
      : 'Install MetaMask to act'
    : !parsedOk
      ? 'Enter an amount in CTC'
      : null;

  return (
    <div className="neo-card borrow-card">
      <div className="borrow-head">
        <h2>Borrow</h2>
        <span className="dim num">up to {fmtCtc(maxAmount)} CTC</span>
      </div>
      <div className="borrow-controls">
        <input
          className="neo-input num"
          placeholder="Amount, CTC"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          inputMode="decimal"
        />
        {address ? (
          <button
            className="neo-btn"
            disabled={disabledReason !== null || borrow.isPending}
            title={disabledReason ?? undefined}
            onClick={() => borrow.mutate(amount)}
          >
            {borrow.isPending ? 'Transaction…' : 'Borrow'}
          </button>
        ) : (
          <button
            className="neo-btn"
            disabled={!hasWallet || connecting}
            title={disabledReason ?? undefined}
            onClick={() => void connect()}
          >
            {connecting ? 'Connecting…' : 'Connect wallet'}
          </button>
        )}
      </div>
      {borrow.error && <p className="tx-error">{(borrow.error as Error).message}</p>}
      {borrow.data && (
        <p className="tx-ok num">
          Loan issued:{' '}
          <a href={`${EXPLORER}/tx/${borrow.data}`} target="_blank" rel="noreferrer">
            {borrow.data.slice(0, 14)}…
          </a>
        </p>
      )}
    </div>
  );
}

function LoanTable({
  loans,
  headBlock,
  deliveries,
}: {
  loans: LoanView[];
  headBlock: bigint;
  deliveries: Record<string, PathBDelivery>;
}) {
  const { address } = useWallet();
  const repay = useRepay();

  return (
    <table className="data-table">
      <thead>
        <tr>
          <th>ID</th>
          <th>Status</th>
          <th>Principal</th>
          <th>Outstanding</th>
          <th>Deadline (CC3 blocks)</th>
          <th>Path B / 30% cap</th>
          <th></th>
        </tr>
      </thead>
      <tbody>
        {loans.map((l) => {
          const badge = STATUS_BADGE[l.status];
          const open = l.status === 'Funded' || l.status === 'PartlyRepaid';
          const deadline = fmtDeadline(l.deadlineBlock, headBlock);
          const capPct = l.usdcCap > 0n ? Number((l.usdcRepaidShare * 100n) / l.usdcCap) : 0;
          const delivery = deliveries[l.id.toString()];
          const repayingThis = repay.isPending && repay.variables?.loanId === l.id;
          return (
            <tr key={l.id.toString()}>
              <td className="num">#{l.id.toString()}</td>
              <td>
                <span className={`badge ${badge.cls}`}>{badge.label}</span>
              </td>
              <td className="num">{fmtCtc(l.principal)} CTC</td>
              <td className="num">{open ? `${fmtCtc(l.outstanding)} CTC` : '—'}</td>
              <td className="num deadline-cell">
                {open ? (
                  <span style={deadline.overdue ? { color: 'var(--red)' } : undefined}>
                    <span className="dim">{l.deadlineBlock.toLocaleString('en-US')}</span> · {deadline.text}
                  </span>
                ) : (
                  '—'
                )}
              </td>
              <td>
                <div className="cap-cell">
                  <div className="mini-bar">
                    <i
                      style={{
                        width: `${Math.min(capPct, 100)}%`,
                        background: capPct >= 100 ? 'var(--red)' : 'var(--accent-cyan)',
                      }}
                    />
                  </div>
                  <span className="num dim">
                    {fmtCtc(l.usdcRepaidShare)} / {fmtCtc(l.usdcCap)}
                  </span>
                  {delivery && (
                    <a
                      className="proof-link num"
                      href={`${EXPLORER}/tx/${delivery.lastCc3TxHash}`}
                      target="_blank"
                      rel="noreferrer"
                      title={`Proof delivery on CC3: ${delivery.lastCc3TxHash}`}
                    >
                      {delivery.count > 1 ? `${delivery.count} proofs ↗` : 'proof ↗'}
                    </a>
                  )}
                </div>
              </td>
              <td>
                {open && (
                  <button
                    className="flat-btn"
                    disabled={!address || repay.isPending}
                    title={address ? `Repay outstanding ${fmtCtc(l.outstanding)} CTC` : 'Connect a wallet'}
                    onClick={() => repay.mutate({ loanId: l.id, outstanding: l.outstanding })}
                  >
                    {repayingThis ? 'Transaction…' : 'Repay'}
                  </button>
                )}
              </td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}
