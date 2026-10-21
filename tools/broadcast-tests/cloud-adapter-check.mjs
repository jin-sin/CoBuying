// Use the unchanged Flutter adapter against the isolated Cloud test project.
// Requires two Auth-issued sessions in an owner-only temporary fixture file.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {readFile, stat} from 'node:fs/promises';
import {dirname, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const path = process.argv[2];
assert.ok(path);
assert.equal((await stat(path)).mode & 0o077, 0);
const {base, users} = JSON.parse(await readFile(path, 'utf8'));
assert.equal(new URL(base).hostname, 'kshysvfxcjtixfveimai.supabase.co',
  'Only the isolated orendam-broadcast-test project is allowed.');
const key = process.env.BROADCAST_CLOUD_KEY;
assert.ok(key?.startsWith('sb_publishable_'));
const seller = users.find(user => user.role === 'seller');
const assistant = users.find(user => user.role === 'assistant');
assert.ok(seller && assistant);
const rpc = async (name, params) => {
  const response = await fetch(`${base}/rest/v1/rpc/${name}`, {
    method: 'POST', headers: {apikey: key, authorization: `Bearer ${seller.access_token}`,
      'content-type': 'application/json'},
    body: JSON.stringify(params),
  });
  const body = await response.json();
  assert.equal(response.status, 200, `${name}: ${JSON.stringify(body)}`);
  return body;
};
const workspace = await rpc('broadcast_workspace', {p_seller_id: seller.id});
const session = workspace.sessions.find(row => row.title === 'Cloud B01 검증');
assert.ok(session);
const product = workspace.products.find(row => row.session_id === session.id && row.title === '데님조끼');
assert.ok(product);
const customers = await rpc('broadcast_customer_page', {p_seller_id: seller.id, p_query: 'Cloud'});
const customer = customers.items.find(row => row.nickname === 'Cloud 시험 고객');
assert.ok(customer);

const project = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const result = await new Promise((resolve, reject) => {
  let output = '';
  const child = spawn('sh', ['tools/broadcast-tests/test_adapter_isolated.sh'], {
    cwd: project,
    env: {...process.env,
      BROADCAST_TEST_URL: base, BROADCAST_TEST_API_KEY: key,
      BROADCAST_TEST_OWNER: seller.id, BROADCAST_TEST_OWNER_JWT: seller.access_token,
      BROADCAST_TEST_STRANGER_JWT: assistant.access_token,
      BROADCAST_TEST_CUSTOMER: customer.id, BROADCAST_TEST_SESSION: session.id,
      BROADCAST_TEST_PRODUCT: product.id, BROADCAST_TEST_CUSTOMER_QUERY: 'Cloud',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout.on('data', chunk => { output = (output + chunk).slice(-12000); });
  child.stderr.on('data', chunk => { output = (output + chunk).slice(-12000); });
  child.once('error', reject);
  child.once('exit', code => resolve({code, output}));
});
assert.equal(result.code, 0, result.output);
console.log('Flutter SupabaseBroadcastRepository → Cloud Auth JWT → Cloud RPC 통과');
