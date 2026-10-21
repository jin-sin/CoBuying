// Read-only checks that do not require enabling temporary test sign-in.
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';

const base=process.env.BROADCAST_CLOUD_URL;
const apiKey=process.env.BROADCAST_CLOUD_KEY;
assert.equal(new URL(base).hostname,'kshysvfxcjtixfveimai.supabase.co',
  'Only the isolated orendam-broadcast-test project is allowed.');
assert.ok(apiKey?.startsWith('sb_publishable_'));
const headers={apikey:apiKey};
const table=await fetch(`${base}/rest/v1/broadcast_customers?select=id&limit=1`,{
  headers,signal:AbortSignal.timeout(30000)});
assert.ok([401,403].includes(table.status),
  `Broadcast customer table must not be readable anonymously: ${table.status}`);
const rpc=await fetch(`${base}/rest/v1/rpc/broadcast_workspace`,{
  method:'POST',headers:{...headers,'content-type':'application/json'},
  body:JSON.stringify({p_seller_id:randomUUID()}),signal:AbortSignal.timeout(30000)});
assert.ok([401,403].includes(rpc.status),
  `Broadcast workspace must not be callable anonymously: ${rpc.status}`);
for(const bucket of ['broadcast-evidence','broadcast-receiver-qr']) {
  const listing=await fetch(`${base}/storage/v1/object/list/${bucket}`,{
    method:'POST',headers:{...headers,'content-type':'application/json'},
    body:'{"prefix":"","limit":1}',signal:AbortSignal.timeout(30000)});
  if(listing.status===200) {
    const visible=await listing.json();
    assert.deepEqual(visible,[],`${bucket} must not expose object names anonymously`);
  } else assert.ok([400,401,403].includes(listing.status),
    `${bucket} unexpected anonymous listing response: ${listing.status}`);
}
console.log('Cloud anonymous boundary: customer table and staff workspace denied; private bucket listing exposed no names.');
