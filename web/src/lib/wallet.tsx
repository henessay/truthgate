import { createContext, useCallback, useContext, useState, type ReactNode } from 'react';
import type { JsonRpcSigner } from 'ethers';
import { connectWallet, injectedWallet } from './providers';

interface WalletCtx {
  address: string | null;
  signer: JsonRpcSigner | null;
  hasWallet: boolean;
  connecting: boolean;
  error: string | null;
  connect: () => Promise<void>;
}

const Ctx = createContext<WalletCtx | null>(null);

export function WalletProvider({ children }: { children: ReactNode }) {
  const [address, setAddress] = useState<string | null>(null);
  const [signer, setSigner] = useState<JsonRpcSigner | null>(null);
  const [connecting, setConnecting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const connect = useCallback(async () => {
    setConnecting(true);
    setError(null);
    try {
      const { signer: s, address: a } = await connectWallet();
      setSigner(s);
      setAddress(a);
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setConnecting(false);
    }
  }, []);

  return (
    <Ctx.Provider value={{ address, signer, hasWallet: injectedWallet() !== null, connecting, error, connect }}>
      {children}
    </Ctx.Provider>
  );
}

export function useWallet(): WalletCtx {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error('useWallet outside WalletProvider');
  return ctx;
}
