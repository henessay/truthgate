import { useState } from 'react';
import { BorrowerScreen } from './features/borrower/BorrowerScreen';
import { PipelineScreen } from './features/pipeline/PipelineScreen';
import { shortAddr } from './lib/format';
import { useWallet } from './lib/wallet';
import './app.css';

const TABS = [
  { id: 'borrower', label: 'Заёмщик', ready: true },
  { id: 'pipeline', label: 'Пайплайн proof’ов', ready: true },
  { id: 'overview', label: 'Обзор', ready: false },
  { id: 'swap', label: 'SwapDesk', ready: false },
] as const;

type TabId = (typeof TABS)[number]['id'];

export function App() {
  const [tab, setTab] = useState<TabId>('borrower');
  const { address, hasWallet, connecting, connect, error } = useWallet();

  return (
    <div className="shell">
      <header className="topbar">
        <div className="brand">
          Truth<span>Gate</span>
          <span className="brand-sub">Creditcoin CC3 × Sepolia · USC</span>
        </div>
        <nav className="tabs">
          {TABS.map((t) => (
            <button
              key={t.id}
              className={`tab ${tab === t.id ? 'active' : ''}`}
              disabled={!t.ready}
              title={t.ready ? undefined : 'скоро'}
              onClick={() => setTab(t.id)}
            >
              {t.label}
            </button>
          ))}
        </nav>
        <div className="wallet-slot">
          {address ? (
            <span className="wallet-addr num badge proven">{shortAddr(address)}</span>
          ) : (
            <button
              className="neo-btn wallet-btn"
              disabled={!hasWallet || connecting}
              title={hasWallet ? undefined : 'MetaMask не найден'}
              onClick={() => void connect()}
            >
              {connecting ? 'Подключение…' : hasWallet ? 'Подключить' : 'Нет кошелька'}
            </button>
          )}
        </div>
      </header>

      {error && <p className="wallet-error">{error}</p>}

      <main className="content">
        {tab === 'borrower' && <BorrowerScreen />}
        {tab === 'pipeline' && <PipelineScreen />}
      </main>
    </div>
  );
}
