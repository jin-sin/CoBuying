// Runs the unchanged broadcast migrations through real PostgreSQL + PostgREST.
// POSTGREST_BIN must point to an official PostgREST executable. No service URL
// or production credentials are read; both servers bind only to 127.0.0.1.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac, createHash, randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { createServer as createHttpServer } from 'node:http';
import { existsSync } from 'node:fs';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import EmbeddedPostgres from 'embedded-postgres';

const project = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const postgrestBin = process.env.POSTGREST_BIN;
const migrations = [
  '202609230001_broadcast_capture.sql',
  '202609280001_broadcast_capture_management.sql',
  '202609280002_broadcast_staff_invites.sql',
  '202609280003_broadcast_paging.sql',
  '202609280004_broadcast_customer_access.sql',
  '202609280005_broadcast_customer_requests.sql',
  '202609280006_broadcast_billing.sql',
  '202609280007_broadcast_payments.sql',
  '202609280008_broadcast_procurement.sql',
  '202609280009_broadcast_arrivals.sql',
  '202609280010_broadcast_shipments.sql',
  '202609280011_broadcast_tasks.sql',
  '202609280012_broadcast_purchase_page.sql',
  '202609280013_broadcast_missing_detail.sql',
  '202609280014_broadcast_shipment_ready.sql',
  '202609280015_broadcast_defect_page.sql',
  '202609280016_broadcast_billing_preview.sql',
  '202609290001_broadcast_receipt_supplement.sql',
  '202609290002_broadcast_receivers.sql',
  '202609290003_broadcast_invoice_revision.sql',
  '202609290004_broadcast_invoice_request_revision.sql',
    '202609290005_broadcast_deposit_returns.sql',
    '202609290006_broadcast_manager_address.sql',
    '202609290007_broadcast_shipment_history.sql',
    '202609290008_broadcast_seller_invoice_correction.sql',
    '202609290009_broadcast_purchase_export_status.sql',
    '202609290010_broadcast_receiver_qr.sql',
    '202609290011_broadcast_invoice_country_revision.sql',
    '202609290012_broadcast_invoice_full_exclusion.sql',
];
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const freePort = () => new Promise((resolve, reject) => {
  const server = createServer();
  server.once('error', reject);
  server.listen(0, '127.0.0.1', () => {
    const port = server.address().port;
    server.close(() => resolve(port));
  });
});
const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');

test('JWT → PostgREST → broadcast RPC, 권한·재시도·두 접속 경합', async t => {
  assert.ok(postgrestBin, 'POSTGREST_BIN is required; use npm run test:http');
  assert.ok(existsSync(postgrestBin), `PostgREST executable missing: ${postgrestBin}`);
  const scratch = await mkdtemp(join(tmpdir(), 'orendam-b01-http-'));
  const pgPort = await freePort();
  let apiPort = await freePort();
  while (apiPort === pgPort) apiPort = await freePort();
  const secret = 'orendam-local-http-jwt-secret-at-least-32-chars';
  const pg = new EmbeddedPostgres({
    databaseDir: join(scratch, 'db'), user: 'postgres', password: 'local-only',
    port: pgPort, persistent: false, onLog: () => {}, onError: () => {},
  });
  let admin, api, pgStarted = false;
  let apiLog = '';
  t.after(async () => {
    api?.kill();
    if (api && api.exitCode === null) await new Promise(resolve => api.once('exit', resolve));
    await admin?.end();
    if (pgStarted) await pg.stop();
    await rm(scratch, {recursive: true, force: true});
  });
  await pg.initialise();
  await pg.start();
  pgStarted = true;
  admin = pg.getPgClient();
  await admin.connect();
  await admin.query(`
    create role anon; create role authenticated; create role service_role;
    create role authenticator login password 'local-only' noinherit;
    grant anon,authenticated,service_role to authenticator;
    create schema auth; create schema storage;
    create table storage.objects(bucket_id text not null,name text not null,primary key(bucket_id,name));
    create table auth.users(id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$
      select (nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub')::uuid
    $$;
    grant usage on schema public,auth to anon,authenticated,service_role;
    grant execute on function auth.uid() to anon,authenticated,service_role;
    create table public.seller_profiles(user_id uuid primary key references auth.users(id),status text not null);
  `);
  for (const file of migrations) {
    await admin.query(await readFile(join(project, 'supabase/migrations', file), 'utf8'));
  }
  const owner = randomUUID(), other = randomUUID(), staff = randomUUID(), stranger = randomUUID();
  for (const id of [owner, other, staff, stranger]) await admin.query('insert into auth.users values($1)', [id]);
  for (const id of [owner, other]) await admin.query("insert into seller_profiles values($1,'approved')", [id]);
  const libRoot = join(project, 'tools/broadcast-tests/node_modules/@embedded-postgres');
  const libDir = ['darwin-arm64', 'darwin-x64']
    .map(name => join(libRoot, name, 'native/lib')).find(existsSync);
  api = spawn(postgrestBin, [], {
    env: {
      ...process.env,
      ...(libDir && process.platform === 'darwin' ? {DYLD_LIBRARY_PATH: libDir} : {}),
      PGRST_DB_URI: `postgresql://authenticator:local-only@127.0.0.1:${pgPort}/postgres`,
      PGRST_DB_SCHEMAS: 'public', PGRST_DB_ANON_ROLE: 'anon',
      PGRST_JWT_SECRET: secret, PGRST_SERVER_HOST: '127.0.0.1',
      PGRST_SERVER_PORT: String(apiPort), PGRST_DB_POOL: '5',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  api.stdout.on('data', chunk => { apiLog = (apiLog + chunk).slice(-8000); });
  api.stderr.on('data', chunk => { apiLog = (apiLog + chunk).slice(-8000); });
  let ready = false;
  for (let i = 0; i < 50; i++) {
    try { const response = await fetch(`http://127.0.0.1:${apiPort}/`); if (response.status) { ready = true; break; } }
    catch { /* startup */ }
    if (api.exitCode !== null) break;
    await pause(200);
  }
  assert.ok(ready, `PostgREST did not start: ${apiLog}`);
  const jwt = (id, role = 'authenticated') => {
    const header = encode({alg: 'HS256', typ: 'JWT'});
    const payload = encode({role, sub: id, exp: Math.floor(Date.now()/1000)+3600});
    return `${header}.${payload}.${createHmac('sha256', secret).update(`${header}.${payload}`).digest('base64url')}`;
  };
  const rpc = async (name, params, actor, role = 'authenticated') => {
    const response = await fetch(`http://127.0.0.1:${apiPort}/rpc/${name}`, {
      method: 'POST', headers: {'content-type': 'application/json', ...(actor ? {authorization: `Bearer ${jwt(actor,role)}`} : {})},
      body: JSON.stringify(params),
    });
    return {status: response.status, body: await response.json()};
  };
  const must = async (name, params, actor, role = 'authenticated') => {
    const result = await rpc(name, params, actor, role);
    assert.equal(result.status, 200, `${name}: ${JSON.stringify(result.body)}`);
    return result.body;
  };
  const command = (actor, name, data, key = randomUUID()) => must('broadcast_command', {
    p_seller_id: owner, p_command: name, p_data: data, p_key: key,
  }, actor);

  assert.equal((await must('broadcast_workspace', {p_seller_id: owner}, owner)).role, 'manager');
  assert.notEqual((await rpc('broadcast_workspace', {p_seller_id: owner}, stranger)).status, 200);
  assert.notEqual((await rpc('broadcast_workspace', {p_seller_id: owner}, null)).status, 200);
  const invite = await must('broadcast_staff_manage', {
    p_seller_id: owner, p_action: 'invite', p_user_id: null, p_key: randomUUID(),
  }, owner);
  assert.equal((await must('broadcast_staff_join', {p_code: invite.code}, staff)).role, 'assistant');
  const customer = await command(owner, 'customer.create', {nickname: '몽이맘', wechat_note: '위챗 확인'});
  const session = await command(owner, 'session.create', {title: 'HTTP 시험', kind: 'new', exchange_rate: 190});
  const product = await command(staff, 'product.create', {
    session_id: session.id, supplier: '테스트 거래처', title: '조끼', price_krw: 19000,
    colors: ['검정'], sizes: ['M'],
  });
  const data = {session_id: session.id, customer_id: customer.id, product_id: product.id,
    color: '검정', size: 'M', quantity: 1};
  const sameKey = randomUUID();
  const [a, replay] = await Promise.all([
    command(staff, 'order.create', data, sameKey),
    command(staff, 'order.create', data, sameKey),
  ]);
  assert.equal(a.id, replay.id, '동일 행위의 동시 재시도는 한 주문');
  const requests = Array.from({length: 20}, (_, index) => command(index % 2 === 0 ? staff : owner, 'order.create', data));
  const lines = await Promise.all(requests);
  assert.equal(new Set(lines.map(line => line.id)).size, 20);
  assert.equal(new Set(lines.map(line => line.sequence)).size, 20);
  const count = await admin.query('select count(*)::int count from broadcast_order_lines where session_id=$1', [session.id]);
  assert.equal(count.rows[0].count, 21);
  const sources = await admin.query('select distinct source from broadcast_order_lines where session_id=$1', [session.id]);
  assert.deepEqual(new Set(sources.rows.map(row => row.source)), new Set(['broadcast_assistant', 'seller_input']));
  const page = await must('broadcast_order_page', {p_seller_id: owner, p_session_id: session.id, p_limit: 5}, staff);
  assert.equal(page.items.length, 5);
  assert.ok(page.next_before_sequence);
  const older = await must('broadcast_order_page', {p_seller_id: owner, p_session_id: session.id,
    p_before_sequence: page.next_before_sequence, p_limit: 5}, staff);
  assert.ok(older.items.every(line => line.sequence < page.next_before_sequence));
  assert.equal(older.items[0].nickname, '몽이맘');
  const workspace = await must('broadcast_workspace', {p_seller_id: owner}, owner);
  assert.deepEqual(workspace.orders, []);
  assert.ok(workspace.products.find(row => row.id === product.id)?.has_orders);
  assert.equal((await must('broadcast_customer_page', {p_seller_id: owner, p_query: '몽'}, staff)).items[0].id, customer.id);
  assert.notEqual((await rpc('broadcast_order_page', {p_seller_id: other, p_session_id: session.id}, other)).status, 200);
  const service = (name, params) => must(name, params, owner, 'service_role');
  const link = await must('broadcast_customer_link', {p_seller_id: owner, p_customer_id: customer.id}, owner);
  assert.notEqual((await rpc('broadcast_guest_view', {p_locator: link.locator,
    p_session_hash: 'a'.repeat(64)}, null)).status, 200);
  const digest = value => createHash('sha256').update(value).digest('hex');
  const pendingHash = digest('local pending cookie');
  const request = await service('broadcast_access_request', {p_locator: link.locator,p_pending_hash: pendingHash});
  const approval = await must('broadcast_access_approve', {p_seller_id: owner,p_request_id: request.request_id},owner);
  assert.notEqual((await rpc('broadcast_access_activate', {
    p_request_id:request.request_id,p_pending_hash:pendingHash,
    p_token_hash:digest(approval.activation_token),p_session_hash:digest('local session cookie'),
  },null)).status,200);
  const activated = await service('broadcast_access_activate', {
    p_request_id:request.request_id,p_pending_hash:pendingHash,
    p_token_hash:digest(approval.activation_token),p_session_hash:digest('local session cookie'),
  });
  const guestView = await service('broadcast_guest_view', {
    p_locator:link.locator,p_session_hash:digest('local session cookie'),
  });
  assert.equal(guestView.customer.nickname,'몽이맘');
  assert.equal(guestView.orders.length,21);
  await must('broadcast_access_revoke',{p_seller_id:owner,p_device_id:activated.device_id},owner);
  assert.notEqual((await rpc('broadcast_guest_view', {
    p_locator:link.locator,p_session_hash:digest('local session cookie'),
  },owner,'service_role')).status,200);
  if (process.env.BROADCAST_TEST_ADAPTER === '1') {
    const proxy = createHttpServer(async (request, response) => {
      try {
        if (!request.url?.startsWith('/rest/v1/')) {
          response.writeHead(404).end();
          return;
        }
        const chunks = [];
        for await (const chunk of request) chunks.push(chunk);
        const headers = {...request.headers};
        delete headers.host;
        const upstream = await fetch(`http://127.0.0.1:${apiPort}${request.url.slice('/rest/v1'.length)}`, {
          method: request.method, headers,
          body: chunks.length ? Buffer.concat(chunks) : undefined,
        });
        response.writeHead(upstream.status, {'content-type': upstream.headers.get('content-type') ?? 'application/json'});
        response.end(Buffer.from(await upstream.arrayBuffer()));
      } catch (error) {
        response.writeHead(502, {'content-type': 'text/plain'}).end(String(error));
      }
    });
    await new Promise(resolve => proxy.listen(0, '127.0.0.1', resolve));
    try {
      const result = await new Promise((resolve, reject) => {
        let output = '';
        const child = spawn('sh', ['tools/broadcast-tests/test_adapter_isolated.sh'], {
          cwd: project,
          env: {...process.env, BROADCAST_TEST_URL: `http://127.0.0.1:${proxy.address().port}`,
            BROADCAST_TEST_OWNER: owner, BROADCAST_TEST_STRANGER: stranger,
            BROADCAST_TEST_OWNER_JWT: jwt(owner), BROADCAST_TEST_STRANGER_JWT: jwt(stranger),
            BROADCAST_TEST_CUSTOMER: customer.id, BROADCAST_TEST_SESSION: session.id,
            BROADCAST_TEST_PRODUCT: product.id},
          stdio: ['ignore', 'pipe', 'pipe'],
        });
        child.stdout.on('data', chunk => { output = (output + chunk).slice(-12000); });
        child.stderr.on('data', chunk => { output = (output + chunk).slice(-12000); });
        child.once('error', reject);
        child.once('exit', code => resolve({code, output}));
      });
      assert.equal(result.code, 0, result.output);
    } finally {
      await new Promise(resolve => proxy.close(resolve));
    }
  }
  await must('broadcast_staff_manage', {p_seller_id: owner, p_action: 'remove', p_user_id: staff, p_key: randomUUID()}, owner);
  assert.notEqual((await rpc('broadcast_workspace', {p_seller_id: owner}, staff)).status, 200);
  assert.notEqual((await rpc('broadcast_command', {p_seller_id: owner, p_command: 'order.create', p_data: data, p_key: randomUUID()}, staff)).status, 200);
});
