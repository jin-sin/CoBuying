// Run only against the isolated broadcast test project with short-lived Auth JWTs.
// The fixture is created by cloud-auth-create.mjs and kept outside the repository.
import assert from 'node:assert/strict';
import {randomBytes, randomUUID} from 'node:crypto';
import {createServer as createNetServer} from 'node:net';
import {readFile, stat} from 'node:fs/promises';
import {createCustomerGateway} from '../../services/broadcast-customer-gateway/server.mjs';

const fixturePath = process.argv[2];
assert.ok(fixturePath, 'Pass the temporary Auth fixture path.');
assert.equal((await stat(fixturePath)).mode & 0o077, 0, 'Auth fixture must be owner-only.');
const {base, users} = JSON.parse(await readFile(fixturePath, 'utf8'));
assert.equal(new URL(base).hostname, 'kshysvfxcjtixfveimai.supabase.co',
  'Only the isolated orendam-broadcast-test project is allowed.');
const apiKey = process.env.BROADCAST_CLOUD_KEY;
assert.ok(apiKey?.startsWith('sb_publishable_'), 'Use the test publishable key.');
const seller = users.find(user => user.role === 'seller');
const assistant = users.find(user => user.role === 'assistant');
assert.ok(seller?.id && seller.access_token && assistant?.id && assistant.access_token);

const rpc = async (name, params, user=seller) => {
  const response = await fetch(`${base}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: {apikey:apiKey, authorization:`Bearer ${user.access_token}`,
      'content-type':'application/json'},
    body: JSON.stringify(params), signal: AbortSignal.timeout(30000),
  });
  const body = await response.json();
  return {status:response.status, body};
};
const must = async (name, params, user=seller) => {
  const result = await rpc(name, params, user);
  assert.equal(result.status, 200, `${name}: ${JSON.stringify(result.body)}`);
  return result.body;
};
const denied = async (name, params, user=assistant) => {
  const result = await rpc(name, params, user);
  assert.equal(result.status, 403, `${name} should deny unrelated actor`);
};
const capture = (action, data, user=seller, key=randomUUID()) => must('broadcast_command', {
  p_seller_id:seller.id, p_command:action, p_data:data, p_key:key,
}, user);
const billing = (action, data, key=randomUUID()) => must('broadcast_billing_command', {
  p_seller_id:seller.id, p_command:action, p_data:data, p_key:key,
});

// The test does not require customer service-role access or a real money transfer.
assert.equal((await must('broadcast_workspace', {p_seller_id:seller.id})).role, 'manager');
await denied('broadcast_workspace', {p_seller_id:seller.id});
const customer = await capture('customer.create', {nickname:'B09 Cloud 사전검증'});
const session = await capture('session.create', {
  title:'B09 Cloud 사전검증',kind:'new',exchange_rate:200,
  shipping_krw:4000,shipping_cny_fen:3000,free_shipping_count:5,
});
const product = await capture('product.create', {
  session_id:session.id,supplier:'B09 테스트 거래처',title:'테스트 조끼',
  price_krw:12000,colors:['검정'],sizes:['M'],
});
const orderData={session_id:session.id,customer_id:customer.id,
  product_id:product.id,color:'검정',size:'M',quantity:1};
const orderKey=randomUUID();
const first=await capture('order.create',orderData,seller,orderKey);
assert.equal((await capture('order.create',orderData,seller,orderKey)).id,first.id);
const second=await capture('order.create',orderData);
assert.notEqual(second.id,first.id, 'A new order action must create a separate line.');
assert.ok(Number(second.sequence)>Number(first.sequence));
await denied('broadcast_billing_preview', {
  p_seller_id:seller.id,p_customer_id:customer.id,p_session_id:session.id,
});
const published=await capture('product.publish', {
  id:product.id,version:product.version,visible:true,
});
assert.equal(published.visible,true);
const link=await must('broadcast_customer_link', {
  p_seller_id:seller.id,p_customer_id:customer.id,
});
assert.ok(link.locator);
await denied('broadcast_customer_link', {
  p_seller_id:seller.id,p_customer_id:customer.id,
});
const receiver=await must('broadcast_receiver_command', {
  p_seller_id:seller.id,p_data:{method:'alipay',holder:'B09 테스트 명의',
    instructions:'테스트용 QR. 실제 송금 금지',active:true,verified:true},p_key:randomUUID(),
});
assert.equal(receiver.active,true);

// Upload a harmless 1x1 PNG through the authenticated seller Storage policy.
const objectId=randomUUID();
const objectKey=`${seller.id}/${objectId}.png`;
const png=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=','base64');
const upload=await fetch(`${base}/storage/v1/object/broadcast-receiver-qr/${objectKey}`, {
  method:'POST',headers:{apikey:apiKey,authorization:`Bearer ${seller.access_token}`,
    'content-type':'image/png','x-upsert':'false'},body:png,signal:AbortSignal.timeout(30000),
});
const uploaded=await upload.json();
assert.ok(upload.ok, `QR upload: ${JSON.stringify(uploaded)}`);
const deniedRead=await fetch(`${base}/storage/v1/object/authenticated/broadcast-receiver-qr/${objectKey}`, {
  headers:{apikey:apiKey},signal:AbortSignal.timeout(30000),
});
assert.ok([400,401,403,404].includes(deniedRead.status),
  `QR must remain private; anonymous status=${deniedRead.status}`);
const attached=await must('broadcast_receiver_qr_attach', {
  p_seller_id:seller.id,p_method:'alipay',p_object_id:objectId,
  p_content_type:'image/png',p_key:randomUUID(),
});
assert.equal(attached.object_id,objectId);
const preview=await must('broadcast_billing_preview', {
  p_seller_id:seller.id,p_customer_id:customer.id,p_session_id:session.id,
});
assert.equal(preview.orders.length,2);
await billing('destination.country',{customer_id:customer.id,country:'CN'});
const invoiceKey=randomUUID();
const invoice=await billing('invoice.issue',
  {customer_id:customer.id,session_id:session.id},invoiceKey);
assert.equal((await billing('invoice.issue',
  {customer_id:customer.id,session_id:session.id},invoiceKey)).id,invoice.id);
assert.equal(invoice.snapshot.receiver_snapshots.find(row=>row.method==='alipay')
  ?.private_qr_object_id,objectId);
assert.equal((await must('broadcast_purchase_preview', {p_seller_id:seller.id})).length,0,
  'Unpaid and unaccepted invoices must not enter procurement.');
await denied('broadcast_purchase_preview', {p_seller_id:seller.id});
console.log('Cloud preflight: Auth seller/stranger isolation, separate orders, invoice snapshot, private QR upload and unpaid procurement gate passed.');
console.log(`test session=${session.id}, invoice=${invoice.id}, customer=${customer.id}`);

// Service-role access is optional for the seller-only preflight. When a server-only
// test key is supplied, continue through the real customer gateway and Storage.
if (process.env.BROADCAST_SERVICE_KEY) {
  assert.ok(process.env.BROADCAST_SERVICE_KEY.startsWith('sb_secret_') ||
    process.env.BROADCAST_SERVICE_KEY.startsWith('eyJ'),
  'Use only a server-side test secret or legacy service-role JWT.');
  const port=await new Promise(resolve=>{
    const server=createNetServer();
    server.listen(0,'127.0.0.1',()=>{
      const value=server.address().port;
      server.close(()=>resolve(value));
    });
  });
  const origin=`http://127.0.0.1:${port}`;
  const gateway=createCustomerGateway({backendUrl:base,
    serviceKey:process.env.BROADCAST_SERVICE_KEY,
    sessionSecret:randomBytes(32).toString('hex'),origin,allowInsecureLocal:true});
  await new Promise(resolve=>gateway.listen(port,'127.0.0.1',resolve));
  try {
    const call=(path,{method='GET',body,cookie,contentType='application/json'}={})=>
      fetch(`${origin}${path}`,{method,headers:{...(method==='POST'?{origin,
        'content-type':contentType}:{}),...(cookie?{cookie}:{})},
        ...(body!==undefined?{body:contentType==='application/json'?JSON.stringify(body):body}:{}),
        signal:AbortSignal.timeout(30000)});
    const json=async (path,options) => {
      const response=await call(path,options);
      const body=await response.json();
      assert.equal(response.status,200,`${path}: ${JSON.stringify(body)}`);
      return {response,body};
    };
    const path=`/api/broadcast/v2/customer/${link.locator}`;
    assert.equal((await call(path)).status,401);
    const request=await json('/api/broadcast/v2/access/request',{
      method:'POST',body:{locator:link.locator}});
    const pending=request.response.headers.get('set-cookie').split(';')[0];
    const approved=await must('broadcast_access_approve',{
      p_seller_id:seller.id,p_request_id:request.body.request_id});
    assert.equal((await call('/api/broadcast/v2/access/activate',{
      method:'POST',body:{request_id:request.body.request_id,
        token:approved.activation_token}})).status,403);
    const active=await json('/api/broadcast/v2/access/activate',{
      method:'POST',cookie:pending,body:{request_id:request.body.request_id,
        token:approved.activation_token}});
    const sessionCookie=active.response.headers.get('set-cookie').split(';')[0];
    const own=(await json(path,{cookie:sessionCookie})).body;
    assert.equal(own.customer.nickname,'B09 Cloud 사전검증');
    assert.deepEqual(new Set(own.orders.map(row=>row.id)),new Set([first.id,second.id]));
    const other=await capture('customer.create',{nickname:'B09 다른 고객'});
    const otherLink=await must('broadcast_customer_link',{
      p_seller_id:seller.id,p_customer_id:other.id});
    assert.equal((await call(`/api/broadcast/v2/customer/${otherLink.locator}`,
      {cookie:sessionCookie})).status,403);
    const shown=(await json(`${path}/billing`,{cookie:sessionCookie})).body;
    assert.equal(shown.invoices.find(row=>row.id===invoice.id)?.id,invoice.id);
    const qr=await call(`${path}/invoices/${invoice.id}/receiver-qr/alipay`,
      {cookie:sessionCookie});
    assert.equal(qr.status,200);
    assert.equal(Buffer.compare(Buffer.from(await qr.arrayBuffer()),png),0);
    const address={country:'CN',recipient:'B09 테스트 손님',phone:'13800000000',
      region:'延吉',detail:'테스트 주소, 실제 배송 금지'};
    const destination=shown.destination;
    const saved=(await json(`${path}/address`,{method:'POST',cookie:sessionCookie,
      body:{address,expected_version:destination.version}})).body;
    assert.ok(saved.version>destination.version);
    await json(`${path}/invoices/${invoice.id}/accept`,{
      method:'POST',cookie:sessionCookie,body:{}});
    const evidence=await json(`${path}/evidence?invoice=${invoice.id}&key=${randomUUID()}`,{
      method:'POST',cookie:sessionCookie,body:png,contentType:'image/png'});
    assert.ok(evidence.body.evidence_id);
    const half=Math.floor(Number(invoice.total_cny_fen)/2);
    const amounts=[half,Number(invoice.total_cny_fen)-half];
    for (const [index,amount] of amounts.entries()) {
      const uploaded=index===0?evidence.body:
        (await json(`${path}/evidence?invoice=${invoice.id}&key=${randomUUID()}`,{
          method:'POST',cookie:sessionCookie,body:png,contentType:'image/png'})).body;
      const submitted=(await json(`${path}/receipts`,{
        method:'POST',cookie:sessionCookie,body:{evidence_id:uploaded.evidence_id,
          currency:'CNY',amount_minor:amount,payer_name:'B09 테스트 대리송금'}})).body;
      const payment=await must('broadcast_payment_command',{
        p_seller_id:seller.id,p_command:'receipt.confirm',p_data:{
          receipt_id:submitted.receipt_id,confirmed_minor:amount,receiver:'B09 테스트 알리페이',
          transaction_ref:`B09-TEST-${randomUUID()}`},p_key:randomUUID(),
      });
      assert.equal(payment.status,'confirmed');
    }
    const summary=(await json(`${path}/payments`,{cookie:sessionCookie})).body;
    assert.equal(Number(summary.find(row=>row.invoice_id===invoice.id)?.confirmed_minor),
      Number(invoice.total_cny_fen));
    const purchase=await must('broadcast_purchase_preview',{p_seller_id:seller.id});
    assert.ok(purchase.some(row=>row.product_id===product.id&&Number(row.quantity)===2));
    const committed=await must('broadcast_purchase_commit',{
      p_seller_id:seller.id,p_key:randomUUID()});
    const orderId=committed.purchase_orders.find(row=>row.supplier==='B09 테스트 거래처').id;
    const tables=await must('broadcast_purchase_tables',{
      p_seller_id:seller.id,p_purchase_order_id:orderId});
    assert.equal(tables.supplier[0].nickname,undefined);
    assert.equal(Number(tables.supplier[0].quantity),2);
    const itemId=tables.supplier[0].item_id;
    await must('broadcast_inventory_command',{
      p_seller_id:seller.id,p_command:'arrival.record',
      p_data:{purchase_item_id:itemId,good_quantity:1,defect_quantity:0},p_key:randomUUID()});
    await must('broadcast_inventory_command',{
      p_seller_id:seller.id,p_command:'allocation.commit',
      p_data:{purchase_item_id:itemId},p_key:randomUUID()});
    const status=await must('broadcast_inventory_status',{
      p_seller_id:seller.id,p_purchase_item_id:itemId});
    assert.equal(Number(status.allocated),1);
    assert.equal(Number(status.unreceived),1);
    const ready=await must('broadcast_shipment_ready',{
      p_seller_id:seller.id,p_customer_id:customer.id});
    assert.equal(ready.length,1);
    const shipped=await must('broadcast_shipment_create',{
      p_seller_id:seller.id,p_data:{customer_id:customer.id,carrier:'B09 테스트',
        tracking_number:`B09-TEST-${randomUUID()}`,
        lines:[{stock_allocation_id:ready[0].stock_allocation_id,quantity:1}]},
      p_key:randomUUID()});
    assert.equal(shipped.line_count,1);
    assert.equal((await json(`${path}/shipments`,{cookie:sessionCookie})).body.length,1);
    console.log('Cloud gateway: device approval, A/B isolation, private QR, evidence, two confirmed test receipts, purchase, partial arrival and shipment passed.');
  } finally {
    await new Promise(resolve=>gateway.close(resolve));
  }
}
