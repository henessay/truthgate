import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Wallet } from 'ethers';
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
  // Networks (CLAUDE.md): CC3 chainId 102031, Sepolia 11155111, chainKey Sepolia = 1
  chainKey: 1,
  // SEPOLIA_RPC — a single URL or a comma-separated list (first is the primary,
  // the rest are fallbacks on provider errors)
  sepoliaRpcs: requireEnv('SEPOLIA_RPC')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean),
  cc3Rpc: process.env.CC3_RPC ?? 'https://rpc.cc3-testnet.creditcoin.network',
  proverApiUrl: process.env.PROVER_API_URL ?? 'https://prover.cc3-testnet.creditcoin.network',
  privateKey: requireEnv('DEPLOYER_PRIVATE_KEY'),

  // Intervals and limits
  pollIntervalMs: Number(process.env.WORKER_POLL_INTERVAL_MS ?? 15_000),
  attestPollMs: Number(process.env.WORKER_ATTEST_POLL_MS ?? 15_000),
  // Attestation of a Sepolia block on CC3 takes ~8 minutes in practice; timeout is conservative
  attestTimeoutMs: Number(process.env.WORKER_ATTEST_TIMEOUT_MS ?? 1_200_000),
  maxAttempts: 5,
  retryBaseDelayMs: 30_000, // exponential backoff: 30s, 60s, 120s, 240s, 480s
  // Alchemy free tier caps eth_getLogs at 10 blocks; on a range error the
  // watcher additionally shrinks the chunk on its own (adaptive degradation)
  getLogsChunk: Number(process.env.LOGS_CHUNK_SIZE ?? 9),
  // First cursor initialization: head − lookback, so events sent before the
  // worker started are not lost
  startLookbackBlocks: Number(process.env.START_LOOKBACK_BLOCKS ?? 50),
  // Chunks per pollOnce — so a long backfill does not block the queue
  maxChunksPerPoll: 20,

  // WORKER_STATE_FILE — for state-management tests on an isolated file
  stateFile: resolve(WORKER_DIR, process.env.WORKER_STATE_FILE ?? 'state.json'),
  failedFile: resolve(WORKER_DIR, 'failed.json'),
} as const;

/** The worker's own address (identity v1: deployer == borrower == worker).
 * External-protocol watchers filter by it — see watcher.ts subjectArg. */
export const WORKER_ADDRESS = new Wallet(CONFIG.privateKey).address;
