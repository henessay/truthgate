import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from 'react';
import type { JsonRpcSigner } from 'ethers';
import {
  CC3_CHAIN_ID,
  connectWallet,
  friendlyWalletError,
  injectedWallet,
  isUserRejection,
  signerFromInjected,
} from './providers';

interface WalletCtx {
  address: string | null;
  signer: JsonRpcSigner | null;
  hasWallet: boolean;
  connecting: boolean;
  /** Connected, but the wallet left CC3: address is shown, signer is withheld. */
  wrongChain: boolean;
  error: string | null;
  /** 'cancelled' — the user declined in the wallet themselves (not an error) */
  errorKind: 'cancelled' | 'error' | null;
  connect: () => Promise<void>;
  disconnect: () => void;
}

const Ctx = createContext<WalletCtx | null>(null);

export function WalletProvider({ children }: { children: ReactNode }) {
  const [address, setAddress] = useState<string | null>(null);
  const [signer, setSigner] = useState<JsonRpcSigner | null>(null);
  const [connecting, setConnecting] = useState(false);
  const [wrongChain, setWrongChain] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [errorKind, setErrorKind] = useState<'cancelled' | 'error' | null>(null);

  // Event handlers must ignore wallet events for sites the user authorized but
  // hasn't connected in this app session (MetaMask fires accountsChanged for those too).
  const connectedRef = useRef(false);

  const reset = useCallback(() => {
    connectedRef.current = false;
    setAddress(null);
    setSigner(null);
    setWrongChain(false);
    setError(null);
    setErrorKind(null);
  }, []);

  const connect = useCallback(async () => {
    setConnecting(true);
    setError(null);
    setErrorKind(null);
    try {
      const { signer: s, address: a } = await connectWallet();
      connectedRef.current = true;
      setSigner(s);
      setAddress(a);
      setWrongChain(false);
    } catch (err) {
      setError(friendlyWalletError(err));
      setErrorKind(isUserRejection(err) ? 'cancelled' : 'error');
    } finally {
      setConnecting(false);
    }
  }, []);

  useEffect(() => {
    const eth = injectedWallet();
    if (!eth?.on) return;

    // Rebuild the signer from the wallet's current account; stale async results
    // (the user disconnected while we awaited) are dropped via connectedRef.
    const refreshSigner = async () => {
      try {
        const { signer: s, address: a } = await signerFromInjected(eth);
        if (!connectedRef.current) return;
        setSigner(s);
        setAddress(a);
      } catch {
        if (connectedRef.current) reset();
      }
    };

    const onAccountsChanged = (...args: unknown[]) => {
      if (!connectedRef.current) return;
      const accounts = (args[0] ?? []) as string[];
      if (accounts.length === 0) {
        reset(); // disconnected from the wallet side (MetaMask and Rabby both signal this way)
      } else {
        void refreshSigner();
      }
    };

    const onChainChanged = (...args: unknown[]) => {
      if (!connectedRef.current) return;
      const chainIdHex = String(args[0] ?? '');
      if (Number.parseInt(chainIdHex, 16) === CC3_CHAIN_ID) {
        setWrongChain(false);
        void refreshSigner();
      } else {
        // Keep the address visible, withhold the signer: a signer pinned to CC3
        // would sign on whatever chain the wallet is actually on.
        setWrongChain(true);
        setSigner(null);
      }
    };

    const onDisconnect = (...args: unknown[]) => {
      // 4901 = disconnected from this chain only (EIP-1193), 1013 = MetaMask's
      // transient "try again" it emits during network switches — both recoverable.
      const code = (args[0] as { code?: number } | undefined)?.code;
      if (code === 4901 || code === 1013) return;
      if (connectedRef.current) reset();
    };

    eth.on('accountsChanged', onAccountsChanged);
    eth.on('chainChanged', onChainChanged);
    eth.on('disconnect', onDisconnect);
    return () => {
      eth.removeListener?.('accountsChanged', onAccountsChanged);
      eth.removeListener?.('chainChanged', onChainChanged);
      eth.removeListener?.('disconnect', onDisconnect);
    };
  }, [reset]);

  return (
    <Ctx.Provider
      value={{
        address,
        signer,
        hasWallet: injectedWallet() !== null,
        connecting,
        wrongChain,
        error,
        errorKind,
        connect,
        disconnect: reset,
      }}
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
