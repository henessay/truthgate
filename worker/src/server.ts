import { createServer, type Server, type ServerResponse } from 'node:http';
import { log, getLogEvents } from './logger.js';
import { loadState, loadFailed } from './state.js';

/**
 * HTTP-витрина worker'а для web-фронта (`worker run --serve`).
 * Только чтение: state/failed с диска, события пайплайна из ring-буфера
 * логгера, лаг аттестации. CORS открыт — фронт живёт на другом порту.
 */

export interface AttestationSnapshot {
  chainKey: number;
  sepoliaHead: number;
  latestAttestedHeight: number;
  gapBlocks: number;
  ts: string;
}

function json(res: ServerResponse, body: unknown): void {
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}

export function startServer(port: number, attestation: () => Promise<AttestationSnapshot>): Server {
  // Кэш аттестации: фронт поллит каждые 3 с, реальный запрос — не чаще
  let cached: { at: number; value: AttestationSnapshot } | null = null;
  const ATTESTATION_CACHE_MS = 3_000;

  const srv = createServer((req, res) => {
    res.setHeader('Access-Control-Allow-Origin', '*');
    const url = new URL(req.url ?? '/', 'http://localhost');

    void (async () => {
      try {
        switch (url.pathname) {
          case '/api/state':
            return json(res, loadState());
          case '/api/failed':
            return json(res, loadFailed());
          case '/api/events':
            return json(res, getLogEvents(Number(url.searchParams.get('since') ?? 0)));
          case '/api/attestation': {
            if (!cached || Date.now() - cached.at > ATTESTATION_CACHE_MS) {
              cached = { at: Date.now(), value: await attestation() };
            }
            return json(res, cached.value);
          }
          default:
            res.writeHead(404, { 'Content-Type': 'application/json' });
            return res.end('{"error":"not found"}');
        }
      } catch (err) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: (err as Error).message }));
      }
    })();
  });

  srv.listen(port, () => log.info('serve:started', { port }));
  return srv;
}
