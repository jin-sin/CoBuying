// Prepare two disposable Auth-issued sessions in an isolated Supabase Cloud
// test project while anonymous sign-ins are temporarily enabled. The output
// file is mode 0600 and must stay outside this repository.
import assert from 'node:assert/strict';
import {writeFile} from 'node:fs/promises';

const path = process.argv[2];
const base = process.env.BROADCAST_CLOUD_URL;
const key = process.env.BROADCAST_CLOUD_KEY;
assert.ok(path?.startsWith('/'), 'Pass an absolute temporary output path.');
assert.ok(!path.includes('/CoBuying/'), 'Do not save Auth sessions in this repository.');
assert.equal(new URL(base).hostname, 'kshysvfxcjtixfveimai.supabase.co',
  'Only the isolated orendam-broadcast-test project is allowed.');
assert.ok(key?.startsWith('sb_publishable_'));
const users = [];
for (const role of ['seller', 'assistant']) {
  const response = await fetch(`${base}/auth/v1/signup`, {
    method: 'POST', headers: {apikey: key, 'content-type': 'application/json'},
    body: '{}',
  });
  const data = await response.json();
  assert.ok(response.ok, `${role} signup failed with HTTP ${response.status}`);
  assert.ok(data.access_token && data.user?.id);
  users.push({role, id: data.user.id, access_token: data.access_token,
    refresh_token: data.refresh_token});
}
await writeFile(path, JSON.stringify({base, users}), {mode: 0o600, flag: 'wx'});
for (const {role, id} of users) console.log(`${role}: ${id}`);
console.log('Auth sessions written outside repository; delete after verification.');
