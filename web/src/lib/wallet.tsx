import { createContext, useCallback, useContext, useState, type ReactNode } from 'react';
import type { JsonRpcSigner } from 'ethers';
import { connectWallet, friendlyWalletError, injectedWallet, isUserRejection } from './providers';

interface WalletCtx {
  address: string | null;
  signer: JsonRpcSigner | null;
  hasWallet: boolean;
  connecting: boolean;
  error: string | null;
  /** 'cancelled' — пользователь сам отказал в кошельке (не ошибка) */
  errorKind: 'cancelled' | 'error' | null;
  connect: () => Promise<void>;
}

const Ctx = createContext<WalletCtx | null>(null);

export function WalletProvider({ children }: { children: ReactNode }) {
  const [address, setAddress] = useState<string | null>(null);
  const [signer, setSigner] = useState<JsonRpcSigner | null>(null);
  const [connecting, setConnecting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [errorKind, setErrorKind] = useState<'cancelled' | 'error' | null>(null);

  const connect = useCallback(async () => {
    setConnecting(true);
    setError(null);
    setErrorKind(null);
    try {
      const { signer: s, address: a } = await connectWallet();
      setSigner(s);
      setAddress(a);
    } catch (err) {
      setError(friendlyWalletError(err));
      setErrorKind(isUserRejection(err) ? 'cancelled' : 'error');
    } finally {
      setConnecting(false);
    }
  }, []);

  return (
    <Ctx.Provider
      value={{ address, signer, hasWallet: injectedWallet() !== null, connecting, error, errorKind, connect }}
    >
      {children}
    </Ctx.Provider>
  );
}

export function useWallet(): WalletCtx {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error('useWallet outside WalletProvider');
  return ctx;
}
