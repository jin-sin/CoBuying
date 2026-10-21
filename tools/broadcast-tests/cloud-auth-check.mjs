// One-shot B01 test against an explicitly isolated Supabase Cloud project.
// Set BROADCAST_CLOUD_KEY to its publishable key and pass a mode-0600 fixture
// file containing two freshly Auth-issued anonymous sessions. Never commit it.
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readFile, stat} from 'node:fs/promises';

const path = process.argv[2];
assert.ok(path, 'Pass the temporary fixture file path.');
const info = await stat(path);
assert.equal(info.mode & 0o077, 0, 'Fixture file must be readable only by its owner.');
const {base, users} = JSON.parse(await readFile(path, 'utf8'));
const project = new URL(base);
assert.equal(project.protocol, 'https:');
assert.equal(project.hostname, 'kshysvfxcjtixfveimai.supabase.co',
  'Only the isolated orendam-broadcast-test project is allowed.');
const key = process.env.BROADCAST_CLOUD_KEY;
assert.ok(key?.startsWith('sb_publishable_'), 'Use only the test publishable key.');
const seller = users.find(user => user.role === 'seller');
const assistant = users.find(user => user.role === 'assistant');
assert.ok(seller?.id && seller.access_token && assistant?.id && assistant.access_token);
assert.notEqual(seller.id, assistant.id);

const rpc = async (name, params, user) => {
  const response = await fetch(`${base}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: {
      apikey: key,
      authorization: `Bearer ${user.access_token}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify(params),
    signal: AbortSignal.timeout(30000),
  });
  return {status: response.status, body: await response.json()};
};
const must = async (name, params, user) => {
  const result = await rpc(name, params, user);
  assert.equal(result.status, 200, `${name}: ${JSON.stringify(result.body)}`);
  return result.body;
};
const command = (name, data, user, key = randomUUID()) => must('broadcast_command', {
  p_seller_id: seller.id, p_command: name, p_data: data, p_key: key,
}, user);
const manage = (action, userId = null) => must('broadcast_staff_manage', {
  p_seller_id: seller.id, p_action: action, p_user_id: userId, p_key: randomUUID(),
}, seller);

for (const user of [seller, assistant]) {
  const jwtPayload = JSON.parse(Buffer.from(user.access_token.split('.')[1], 'base64url'));
  assert.equal(jwtPayload.sub, user.id);
  assert.equal(jwtPayload.role, 'authenticated');
  assert.equal(jwtPayload.is_anonymous, true);
}
assert.equal((await must('broadcast_workspace', {p_seller_id: seller.id}, seller)).role, 'manager');
assert.equal((await rpc('broadcast_workspace', {p_seller_id: seller.id}, assistant)).status, 403);

const invite = await manage('invite');
let joined = false;
let removed = false;
try {
  assert.equal((await must('broadcast_staff_join', {p_code: invite.code}, assistant)).role, 'assistant');
  joined = true;
  assert.equal((await must('broadcast_workspace', {p_seller_id: seller.id}, assistant)).role, 'assistant');
  assert.equal((await rpc('broadcast_command', {
    p_seller_id: seller.id, p_command: 'session.create',
    p_data: {title: '권한 거부', kind: 'new', exchange_rate: 190}, p_key: randomUUID(),
  }, assistant)).status, 403);

  const customer = await command('customer.create', {nickname: 'Cloud 시험 고객'}, seller);
  const session = await command('session.create', {title: 'Cloud B01 검증', kind: 'new', exchange_rate: 190}, seller);
  const product = await command('product.create', {
    session_id: session.id, supplier: '시험 거래처', title: '데님조끼',
    price_krw: 19000, colors: ['검정'], sizes: ['M'],
  }, assistant);
  const data = {session_id: session.id, customer_id: customer.id, product_id: product.id,
    color: '검정', size: 'M', quantity: 1};
  const replayKey = randomUUID();
  const first = await command('order.create', data, assistant, replayKey);
  const replay = await command('order.create', data, assistant, replayKey);
  assert.equal(first.id, replay.id, '같은 저장 동작은 한 행');
  assert.equal(first.source, 'broadcast_assistant');
  assert.equal(first.original.product.title, '데님조끼');

  const lines = await Promise.all(Array.from({length: 20}, (_, index) =>
    command('order.create', data, index % 2 === 0 ? assistant : seller)));
  assert.equal(new Set(lines.map(line => line.id)).size, 20);
  assert.equal(new Set(lines.map(line => line.sequence)).size, 20);
  assert.deepEqual(new Set(lines.map(line => line.source)), new Set(['broadcast_assistant', 'seller_input']));
  const orderPage = await must('broadcast_order_page', {
    p_seller_id: seller.id, p_session_id: session.id, p_limit: 5,
  }, assistant);
  assert.equal(orderPage.items.length, 5);
  assert.ok(orderPage.next_before_sequence);
  const olderPage = await must('broadcast_order_page', {
    p_seller_id: seller.id, p_session_id: session.id,
    p_before_sequence: orderPage.next_before_sequence, p_limit: 5,
  }, assistant);
  assert.ok(olderPage.items.every(row => row.sequence < orderPage.next_before_sequence));
  const customerPage = await must('broadcast_customer_page', {
    p_seller_id: seller.id, p_query: 'Cloud',
  }, assistant);
  assert.equal(customerPage.items[0].id, customer.id);
  const workspace = await must('broadcast_workspace', {p_seller_id: seller.id}, seller);
  assert.deepEqual(workspace.orders, []);
  assert.ok(workspace.products.find(row => row.id === product.id)?.has_orders);

  await manage('remove', assistant.id);
  removed = true;
  assert.equal((await rpc('broadcast_workspace', {p_seller_id: seller.id}, assistant)).status, 403);
  assert.equal((await rpc('broadcast_command', {
    p_seller_id: seller.id, p_command: 'order.create', p_data: data, p_key: randomUUID(),
  }, assistant)).status, 403);
  assert.equal((await must('broadcast_workspace', {p_seller_id: seller.id}, seller)).role, 'manager');
  console.log('Cloud Auth JWT 2명: 참여·20건 동시 주문·멱등·페이지·회수 후 차단 통과');
  console.log(`test seller=${seller.id}, assistant=${assistant.id}, session=${session.id}`);
} finally {
  if (joined && !removed) {
    try { await manage('remove', assistant.id); } catch { /* preserve original failure */ }
  }
}
