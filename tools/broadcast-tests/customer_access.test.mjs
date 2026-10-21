import {test, before, after} from 'node:test';
import assert from 'node:assert/strict';
import {createHash, randomUUID} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

const db = new PGlite();
const owner = randomUUID(), other = randomUUID(), assistant = randomUUID();
let customer, anotherCustomer, foreignCustomer, session, product, firstOrder;
const hash = value => createHash('sha256').update(value).digest('hex');
async function as(role, user, fn) {
  await db.exec(`set role ${role}`);
  await db.query("select set_config('request.jwt.claim.sub',$1,false)", [user ?? '']);
  try { return await fn(); } finally { await db.exec('reset role'); }
}
const rpc = (role, user, name, args) => as(role, user, async () =>
  (await db.query(`select public.${name}(${args.map((_, i) => `$${i+1}`).join(',')}) value`, args)).rows[0].value);
const staff = (user, name, ...args) => rpc('authenticated', user, name, args);
const guest = (name, ...args) => rpc('service_role', null, name, args);
const command = (user, name, data, seller=owner) => staff(user, 'broadcast_command',
  seller, name, JSON.stringify(data), randomUUID());

before(async () => {
  await db.exec(`create role anon; create role authenticated; create role service_role;
    create schema auth; create schema storage;
    create table storage.objects(bucket_id text not null,name text not null,primary key(bucket_id,name));
    create table auth.users(id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$
      select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
    grant usage on schema public,auth to anon,authenticated,service_role;
    grant execute on function auth.uid() to anon,authenticated,service_role;
    create table public.seller_profiles(user_id uuid primary key references auth.users(id),status text not null);`);
  for (const id of [owner,other,assistant]) await db.query('insert into auth.users values($1)',[id]);
  for (const id of [owner,other]) await db.query("insert into seller_profiles values($1,'approved')",[id]);
  for (const file of [
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
  ]) await db.exec(await readFile(new URL(`../../supabase/migrations/${file}`, import.meta.url),'utf8'));
  customer = await command(owner,'customer.create',{nickname:'손님 A'});
  anotherCustomer = await command(owner,'customer.create',{nickname:'손님 A2'});
  foreignCustomer = await command(other,'customer.create',{nickname:'다른 셀러 손님'},other);
  session = await command(owner,'session.create',{title:'방송',kind:'new',exchange_rate:190});
  product = await command(owner,'product.create',{
    session_id:session.id,supplier:'거래처',title:'데님조끼',price_krw:12000,
    colors:['검정'],sizes:['M'],
  });
  firstOrder = await command(owner,'order.create',{
    session_id:session.id,customer_id:customer.id,product_id:product.id,
    color:'검정',size:'M',quantity:1,
  });
  await command(owner,'order.create',{
    session_id:session.id,customer_id:anotherCustomer.id,product_id:product.id,
    color:'검정',size:'M',quantity:2,
  });
});
after(() => db.close());

test('고정 링크만으로는 개인정보를 볼 수 없고 다른 판매자는 링크를 발급하지 못한다', async () => {
  const link = await staff(owner,'broadcast_customer_link',owner,customer.id);
  assert.equal((await staff(owner,'broadcast_customer_link',owner,customer.id)).locator,link.locator);
  await assert.rejects(staff(other,'broadcast_customer_link',owner,customer.id),/권한/);
  await assert.rejects(staff(owner,'broadcast_customer_link',owner,foreignCustomer.id),/고객을 찾을/);
  await assert.rejects(rpc('anon',null,'broadcast_guest_view',[link.locator,hash('session')]),/permission denied/);
  await assert.rejects(guest('broadcast_guest_view',link.locator,hash('session')),/기기에서는/);
  await assert.rejects(as('authenticated',owner,()=>db.query('select * from broadcast_customer_devices')),/permission denied/);
});

test('위챗 확인 후 승인된 원래 기기만 활성화, 단회 사용, A/B 격리와 회수', async () => {
  const link = await staff(owner,'broadcast_customer_link',owner,customer.id);
  const otherLink = await staff(owner,'broadcast_customer_link',owner,anotherCustomer.id);
  const pending = hash('unpredictable pending cookie');
  const requested = await guest('broadcast_access_request',link.locator,pending);
  assert.equal(requested.status,'pending');
  assert.equal((await guest('broadcast_access_request',link.locator,pending)).request_id,requested.request_id);
  const overview = await staff(owner,'broadcast_access_overview',owner);
  assert.ok(overview.requests.some(row=>row.id===requested.request_id && row.nickname==='손님 A'));
  await assert.rejects(staff(other,'broadcast_access_approve',owner,requested.request_id),/권한/);
  const approved = await staff(owner,'broadcast_access_approve',owner,requested.request_id);
  const tokenHash = hash(approved.activation_token);
  const sessionHash = hash('unpredictable session cookie');
  await assert.rejects(guest('broadcast_access_activate',requested.request_id,hash('wrong browser'),tokenHash,sessionHash),/기존 기기/);
  await assert.rejects(guest('broadcast_access_activate',requested.request_id,pending,hash('wrong token'),sessionHash),/기존 기기/);
  const active = await guest('broadcast_access_activate',requested.request_id,pending,tokenHash,sessionHash);
  assert.equal(active.locator,link.locator);
  assert.deepEqual(await guest('broadcast_access_activate',requested.request_id,pending,tokenHash,sessionHash),active);
  await assert.rejects(guest('broadcast_access_activate',requested.request_id,pending,tokenHash,hash('new session')),/이미 사용한/);
  const view = await guest('broadcast_guest_view',link.locator,sessionHash);
  assert.equal(view.customer.nickname,'손님 A');
  assert.deepEqual(view.orders.map(row=>row.id),[firstOrder.id]);
  assert.equal(view.products.length,0,'미공개 상품은 고객에게 보이지 않아야 한다');
  await assert.rejects(guest('broadcast_guest_view',otherLink.locator,sessionHash),/기기에서는/);
  await staff(owner,'broadcast_access_revoke',owner,active.device_id);
  await assert.rejects(guest('broadcast_guest_view',link.locator,sessionHash),/기기에서는/);
  await assert.rejects(guest('broadcast_access_activate',requested.request_id,pending,tokenHash,sessionHash),
    /이미 사용한/);
});

test('승인 토큰 만료와 고객별 접근 요청 횟수 제한', async () => {
  const link = await staff(owner,'broadcast_customer_link',owner,anotherCustomer.id);
  const requests=[];
  for(let i=0;i<3;i++) requests.push(await guest('broadcast_access_request',
    link.locator,hash(`pending-${i}`)));
  await assert.rejects(guest('broadcast_access_request',link.locator,hash('pending-4')),
    /요청 횟수를 초과/);
  const approved=await staff(owner,'broadcast_access_approve',owner,requests[0].request_id);
  await db.query("update broadcast_access_requests set activation_expires_at=now()-interval '1 second' where id=$1",
    [requests[0].request_id]);
  await assert.rejects(guest('broadcast_access_activate',requests[0].request_id,
    hash('pending-0'),hash(approved.activation_token),hash('expired-session')),/활성화할 수 없습니다/);
});

test('고객 원문 추가주문과 변경요청은 관리자 검토 후 한 번만 반영된다', async () => {
  const link = await staff(owner,'broadcast_customer_link',owner,customer.id);
  const otherLink = await staff(owner,'broadcast_customer_link',owner,anotherCustomer.id);
  const pendingHash=hash(randomUUID()), sessionHash=hash(randomUUID());
  const access=await guest('broadcast_access_request',link.locator,pendingHash);
  const approved=await staff(owner,'broadcast_access_approve',owner,access.request_id);
  await guest('broadcast_access_activate',access.request_id,pendingHash,hash(approved.activation_token),sessionHash);
  const published=await command(owner,'product.publish',{id:product.id,version:product.version,visible:true});
  assert.equal(published.visible,true);
  const requestKey=randomUUID();
  const addition=await guest('broadcast_guest_request',link.locator,sessionHash,'addition',product.id,'검정 M 하나',requestKey);
  assert.equal(addition.status,'pending');
  assert.deepEqual(await guest('broadcast_guest_request',link.locator,sessionHash,'addition',product.id,'검정 M 하나',requestKey),addition);
  await assert.rejects(guest('broadcast_guest_request',link.locator,sessionHash,'addition',product.id,'빨강 M 하나',requestKey),/요청 키/);
  await assert.rejects(guest('broadcast_guest_request',otherLink.locator,sessionHash,'addition',product.id,'검정 M 하나',randomUUID()),/기기에서는/);
  const pending=await staff(owner,'broadcast_customer_request_page',owner,'pending',50);
  assert.ok(pending.some(row=>row.id===addition.id && row.raw_text==='검정 M 하나'));
  assert.ok((await guest('broadcast_guest_requests',link.locator,sessionHash)).some(row=>row.id===addition.id));
  const reviewKey=randomUUID(), reviewData={color:'검정',size:'M',quantity:1};
  const accepted=await staff(owner,'broadcast_customer_request_review',owner,addition.id,'accept',JSON.stringify(reviewData),reviewKey);
  assert.deepEqual(await staff(owner,'broadcast_customer_request_review',owner,addition.id,'accept',JSON.stringify(reviewData),reviewKey),accepted);
  const newLine=(await db.query('select * from broadcast_order_lines where id=$1',[accepted.order_line_id])).rows[0];
  assert.equal(Number(newLine.sequence),Number(addition.reserved_sequence));
  assert.equal(newLine.source,'customer_addition');
  assert.equal(newLine.original.raw_text,'검정 M 하나');
  assert.equal((await db.query('select count(*)::integer n from broadcast_order_lines where id=$1',[accepted.order_line_id])).rows[0].n,1);
  const change=await guest('broadcast_guest_request',link.locator,sessionHash,'change',firstOrder.id,'L로 바꿔주세요',randomUUID());
  const changed=await staff(owner,'broadcast_customer_request_review',owner,change.id,'accept',
    JSON.stringify({color:'검정',size:'L',quantity:1,expected_version:1}),randomUUID());
  assert.equal(changed.version,2);
  const original=(await db.query('select sequence,original,size from broadcast_order_lines where id=$1',[firstOrder.id])).rows[0];
  assert.equal(original.size,'L');
  assert.equal(Number(original.sequence),Number(firstOrder.sequence));
  assert.equal(original.original.size,'M');
  await assert.rejects(guest('broadcast_guest_request',link.locator,sessionHash,'change',randomUUID(),'바꿔주세요',randomUUID()),/변경할 주문/);
  const rejected=await guest('broadcast_guest_request',link.locator,sessionHash,'change',firstOrder.id,'취소해 주세요',randomUUID());
  const rejection=await staff(owner,'broadcast_customer_request_review',owner,rejected.id,'decline',
    JSON.stringify({resolution:'이미 확인 중입니다'}),randomUUID());
  assert.equal(rejection.status,'declined');
  assert.ok((await guest('broadcast_guest_requests',link.locator,sessionHash)).some(
    row=>row.id===rejected.id && row.resolution==='이미 확인 중입니다'));
  const stale=await guest('broadcast_guest_request',link.locator,sessionHash,'change',firstOrder.id,'검정 M으로',randomUUID());
  await assert.rejects(staff(owner,'broadcast_customer_request_review',owner,stale.id,'accept',
    JSON.stringify({color:'검정',size:'M',quantity:1,expected_version:1}),randomUUID()),/주문이 변경/);
  await db.query('update broadcast_order_lines set payment_locked=true where id=$1',[firstOrder.id]);
  await assert.rejects(guest('broadcast_guest_request',link.locator,sessionHash,'change',firstOrder.id,'또 수정',randomUUID()),/입금이 진행/);
});

test('청구 원본·환율·배송·선입금 배분을 고정하고 같은 명령만 재시도한다', async () => {
  const buyer=await command(owner,'customer.create',{nickname:'정산 손님'});
  const show=await command(owner,'session.create',{title:'정산 방송',kind:'new',exchange_rate:200,
    shipping_krw:4000,shipping_cny_fen:3000,free_shipping_count:5});
  const item=await command(owner,'product.create',{session_id:show.id,supplier:'거래처',title:'상의',price_krw:12000});
  const line=await command(owner,'order.create',{session_id:show.id,customer_id:buyer.id,
    product_id:item.id,color:'검정',size:'M',quantity:2});
  const billing=(user,name,data,key=randomUUID())=>staff(user,'broadcast_billing_command',
    owner,name,JSON.stringify(data),key);
  await assert.rejects(billing(other,'destination.country',{customer_id:buyer.id,country:'KR'}),/권한/);
  await billing(owner,'destination.country',{customer_id:buyer.id,country:'KR'});
  const deposit=await billing(owner,'deposit.verify',{customer_id:buyer.id,amount_krw:10000,
    receiver:'한국계좌',transaction_ref:'test-billing-ref-1',received_at:new Date().toISOString()});
  assert.equal(deposit.amount_krw,10000);
  await assert.rejects(billing(owner,'deposit.verify',{customer_id:buyer.id,amount_krw:10000,
    receiver:'한국계좌',transaction_ref:'test-billing-ref-1',received_at:new Date().toISOString()}),/duplicate key/);
  const billingPreview=await staff(owner,'broadcast_billing_preview',owner,buyer.id,show.id);
  assert.equal(billingPreview.country,'KR');
  assert.equal(Number(billingPreview.deposit_available_krw),10000);
  assert.equal(billingPreview.orders.length,1);
  await assert.rejects(staff(other,'broadcast_billing_preview',owner,buyer.id,show.id),/권한/);
  const key=randomUUID(),payload={customer_id:buyer.id,session_id:show.id};
  const invoice=await billing(owner,'invoice.issue',payload,key);
  assert.deepEqual(await billing(owner,'invoice.issue',payload,key),invoice);
  assert.equal(Number(invoice.subtotal_krw),24000);
  assert.equal(invoice.shipping_krw,4000);
  assert.equal(invoice.deposit_krw,10000);
  assert.equal(Number(invoice.total_krw),18000);
  assert.equal(Number(invoice.total_cny_fen),9000);
  assert.equal((await db.query('select count(*)::integer n from broadcast_invoice_lines where invoice_id=$1',[invoice.id])).rows[0].n,1);
  assert.equal((await db.query('select invoice_id from broadcast_order_lines where id=$1',[line.id])).rows[0].invoice_id,invoice.id);
  assert.equal((await db.query('select sum(amount_krw)::integer n from broadcast_deposit_allocations where invoice_id=$1',[invoice.id])).rows[0].n,10000);
  await assert.rejects(billing(owner,'invoice.issue',payload),/청구할 주문이 없습니다/);
  await assert.rejects(billing(owner,'destination.country',{customer_id:buyer.id,country:'CN'}),/판본 정정/);
  await db.query('update broadcast_sessions set exchange_rate=300,shipping_krw=7000 where id=$1',[show.id]);
  const fixed=(await db.query('select snapshot,total_krw from broadcast_invoices where id=$1',[invoice.id])).rows[0];
  assert.equal(Number(fixed.snapshot.exchange_rate),200);
  assert.equal(Number(fixed.total_krw),18000);
  const link=await staff(owner,'broadcast_customer_link',owner,buyer.id);
  const pendingHash=hash(randomUUID()),sessionHash=hash(randomUUID());
  const access=await guest('broadcast_access_request',link.locator,pendingHash);
  const approved=await staff(owner,'broadcast_access_approve',owner,access.request_id);
  await guest('broadcast_access_activate',access.request_id,pendingHash,hash(approved.activation_token),sessionHash);
  const visible=await guest('broadcast_guest_billing',link.locator,sessionHash);
  assert.equal(visible.invoices[0].id,invoice.id);
  assert.equal(visible.invoices[0].lines[0].id,line.id);
  assert.equal(visible.invoices[0].lines[0].supplier,undefined);
  assert.equal(visible.invoices[0].lines[0].created_by,undefined);
  await assert.rejects(guest('broadcast_guest_invoice_accept',link.locator,sessionHash,invoice.id),/배송주소/);
  const unrelatedLink=await staff(owner,'broadcast_customer_link',owner,anotherCustomer.id);
  await assert.rejects(guest('broadcast_guest_billing',unrelatedLink.locator,sessionHash),/기기에서는/);
  const address={country:'KR',recipient:'정산 손님',phone:'01012345678',region:'서울',detail:'테스트 1'};
  const saved=await guest('broadcast_guest_address',link.locator,sessionHash,JSON.stringify(address),1);
  assert.equal(saved.version,2);
  await assert.rejects(guest('broadcast_guest_address',link.locator,sessionHash,JSON.stringify(address),1),/주소가 변경/);
  const accepted=await guest('broadcast_guest_invoice_accept',link.locator,sessionHash,invoice.id);
  assert.equal((await guest('broadcast_guest_invoice_accept',link.locator,sessionHash,invoice.id)).accepted_at,accepted.accepted_at);
  await db.query('update broadcast_order_lines set payment_locked=true where id=$1',[line.id]);
  await assert.rejects(guest('broadcast_guest_address',link.locator,sessionHash,JSON.stringify(address),2),/입금 진행/);
});

test('복수 입금은 증빙 저장 뒤 수취자가 확정하며 초과금 환불을 별도 기록한다',async()=>{
  const buyer=await command(owner,'customer.create',{nickname:'복수입금 손님'});
  const show=await command(owner,'session.create',{title:'입금 방송',kind:'new',exchange_rate:200});
  const item=await command(owner,'product.create',{session_id:show.id,supplier:'A',title:'상의',price_krw:14000});
  const line=await command(owner,'order.create',{session_id:show.id,customer_id:buyer.id,
    product_id:item.id,color:'검정',size:'M',quantity:1});
  const billing=(name,data)=>staff(owner,'broadcast_billing_command',owner,name,JSON.stringify(data),randomUUID());
  await billing('destination.country',{customer_id:buyer.id,country:'KR'});
  const invoice=await billing('invoice.issue',{customer_id:buyer.id,session_id:show.id});
  assert.equal(Number(invoice.total_krw),18000);
  const link=await staff(owner,'broadcast_customer_link',owner,buyer.id);
  const pendingHash=hash(randomUUID()),sessionHash=hash(randomUUID());
  const access=await guest('broadcast_access_request',link.locator,pendingHash);
  const approved=await staff(owner,'broadcast_access_approve',owner,access.request_id);
  await guest('broadcast_access_activate',access.request_id,pendingHash,hash(approved.activation_token),sessionHash);
  const address={country:'KR',recipient:'손님',phone:'01012341234',region:'서울',detail:'1호'};
  await guest('broadcast_guest_address',link.locator,sessionHash,JSON.stringify(address),1);
  await guest('broadcast_guest_invoice_accept',link.locator,sessionHash,invoice.id);
  const payment=(name,data,key=randomUUID())=>staff(owner,'broadcast_payment_command',owner,name,JSON.stringify(data),key);
  const receiptIds=[];
  for(const [index,claimed] of [15000,3000,1000].entries()){
    const key=randomUUID();
    const reserved=await guest('broadcast_guest_evidence_reserve',link.locator,sessionHash,
      invoice.id,key,'image/png',8);
    assert.deepEqual(await guest('broadcast_guest_evidence_reserve',link.locator,sessionHash,
      invoice.id,key,'image/png',8),reserved);
    if(index===0){
      await assert.rejects(guest('broadcast_guest_receipt_submit',link.locator,sessionHash,
        reserved.evidence_id,'KRW',claimed,''),/저장 완료된/);
    }
    // Storage is mocked here; only the gateway may mark a verified private upload stored.
    await guest('broadcast_evidence_stored',reserved.evidence_id,8,hash(`image-${index}`));
    const submitted=await guest('broadcast_guest_receipt_submit',link.locator,sessionHash,
      reserved.evidence_id,'KRW',claimed,'대리 송금');
    assert.equal(submitted.status,'pending_review');
    if(index===0){
      const page=await staff(owner,'broadcast_receipt_page',owner,'pending_review');
      assert.ok(page.some(row=>row.id===submitted.receipt_id && row.object_key===reserved.object_key));
      await assert.rejects(staff(other,'broadcast_receipt_page',owner,'pending_review'),/권한/);
    }
    receiptIds.push(submitted.receipt_id);
    assert.equal((await db.query('select payment_locked from broadcast_order_lines where id=$1',[line.id])).rows[0].payment_locked,true);
    const confirmed=await payment('receipt.confirm',{receipt_id:submitted.receipt_id,
      confirmed_minor:claimed,receiver:'한국계좌',transaction_ref:`payment-test-${index}`});
    assert.equal(confirmed.status,'confirmed');
  }
  const summary=await guest('broadcast_guest_payment_summary',link.locator,sessionHash);
  assert.equal(Number(summary[0].confirmed_minor),19000);
  assert.equal(Number(summary[0].due_minor),18000);
  await assert.rejects(payment('refund.plan',{invoice_id:invoice.id,amount_minor:1001,reason:'초과'}),/초과 수취/);
  const planned=await payment('refund.plan',{invoice_id:invoice.id,amount_minor:1000,reason:'초과 입금'});
  assert.equal(planned.status,'planned');
  const refunded=await payment('refund.confirm',{refund_id:planned.id,transaction_ref:'refund-test-1'});
  assert.equal(refunded.status,'confirmed');
  assert.equal(Number((await guest('broadcast_guest_payment_summary',link.locator,sessionHash))[0].refund_confirmed_minor),1000);
  await assert.rejects(payment('receipt.confirm',{receipt_id:receiptIds[0],confirmed_minor:15000,
    receiver:'한국계좌',transaction_ref:'payment-test-0'}),/확인 대기/);
  const preview=await staff(owner,'broadcast_purchase_preview',owner);
  assert.equal(preview.length,1,'다른 미입금 청구와 미청구 주문은 제외한다');
  assert.ok(preview.some(row=>row.product_id===item.id && Number(row.quantity)===1));
  assert.equal(preview[0].product_title,'상의');
  assert.ok(!preview.some(row=>row.product_id===product.id),'미입금 주문은 발주에서 빠져야 한다');
  const orderKey=randomUUID();
  const committed=await staff(owner,'broadcast_purchase_commit',owner,orderKey);
  assert.deepEqual(await staff(owner,'broadcast_purchase_commit',owner,orderKey),committed);
  assert.equal(committed.order_line_count,1);
  assert.equal((await staff(owner,'broadcast_purchase_preview',owner)).length,0);
  const tables=await staff(owner,'broadcast_purchase_tables',owner,committed.purchase_orders[0].id);
  assert.equal(tables.supplier[0].quantity,1);
  assert.equal(tables.supplier[0].nickname,undefined);
  assert.equal(tables.customers[0].nickname,'복수입금 손님');
  const purchasePage=await staff(owner,'broadcast_purchase_page',owner,50,null,null);
  assert.ok(purchasePage.items.some(row=>row.id===committed.purchase_orders[0].id && Number(row.quantity)===1));
  assert.ok(!JSON.stringify(purchasePage).includes('복수입금 손님'));
  await assert.rejects(staff(other,'broadcast_purchase_tables',owner,committed.purchase_orders[0].id),/권한/);
  await assert.rejects(staff(other,'broadcast_purchase_page',owner,50,null,null),/권한/);
});

test('부분입고 10→6→추가2·불량1은 원 주문순 수량을 보존한다',async()=>{
  const buyer=await command(owner,'customer.create',{nickname:'부분입고 손님'});
  const show=await command(owner,'session.create',{title:'입고 방송',kind:'new',exchange_rate:200,
    shipping_krw:0,shipping_cny_fen:0});
  const item=await command(owner,'product.create',{session_id:show.id,supplier:'도매상',title:'바지',price_krw:10000});
  const line=await command(owner,'order.create',{session_id:show.id,customer_id:buyer.id,product_id:item.id,
    color:'검정',size:'M',quantity:10});
  const bill=(name,data)=>staff(owner,'broadcast_billing_command',owner,name,JSON.stringify(data),randomUUID());
  await bill('destination.country',{customer_id:buyer.id,country:'KR'});
  await bill('deposit.verify',{customer_id:buyer.id,amount_krw:100000,
    receiver:'한국계좌',transaction_ref:'inventory-deposit',received_at:new Date().toISOString()});
  const invoice=await bill('invoice.issue',{customer_id:buyer.id,session_id:show.id});
  assert.equal(Number(invoice.total_krw),0);
  const link=await staff(owner,'broadcast_customer_link',owner,buyer.id);
  const pendingHash=hash(randomUUID()),sessionHash=hash(randomUUID());
  const access=await guest('broadcast_access_request',link.locator,pendingHash);
  const approved=await staff(owner,'broadcast_access_approve',owner,access.request_id);
  await guest('broadcast_access_activate',access.request_id,pendingHash,hash(approved.activation_token),sessionHash);
  const address={country:'KR',recipient:'손님',phone:'01012341234',region:'서울',detail:'2호'};
  await guest('broadcast_guest_address',link.locator,sessionHash,JSON.stringify(address),1);
  await guest('broadcast_guest_invoice_accept',link.locator,sessionHash,invoice.id);
  const batch=await staff(owner,'broadcast_purchase_commit',owner,randomUUID());
  const tables=await staff(owner,'broadcast_purchase_tables',owner,batch.purchase_orders[0].id);
  assert.equal(tables.supplier[0].quantity,10);
  assert.equal(tables.customers[0].status,'미송');
  const purchaseItem=tables.supplier[0].item_id;
  const inventory=(name,data,key=randomUUID())=>staff(owner,'broadcast_inventory_command',
    owner,name,JSON.stringify(data),key);
  const firstKey=randomUUID();
  const first=await inventory('arrival.record',{purchase_item_id:purchaseItem,good_quantity:6,defect_quantity:0},firstKey);
  assert.deepEqual(await inventory('arrival.record',{purchase_item_id:purchaseItem,good_quantity:6,defect_quantity:0},firstKey),first);
  assert.equal(first.remaining_unreceived,4);
  await inventory('allocation.commit',{purchase_item_id:purchaseItem});
  let status=await staff(owner,'broadcast_inventory_status',owner,purchaseItem);
  assert.equal(Number(status.allocated),6);
  assert.equal(Number(status.unreceived),4);
  await inventory('arrival.record',{purchase_item_id:purchaseItem,good_quantity:2,defect_quantity:1});
  await inventory('allocation.commit',{purchase_item_id:purchaseItem});
  status=await staff(owner,'broadcast_inventory_status',owner,purchaseItem);
  assert.equal(Number(status.arrived_good),8);
  assert.equal(Number(status.allocated),8);
  assert.equal(Number(status.defect_waiting),1);
  assert.equal(Number(status.unreceived),1);
  const exportNow=await staff(owner,'broadcast_purchase_tables',owner,batch.purchase_orders[0].id);
  assert.equal(Number(exportNow.supplier[0].latest_received_quantity),3);
  assert.equal(Number(exportNow.supplier[0].cumulative_received_quantity),9);
  assert.equal(Number(exportNow.supplier[0].remaining_missing_quantity),1);
  assert.equal(Number(exportNow.supplier[0].defect_exchange_quantity),1);
  assert.equal(exportNow.supplier[0].nickname,undefined);
  assert.equal(exportNow.customers[0].status,'부분입고');
  await db.query("update broadcast_purchase_orders set ordered_at=now()-interval '15 days' where id=$1",[batch.purchase_orders[0].id]);
  const tasks=await staff(owner,'broadcast_tasks',owner);
  const missing=tasks.find(task=>task.type==='missing_14d'&&task.customer_id===buyer.id);
  assert.equal(Number(missing.quantity),2);
  await assert.rejects(inventory('arrival.record',{purchase_item_id:purchaseItem,good_quantity:2,defect_quantity:0}),/잔량/);
  assert.equal((await db.query('select sequence from broadcast_order_lines where id=$1',[line.id])).rows[0].sequence,line.sequence);
  const stock=(await db.query(`select sa.id,sa.quantity from broadcast_stock_allocations sa
    join broadcast_purchase_allocations pa on pa.id=sa.purchase_allocation_id
    where pa.order_line_id=$1 order by sa.quantity desc`,[line.id])).rows;
  assert.deepEqual(stock.map(row=>row.quantity),[6,2]);
  const ready=await staff(owner,'broadcast_shipment_ready',owner,buyer.id);
  assert.deepEqual(ready.map(row=>Number(row.available_quantity)).sort(),[2,6]);
  await assert.rejects(staff(other,'broadcast_shipment_ready',owner,buyer.id),/권한/);
  const ship=(tracking,stockId,qty,key=randomUUID())=>staff(owner,'broadcast_shipment_create',owner,
    JSON.stringify({customer_id:buyer.id,carrier:'택배',tracking_number:tracking,
      lines:[{stock_allocation_id:stockId,quantity:qty}]}),key);
  const firstShipKey=randomUUID();
  const firstShipment=await ship('TRACK-1',stock[0].id,6,firstShipKey);
  assert.deepEqual(await ship('TRACK-1',stock[0].id,6,firstShipKey),firstShipment);
  assert.equal((await staff(owner,'broadcast_purchase_tables',owner,batch.purchase_orders[0].id)).customers[0].status,'부분출고');
  assert.equal((await staff(owner,'broadcast_shipment_ready',owner,buyer.id)).length,1);
  await assert.rejects(ship('TRACK-OVER',stock[0].id,1),/출고 가능 수량/);
  await db.query(`update broadcast_customer_destinations set address=$1 where customer_id=$2`,
    [JSON.stringify({...address,detail:'새 주소'}),buyer.id]);
  const secondShipment=await ship('TRACK-2',stock[1].id,2);
  assert.equal((await staff(owner,'broadcast_shipment_ready',owner,buyer.id)).length,0);
  const snapshots=(await db.query('select tracking_number,address_snapshot from broadcast_shipments where customer_id=$1 order by shipped_at',[buyer.id])).rows;
  assert.equal(snapshots.find(row=>row.tracking_number==='TRACK-1').address_snapshot.detail,'2호');
  assert.equal(snapshots.find(row=>row.tracking_number==='TRACK-2').address_snapshot.detail,'새 주소');
  const addressTask=(await staff(owner,'broadcast_tasks',owner)).find(task=>task.type==='address_change'&&task.customer_id===buyer.id);
  assert.ok(addressTask);
  await staff(owner,'broadcast_task_resolve_address',owner,addressTask.source_id);
  assert.ok(!(await staff(owner,'broadcast_tasks',owner)).some(task=>task.type==='address_change'&&task.source_id===addressTask.source_id));
  assert.ok((await staff(owner,'broadcast_tasks',owner)).some(task=>task.type==='missing_14d'&&task.customer_id===buyer.id));
  const overdue=await staff(owner,'broadcast_missing_detail',owner,buyer.id);
  assert.ok(overdue.some(row=>row.product_title==='바지' && row.supplier==='도매상'
    && Number(row.missing_quantity)===2 && Number(row.days)>=14));
  await assert.rejects(staff(other,'broadcast_missing_detail',owner,buyer.id),/권한/);
  const shipped=await guest('broadcast_guest_shipments',link.locator,sessionHash);
  assert.equal(shipped.length,2);
  assert.deepEqual(shipped.map(row=>row.tracking_number).sort(),['TRACK-1','TRACK-2']);
  assert.equal(firstShipment.line_count,1);
  assert.equal(secondShipment.line_count,1);
  const defect=(await db.query(`select d.id from broadcast_defect_exchanges d
    join broadcast_arrivals a on a.id=d.arrival_id where a.purchase_item_id=$1`,[purchaseItem])).rows[0];
  const waitingDefects=await staff(owner,'broadcast_defect_page',owner,purchaseItem);
  assert.equal(waitingDefects.length,1);
  assert.equal(Number(waitingDefects[0].quantity),1);
  await assert.rejects(staff(other,'broadcast_defect_page',owner,purchaseItem),/권한/);
  const replaced=await inventory('exchange.receive',{purchase_item_id:purchaseItem,defect_id:defect.id,quantity:1});
  assert.equal(replaced.replaced_quantity,1);
  assert.equal((await staff(owner,'broadcast_defect_page',owner,purchaseItem)).length,0);
  await inventory('allocation.commit',{purchase_item_id:purchaseItem});
  const afterExchange=await staff(owner,'broadcast_inventory_status',owner,purchaseItem);
  assert.equal(Number(afterExchange.defect_waiting),0);
  assert.equal(Number(afterExchange.allocated),9);
  assert.equal(Number(afterExchange.unreceived),1);
});

test('72시간 무입금은 자동취소하지 않고 관리자 확인 취소 후 처리함에서 사라진다',async()=>{
  const buyer=await command(owner,'customer.create',{nickname:'미입금 손님'});
  const show=await command(owner,'session.create',{title:'미입금 방송',kind:'new',exchange_rate:200});
  const item=await command(owner,'product.create',{session_id:show.id,supplier:'A',title:'조끼',price_krw:10000});
  const line=await command(owner,'order.create',{session_id:show.id,customer_id:buyer.id,
    product_id:item.id,color:'빨강',size:'M',quantity:1});
  const bill=(name,data)=>staff(owner,'broadcast_billing_command',owner,name,JSON.stringify(data),randomUUID());
  await bill('destination.country',{customer_id:buyer.id,country:'KR'});
  const invoice=await bill('invoice.issue',{customer_id:buyer.id,session_id:show.id});
  await db.query("update broadcast_invoices set issued_at=now()-interval '73 hours' where id=$1",[invoice.id]);
  let tasks=await staff(owner,'broadcast_tasks',owner);
  assert.ok(tasks.some(task=>task.type==='unpaid_72h'&&task.source_id===invoice.id));
  assert.equal((await db.query('select status from broadcast_invoices where id=$1',[invoice.id])).rows[0].status,'issued');
  await assert.rejects(staff(other,'broadcast_invoice_cancel',owner,invoice.id,'3일 미입금',randomUUID()),/권한/);
  const key=randomUUID();
  const cancelled=await staff(owner,'broadcast_invoice_cancel',owner,invoice.id,'3일 미입금',key);
  assert.deepEqual(await staff(owner,'broadcast_invoice_cancel',owner,invoice.id,'3일 미입금',key),cancelled);
  tasks=await staff(owner,'broadcast_tasks',owner);
  assert.ok(!tasks.some(task=>task.type==='unpaid_72h'&&task.source_id===invoice.id));
  assert.equal((await db.query('select cancelled from broadcast_order_lines where id=$1',[line.id])).rows[0].cancelled,true);
});

test('보완 증빙은 같은 입금 건에 연결하고 과거 캡처 재사용과 보완 중 확정을 막는다',async()=>{
  const buyer=await command(owner,'customer.create',{nickname:'증빙 보완 손님'});
  const show=await command(owner,'session.create',{title:'보완 방송',kind:'new',exchange_rate:200});
  const item=await command(owner,'product.create',{session_id:show.id,supplier:'A',title:'상의',price_krw:12000});
  await command(owner,'order.create',{session_id:show.id,customer_id:buyer.id,
    product_id:item.id,color:'검정',size:'M',quantity:1});
  const bill=(name,data)=>staff(owner,'broadcast_billing_command',owner,name,JSON.stringify(data),randomUUID());
  await bill('destination.country',{customer_id:buyer.id,country:'KR'});
  const invoice=await bill('invoice.issue',{customer_id:buyer.id,session_id:show.id});
  const link=await staff(owner,'broadcast_customer_link',owner,buyer.id);
  const pending=hash(randomUUID()),sessionHash=hash(randomUUID());
  const request=await guest('broadcast_access_request',link.locator,pending);
  const approval=await staff(owner,'broadcast_access_approve',owner,request.request_id);
  await guest('broadcast_access_activate',request.request_id,pending,hash(approval.activation_token),sessionHash);
  await guest('broadcast_guest_address',link.locator,sessionHash,JSON.stringify({
    country:'KR',recipient:'손님',phone:'01012345678',region:'서울',detail:'1호'}),1);
  await guest('broadcast_guest_invoice_accept',link.locator,sessionHash,invoice.id);
  const evidence=async label=>{
    const row=await guest('broadcast_guest_evidence_reserve',link.locator,sessionHash,
      invoice.id,randomUUID(),'image/png',8);
    await guest('broadcast_evidence_stored',row.evidence_id,8,hash(label));
    return row.evidence_id;
  };
  const first=await evidence('first');
  const receipt=await guest('broadcast_guest_receipt_submit',link.locator,sessionHash,
    first,'KRW',16000,'대리송금');
  const key=randomUUID();
  const info=await staff(owner,'broadcast_receipt_request_info',owner,receipt.receipt_id,'거래내역이 잘리지 않게 다시 올려주세요',key);
  assert.deepEqual(await staff(owner,'broadcast_receipt_request_info',owner,receipt.receipt_id,
    '거래내역이 잘리지 않게 다시 올려주세요',key),info);
  assert.equal((await guest('broadcast_guest_receipt_needs_info',link.locator,sessionHash))[0].receipt_id,receipt.receipt_id);
  await assert.rejects(guest('broadcast_guest_receipt_needs_info',link.locator,hash('other')),/기기에서/);
  await assert.rejects(staff(owner,'broadcast_payment_command',owner,'receipt.confirm',JSON.stringify({
    receipt_id:receipt.receipt_id,confirmed_minor:16000,receiver:'한국계좌',transaction_ref:'supplement-1'}),randomUUID()),/보완/);
  const second=await evidence('second');
  await assert.rejects(guest('broadcast_guest_receipt_supplement',link.locator,hash('other'),receipt.receipt_id,second),/기기에서/);
  assert.deepEqual(await guest('broadcast_guest_receipt_supplement',link.locator,sessionHash,receipt.receipt_id,second),
    {receipt_id:receipt.receipt_id,status:'pending_review'});
  assert.deepEqual(await guest('broadcast_guest_receipt_supplement',link.locator,sessionHash,receipt.receipt_id,second),
    {receipt_id:receipt.receipt_id,status:'pending_review'});
  assert.deepEqual(await guest('broadcast_guest_receipt_needs_info',link.locator,sessionHash),[]);
  await assert.rejects(guest('broadcast_guest_receipt_submit',link.locator,sessionHash,
    first,'KRW',16000,'대리송금'),/이미 제출한 증빙/);
  assert.equal(Number((await db.query('select count(*) n from broadcast_receipts where id=$1',[receipt.receipt_id])).rows[0].n),1);
  assert.equal(Number((await db.query('select count(*) n from broadcast_receipt_evidence_history where receipt_id=$1',[receipt.receipt_id])).rows[0].n),2);
  const confirmed=await staff(owner,'broadcast_payment_command',owner,'receipt.confirm',JSON.stringify({
    receipt_id:receipt.receipt_id,confirmed_minor:16000,receiver:'한국계좌',transaction_ref:'supplement-2'}),randomUUID());
  assert.equal(confirmed.status,'confirmed');
});

test('확인된 수취 안내는 발행 당시 청구에 고정되고 이후 변경은 새 청구에만 반영된다',async()=>{
  const commandReceiver=(data,key=randomUUID())=>staff(owner,'broadcast_receiver_command',
    owner,JSON.stringify(data),key);
  const first={method:'wechat',holder:'샘플 판매자',instructions:'테스트 위챗 ID A',
    active:true,verified:true};
  await assert.rejects(commandReceiver({...first,verified:false}),/확인한 뒤/);
  await assert.rejects(staff(other,'broadcast_receiver_command',owner,JSON.stringify(first),randomUUID()),/권한/);
  const key=randomUUID();
  const configured=await commandReceiver(first,key);
  assert.deepEqual(await commandReceiver(first,key),configured);
  assert.equal(configured.currency,'CNY');
  assert.equal((await staff(owner,'broadcast_receiver_page',owner))[0].holder,'샘플 판매자');
  const show=await command(owner,'session.create',{title:'수취 방송',kind:'new',exchange_rate:200});
  const item=await command(owner,'product.create',{session_id:show.id,supplier:'A',title:'셔츠',price_krw:10000});
  const issue=async nickname=>{
    const buyer=await command(owner,'customer.create',{nickname});
    await command(owner,'order.create',{session_id:show.id,customer_id:buyer.id,
      product_id:item.id,color:'검정',size:'M',quantity:1});
    await staff(owner,'broadcast_billing_command',owner,'destination.country',
      JSON.stringify({customer_id:buyer.id,country:'CN'}),randomUUID());
    const invoice=await staff(owner,'broadcast_billing_command',owner,'invoice.issue',
      JSON.stringify({customer_id:buyer.id,session_id:show.id}),randomUUID());
    return {buyer,invoice};
  };
  const old=await issue('수취 A');
  assert.equal(old.invoice.snapshot.receiver_snapshots[0].instructions,'테스트 위챗 ID A');
  await commandReceiver({...first,instructions:'테스트 위챗 ID B'});
  const current=await issue('수취 B');
  assert.equal(current.invoice.snapshot.receiver_snapshots[0].instructions,'테스트 위챗 ID B');
  assert.equal((await db.query('select snapshot from broadcast_invoices where id=$1',[old.invoice.id]))
    .rows[0].snapshot.receiver_snapshots[0].instructions,'테스트 위챗 ID A');
  await commandReceiver({...first,active:false,verified:false});
  const stopped=await issue('수취 중지');
  assert.deepEqual(stopped.invoice.snapshot.receiver_snapshots,[]);
  const link=await staff(owner,'broadcast_customer_link',owner,old.buyer.id);
  const pending=hash(randomUUID()),sessionHash=hash(randomUUID());
  const request=await guest('broadcast_access_request',link.locator,pending);
  const approval=await staff(owner,'broadcast_access_approve',owner,request.request_id);
  await guest('broadcast_access_activate',request.request_id,pending,hash(approval.activation_token),sessionHash);
  const billing=await guest('broadcast_guest_billing',link.locator,sessionHash);
  assert.equal(billing.invoices[0].snapshot.receiver_snapshots[0].instructions,'테스트 위챗 ID A');
  assert.ok(!JSON.stringify(billing).includes('테스트 위챗 ID B'));
});

test('비공개 수취 QR은 업로드 확인 후 청구에 고정되고 해당 고객 기기만 조회한다',async()=>{
  const receiver={method:'alipay',holder:'테스트 판매자',instructions:'알리페이 계정 확인',
    active:true,verified:true};
  await staff(owner,'broadcast_receiver_command',owner,JSON.stringify(receiver),randomUUID());
  const firstId=randomUUID(),path=`${owner}/${firstId}.png`;
  await db.query('insert into storage.objects(bucket_id,name) values($1,$2)',
    ['broadcast-receiver-qr',path]);
  const key=randomUUID();
  const attach=(actor,id=firstId,k=key)=>staff(actor,'broadcast_receiver_qr_attach',owner,
    'alipay',id,'image/png',k);
  await assert.rejects(attach(other,firstId,randomUUID()),/권한/);
  await assert.rejects(attach(owner,randomUUID(),randomUUID()),/업로드된/);
  assert.deepEqual(await attach(owner),await attach(owner));
  const show=await command(owner,'session.create',{title:'QR 방송',kind:'new',exchange_rate:200});
  const item=await command(owner,'product.create',{session_id:show.id,supplier:'A',title:'스커트',price_krw:10000});
  const buyer=await command(owner,'customer.create',{nickname:'QR 손님'});
  await command(owner,'order.create',{session_id:show.id,customer_id:buyer.id,
    product_id:item.id,color:'검정',size:'M',quantity:1});
  await staff(owner,'broadcast_billing_command',owner,'destination.country',
    JSON.stringify({customer_id:buyer.id,country:'CN'}),randomUUID());
  const invoice=await staff(owner,'broadcast_billing_command',owner,'invoice.issue',
    JSON.stringify({customer_id:buyer.id,session_id:show.id}),randomUUID());
  const link=await staff(owner,'broadcast_customer_link',owner,buyer.id);
  const pending=hash(randomUUID()),sessionHash=hash(randomUUID());
  const access=await guest('broadcast_access_request',link.locator,pending);
  const approved=await staff(owner,'broadcast_access_approve',owner,access.request_id);
  await guest('broadcast_access_activate',access.request_id,pending,hash(approved.activation_token),sessionHash);
  const qr=await guest('broadcast_guest_receiver_qr',link.locator,sessionHash,invoice.id,'alipay');
  assert.deepEqual(qr,{object_key:path,content_type:'image/png'});
  await assert.rejects(guest('broadcast_guest_receiver_qr',link.locator,hash('other'),invoice.id,'alipay'),/기기에서는/);
  await assert.rejects(guest('broadcast_guest_receiver_qr',link.locator,sessionHash,invoice.id,'wechat'),/QR이 없습니다/);
  const secondId=randomUUID();
  await db.query('insert into storage.objects(bucket_id,name) values($1,$2)',
    ['broadcast-receiver-qr',`${owner}/${secondId}.png`]);
  await attach(owner,secondId,randomUUID());
  assert.equal((await guest('broadcast_guest_receiver_qr',link.locator,sessionHash,invoice.id,'alipay')).object_key,path);
  await staff(owner,'broadcast_receiver_command',owner,
    JSON.stringify({...receiver,instructions:'새 수취 안내'}),randomUUID());
  assert.equal((await staff(owner,'broadcast_receiver_page',owner)).find(r=>r.method==='alipay').has_qr,false);
  assert.equal((await guest('broadcast_guest_receiver_qr',link.locator,sessionHash,invoice.id,'alipay')).object_key,path);
});

test('청구 상품 제외 재발행은 원판·주문순서·선입금 원장을 보존하고 새 판본 재동의를 요구한다',async()=>{
  const buyer=await command(owner,'customer.create',{nickname:'정정 손님'});
  const show=await command(owner,'session.create',{title:'정정 방송',kind:'new',exchange_rate:200});
  const a=await command(owner,'product.create',{session_id:show.id,supplier:'A',title:'니트',price_krw:10000});
  const b=await command(owner,'product.create',{session_id:show.id,supplier:'B',title:'셔츠',price_krw:20000});
  const first=await command(owner,'order.create',{session_id:show.id,customer_id:buyer.id,
    product_id:a.id,color:'검정',size:'M',quantity:1});
  const second=await command(owner,'order.create',{session_id:show.id,customer_id:buyer.id,
    product_id:b.id,color:'흰색',size:'L',quantity:1});
  const bill=(name,data)=>staff(owner,'broadcast_billing_command',owner,name,JSON.stringify(data),randomUUID());
  await bill('destination.country',{customer_id:buyer.id,country:'KR'});
  await bill('deposit.verify',{customer_id:buyer.id,amount_krw:10000,
    receiver:'테스트 계좌',transaction_ref:'revision-deposit-1',received_at:new Date().toISOString()});
  const original=await bill('invoice.issue',{customer_id:buyer.id,session_id:show.id});
  assert.equal(Number(original.total_krw),24000);
  const revision=(invoiceId,exclude,reason,key=randomUUID())=>staff(owner,
    'broadcast_invoice_revise',owner,invoiceId,exclude,reason,key);
  await assert.rejects(revision(original.id,[randomUUID()],'고객 제외 요청'),/현재 정산서/);
  assert.equal((await db.query('select status from broadcast_invoices where id=$1',[original.id])).rows[0].status,'issued');
  assert.equal((await db.query('select status from broadcast_invoices where id=$1',[original.id])).rows[0].status,'issued');
  const key=randomUUID();
  const revised=await revision(original.id,[second.id],'고객이 셔츠를 제외 요청함',key);
  assert.deepEqual(await revision(original.id,[second.id],'고객이 셔츠를 제외 요청함',key),revised);
  assert.equal(revised.version,2);
  assert.equal(revised.series_id,original.series_id);
  assert.equal(revised.accepted_at,null);
  assert.equal(Number(revised.total_krw),4000);
  assert.equal(revised.snapshot.revised_from,original.id);
  assert.equal((await db.query('select status,snapshot from broadcast_invoices where id=$1',[original.id])).rows[0].status,'superseded');
  assert.equal((await db.query('select count(*) n from broadcast_invoice_lines where invoice_id=$1',[original.id])).rows[0].n,2);
  assert.equal((await db.query('select cancelled,invoice_id from broadcast_order_lines where id=$1',[second.id])).rows[0].cancelled,true);
  assert.equal((await db.query('select invoice_id from broadcast_order_lines where id=$1',[first.id])).rows[0].invoice_id,revised.id);
  assert.equal((await db.query('select count(*) n from broadcast_deposit_allocations where invoice_id=$1 and reversed_at is not null',[original.id])).rows[0].n,1);
  assert.equal((await db.query('select count(*) n from broadcast_deposit_allocations where invoice_id=$1 and reversed_at is null',[revised.id])).rows[0].n,1);
  await assert.rejects(revision(original.id,[],'다시 정정'),/현재 발행된/);
  const link=await staff(owner,'broadcast_customer_link',owner,buyer.id);
  const pending=hash(randomUUID()),sessionHash=hash(randomUUID());
  const request=await guest('broadcast_access_request',link.locator,pending);
  const approval=await staff(owner,'broadcast_access_approve',owner,request.request_id);
  await guest('broadcast_access_activate',request.request_id,pending,hash(approval.activation_token),sessionHash);
  await guest('broadcast_guest_address',link.locator,sessionHash,JSON.stringify({
    country:'KR',recipient:'손님',phone:'01012345678',region:'서울',detail:'1호'}),1);
  await assert.rejects(guest('broadcast_guest_invoice_accept',link.locator,sessionHash,original.id),/확인 가능한/);
  await guest('broadcast_guest_invoice_accept',link.locator,sessionHash,revised.id);
  const evidence=await guest('broadcast_guest_evidence_reserve',link.locator,sessionHash,
    revised.id,randomUUID(),'image/png',8);
  assert.ok(evidence.evidence_id);
  await assert.rejects(revision(revised.id,[],'입금 중 정정'),/증빙·입금·발주/);
});

test('정산서의 모든 상품 제외는 빈 재발행 없이 무효화하고 선입금을 반환한다',async()=>{
  const buyer=await command(owner,'customer.create',{nickname:'전량 제외 손님'});
  const show=await command(owner,'session.create',{title:'전량 제외 방송',kind:'new',exchange_rate:200});
  const item=await command(owner,'product.create',{
    session_id:show.id,supplier:'A',title:'니트',price_krw:10000});
  const line=await command(owner,'order.create',{
    session_id:show.id,customer_id:buyer.id,product_id:item.id,
    color:'검정',size:'M',quantity:1});
  const bill=(name,data)=>staff(owner,'broadcast_billing_command',owner,name,JSON.stringify(data),randomUUID());
  await bill('destination.country',{customer_id:buyer.id,country:'KR'});
  await bill('deposit.verify',{customer_id:buyer.id,amount_krw:10000,
    receiver:'테스트 계좌',transaction_ref:'full-exclusion-deposit',received_at:new Date().toISOString()});
  const invoice=await bill('invoice.issue',{customer_id:buyer.id,session_id:show.id});
  const key=randomUUID();
  const revise=(k=key)=>staff(owner,'broadcast_invoice_revise',owner,invoice.id,[line.id],'전량 제외',k);
  const result=await revise();
  assert.deepEqual(result,{status:'void',invoice_id:invoice.id});
  assert.deepEqual(await revise(),result);
  assert.equal((await db.query('select status from broadcast_invoices where id=$1',[invoice.id])).rows[0].status,'void');
  assert.equal((await db.query('select cancelled,invoice_id from broadcast_order_lines where id=$1',[line.id])).rows[0].cancelled,true);
  assert.equal((await db.query('select count(*) n from broadcast_deposit_allocations where invoice_id=$1 and reversed_at is not null',[invoice.id])).rows[0].n,1);
  await assert.rejects(revise(randomUUID()),/현재 발행된 정산서/);
});

test('청구된 고객 수정 요청은 행 정정·재청구·요청 해결을 한 거래에서 처리한다',async()=>{
  const buyer=await command(owner,'customer.create',{nickname:'청구 수정 손님'});
  const show=await command(owner,'session.create',{title:'청구 수정 방송',kind:'new',exchange_rate:200});
  const item=await command(owner,'product.create',{session_id:show.id,supplier:'A',title:'조끼',price_krw:10000});
  const line=await command(owner,'order.create',{session_id:show.id,customer_id:buyer.id,
    product_id:item.id,color:'검정',size:'M',quantity:1});
  const bill=(name,data)=>staff(owner,'broadcast_billing_command',owner,name,JSON.stringify(data),randomUUID());
  await bill('destination.country',{customer_id:buyer.id,country:'KR'});
  const original=await bill('invoice.issue',{customer_id:buyer.id,session_id:show.id});
  const link=await staff(owner,'broadcast_customer_link',owner,buyer.id);
  const pending=hash(randomUUID()),sessionHash=hash(randomUUID());
  const access=await guest('broadcast_access_request',link.locator,pending);
  const approved=await staff(owner,'broadcast_access_approve',owner,access.request_id);
  await guest('broadcast_access_activate',access.request_id,pending,hash(approved.activation_token),sessionHash);
  const request=await guest('broadcast_guest_request',link.locator,sessionHash,
    'change',line.id,'빨강 L 두 개로 바꿔주세요',randomUUID());
  const row=(await staff(owner,'broadcast_customer_request_page',owner,'pending',100))
    .find(r=>r.id===request.id);
  assert.equal(row.invoice_id,original.id);
  const change={color:'빨강',size:'L',quantity:2,unit_price_krw:10000,
    expected_version:row.current_version,cancelled:false};
  const key=randomUUID();
  const revise=(actor,k=key)=>staff(actor,'broadcast_invoice_revise_request',owner,
    original.id,request.id,JSON.stringify(change),'고객 요청 반영',k);
  await assert.rejects(revise(other,randomUUID()),/권한/);
  const revised=await revise(owner);
  assert.deepEqual(await revise(owner),revised);
  assert.equal(revised.version,2);
  assert.equal(Number(revised.total_krw),24000);
  assert.equal(revised.accepted_at,null);
  const current=(await db.query('select * from broadcast_order_lines where id=$1',[line.id])).rows[0];
  assert.equal(current.original.product.title,'조끼');
  assert.equal(current.sequence,line.sequence);
  assert.equal(current.color,'빨강');
  assert.equal(current.quantity,2);
  assert.equal(current.invoice_id,revised.id);
  assert.equal((await db.query('select status from broadcast_customer_requests where id=$1',[request.id])).rows[0].status,'accepted');
  assert.equal((await db.query('select status from broadcast_invoices where id=$1',[original.id])).rows[0].status,'superseded');
  await assert.rejects(staff(owner,'broadcast_invoice_revise_request',owner,
    original.id,request.id,JSON.stringify(change),'고객 요청 반영',randomUUID()),/처리 대기/);
});

test('실제 선입금 반환은 미배분 잔액만 기록하고 다음 청구에서 재차감하지 않는다',async()=>{
  const buyer=await command(owner,'customer.create',{nickname:'선입금 반환 손님'});
  const show=await command(owner,'session.create',{title:'반환 방송',kind:'new',exchange_rate:200});
  const item=await command(owner,'product.create',{session_id:show.id,supplier:'A',title:'상의',price_krw:10000});
  await command(owner,'order.create',{session_id:show.id,customer_id:buyer.id,
    product_id:item.id,color:'검정',size:'M',quantity:1});
  const bill=(name,data)=>staff(owner,'broadcast_billing_command',owner,name,JSON.stringify(data),randomUUID());
  await bill('destination.country',{customer_id:buyer.id,country:'KR'});
  const deposit=await bill('deposit.verify',{customer_id:buyer.id,amount_krw:10000,
    receiver:'테스트 계좌',transaction_ref:'return-deposit-1',received_at:new Date().toISOString()});
  const invoice=await bill('invoice.issue',{customer_id:buyer.id,session_id:show.id});
  const data={deposit_id:deposit.id,amount_krw:6000,receiver:'테스트 계좌',
    transaction_ref:'return-transfer-1',reason:'고객 요청 반환',returned_at:new Date().toISOString()};
  const refund=(actor,payload,key=randomUUID())=>staff(actor,'broadcast_deposit_return',owner,JSON.stringify(payload),key);
  await assert.rejects(refund(other,data),/권한/);
  await assert.rejects(staff(owner,'broadcast_deposit_void',owner,deposit.id,
    '사용된 선입금',randomUUID()),/청구 배분/);
  await assert.rejects(refund(owner,data),/미배분/);
  await staff(owner,'broadcast_invoice_cancel',owner,invoice.id,'고객 요청',randomUUID());
  const key=randomUUID();
  const returned=await refund(owner,data,key);
  assert.deepEqual(await refund(owner,data,key),returned);
  assert.equal(Number(returned.amount_krw),6000);
  await assert.rejects(refund(owner,{...data,amount_krw:5000,transaction_ref:'return-transfer-2'}),/미배분/);
  const preview=await staff(owner,'broadcast_billing_preview',owner,buyer.id,show.id);
  assert.equal(Number(preview.deposit_available_krw),4000);
  const nextShow=await command(owner,'session.create',{title:'다음 방송',kind:'new',exchange_rate:200});
  const nextItem=await command(owner,'product.create',{session_id:nextShow.id,supplier:'A',title:'치마',price_krw:10000});
  await command(owner,'order.create',{session_id:nextShow.id,customer_id:buyer.id,
    product_id:nextItem.id,color:'검정',size:'M',quantity:1});
  const next=await bill('invoice.issue',{customer_id:buyer.id,session_id:nextShow.id});
  assert.equal(Number(next.deposit_krw),4000);
  assert.equal(Number(next.total_krw),10000);
  const link=await staff(owner,'broadcast_customer_link',owner,buyer.id);
  const pending=hash(randomUUID()),sessionHash=hash(randomUUID());
  const access=await guest('broadcast_access_request',link.locator,pending);
  const approved=await staff(owner,'broadcast_access_approve',owner,access.request_id);
  await guest('broadcast_access_activate',access.request_id,pending,hash(approved.activation_token),sessionHash);
  const visible=await guest('broadcast_guest_deposit_returns',link.locator,sessionHash);
  assert.equal(Number(visible[0].amount_krw),6000);
  assert.equal(visible[0].transaction_ref,undefined);
  await assert.rejects(guest('broadcast_guest_deposit_returns',link.locator,hash('other')),/기기에서/);
});

test('청구의 마지막 상품 취소 요청은 새 빈 청구 없이 기존 청구를 무효화한다',async()=>{
  const buyer=await command(owner,'customer.create',{nickname:'전량 취소 손님'});
  const show=await command(owner,'session.create',{title:'취소 방송',kind:'new',exchange_rate:200});
  const item=await command(owner,'product.create',{session_id:show.id,supplier:'A',title:'치마',price_krw:10000});
  const line=await command(owner,'order.create',{session_id:show.id,customer_id:buyer.id,
    product_id:item.id,color:'검정',size:'M',quantity:1});
  const bill=(name,data)=>staff(owner,'broadcast_billing_command',owner,name,JSON.stringify(data),randomUUID());
  await bill('destination.country',{customer_id:buyer.id,country:'KR'});
  const invoice=await bill('invoice.issue',{customer_id:buyer.id,session_id:show.id});
  const link=await staff(owner,'broadcast_customer_link',owner,buyer.id);
  const pending=hash(randomUUID()),sessionHash=hash(randomUUID());
  const access=await guest('broadcast_access_request',link.locator,pending);
  const approved=await staff(owner,'broadcast_access_approve',owner,access.request_id);
  await guest('broadcast_access_activate',access.request_id,pending,hash(approved.activation_token),sessionHash);
  const request=await guest('broadcast_guest_request',link.locator,sessionHash,
    'change',line.id,'이 상품 취소해주세요',randomUUID());
  const key=randomUUID();
  const change={cancelled:true,expected_version:line.version};
  const revise=()=>staff(owner,'broadcast_invoice_revise_request',owner,invoice.id,
    request.id,JSON.stringify(change),'고객 취소 요청',key);
  const result=await revise();
  assert.deepEqual(await revise(),result);
  assert.equal(result.status,'void');
  assert.equal((await db.query('select status from broadcast_invoices where id=$1',[invoice.id])).rows[0].status,'void');
  assert.equal((await db.query('select cancelled from broadcast_order_lines where id=$1',[line.id])).rows[0].cancelled,true);
  assert.equal((await db.query('select count(*)::integer n from broadcast_invoices where seller_id=$1 and customer_id=$2',[owner,buyer.id])).rows[0].n,1);
  assert.equal((await guest('broadcast_guest_billing',link.locator,sessionHash)).invoices[0].status,'void');
});

test('오기입 선입금은 사용 전 무효화하고 원 수취 기록과 사유를 보존한다',async()=>{
  const buyer=await command(owner,'customer.create',{nickname:'오기입 손님'});
  const show=await command(owner,'session.create',{title:'오기입 방송',kind:'new',exchange_rate:200});
  const item=await command(owner,'product.create',{session_id:show.id,supplier:'A',title:'모자',price_krw:10000});
  await command(owner,'order.create',{session_id:show.id,customer_id:buyer.id,
    product_id:item.id,color:'검정',size:'M',quantity:1});
  const bill=(name,data)=>staff(owner,'broadcast_billing_command',owner,name,JSON.stringify(data),randomUUID());
  await bill('destination.country',{customer_id:buyer.id,country:'KR'});
  const deposit=await bill('deposit.verify',{customer_id:buyer.id,amount_krw:10000,
    receiver:'테스트 계좌',transaction_ref:'mistake-1',received_at:new Date().toISOString()});
  const key=randomUUID();
  const voidIt=(actor,k=key)=>staff(actor,'broadcast_deposit_void',owner,deposit.id,'다른 고객 입금',k);
  await assert.rejects(voidIt(other,randomUUID()),/권한/);
  const done=await voidIt(owner);
  assert.deepEqual(await voidIt(owner),done);
  assert.equal((await db.query('select amount_krw,void_reason from broadcast_deposits where id=$1',
    [deposit.id])).rows[0].amount_krw,10000);
  assert.equal((await db.query('select void_reason from broadcast_deposits where id=$1',
    [deposit.id])).rows[0].void_reason,'다른 고객 입금');
  const preview=await staff(owner,'broadcast_billing_preview',owner,buyer.id,show.id);
  assert.equal(Number(preview.deposit_available_krw),0);
  assert.equal(preview.deposits.length,0);
  const invoice=await bill('invoice.issue',{customer_id:buyer.id,session_id:show.id});
  assert.equal(Number(invoice.deposit_krw),0);
  await assert.rejects(staff(owner,'broadcast_deposit_void',owner,deposit.id,'다시',randomUUID()),/찾을 수/);
});

test('판매자 입력 실수는 고객 요청 없이 단가·수량을 정정하고 판본을 다시 발행한다',async()=>{
  const buyer=await command(owner,'customer.create',{nickname:'판매자 정정 손님'});
  const show=await command(owner,'session.create',{title:'정정 방송',kind:'new',exchange_rate:200});
  const item=await command(owner,'product.create',{session_id:show.id,supplier:'A',title:'조끼',price_krw:10000});
  const line=await command(owner,'order.create',{session_id:show.id,customer_id:buyer.id,
    product_id:item.id,color:'검정',size:'M',quantity:1});
  const bill=(name,data)=>staff(owner,'broadcast_billing_command',owner,name,JSON.stringify(data),randomUUID());
  await bill('destination.country',{customer_id:buyer.id,country:'KR'});
  const invoice=await bill('invoice.issue',{customer_id:buyer.id,session_id:show.id});
  const before=await staff(owner,'broadcast_invoice_revision_preview',owner,buyer.id,show.id);
  assert.equal(before.lines[0].current_version,line.version);
  const change={order_line_id:line.id,expected_version:line.version,
    color:'빨강',size:'L',quantity:2,unit_price_krw:9000,cancelled:false};
  const key=randomUUID();
  const revise=(actor,k=key)=>staff(actor,'broadcast_invoice_revise_line',owner,
    invoice.id,JSON.stringify(change),'상품 단가 오기입',k);
  await assert.rejects(revise(other,randomUUID()),/권한/);
  const revised=await revise(owner);
  assert.deepEqual(await revise(owner),revised);
  assert.equal(revised.version,2);
  assert.equal(Number(revised.total_krw),22000);
  assert.equal((await db.query('select color,size,quantity,unit_price_krw from broadcast_order_lines where id=$1',
    [line.id])).rows[0].unit_price_krw,9000);
  assert.equal((await db.query('select status from broadcast_invoices where id=$1',[invoice.id])).rows[0].status,'superseded');
  await assert.rejects(staff(owner,'broadcast_invoice_revise_line',owner,invoice.id,
    JSON.stringify(change),'다시 정정',randomUUID()),/현재 청구서/);
});

test('입금 후 판매자 주소 정정은 감사기록을 남기고 이전 출고 주소를 보존한다',async()=>{
  const buyer=await command(owner,'customer.create',{nickname:'주소 정정 손님'});
  const show=await command(owner,'session.create',{title:'주소 방송',kind:'new',exchange_rate:200});
  const item=await command(owner,'product.create',{session_id:show.id,supplier:'A',title:'바지',price_krw:10000});
  const line=await command(owner,'order.create',{session_id:show.id,customer_id:buyer.id,
    product_id:item.id,color:'검정',size:'M',quantity:1});
  const bill=(name,data)=>staff(owner,'broadcast_billing_command',owner,name,JSON.stringify(data),randomUUID());
  await bill('destination.country',{customer_id:buyer.id,country:'KR'});
  await bill('invoice.issue',{customer_id:buyer.id,session_id:show.id});
  const link=await staff(owner,'broadcast_customer_link',owner,buyer.id);
  const pending=hash(randomUUID()),sessionHash=hash(randomUUID());
  const access=await guest('broadcast_access_request',link.locator,pending);
  const approved=await staff(owner,'broadcast_access_approve',owner,access.request_id);
  await guest('broadcast_access_activate',access.request_id,pending,hash(approved.activation_token),sessionHash);
  const oldAddress={country:'KR',recipient:'손님',phone:'01012345678',region:'서울',detail:'1호'};
  await guest('broadcast_guest_address',link.locator,sessionHash,JSON.stringify(oldAddress),1);
  await db.query('update broadcast_order_lines set payment_locked=true where id=$1',[line.id]);
  const current=await staff(owner,'broadcast_manager_destination',owner,buyer.id);
  assert.equal(current.version,2);
  await assert.rejects(staff(other,'broadcast_manager_destination',owner,buyer.id),/권한/);
  await db.query(`insert into broadcast_shipments(seller_id,customer_id,request_key,address_snapshot,
    carrier,tracking_number,created_by) values($1,$2,$3,$4,'택배','OLD-1',$1)`,
    [owner,buyer.id,randomUUID(),JSON.stringify(oldAddress)]);
  const newAddress={...oldAddress,detail:'2호'};
  const key=randomUUID();
  const correct=(actor,address=newAddress,version=2,k=key)=>staff(actor,'broadcast_manager_address',
    owner,buyer.id,JSON.stringify(address),version,'고객 위챗 요청',k);
  await assert.rejects(correct(other,newAddress,2,randomUUID()),/권한/);
  await assert.rejects(correct(owner,{...newAddress,country:'CN'},2,randomUUID()),/배송국가/);
  const saved=await correct(owner);
  assert.deepEqual(await correct(owner),saved);
  assert.equal(saved.version,3);
  await assert.rejects(correct(owner,newAddress,2,randomUUID()),/주소가 변경/);
  await assert.rejects(guest('broadcast_guest_address',link.locator,sessionHash,
    JSON.stringify(newAddress),3),/입금 진행/);
  assert.equal((await guest('broadcast_guest_billing',link.locator,sessionHash)).destination.address.detail,'2호');
  assert.equal((await db.query('select address_snapshot from broadcast_shipments where tracking_number=$1',
    ['OLD-1'])).rows[0].address_snapshot.detail,'1호');
  const audit=(await db.query('select before_address,reason from broadcast_manager_address_commands where key=$1',[key])).rows[0];
  assert.equal(audit.before_address.detail,'1호');
  assert.equal(audit.reason,'고객 위챗 요청');
  assert.ok(!(await staff(owner,'broadcast_tasks',owner)).some(t=>t.type==='address_change'&&t.customer_id===buyer.id));
  const history=await staff(owner,'broadcast_shipment_history',owner,buyer.id,null,null,10);
  assert.equal(history.items.length,1);
  assert.equal(history.items[0].tracking_number,'OLD-1');
  assert.equal(history.items[0].address_snapshot.detail,'1호');
  await assert.rejects(staff(other,'broadcast_shipment_history',owner,buyer.id,null,null,10),/권한/);
  const all=await staff(owner,'broadcast_shipment_history',owner,null,null,null,1);
  assert.equal(all.items.length,1);
  assert.ok(all.next_cursor);
  const next=await staff(owner,'broadcast_shipment_history',owner,null,
    all.next_cursor.shipped_at,all.next_cursor.id,1);
  assert.ok(next.items.every(item=>item.id!==all.items[0].id));
});

test('미입금 청구의 배송국가 정정은 배송비를 재계산하고 주소·고객 확인을 다시 요구한다',async()=>{
  const buyer=await command(owner,'customer.create',{nickname:'국가 정정 손님'});
  const show=await command(owner,'session.create',{title:'국가 방송',kind:'new',exchange_rate:200});
  const item=await command(owner,'product.create',{session_id:show.id,supplier:'A',title:'가방',price_krw:10000});
  await command(owner,'order.create',{session_id:show.id,customer_id:buyer.id,
    product_id:item.id,color:'검정',size:'M',quantity:1});
  const bill=(name,data)=>staff(owner,'broadcast_billing_command',owner,name,JSON.stringify(data),randomUUID());
  await bill('destination.country',{customer_id:buyer.id,country:'KR'});
  const original=await bill('invoice.issue',{customer_id:buyer.id,session_id:show.id});
  assert.equal(original.shipping_krw,4000);
  const link=await staff(owner,'broadcast_customer_link',owner,buyer.id);
  const pending=hash(randomUUID()),sessionHash=hash(randomUUID());
  const access=await guest('broadcast_access_request',link.locator,pending);
  const approved=await staff(owner,'broadcast_access_approve',owner,access.request_id);
  await guest('broadcast_access_activate',access.request_id,pending,hash(approved.activation_token),sessionHash);
  await guest('broadcast_guest_address',link.locator,sessionHash,JSON.stringify({
    country:'KR',recipient:'손님',phone:'01012345678',region:'서울',detail:'1호'}),1);
  await guest('broadcast_guest_invoice_accept',link.locator,sessionHash,original.id);
  const key=randomUUID();
  const revise=(actor,invoice=original.id,k=key)=>staff(actor,'broadcast_invoice_country_revise',
    owner,invoice,'CN','배송국가 오기입',k);
  await assert.rejects(revise(other,original.id,randomUUID()),/권한/);
  const changed=await revise(owner);
  assert.deepEqual(await revise(owner),changed);
  assert.equal(changed.version,2);
  assert.equal(changed.snapshot.country,'CN');
  assert.equal(changed.shipping_cny_fen,3000);
  assert.equal(Number(changed.total_cny_fen),8000);
  assert.equal(changed.accepted_at,null);
  assert.equal((await db.query('select status from broadcast_invoices where id=$1',[original.id])).rows[0].status,'superseded');
  const destination=(await db.query('select country,address,version from broadcast_customer_destinations where customer_id=$1',[buyer.id])).rows[0];
  assert.equal(destination.country,'CN');
  assert.equal(destination.address,null);
  assert.equal(destination.version,3);
  await assert.rejects(guest('broadcast_guest_invoice_accept',link.locator,sessionHash,changed.id),/배송주소/);
  await assert.rejects(revise(owner,original.id,randomUUID()),/현재 청구서/);
  await guest('broadcast_guest_address',link.locator,sessionHash,JSON.stringify({
    country:'CN',recipient:'손님',phone:'13812345678',region:'연길',detail:'2호'}),3);
  await guest('broadcast_guest_invoice_accept',link.locator,sessionHash,changed.id);
  const reserve=await guest('broadcast_guest_evidence_reserve',link.locator,sessionHash,
    changed.id,randomUUID(),'image/png',8);
  assert.ok(reserve.evidence_id);
  await assert.rejects(staff(owner,'broadcast_invoice_country_revise',owner,changed.id,
    'KR','입금 중',randomUUID()),/증빙·입금·발주/);
});
