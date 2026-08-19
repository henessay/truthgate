import { useState } from 'react';
import { DEMO_BORROWER, type LoanView, type LoanStatusName } from '../../lib/contracts';
import { fmtCtc, fmtDeadline, shortAddr } from '../../lib/format';
import { useWallet } from '../../lib/wallet';
import { useBorrow, useBorrowerOverview, useCc3Head, useLoans, useRepay } from './hooks';
import './borrower.css';

const STATUS_BADGE: Record<LoanStatusName, { cls: string; label: string }> = {
  None: { cls: 'idle', label: '—' },
  Created: { cls: 'idle', label: 'создан' },
  Funded: { cls: 'action', label: 'активен' },
  PartlyRepaid: { cls: 'pending', label: 'частично погашен' },
  Repaid: { cls: 'proven', label: 'погашен' },
  Expired: { cls: 'rejected', label: 'просрочен' },
};

export function BorrowerScreen() {
  const { address } = useWallet();
  const viewAddress = address ?? DEMO_BORROWER;

  const overview = useBorrowerOverview(viewAddress);
  const loans = useLoans(viewAddress);
  const head = useCc3Head();

  return (
    <div className="borrower">
      {!address && (
        <p className="demo-note">
          Режим чтения: показан демо-заёмщик <span className="mono">{shortAddr(DEMO_BORROWER)}</span>. Подключите
          кошелёк, чтобы действовать от своего адреса.
        </p>
      )}

      <div className="stat-row">
        <StatCard
          title="Кредитный лимит"
          value={overview.data ? `${fmtCtc(overview.data.creditLimit)} CTC` : '…'}
          accent="var(--accent)"
        >
          {overview.data && overview.data.creditLimit > 0n && (
            <div className="limit-breakdown num">
              <span>база {fmtCtc(overview.data.baseLimit)}</span>
              <span className="sep">+</span>
              <span title="ethScore из доказанных Sepolia-событий">
                ETH-скор {fmtCtc(overview.data.fromEthScore)}
              </span>
              <span className="sep">+</span>
              <span title="localScore за погашенные займы на CC3">
                локальный {fmtCtc(overview.data.fromLocalScore)}
              </span>
            </div>
          )}
          {overview.data?.creditLimit === 0n && (
            <div className="limit-breakdown">ethScore ниже минимума — докажите депозит на Sepolia</div>
          )}
        </StatCard>

        <StatCard
          title="Доступно к займу"
          value={overview.data ? `${fmtCtc(overview.data.available)} CTC` : '…'}
          accent="var(--green)"
        >
          {overview.data && (
            <div className="limit-breakdown num">
              ethScore {fmtCtc(overview.data.ethScore)} · localScore {overview.data.localScore.toString()} · погашено
              займов {overview.data.loansCompleted.toString()}
            </div>
          )}
        </StatCard>

        <StatCard
          title="Текущий долг"
          value={overview.data ? `${fmtCtc(overview.data.openDebt)} CTC` : '…'}
          accent={overview.data && overview.data.openDebt > 0n ? 'var(--amber)' : 'var(--text-dim)'}
        >
          <div className="limit-breakdown">тело + процент по всем открытым займам</div>
        </StatCard>
      </div>

      <BorrowCard maxAmount={overview.data?.available ?? 0n} />

      <section className="loans-section">
        <h2>Займы</h2>
        {loans.isLoading && <p className="dim">Загрузка займов с CC3…</p>}
        {loans.data && loans.data.length === 0 && <p className="dim">У адреса ещё нет займов.</p>}
        {loans.data && loans.data.length > 0 && (
          <LoanTable loans={loans.data} headBlock={head.data ?? 0n} />
        )}
      </section>
    </div>
  );
}

function StatCard({
  title,
  value,
  accent,
  children,
}: {
  title: string;
  value: string;
  accent: string;
  children?: React.ReactNode;
}) {
  return (
    <div className="neo-card stat-card">
      <div className="stat-title">{title}</div>
      <div className="stat-value num" style={{ color: accent }}>
        {value}
      </div>
      {children}
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
      ? 'Подключите кошелёк, чтобы взять заём'
      : 'Установите MetaMask, чтобы действовать'
    : !parsedOk
      ? 'Введите сумму в CTC'
      : null;

  return (
    <div className="neo-card borrow-card">
      <div className="borrow-head">
        <h2>Взять заём</h2>
        <span className="dim num">доступно {fmtCtc(maxAmount)} CTC</span>
      </div>
      <div className="borrow-controls">
        <input
          className="neo-input num"
          placeholder="Сумма, CTC"
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
            {borrow.isPending ? 'Транзакция…' : 'Занять'}
          </button>
        ) : (
          <button className="neo-btn" disabled={!hasWallet || connecting} title={disabledReason ?? undefined} onClick={() => void connect()}>
            {connecting ? 'Подключение…' : 'Подключить кошелёк'}
          </button>
        )}
      </div>
      {borrow.error && <p className="tx-error">{(borrow.error as Error).message}</p>}
      {borrow.data && (
        <p className="tx-ok num">
          Заём выдан:{' '}
          <a href={`https://creditcoin-testnet.blockscout.com/tx/${borrow.data}`} target="_blank" rel="noreferrer">
            {borrow.data.slice(0, 14)}…
          </a>
        </p>
      )}
    </div>
  );
}

function LoanTable({ loans, headBlock }: { loans: LoanView[]; headBlock: bigint }) {
  const { address } = useWallet();
  const repay = useRepay();

  return (
    <table className="data-table">
      <thead>
        <tr>
          <th>ID</th>
          <th>Статус</th>
          <th>Тело</th>
          <th>Остаток</th>
          <th>Дедлайн (CC3-блоки)</th>
          <th>Путь Б / кап 30%</th>
          <th></th>
        </tr>
      </thead>
      <tbody>
        {loans.map((l) => {
          const badge = STATUS_BADGE[l.status];
          const open = l.status === 'Funded' || l.status === 'PartlyRepaid';
          const deadline = fmtDeadline(l.deadlineBlock, headBlock);
          const capPct = l.usdcCap > 0n ? Number((l.usdcRepaidShare * 100n) / l.usdcCap) : 0;
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
                    <span className="dim">{l.deadlineBlock.toLocaleString('ru-RU')}</span> · {deadline.text}
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
                </div>
              </td>
              <td>
                {open && (
                  <button
                    className="flat-btn"
                    disabled={!address || repay.isPending}
                    title={address ? `Погасить остаток ${fmtCtc(l.outstanding)} CTC` : 'Подключите кошелёк'}
                    onClick={() => repay.mutate({ loanId: l.id, outstanding: l.outstanding })}
                  >
                    {repayingThis ? 'Транзакция…' : 'Погасить'}
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
