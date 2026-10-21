// Refresh two short-lived test Auth sessions after anonymous sign-in is off.
// Rotate the owner-only fixture atomically; never print tokens.
import assert from 'node:assert/strict';
import {readFile, rename, stat, writeFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';

const path=process.argv[2];
assert.ok(path?.startsWith('/tmp/') && !path.includes('/CoBuying/'));
assert.equal((await stat(path)).mode & 0o077,0);
const fixture=JSON.parse(await readFile(path,'utf8'));
assert.equal(new URL(fixture.base).hostname,'kshysvfxcjtixfveimai.supabase.co');
const key=process.env.BROADCAST_CLOUD_KEY;
assert.ok(key?.startsWith('sb_publishable_'));
const save=async()=>{
  const next=`${path}.${randomUUID()}.tmp`;
  await writeFile(next,JSON.stringify(fixture),{mode:0o600,flag:'wx'});
  await rename(next,path);
};
for(const user of fixture.users) {
  assert.ok(user.refresh_token && user.id);
  const response=await fetch(`${fixture.base}/auth/v1/token?grant_type=refresh_token`,{
    method:'POST',headers:{apikey:key,'content-type':'application/json'},
    body:JSON.stringify({refresh_token:user.refresh_token}),
    signal:AbortSignal.timeout(30000),
  });
  assert.equal(response.status,200,`Test ${user.role} token refresh failed.`);
  const data=await response.json();
  assert.equal(data.user?.id,user.id);
  assert.ok(data.access_token && data.refresh_token);
  user.access_token=data.access_token;
  user.refresh_token=data.refresh_token;
  await save();
}
console.log('Two test Auth sessions refreshed without enabling anonymous sign-in.');
