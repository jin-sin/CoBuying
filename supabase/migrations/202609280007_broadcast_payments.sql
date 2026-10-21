-- B04 first slice: private evidence references, manual receipt verification and refund ledger.
begin;
alter table public.broadcast_invoices add column selected_currency text
 check(selected_currency in ('KRW','CNY'));
create table public.broadcast_evidence (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,
 customer_id uuid not null,invoice_id uuid not null,request_key uuid not null,
 object_key text not null unique,content_type text not null check(content_type in ('image/jpeg','image/png','image/webp')),
 expected_size integer not null check(expected_size between 1 and 5242880),
 actual_size integer,sha256 text check(sha256 ~ '^[a-f0-9]{64}$'),
 status text not null default 'reserved' check(status in ('reserved','stored')),
 created_at timestamptz not null default clock_timestamp(),stored_at timestamptz,
 unique(seller_id,customer_id,request_key),unique(seller_id,id),
 foreign key(seller_id,customer_id) references public.broadcast_customers(seller_id,id),
 foreign key(seller_id,invoice_id) references public.broadcast_invoices(seller_id,id)
);
create table public.broadcast_receipts (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,
 customer_id uuid not null,invoice_id uuid not null,evidence_id uuid not null unique,
 currency text not null check(currency in ('KRW','CNY')),
 claimed_minor bigint not null check(claimed_minor>0),confirmed_minor bigint check(confirmed_minor>0),
 payer_name text not null default '',receiver text,transaction_ref text,
 status text not null default 'pending_review' check(status in ('pending_review','needs_info','confirmed','rejected')),
 created_at timestamptz not null default clock_timestamp(),confirmed_at timestamptz,
 confirmed_by uuid references auth.users(id),
 unique(seller_id,id),
 foreign key(seller_id,customer_id) references public.broadcast_customers(seller_id,id),
 foreign key(seller_id,invoice_id) references public.broadcast_invoices(seller_id,id),
 foreign key(seller_id,evidence_id) references public.broadcast_evidence(seller_id,id),
 check((status='confirmed' and confirmed_minor is not null and receiver is not null and transaction_ref is not null
   and confirmed_at is not null and confirmed_by is not null)
   or status<>'confirmed')
);
create unique index broadcast_receipt_transaction on public.broadcast_receipts(seller_id,receiver,transaction_ref)
 where status='confirmed';
create table public.broadcast_refunds (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,
 invoice_id uuid not null,currency text not null check(currency in ('KRW','CNY')),
 amount_minor bigint not null check(amount_minor>0),reason text not null check(length(trim(reason)) between 1 and 500),
 status text not null default 'planned' check(status in ('planned','confirmed')),
 actual_transaction_ref text,created_by uuid not null references auth.users(id),
 confirmed_by uuid references auth.users(id),confirmed_at timestamptz,
 created_at timestamptz not null default clock_timestamp(),
 unique(seller_id,id),foreign key(seller_id,invoice_id) references public.broadcast_invoices(seller_id,id)
);
create unique index broadcast_refund_transaction on public.broadcast_refunds(seller_id,actual_transaction_ref)
 where status='confirmed';
create table public.broadcast_payment_commands (
 seller_id uuid not null,actor_id uuid not null references auth.users(id),key uuid not null,
 command text not null,payload jsonb not null,result jsonb not null,
 primary key(seller_id,actor_id,key)
);
do $$ declare t text; begin
 foreach t in array array['broadcast_evidence','broadcast_receipts','broadcast_refunds','broadcast_payment_commands'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated,service_role',t);
 end loop;
end $$;

create function public.broadcast_guest_evidence_reserve(p_locator uuid,p_session_hash text,
 p_invoice_id uuid,p_key uuid,p_content_type text,p_size integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_device public.broadcast_customer_devices;v_invoice public.broadcast_invoices;
 v_evidence public.broadcast_evidence;begin
 select d.* into v_device from public.broadcast_customer_devices d
 join public.broadcast_customer_links l on l.seller_id=d.seller_id and l.customer_id=d.customer_id
 where l.locator=p_locator and d.session_hash=p_session_hash and d.revoked_at is null
  and d.expires_at>clock_timestamp();
 if not found then raise exception '이 기기에서 증빙을 제출할 수 없습니다.' using errcode='42501'; end if;
 if p_key is null or p_content_type not in ('image/jpeg','image/png','image/webp')
  or p_size not between 1 and 5242880 then raise exception '증빙 파일을 확인해주세요.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(v_device.seller_id::text,0));
 select * into v_invoice from public.broadcast_invoices where id=p_invoice_id
  and seller_id=v_device.seller_id and customer_id=v_device.customer_id for update;
 if not found or v_invoice.status<>'issued' or v_invoice.accepted_at is null or v_invoice.total_krw=0 then
  raise exception '송금 확인 가능한 정산서가 아닙니다.' using errcode='22023'; end if;
 select * into v_evidence from public.broadcast_evidence where seller_id=v_device.seller_id
  and customer_id=v_device.customer_id and request_key=p_key;
 if found then
  if v_evidence.invoice_id<>p_invoice_id or v_evidence.content_type<>p_content_type
   or v_evidence.expected_size<>p_size then
   raise exception '같은 업로드 키로 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
 else
  insert into public.broadcast_evidence(seller_id,customer_id,invoice_id,request_key,
   object_key,content_type,expected_size)
  values(v_device.seller_id,v_device.customer_id,p_invoice_id,p_key,
   'broadcast-evidence/'||v_device.seller_id||'/'||gen_random_uuid(),p_content_type,p_size)
  returning * into v_evidence;
 end if;
 return jsonb_build_object('evidence_id',v_evidence.id,'object_key',v_evidence.object_key,
  'status',v_evidence.status,'sha256',v_evidence.sha256);
end $$;

create function public.broadcast_evidence_stored(p_evidence_id uuid,p_size integer,p_sha256 text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_evidence public.broadcast_evidence;begin
 select * into v_evidence from public.broadcast_evidence where id=p_evidence_id for update;
 if not found or p_size<>v_evidence.expected_size or p_sha256 is null
  or p_sha256 !~ '^[a-f0-9]{64}$' then
  raise exception '업로드 결과를 확인해주세요.' using errcode='22023'; end if;
 if v_evidence.status='stored' then
  if v_evidence.sha256<>p_sha256 then raise exception '저장된 파일이 다릅니다.' using errcode='22023'; end if;
  return jsonb_build_object('evidence_id',v_evidence.id,'status','stored');
 end if;
 update public.broadcast_evidence set status='stored',actual_size=p_size,sha256=p_sha256,
  stored_at=clock_timestamp() where id=p_evidence_id;
 return jsonb_build_object('evidence_id',p_evidence_id,'status','stored');
end $$;

create function public.broadcast_guest_receipt_submit(p_locator uuid,p_session_hash text,
 p_evidence_id uuid,p_currency text,p_claimed_minor bigint,p_payer_name text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_device public.broadcast_customer_devices;v_evidence public.broadcast_evidence;
 v_invoice public.broadcast_invoices;v_receipt public.broadcast_receipts;begin
 select d.* into v_device from public.broadcast_customer_devices d
 join public.broadcast_customer_links l on l.seller_id=d.seller_id and l.customer_id=d.customer_id
 where l.locator=p_locator and d.session_hash=p_session_hash and d.revoked_at is null
  and d.expires_at>clock_timestamp();
 if not found then raise exception '이 기기에서 송금을 신고할 수 없습니다.' using errcode='42501'; end if;
 if p_currency is null or p_currency not in ('KRW','CNY') or p_claimed_minor is null
  or p_claimed_minor<=0 or length(coalesce(p_payer_name,''))>100 then
  raise exception '송금 정보를 확인해주세요.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(v_device.seller_id::text,0));
 select * into v_evidence from public.broadcast_evidence where id=p_evidence_id
  and seller_id=v_device.seller_id and customer_id=v_device.customer_id;
 if not found or v_evidence.status<>'stored' then
  raise exception '저장 완료된 증빙을 선택해주세요.' using errcode='22023'; end if;
 select * into v_receipt from public.broadcast_receipts where evidence_id=p_evidence_id;
 if found then
  if v_receipt.currency<>p_currency or v_receipt.claimed_minor<>p_claimed_minor
   or v_receipt.payer_name<>trim(coalesce(p_payer_name,'')) then
   raise exception '같은 증빙의 송금 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
  return jsonb_build_object('receipt_id',v_receipt.id,'status',v_receipt.status);
 end if;
 select * into v_invoice from public.broadcast_invoices where id=v_evidence.invoice_id for update;
 if v_invoice.status<>'issued' or v_invoice.accepted_at is null
  or (v_invoice.selected_currency is not null and v_invoice.selected_currency<>p_currency) then
  raise exception '청구 통화와 상태를 확인해주세요.' using errcode='22023'; end if;
 update public.broadcast_invoices set selected_currency=p_currency where id=v_invoice.id;
 insert into public.broadcast_receipts(seller_id,customer_id,invoice_id,evidence_id,currency,
  claimed_minor,payer_name)
 values(v_device.seller_id,v_device.customer_id,v_invoice.id,p_evidence_id,p_currency,
  p_claimed_minor,trim(coalesce(p_payer_name,''))) returning * into v_receipt;
 update public.broadcast_order_lines set payment_locked=true
  where seller_id=v_device.seller_id and invoice_id=v_invoice.id;
 return jsonb_build_object('receipt_id',v_receipt.id,'status','pending_review');
end $$;

create function public.broadcast_payment_command(p_seller_id uuid,p_command text,p_data jsonb,p_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_old public.broadcast_payment_commands;v_receipt public.broadcast_receipts;
 v_invoice public.broadcast_invoices;v_refund public.broadcast_refunds;v_result jsonb;
 v_confirmed bigint;v_reserved bigint;v_due bigint;v_currency text;v_ref text;v_receiver text;
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_key is null or p_data is null or jsonb_typeof(p_data)<>'object' then
  raise exception '입금 확인 명령을 확인해주세요.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into v_old from public.broadcast_payment_commands where seller_id=p_seller_id
  and actor_id=auth.uid() and key=p_key;
 if found then
  if v_old.command<>p_command or v_old.payload<>p_data then
   raise exception '같은 명령 키로 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
  return v_old.result;
 end if;
 if p_command='receipt.confirm' then
  select * into v_receipt from public.broadcast_receipts where seller_id=p_seller_id
   and id=(p_data->>'receipt_id')::uuid for update;
  if not found or v_receipt.status not in ('pending_review','needs_info') then
   raise exception '확인 대기 중인 입금이 아닙니다.' using errcode='22023'; end if;
  v_receiver:=trim(coalesce(p_data->>'receiver',''));v_ref:=trim(coalesce(p_data->>'transaction_ref',''));
  if length(v_receiver) not between 1 and 100 or length(v_ref) not between 1 and 200 then
   raise exception '실제 수취 계정과 거래번호를 입력해주세요.' using errcode='22023'; end if;
  perform 1 from public.broadcast_deposits where seller_id=p_seller_id
   and receiver=v_receiver and transaction_ref=v_ref limit 1;
  if found then raise exception '이미 선입금으로 확인한 거래입니다.' using errcode='23505'; end if;
  update public.broadcast_receipts set status='confirmed',
   confirmed_minor=(p_data->>'confirmed_minor')::bigint,
   receiver=v_receiver,transaction_ref=v_ref,confirmed_at=clock_timestamp(),confirmed_by=auth.uid()
  where id=v_receipt.id returning * into v_receipt;
  v_result:=to_jsonb(v_receipt);
 elsif p_command='receipt.reject' then
  select * into v_receipt from public.broadcast_receipts where seller_id=p_seller_id
   and id=(p_data->>'receipt_id')::uuid for update;
  if not found or v_receipt.status not in ('pending_review','needs_info') then
   raise exception '확인 대기 중인 입금이 아닙니다.' using errcode='22023'; end if;
  update public.broadcast_receipts set status='rejected' where id=v_receipt.id returning * into v_receipt;
  v_result:=to_jsonb(v_receipt);
 elsif p_command='refund.plan' then
  select * into v_invoice from public.broadcast_invoices where seller_id=p_seller_id
   and id=(p_data->>'invoice_id')::uuid for update;
  if not found or v_invoice.selected_currency is null then
   raise exception '환불할 정산서를 찾을 수 없습니다.' using errcode='22023'; end if;
  v_due:=case when v_invoice.selected_currency='KRW' then v_invoice.total_krw else v_invoice.total_cny_fen end;
  select coalesce(sum(confirmed_minor),0) into v_confirmed from public.broadcast_receipts
   where seller_id=p_seller_id and invoice_id=v_invoice.id and status='confirmed';
  select coalesce(sum(amount_minor),0) into v_reserved from public.broadcast_refunds
   where seller_id=p_seller_id and invoice_id=v_invoice.id and status in ('planned','confirmed');
  if (p_data->>'amount_minor')::bigint<=0 or
   (p_data->>'amount_minor')::bigint>v_confirmed-v_due-v_reserved then
   raise exception '초과 수취 범위 안에서만 환불을 예약할 수 있습니다.' using errcode='22023'; end if;
  insert into public.broadcast_refunds(seller_id,invoice_id,currency,amount_minor,reason,created_by)
  values(p_seller_id,v_invoice.id,v_invoice.selected_currency,
   (p_data->>'amount_minor')::bigint,trim(p_data->>'reason'),auth.uid()) returning * into v_refund;
  v_result:=to_jsonb(v_refund);
 elsif p_command='refund.confirm' then
  select * into v_refund from public.broadcast_refunds where seller_id=p_seller_id
   and id=(p_data->>'refund_id')::uuid for update;
  if not found or v_refund.status<>'planned' then
   raise exception '예약된 환불이 아닙니다.' using errcode='22023'; end if;
  v_ref:=trim(coalesce(p_data->>'transaction_ref',''));
  if length(v_ref) not between 1 and 200 then
   raise exception '실제 환불 거래번호를 입력해주세요.' using errcode='22023'; end if;
  update public.broadcast_refunds set status='confirmed',actual_transaction_ref=v_ref,
   confirmed_by=auth.uid(),confirmed_at=clock_timestamp() where id=v_refund.id returning * into v_refund;
  v_result:=to_jsonb(v_refund);
 else raise exception '지원하지 않는 입금 명령입니다.' using errcode='22023'; end if;
 insert into public.broadcast_payment_commands(seller_id,actor_id,key,command,payload,result)
 values(p_seller_id,auth.uid(),p_key,p_command,p_data,v_result);
 return v_result;
end $$;

create function public.broadcast_guest_payment_summary(p_locator uuid,p_session_hash text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_device public.broadcast_customer_devices;begin
 select d.* into v_device from public.broadcast_customer_devices d
 join public.broadcast_customer_links l on l.seller_id=d.seller_id and l.customer_id=d.customer_id
 where l.locator=p_locator and d.session_hash=p_session_hash and d.revoked_at is null
  and d.expires_at>clock_timestamp();
 if not found then raise exception '이 기기에서 입금 정보를 볼 수 없습니다.' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('invoice_id',i.id,
  'currency',i.selected_currency,'due_minor',case when i.selected_currency='CNY' then i.total_cny_fen else i.total_krw end,
  'confirmed_minor',coalesce((select sum(r.confirmed_minor) from public.broadcast_receipts r
   where r.invoice_id=i.id and r.status='confirmed'),0),
  'pending_count',(select count(*) from public.broadcast_receipts r where r.invoice_id=i.id
   and r.status in ('pending_review','needs_info')),
  'refund_confirmed_minor',coalesce((select sum(f.amount_minor) from public.broadcast_refunds f
   where f.invoice_id=i.id and f.status='confirmed'),0)) order by i.issued_at desc)
  from public.broadcast_invoices i where i.seller_id=v_device.seller_id
   and i.customer_id=v_device.customer_id and i.status='issued'),'[]'::jsonb);
end $$;

create function public.broadcast_receipt_page(p_seller_id uuid,p_status text default 'pending_review')
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_status is null or p_status not in ('pending_review','needs_info','confirmed','rejected') then
  raise exception '입금 상태를 확인해주세요.' using errcode='22023'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'customer_id',r.customer_id,
  'nickname',c.nickname,'invoice_id',r.invoice_id,'currency',r.currency,
  'claimed_minor',r.claimed_minor,'payer_name',r.payer_name,
  'status',r.status,'created_at',r.created_at,'object_key',e.object_key,
  'content_type',e.content_type) order by r.created_at,r.id)
  from public.broadcast_receipts r join public.broadcast_customers c
   on c.seller_id=r.seller_id and c.id=r.customer_id
  join public.broadcast_evidence e on e.seller_id=r.seller_id and e.id=r.evidence_id
  where r.seller_id=p_seller_id and r.status=p_status),'[]'::jsonb);
end $$;

revoke all on function public.broadcast_guest_evidence_reserve(uuid,text,uuid,uuid,text,integer),
 public.broadcast_evidence_stored(uuid,integer,text),
 public.broadcast_guest_receipt_submit(uuid,text,uuid,text,bigint,text),
 public.broadcast_guest_payment_summary(uuid,text) from public,anon,authenticated;
grant execute on function public.broadcast_guest_evidence_reserve(uuid,text,uuid,uuid,text,integer),
 public.broadcast_evidence_stored(uuid,integer,text),
 public.broadcast_guest_receipt_submit(uuid,text,uuid,text,bigint,text),
 public.broadcast_guest_payment_summary(uuid,text) to service_role;
revoke all on function public.broadcast_payment_command(uuid,text,jsonb,uuid) from public,anon,service_role;
grant execute on function public.broadcast_payment_command(uuid,text,jsonb,uuid) to authenticated;
revoke all on function public.broadcast_receipt_page(uuid,text) from public,anon,service_role;
grant execute on function public.broadcast_receipt_page(uuid,text) to authenticated;
commit;
