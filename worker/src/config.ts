import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';

const __dirname = dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = resolve(__dirname, '..', '..');
export const WORKER_DIR = resolve(__dirname, '..');

dotenv.config({ path: resolve(REPO_ROOT, '.env'), override: true });

const DEPLOYMENTS_PATH = resolve(REPO_ROOT, 'docs', 'deployments.json');

export interface Deployments {
  sepolia: {
    TestUSDC: string;
    ScoringVault: string;
    LoanBookSim: string;
    RepaymentVault: string;
  };
  cc3: {
    LPPool: string;
    CreditCore: string;
    RepaymentBridge: string;
    WrappedUSDC: string;
  };
}

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing required env var ${name} (see .env in repo root)`);
  return v;
}

export function loadDeployments(): Deployments {
  if (!existsSync(DEPLOYMENTS_PATH)) {
    throw new Error(
      `docs/deployments.json not found — run the deploy scripts first:\n` +
        `  forge script script/DeploySepolia.s.sol --rpc-url sepolia --broadcast\n` +
        `  forge script script/DeployCC3.s.sol --rpc-url cc3 --broadcast`,
    );
  }
  const d = JSON.parse(readFileSync(DEPLOYMENTS_PATH, 'utf8')) as Deployments;
  if (!d.sepolia?.ScoringVault || !d.cc3?.CreditCore) {
    throw new Error(`docs/deployments.json is incomplete: ${JSON.stringify(d)}`);
  }
  return d;
}

export const CONFIG = {
  // Сети (CLAUDE.md): CC3 chainId 102031, Sepolia 11155111, chainKey Sepolia = 1
  chainKey: 1,
  // SEPOLIA_RPC — один URL или список через запятую (первый — основной,
  // остальные — фолбэк при ошибках провайдера)
  sepoliaRpcs: requireEnv('SEPOLIA_RPC')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean),
  cc3Rpc: process.env.CC3_RPC ?? 'https://rpc.cc3-testnet.creditcoin.network',
  proverApiUrl: process.env.PROVER_API_URL ?? 'https://prover.cc3-testnet.creditcoin.network',
  privateKey: requireEnv('DEPLOYER_PRIVATE_KEY'),

  // Интервалы и лимиты
  pollIntervalMs: Number(process.env.WORKER_POLL_INTERVAL_MS ?? 15_000),
  attestPollMs: Number(process.env.WORKER_ATTEST_POLL_MS ?? 15_000),
  // Аттестация Sepolia-блока на CC3 в практике ~8 минут; таймаут консервативный
  attestTimeoutMs: Number(process.env.WORKER_ATTEST_TIMEOUT_MS ?? 1_200_000),
  maxAttempts: 5,
  retryBaseDelayMs: 30_000, // экспоненциальный backoff: 30s, 60s, 120s, 240s, 480s
  // Alchemy free tier режет eth_getLogs до 10 блоков; при ошибке про диапазон
  // watcher дополнительно ужимает чанк сам (адаптивная деградация)
  getLogsChunk: Number(process.env.LOGS_CHUNK_SIZE ?? 9),
  // Первая инициализация курсора: head − lookback, чтобы не терять события,
  // отправленные до запуска worker'а
  startLookbackBlocks: Number(process.env.START_LOOKBACK_BLOCKS ?? 50),
  // Чанков за один pollOnce — чтобы длинный бэкфилл не блокировал очередь
  maxChunksPerPoll: 20,

  // WORKER_STATE_FILE — для тестов state-менеджмента на изолированном файле
  stateFile: resolve(WORKER_DIR, process.env.WORKER_STATE_FILE ?? 'state.json'),
  failedFile: resolve(WORKER_DIR, 'failed.json'),
} as const;
