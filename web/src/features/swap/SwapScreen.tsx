import { useState } from 'react';
import { parseEther } from 'ethers';
import { swapCtcRequired, type SwapDeskState } from '../../lib/contracts';
import { fmtCtc, shortAddr, shortHash } from '../../lib/format';
import { useWallet } from '../../lib/wallet';
import { usePoolStats } from '../borrower/hooks';
import { useSwap, useSwapDesk, useSwapHistory } from './hooks';
import './swap.css';

const CC3_EXPLORER = 'https://creditcoin-testnet.blockscout.com';

function SwapForm({ state }: { state: SwapDeskState }) {
  const { address, hasWallet, connecting, connect, wrongChain } = useWallet();
  const swap = useSwap();
  const [amount, setAmount] = useState('');

  const parsedOk = /^\d+(\.\d{1,18})?$/.test(amount) && Number(amount) > 0;
  const wusdcAmount = parsedOk ? parseEther(amount) : 0n;
  const ctcCost = parsedOk ? swapCtcRequired(wusdcAmount, state) : 0n;

  const disabledReason = !address
    ? hasWallet
      ? 'Connect a wallet to swap'
      : 'Install MetaMask to act'
    : wrongChain
      ? 'Switch the wallet back to CC3'
      : !parsedOk
        ? 'Enter a wUSDC amount'
        : wusdcAmount > state.treasuryWusdc
          ? 'Exceeds the treasury balance'
          : ctcCost === 0n
            ? 'Amount too small'
            : null;

  return (
    <div className="neo-card swap-form">
      <h2>Buy wUSDC at a discount</h2>
      <p className="dim swap-blurb">
        The treasury sells proof-delivered wUSDC {Number(state.discountBps) / 100}% below face value; the CTC you pay
        settles loan principal back into the liquidity pool. The discount is funded from the path-B interest margin,
        not the principal.
      </p>
      <input
        className="neo-input num"
        placeholder="Amount, wUSDC"
        value={amount}
        onChange={(e) => setAmount(e.target.value)}
        inputMode="decimal"
      />
      {parsedOk && disabledReason === null && (
        <p className="swap-quote num">
          you pay <b>{fmtCtc(ctcCost)} CTC</b> for {fmtCtc(wusdcAmount)} wUSDC
          <span className="dim"> (face {fmtCtc((wusdcAmount * state.rate) / 10n ** 18n)} CTC)</span>
        </p>
      )}
      {address ? (
        <button
          className="neo-btn"
          disabled={disabledReason !== null || swap.isPending}
          title={disabledReason ?? undefined}
          onClick={() => swap.mutate({ wusdcAmount, state })}
        >
          {swap.isPending ? 'Transaction…' : 'Swap'}
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
      {swap.error && <p className="tx-error">{(swap.error as Error).message}</p>}
      {swap.data && (
        <p className="tx-ok num">
          Swapped:{' '}
          <a href={`${CC3_EXPLORER}/tx/${swap.data}`} target="_blank" rel="noreferrer">
            {swap.data.slice(0, 14)}…
          </a>
        </p>
      )}
    </div>
  );
}

export function SwapScreen() {
  const desk = useSwapDesk();
  const pool = usePoolStats();
  const history = useSwapHistory();

  return (
    <div className="swap">
      <div className="stat-row">
        <div className="neo-card stat-card">
          <div className="stat-title">Treasury wUSDC</div>
          <div className="stat-value num" style={{ color: 'var(--accent-cyan)' }}>
            {desk.data ? fmtCtc(desk.data.treasuryWusdc) : '…'}
          </div>
          {desk.data && (
            <div className="limit-breakdown num">
              <span>principal face {fmtCtc(desk.data.principalFace)}</span>
              <span className="sep">·</span>
              <span>interest face {fmtCtc(desk.data.interestFace)}</span>
            </div>
          )}
        </div>
        <div className="neo-card stat-card">
          <div className="stat-title">Terms</div>
          <div className="stat-value num" style={{ color: 'var(--accent)' }}>
            {desk.data ? `−${Number(desk.data.discountBps) / 100}%` : '…'}
          </div>
          {desk.data && (
            <div className="limit-breakdown num">
              <span>rate {fmtCtc(desk.data.rate, 2)} CTC / wUSDC</span>
              <span className="sep">·</span>
              <span>discount off face value</span>
            </div>
          )}
        </div>
        <div className="neo-card stat-card">
          <div className="stat-title">Liquidity pool</div>
          <div className="stat-value num" style={{ color: 'var(--green)' }}>
            {pool.data ? `${fmtCtc(pool.data.balance)} CTC` : '…'}
          </div>
          {pool.data && (
            <div className="limit-breakdown num">
              <span>in loans {fmtCtc(pool.data.outstandingPrincipal)} CTC</span>
              <span className="sep">·</span>
              <span>LP share {fmtCtc(pool.data.sharePrice, 5)}</span>
            </div>
          )}
        </div>
      </div>

      <div className="swap-bottom">
        {desk.data &&
          (desk.data.treasuryWusdc > 0n ? (
            <SwapForm state={desk.data} />
          ) : (
            <div className="neo-card swap-form">
              <h2>Buy wUSDC at a discount</h2>
              <p className="dim swap-blurb">
                The treasury is empty — it fills when a borrower repays a loan with USDC locked on Ethereum and the
                proof is delivered to CC3 (path B).
              </p>
            </div>
          ))}

        <section className="swap-history">
          <h2>Swap history</h2>
          {history.isLoading && <p className="dim">Loading swaps from CC3…</p>}
          {history.data && history.data.length === 0 && <p className="dim">No swaps yet.</p>}
          {history.data && history.data.length > 0 && (
            <table className="data-table">
              <thead>
                <tr>
                  <th>Buyer</th>
                  <th>wUSDC</th>
                  <th>CTC paid</th>
                  <th>CC3 block</th>
                  <th>Tx</th>
                </tr>
              </thead>
              <tbody>
                {history.data.map((s) => (
                  <tr key={s.cc3TxHash}>
                    <td className="num">{shortAddr(s.buyer)}</td>
                    <td className="num">{fmtCtc(s.wusdcAmount)}</td>
                    <td className="num">{fmtCtc(s.ctcPaid)}</td>
                    <td className="num dim">{s.blockNumber.toLocaleString('en-US')}</td>
                    <td>
                      <a
                        className="proof-link num"
                        href={`${CC3_EXPLORER}/tx/${s.cc3TxHash}`}
                        target="_blank"
                        rel="noreferrer"
                      >
                        {shortHash(s.cc3TxHash)} ↗
                      </a>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </section>
      </div>
    </div>
  );
}
