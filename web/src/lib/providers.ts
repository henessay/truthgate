import { BrowserProvider, JsonRpcProvider, type JsonRpcSigner } from 'ethers';

export const CC3_CHAIN_ID = 102031;
export const SEPOLIA_CHAIN_ID = 11155111;

// env через optional chaining: под Vite подставляется на билде, под node
// (интеграционные проверки tsx'ом) import.meta.env отсутствует — берём дефолты
const env = (import.meta as { env?: Record<string, string> }).env;
const CC3_RPC = env?.VITE_CC3_RPC ?? 'https://rpc.cc3-testnet.creditcoin.network';
const SEPOLIA_RPC = env?.VITE_SEPOLIA_RPC ?? 'https://ethereum-sepolia-rpc.publicnode.com';

// staticNetwork обязателен для CC3: Substrate-EVM отдаёт заголовки без
// prevRandao/mixHash, и автодетект сети/форматирование блоков у части
// провайдеров ломается. Мы читаем только eth_call / blockNumber / getLogs —
// с ними ethers против CC3 работает (проверено worker'ом).
export const cc3Provider = new JsonRpcProvider(CC3_RPC, CC3_CHAIN_ID, { staticNetwork: true });
export const sepoliaProvider = new JsonRpcProvider(SEPOLIA_RPC, SEPOLIA_CHAIN_ID, { staticNetwork: true });

/** ~15 с/блок (замер по живой сети: 15060 с / 1000 блоков). Для обратных отсчётов. */
export const CC3_BLOCK_TIME_S = 15;

const CC3_CHAIN_PARAMS = {
  chainId: '0x18e8f', // 102031
  chainName: 'Creditcoin CC3 Testnet',
  nativeCurrency: { name: 'Creditcoin', symbol: 'CTC', decimals: 18 },
  rpcUrls: [CC3_RPC],
  blockExplorerUrls: ['https://creditcoin-testnet.blockscout.com'],
};

interface Eip1193 {
  request(args: { method: string; params?: unknown[] }): Promise<unknown>;
  on?(event: string, cb: (...args: unknown[]) => void): void;
}

export function injectedWallet(): Eip1193 | null {
  return (window as { ethereum?: Eip1193 }).ethereum ?? null;
}

interface WalletError {
  code?: number;
  message?: string;
  data?: { code?: number; originalError?: { code?: number; message?: string } };
}

/** 4902 «сеть не добавлена»: MetaMask кладёт код то на верхний уровень, то в data. */
function isUnrecognizedChain(err: unknown): boolean {
  const e = err as WalletError;
  if (e?.code === 4902 || e?.data?.code === 4902 || e?.data?.originalError?.code === 4902) return true;
  const msg = `${e?.message ?? ''} ${e?.data?.originalError?.message ?? ''}`;
  return /unrecognized chain|try adding the chain/i.test(msg);
}

/** 4001 — пользователь отклонил запрос в кошельке. */
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
 * Гарантировать сеть CC3 в кошельке:
 * switch → (4902, в т.ч. вложенный в data) → add с полными параметрами → switch.
 * Некоторые кошельки после add уже стоят на добавленной сети — ошибка повторного
 * switch не роняет флоу, если фактический chainId уже CC3.
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
 * Подключение MetaMask: запрос аккаунта + переключение (или добавление) сети CC3.
 * Возвращает signer, привязанный к CC3.
 */
export async function connectWallet(): Promise<{ signer: JsonRpcSigner; address: string }> {
  const eth = injectedWallet();
  if (!eth) throw new Error('MetaMask не найден: установите расширение');

  await eth.request({ method: 'eth_requestAccounts' });
  await ensureCc3Chain(eth);

  const browser = new BrowserProvider(eth as never, CC3_CHAIN_ID);
  const signer = await browser.getSigner();
  return { signer, address: await signer.getAddress() };
}

/** Человеческое сообщение вместо технического текста ошибки кошелька. */
export function friendlyWalletError(err: unknown): string {
  if (isUserRejection(err)) return 'Подключение отменено в кошельке';
  const msg = (err as Error)?.message ?? String(err);
  if (/MetaMask не найден/.test(msg)) return msg;
  return `Не удалось подключить кошелёк: ${msg.slice(0, 120)}`;
}
