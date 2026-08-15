/**
 * Read-only smoke против живых сетей: не требует средств и деплоя.
 *  1. Sepolia RPC: голова чейна.
 *  2. CC3 RPC: precompile ChainInfo → последняя аттестованная высота chainKey=1.
 *  3. Лаг аттестации (Sepolia head − attested) в блоках и минутах (~12 c/блок).
 *  4. Prover API: доступность и готовность кэша по аттестованной высоте.
 * Запуск: pnpm tsx src/smoke.ts
 */
import { JsonRpcProvider } from 'ethers';
import { proofProvider, chainInfo } from '@gluwa/usc-sdk';
import { CONFIG } from './config.js';
import { log, phase } from './logger.js';

async function main(): Promise<void> {
  const sepolia = new JsonRpcProvider(CONFIG.sepoliaRpc);
  const cc3 = new JsonRpcProvider(CONFIG.cc3Rpc);

  const doneSepolia = phase('smoke:sepolia-head');
  const sepoliaHead = await sepolia.getBlockNumber();
  doneSepolia({ sepoliaHead });

  const doneChainInfo = phase('smoke:cc3-attested-height', { chainKey: CONFIG.chainKey });
  const info = new chainInfo.PrecompileChainInfoProvider(cc3 as never);
  const attested = await info.getLatestAttestedHeightAndHash(CONFIG.chainKey);
  const attestedHeight = Number(attested.height);
  doneChainInfo({ attestedHeight, attestedHash: attested.hash });

  const gapBlocks = sepoliaHead - attestedHeight;
  log.info('smoke:attestation-lag', {
    sepoliaHead,
    attestedHeight,
    gapBlocks,
    gapMinutesApprox: Math.round((gapBlocks * 12) / 60),
  });

  const doneProver = phase('smoke:prover-api', { url: CONFIG.proverApiUrl });
  const proofBuilder = new proofProvider.service.ProofBuilder(CONFIG.chainKey, CONFIG.proverApiUrl);
  // Кэш prover'а по уже аттестованной высоте должен отвечать мгновенно
  await proofBuilder.waitUntilHeightAttested(CONFIG.chainKey, attestedHeight, 2_000, 30_000);
  doneProver({ proverCacheReady: true, height: attestedHeight });

  sepolia.destroy();
  cc3.destroy();
  log.info('smoke:done', { verdict: 'read-only checks passed' });
}

main().catch((err) => {
  log.error('smoke:failed', { error: (err as Error).message, stack: (err as Error).stack });
  process.exit(1);
});
