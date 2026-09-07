import { useEffect, useRef, useState } from 'react';
import { BorrowerScreen } from './features/borrower/BorrowerScreen';
import { OverviewScreen } from './features/overview/OverviewScreen';
import { PipelineScreen } from './features/pipeline/PipelineScreen';
import { SwapScreen } from './features/swap/SwapScreen';
import { shortAddr } from './lib/format';
import { useWallet } from './lib/wallet';
import './app.css';

const TABS = [
  { id: 'overview', label: 'Overview' },
  { id: 'borrower', label: 'Borrower' },
  { id: 'pipeline', label: 'Proof Pipeline' },
  { id: 'swap', label: 'SwapDesk' },
] as const;

type TabId = (typeof TABS)[number]['id'];

function WalletBadge({ address }: { address: string }) {
  const { disconnect } = useWallet();
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const onPointerDown = (e: PointerEvent) => {
      if (!rootRef.current?.contains(e.target as Node)) setOpen(false);
    };
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setOpen(false);
    };
    document.addEventListener('pointerdown', onPointerDown);
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('pointerdown', onPointerDown);
      document.removeEventListener('keydown', onKeyDown);
    };
  }, [open]);

  return (
    <div className="wallet-badge" ref={rootRef}>
      <button
        className="wallet-addr num badge proven"
        aria-haspopup="menu"
        aria-expanded={open}
        title="Wallet menu"
        onClick={() => setOpen((v) => !v)}
      >
        {shortAddr(address)} <span className="wallet-caret">▾</span>
      </button>
      {open && (
        <div className="wallet-menu" role="menu">
          <button
            className="wallet-menu-item"
            role="menuitem"
            onClick={() => {
              setOpen(false);
              disconnect();
            }}
          >
            Disconnect
          </button>
        </div>
      )}
    </div>
  );
}

export function App() {
  const [tab, setTab] = useState<TabId>('overview');
  const { address, hasWallet, connecting, connect, wrongChain, error, errorKind } = useWallet();

  return (
    <div className="shell">
      <header className="topbar">
        <div className="brand">
          Truth<span>Gate</span>
          <span className="brand-sub">Creditcoin CC3 × Sepolia · USC</span>
        </div>
        <nav className="tabs">
          {TABS.map((t) => (
            <button key={t.id} className={`tab ${tab === t.id ? 'active' : ''}`} onClick={() => setTab(t.id)}>
              {t.label}
            </button>
          ))}
        </nav>
        <div className="wallet-slot">
          {address ? (
            <WalletBadge address={address} />
          ) : (
            <button
              className="neo-btn wallet-btn"
              disabled={!hasWallet || connecting}
              title={hasWallet ? undefined : 'MetaMask not found'}
              onClick={() => void connect()}
            >
              {connecting ? 'Connecting…' : hasWallet ? 'Connect' : 'No wallet'}
            </button>
          )}
        </div>
      </header>

      {error && <p className={errorKind === 'cancelled' ? 'wallet-note' : 'wallet-error'}>{error}</p>}
      {wrongChain && (
        <p className="wallet-note">
          Wallet is on a different network — switch back to Creditcoin CC3 Testnet to send transactions.
        </p>
      )}

      <main className="content">
        {tab === 'overview' && <OverviewScreen />}
        {tab === 'borrower' && <BorrowerScreen />}
        {tab === 'pipeline' && <PipelineScreen />}
        {tab === 'swap' && <SwapScreen />}
      </main>
    </div>
  );
}
