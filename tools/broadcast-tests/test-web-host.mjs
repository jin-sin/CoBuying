// Temporary, test-only same-origin host for the Flutter web build and customer gateway.
// Expose its localhost port only through a short-lived HTTPS test tunnel.
import {createReadStream} from 'node:fs';
import {stat} from 'node:fs/promises';
import {createServer, request as httpRequest} from 'node:http';
import {extname, resolve, sep} from 'node:path';
import {randomBytes} from 'node:crypto';
import {createCustomerGateway} from '../../services/broadcast-customer-gateway/server.mjs';

const backendUrl = process.env.BROADCAST_BACKEND_URL;
const serviceKey = process.env.BROADCAST_SERVICE_KEY;
const origin = process.env.BROADCAST_GATEWAY_ORIGIN;
const port = Number(process.env.PORT ?? 8789);
const root = resolve(process.env.BROADCAST_WEB_DIR ?? 'build/web');
if (new URL(backendUrl).hostname !== 'kshysvfxcjtixfveimai.supabase.co') {
  throw new Error('Only the isolated broadcast test project is allowed.');
}
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid port');
if (!serviceKey?.startsWith('sb_secret_') && !serviceKey?.startsWith('eyJ')) {
  throw new Error('A server-only test key is required.');
}
const gateway = createCustomerGateway({
  backendUrl, serviceKey, origin,
  sessionSecret: randomBytes(32).toString('hex'),
});
await new Promise(resolve => gateway.listen(0, '127.0.0.1', resolve));
const gatewayPort = gateway.address().port;

const types = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg', '.webp': 'image/webp', '.wasm': 'application/wasm',
  '.ttf': 'font/ttf', '.otf': 'font/otf', '.woff': 'font/woff',
  '.woff2': 'font/woff2', '.ico': 'image/x-icon',
};
const host = createServer(async (incoming, outgoing) => {
  const path = new URL(incoming.url, origin).pathname;
  if (path === '/__health') {
    outgoing.writeHead(200, {'content-type': 'text/plain', 'cache-control': 'no-store'});
    outgoing.end('broadcast-test-ready');
    return;
  }
  if (path.startsWith('/api/broadcast/v2/')) {
    const upstream = httpRequest({hostname:'127.0.0.1',port:gatewayPort,
      path:incoming.url,method:incoming.method,headers:incoming.headers}, response => {
      outgoing.writeHead(response.statusCode, response.headers);
      response.pipe(outgoing);
    });
    upstream.on('error', () => {
      if (!outgoing.headersSent) outgoing.writeHead(502);
      outgoing.end();
    });
    incoming.pipe(upstream);
    return;
  }
  if (path.startsWith('/api/') || !['GET','HEAD'].includes(incoming.method)) {
    outgoing.writeHead(404); outgoing.end(); return;
  }
  let file;
  try {
    file = resolve(root, `.${decodeURIComponent(path)}`);
  } catch {
    outgoing.writeHead(400); outgoing.end(); return;
  }
  if (file !== root && !file.startsWith(`${root}${sep}`)) {
    outgoing.writeHead(404); outgoing.end(); return;
  }
  let info;
  try { info = await stat(file); } catch { /* Flutter SPA route. */ }
  if (!info?.isFile()) {
    file = resolve(root, 'index.html');
    try { info = await stat(file); } catch { outgoing.writeHead(503); outgoing.end(); return; }
  }
  outgoing.writeHead(200, {
    'content-type': types[extname(file)] ?? 'application/octet-stream',
    'content-length': info.size,
    'cache-control': 'no-store',
    'x-robots-tag': 'noindex, nofollow',
    'x-content-type-options': 'nosniff',
  });
  if (incoming.method === 'HEAD') outgoing.end();
  else createReadStream(file).pipe(outgoing);
});
host.on('error', error => { console.error(error.message); process.exitCode=1; gateway.close(); });
await new Promise(resolve => host.listen(port, '127.0.0.1', resolve));
console.log(`Broadcast test host ready on 127.0.0.1:${port}`);
const shutdown = () => host.close(() => gateway.close());
setTimeout(shutdown, 4 * 60 * 60 * 1000).unref();
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
