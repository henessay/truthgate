import { BrowserProvider, JsonRpcProvider, type JsonRpcSigner } from 'ethers';

export const CC3_CHAIN_ID = 102031;
export const SEPOLIA_CHAIN_ID = 11155111;

// env via optional chaining: Vite substitutes it at build time; under node
// (integration checks run with tsx) import.meta.env is absent — fall back to defaults
const env = (import.meta as { env?: Record<string, string> }).env;
const CC3_RPC = env?.VITE_CC3_RPC ?? 'https://rpc.cc3-testnet.creditcoin.network';
const SEPOLIA_RPC = env?.VITE_SEPOLIA_RPC ?? 'https://ethereum-sepolia-rpc.publicnode.com';

// staticNetwork is required for CC3: the Substrate-EVM returns block headers
// without prevRandao/mixHash, which breaks network auto-detection / block
// formatting in some providers. We only read eth_call / blockNumber / getLogs —
// with those, ethers works fine against CC3 (verified by the worker).
export const cc3Provider = new JsonRpcProvider(CC3_RPC, CC3_CHAIN_ID, { staticNetwork: true });
export const sepoliaProvider = new JsonRpcProvider(SEPOLIA_RPC, SEPOLIA_CHAIN_ID, { staticNetwork: true });

/** ~15 s/block (measured on the live network: 15060 s / 1000 blocks). Used for countdowns. */
export const CC3_BLOCK_TIME_S = 15;

const CC3_CHAIN_PARAMS = {
  chainId: '0x18e8f', // 102031
  chainName: 'Creditcoin CC3 Testnet',
  nativeCurrency: { name: 'Creditcoin', symbol: 'CTC', decimals: 18 },
  rpcUrls: [CC3_RPC],
  blockExplorerUrls: ['https://creditcoin-testnet.blockscout.com'],
};

export interface Eip1193 {
  request(args: { method: string; params?: unknown[] }): Promise<unknown>;
  on?(event: string, cb: (...args: unknown[]) => void): void;
  removeListener?(event: string, cb: (...args: unknown[]) => void): void;
}

export function injectedWallet(): Eip1193 | null {
  return (window as { ethereum?: Eip1193 }).ethereum ?? null;
}

interface WalletError {
  code?: number;
  message?: string;
  data?: { code?: number; originalError?: { code?: number; message?: string } };
}

/** 4902 "chain not added": MetaMask puts the code either at the top level or inside data. */
function isUnrecognizedChain(err: unknown): boolean {
  const e = err as WalletError;
  if (e?.code === 4902 || e?.data?.code === 4902 || e?.data?.originalError?.code === 4902) return true;
  const msg = `${e?.message ?? ''} ${e?.data?.originalError?.message ?? ''}`;
  return /unrecognized chain|try adding the chain/i.test(msg);
}

/** 4001 — the user rejected the request in the wallet. */
export function isUserRejection(err: unknown): boolean {
  const e = err as WalletError;
  if (e?.code === 4001 || e?.data?.code === 4001 || e?.data?.originalError?.code === 4001) return true;
  return /user rejected|user denied/i.test(e?.message ?? '');
}

async function isOnCc3(eth: Eip1193): Promise<boolean> {
  try {
    const id = (await eth.request({ method: 'eth_chainId' })) as string;
    return id?.toLowerCase() === CC3_CHAIN_PARAMS.chainId;
  } catch {
    return false;
  }
}

/**
 * Ensure the CC3 chain in the wallet:
 * switch → (4902, including when nested in data) → add with full params → switch.
 * Some wallets are already on the added chain after add — a failing second
 * switch doesn't break the flow if the actual chainId is already CC3.
 */
async function ensureCc3Chain(eth: Eip1193): Promise<void> {
  try {
    await eth.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: CC3_CHAIN_PARAMS.chainId }] });
    return;
  } catch (err) {
    if (isUserRejection(err) || !isUnrecognizedChain(err)) throw err;
  }

  await eth.request({ method: 'wallet_addEthereumChain', params: [CC3_CHAIN_PARAMS] });

  if (await isOnCc3(eth)) return;
  try {
    await eth.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: CC3_CHAIN_PARAMS.chainId }] });
  } catch (err) {
    if (!(await isOnCc3(eth))) throw err;
  }
}

/**
 * Connect MetaMask: request an account + switch to (or add) the CC3 chain.
 * Returns a signer bound to CC3.
 */
export async function connectWallet(): Promise<{ signer: JsonRpcSigner; address: string }> {
  const eth = injectedWallet();
  if (!eth) throw new Error('MetaMask not found: install the extension');

  await eth.request({ method: 'eth_requestAccounts' });
  await ensureCc3Chain(eth);

  const browser = new BrowserProvider(eth as never, CC3_CHAIN_ID);
  const signer = await browser.getSigner();
  return { signer, address: await signer.getAddress() };
}

/**
 * Signer for the wallet's currently selected account, without prompting
 * (no eth_requestAccounts / chain switch). Used to follow accountsChanged.
 */
export async function signerFromInjected(eth: Eip1193): Promise<{ signer: JsonRpcSigner; address: string }> {
  const browser = new BrowserProvider(eth as never, CC3_CHAIN_ID);
  const signer = await browser.getSigner();
  return { signer, address: await signer.getAddress() };
}

/** Human-friendly message instead of the wallet's technical error text. */
export function friendlyWalletError(err: unknown): string {
  if (isUserRejection(err)) return 'Connection cancelled in the wallet';
  const msg = (err as Error)?.message ?? String(err);
  if (/MetaMask not found/.test(msg)) return msg;
  return `Failed to connect wallet: ${msg.slice(0, 120)}`;
}
