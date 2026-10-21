import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createHash, randomUUID} from 'node:crypto';
import {createServer} from 'node:http';
import {createServer as createNetServer} from 'node:net';
import {createCustomerGateway} from '../../services/broadcast-customer-gateway/server.mjs';

const hash = value => createHash('sha256').update(value).digest('hex');
const freePort = () => new Promise(resolve => {
  const server = createNetServer();
  server.listen(0,'127.0.0.1',()=>{
    const port=server.address().port;
    server.close(()=>resolve(port));
  });
});
const listen = (server,port) => new Promise(resolve=>server.listen(port,'127.0.0.1',resolve));
const close = server => new Promise(resolve=>server.close(resolve));

test('고정 링크만으로 비노출, 같은 요청 기기 활성화, 쿠키·출처·A/B 경계',async t=>{
  const locator=randomUUID(), other=randomUUID(), requestId=randomUUID(), token=randomUUID();
  const qrPath=`${randomUUID()}/${randomUUID()}.png`;
  let pendingHash,sessionHash,backendCalls=0,storedBytes;
  const backend=createServer(async(req,res)=>{
    backendCalls++;
    assert.equal(req.headers.apikey,'sb_secret_local-test');
    assert.equal(req.headers.authorization,undefined,
      'New Supabase secret keys must not be sent as bearer JWTs.');
    const chunks=[];
    for await (const chunk of req) chunks.push(chunk);
    const bytes=Buffer.concat(chunks);
    const data=req.url.startsWith('/rest/')?JSON.parse(bytes.toString()):null;
    res.setHeader('content-type','application/json');
    if(req.url===`/storage/v1/object/authenticated/broadcast-receiver-qr/${qrPath}`) {
      res.setHeader('content-type','image/png');res.end(Buffer.from('89504e470d0a1a0a','hex'));
    } else if(req.url?.startsWith('/storage/v1/object/broadcast-evidence/')) {
      if(storedBytes){res.writeHead(400);res.end('{"error":"Asset Already Exists"}');}
      else{storedBytes=bytes;res.end('{"Key":"stored"}');}
    } else if(req.url?.startsWith('/storage/v1/object/authenticated/broadcast-evidence/')) {
      if(!storedBytes){res.writeHead(404);res.end('{}');}
      else{res.setHeader('content-type','image/png');res.end(storedBytes);}
    } else if(req.url==='/rest/v1/rpc/broadcast_guest_evidence_reserve') {
      assert.equal(data.p_locator,locator);
      assert.equal(data.p_session_hash,sessionHash);
      assert.equal(data.p_content_type,'image/png');
      res.end(JSON.stringify({evidence_id:requestId,object_key:`broadcast-evidence/${locator}/${requestId}`,
        status:storedBytes?'stored':'reserved',sha256:storedBytes?hash(storedBytes):null}));
    } else if(req.url==='/rest/v1/rpc/broadcast_evidence_stored') {
      assert.equal(data.p_evidence_id,requestId);
      assert.equal(data.p_sha256,hash(storedBytes));
      res.end(JSON.stringify({evidence_id:requestId,status:'stored'}));
    } else if(req.url==='/rest/v1/rpc/broadcast_guest_receipt_submit') {
      assert.equal(data.p_evidence_id,requestId);
      assert.equal(data.p_session_hash,sessionHash);
      res.end(JSON.stringify({receipt_id:requestId,status:'pending_review'}));
    } else if(req.url==='/rest/v1/rpc/broadcast_guest_payment_summary') {
      assert.equal(data.p_locator,locator);
      assert.equal(data.p_session_hash,sessionHash);
      res.end(JSON.stringify([{invoice_id:requestId,confirmed_minor:0,pending_count:1}]));
    } else if(req.url==='/rest/v1/rpc/broadcast_guest_deposit_returns') {
      assert.equal(data.p_locator,locator);
      assert.equal(data.p_session_hash,sessionHash);
      res.end(JSON.stringify([{id:requestId,amount_krw:6000,reason:'고객 요청'}]));
    } else if(req.url==='/rest/v1/rpc/broadcast_guest_receiver_qr') {
      assert.equal(data.p_locator,locator);
      assert.equal(data.p_session_hash,sessionHash);
      assert.equal(data.p_invoice_id,requestId);
      assert.equal(data.p_method,'wechat');
      res.end(JSON.stringify({object_key:qrPath,content_type:'image/png'}));
    } else if(req.url==='/rest/v1/rpc/broadcast_guest_receipt_needs_info') {
      assert.equal(data.p_locator,locator);
      assert.equal(data.p_session_hash,sessionHash);
      res.end(JSON.stringify([{receipt_id:requestId,invoice_id:requestId,reason:'캡처를 다시 올려주세요'}]));
    } else if(req.url==='/rest/v1/rpc/broadcast_guest_receipt_supplement') {
      assert.equal(data.p_locator,locator);
      assert.equal(data.p_session_hash,sessionHash);
      assert.equal(data.p_receipt_id,requestId);
      assert.equal(data.p_evidence_id,requestId);
      res.end(JSON.stringify({receipt_id:requestId,status:'pending_review'}));
    } else if(req.url==='/rest/v1/rpc/broadcast_guest_shipments') {
      assert.equal(data.p_locator,locator);
      assert.equal(data.p_session_hash,sessionHash);
      res.end(JSON.stringify([{id:requestId,tracking_number:'TRACK-1',lines:[]}]));
    } else if(req.url==='/rest/v1/rpc/broadcast_access_request') {
      assert.equal(data.p_locator,locator);
      pendingHash=data.p_pending_hash;
      res.end(JSON.stringify({request_id:requestId,status:'pending'}));
    } else if(req.url==='/rest/v1/rpc/broadcast_access_activate') {
      assert.equal(data.p_request_id,requestId);
      assert.equal(data.p_pending_hash,pendingHash);
      assert.equal(data.p_token_hash,hash(token));
      sessionHash=data.p_session_hash;
      res.end(JSON.stringify({locator,device_id:randomUUID()}));
    } else if(req.url==='/rest/v1/rpc/broadcast_guest_view') {
      if(data.p_locator!==locator || data.p_session_hash!==sessionHash) {
        res.writeHead(403);res.end(JSON.stringify({message:'denied'}));
      } else res.end(JSON.stringify({customer:{nickname:'손님 A'},orders:[{id:'A-only'}]}));
    } else if(req.url==='/rest/v1/rpc/broadcast_guest_request') {
      if(data.p_locator!==locator || data.p_session_hash!==sessionHash) {
        res.writeHead(403);res.end('{}');
      } else {
        assert.equal(data.p_kind,'addition');
        assert.equal(data.p_raw_text,'검정 M 하나');
        res.end(JSON.stringify({id:requestId,status:'pending'}));
      }
    } else if(req.url==='/rest/v1/rpc/broadcast_guest_requests') {
      if(data.p_locator!==locator || data.p_session_hash!==sessionHash) {
        res.writeHead(403);res.end('{}');
      } else res.end(JSON.stringify([{id:requestId,status:'pending'}]));
    } else if(req.url==='/rest/v1/rpc/broadcast_guest_billing') {
      if(data.p_locator!==locator || data.p_session_hash!==sessionHash) {
        res.writeHead(403);res.end('{}');
      } else res.end(JSON.stringify({destination:{version:1,country:'KR'},invoices:[{id:requestId}]}));
    } else if(req.url==='/rest/v1/rpc/broadcast_guest_address') {
      assert.equal(data.p_locator,locator);
      assert.equal(data.p_session_hash,sessionHash);
      assert.equal(data.p_expected_version,1);
      res.end(JSON.stringify({version:2,address:data.p_address}));
    } else if(req.url==='/rest/v1/rpc/broadcast_guest_invoice_accept') {
      assert.equal(data.p_locator,locator);
      assert.equal(data.p_session_hash,sessionHash);
      assert.equal(data.p_invoice_id,requestId);
      res.end(JSON.stringify({invoice_id:requestId,accepted_at:'now'}));
    } else {res.writeHead(404);res.end('{}');}
  });
  await listen(backend,0);
  t.after(()=>close(backend));
  const port=await freePort(), origin=`http://127.0.0.1:${port}`;
  const gateway=createCustomerGateway({backendUrl:`http://127.0.0.1:${backend.address().port}`,
    serviceKey:'sb_secret_local-test',sessionSecret:'local-secret-at-least-32-characters',
    origin,allowInsecureLocal:true});
  await listen(gateway,port);
  t.after(()=>close(gateway));
  const api=(path,{method='GET',body,cookie,from=origin}={})=>fetch(`${origin}${path}`,{
    method,headers:{...(method==='POST'?{origin:from,'content-type':'application/json'}:{}),
      ...(cookie?{cookie}:{})},...(body?{body:JSON.stringify(body)}:{}),
  });
  const customerPath=`/api/broadcast/v2/customer/${locator}`;
  const bare=await api(customerPath);
  assert.equal(bare.status,401);
  assert.equal(bare.headers.get('cache-control'),'no-store');
  assert.equal(bare.headers.get('referrer-policy'),'no-referrer');
  assert.equal(backendCalls,0);
  const crossSite=await api('/api/broadcast/v2/access/request',{
    method:'POST',body:{locator},from:'https://example.org'});
  assert.equal(crossSite.status,403);
  const requested=await api('/api/broadcast/v2/access/request',{method:'POST',body:{locator}});
  assert.equal(requested.status,200);
  assert.equal((await requested.json()).request_id,requestId);
  const pending=requested.headers.get('set-cookie').split(';')[0];
  assert.match(requested.headers.get('set-cookie'),/HttpOnly; SameSite=Lax/);
  const repeated=await api('/api/broadcast/v2/access/request',{
    method:'POST',cookie:pending,body:{locator}});
  assert.equal((await repeated.json()).request_id,requestId);
  assert.equal((await api(customerPath,{cookie:pending})).status,401);
  assert.equal((await api('/api/broadcast/v2/access/activate',{
    method:'POST',body:{request_id:requestId,token}})).status,403);
  const activated=await api('/api/broadcast/v2/access/activate',{
    method:'POST',cookie:pending,body:{request_id:requestId,token}});
  assert.equal(activated.status,200);
  const session=activated.headers.get('set-cookie').split(';')[0];
  const own=await api(customerPath,{cookie:session});
  assert.equal((await own.json()).customer.nickname,'손님 A');
  assert.equal((await api(`/api/broadcast/v2/customer/${other}`,{cookie:session})).status,403);
  const requestsPath=`${customerPath}/requests`;
  assert.equal((await api(requestsPath,{method:'POST',body:{kind:'addition',target_id:randomUUID(),raw_text:'검정 M 하나',request_key:randomUUID()}})).status,401);
  assert.equal((await api(requestsPath,{method:'POST',cookie:session,from:'https://example.org',body:{kind:'addition',target_id:randomUUID(),raw_text:'검정 M 하나',request_key:randomUUID()}})).status,403);
  const added=await api(requestsPath,{method:'POST',cookie:session,body:{kind:'addition',target_id:randomUUID(),raw_text:'검정 M 하나',request_key:randomUUID()}});
  assert.equal(added.status,200);
  assert.equal((await added.json()).status,'pending');
  assert.equal((await (await api(requestsPath,{cookie:session})).json())[0].id,requestId);
  assert.equal((await api(`/api/broadcast/v2/customer/${other}/requests`,{cookie:session})).status,403);
  assert.equal((await api(`${customerPath}/billing`)).status,401);
  assert.equal((await (await api(`${customerPath}/billing`,{cookie:session})).json()).invoices[0].id,requestId);
  const address=await api(`${customerPath}/address`,{method:'POST',cookie:session,
    body:{address:{country:'KR',recipient:'손님'},expected_version:1}});
  assert.equal((await address.json()).version,2);
  const accepted=await api(`${customerPath}/invoices/${requestId}/accept`,{method:'POST',cookie:session,body:{}});
  assert.equal((await accepted.json()).invoice_id,requestId);
  const evidencePath=`${customerPath}/evidence?invoice=${requestId}&key=${randomUUID()}`;
  const png=Buffer.from('89504e470d0a1a0a','hex');
  assert.equal((await fetch(`${origin}${evidencePath}`,{method:'POST',headers:{origin,'content-type':'image/png'},body:png})).status,401);
  const upload=await fetch(`${origin}${evidencePath}`,{method:'POST',
    headers:{origin,'content-type':'image/png',cookie:session},body:png});
  assert.equal(upload.status,200);
  assert.equal((await upload.json()).evidence_id,requestId);
  const replay=await fetch(`${origin}${evidencePath}`,{method:'POST',
    headers:{origin,'content-type':'image/png',cookie:session},body:png});
  assert.equal(replay.status,200);
  assert.equal((await fetch(`${origin}${customerPath}/evidence?invoice=${requestId}&key=${randomUUID()}`,{
    method:'POST',headers:{origin,'content-type':'image/png',cookie:session},body:Buffer.from('not an image')})).status,400);
  const receipt=await api(`${customerPath}/receipts`,{method:'POST',cookie:session,
    body:{evidence_id:requestId,currency:'KRW',amount_minor:18000,payer_name:'대리송금'}});
  assert.equal((await receipt.json()).status,'pending_review');
  assert.equal((await api(`${customerPath}/receipts/needs-info`)).status,401);
  assert.equal((await (await api(`${customerPath}/receipts/needs-info`,{cookie:session})).json())[0].reason,
    '캡처를 다시 올려주세요');
  assert.equal((await api(`${customerPath}/receipts/${requestId}/supplement`,{
    method:'POST',cookie:session,from:'https://example.org',body:{evidence_id:requestId}})).status,403);
  assert.equal((await api(`${customerPath}/receipts/${requestId}/supplement`,{
    method:'POST',cookie:session,body:{evidence_id:requestId}})).status,200);
  assert.equal((await (await api(`${customerPath}/payments`,{cookie:session})).json())[0].pending_count,1);
  assert.equal((await api(`${customerPath}/deposit-returns`)).status,401);
  assert.equal((await (await api(`${customerPath}/deposit-returns`,{cookie:session})).json())[0].amount_krw,6000);
  const qrUrl=`${customerPath}/invoices/${requestId}/receiver-qr/wechat`;
  assert.equal((await api(qrUrl)).status,401);
  const qr=await api(qrUrl,{cookie:session});
  assert.equal(qr.status,200);
  assert.equal(qr.headers.get('content-type'),'image/png');
  assert.equal(qr.headers.get('cache-control'),'private, no-store');
  assert.equal((await qr.arrayBuffer()).byteLength,8);
  assert.equal((await (await api(`${customerPath}/shipments`,{cookie:session})).json())[0].tracking_number,'TRACK-1');
});

test('기존 service-role JWT는 Bearer 헤더를 유지한다',async t=>{
  const key='eyJ.test-service-role.jwt';
  const locator=randomUUID();
  const backend=createServer(async(req,res)=>{
    assert.equal(req.headers.apikey,key);
    assert.equal(req.headers.authorization,`Bearer ${key}`);
    res.setHeader('content-type','application/json');
    res.end(JSON.stringify({request_id:randomUUID(),status:'pending'}));
  });
  await listen(backend,0);
  t.after(()=>close(backend));
  const port=await freePort(),origin=`http://127.0.0.1:${port}`;
  const gateway=createCustomerGateway({
    backendUrl:`http://127.0.0.1:${backend.address().port}`,serviceKey:key,
    sessionSecret:'legacy-jwt-test-secret-at-least-32-characters',origin,
    allowInsecureLocal:true,
  });
  await listen(gateway,port);
  t.after(()=>close(gateway));
  const response=await fetch(`${origin}/api/broadcast/v2/access/request`,{
    method:'POST',headers:{origin,'content-type':'application/json'},
    body:JSON.stringify({locator}),
  });
  assert.equal(response.status,200);
});
