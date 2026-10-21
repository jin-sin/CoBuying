-- B03: actual KRW deposit returns reduce only unallocated balance.
begin;
alter table public.broadcast_deposits add column voided_at timestamptz,
 add column voided_by uuid references auth.users(id),
 add column void_reason text;
create table public.broadcast_deposit_returns (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,
 deposit_id uuid not null,customer_id uuid not null,
 amount_krw integer not null check(amount_krw>0),
 receiver text not null check(length(trim(receiver)) between 1 and 100),
 transaction_ref text not null check(length(trim(transaction_ref)) between 1 and 200),
 reason text not null check(length(trim(reason)) between 1 and 500),
 returned_at timestamptz not null,verified_by uuid not null references auth.users(id),
 created_at timestamptz not null default clock_timestamp(),
 unique(seller_id,id),unique(seller_id,receiver,transaction_ref),
 foreign key(seller_id,deposit_id) references public.broadcast_deposits(seller_id,id),
 foreign key(seller_id,customer_id) references public.broadcast_customers(seller_id,id)
);
alter table public.broadcast_deposit_returns enable row level security;
revoke all on public.broadcast_deposit_returns from public,anon,authenticated,service_role;
create table public.broadcast_deposit_return_commands (
 seller_id uuid not null,actor_id uuid not null references auth.users(id),
 key uuid not null,payload jsonb not null,result jsonb not null,
 primary key(seller_id,actor_id,key)
);
alter table public.broadcast_deposit_return_commands enable row level security;
revoke all on public.broadcast_deposit_return_commands from public,anon,authenticated,service_role;

create function public.broadcast_deposit_return(p_seller_id uuid,p_data jsonb,p_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_old public.broadcast_deposit_return_commands;v_deposit public.broadcast_deposits;
 v_return public.broadcast_deposit_returns;v_used bigint;v_returned bigint;
 v_amount integer;v_receiver text;v_ref text;v_reason text;
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_key is null or p_data is null or jsonb_typeof(p_data)<>'object' then
  raise exception '선입금 반환 내용을 확인해주세요.' using errcode='22023'; end if;
 v_amount:=(p_data->>'amount_krw')::integer;
 v_receiver:=trim(coalesce(p_data->>'receiver',''));
 v_ref:=trim(coalesce(p_data->>'transaction_ref',''));
 v_reason:=trim(coalesce(p_data->>'reason',''));
 if v_amount is null or v_amount<=0 or length(v_receiver) not between 1 and 100
  or length(v_ref) not between 1 and 200 or length(v_reason) not between 1 and 500
  or (p_data->>'returned_at')::timestamptz is null then
  raise exception '실제 반환 거래와 금액·사유를 확인해주세요.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into v_old from public.broadcast_deposit_return_commands
  where seller_id=p_seller_id and actor_id=auth.uid() and key=p_key;
 if found then
  if v_old.payload<>p_data then
   raise exception '같은 명령 키로 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
  return v_old.result;
 end if;
 select * into v_deposit from public.broadcast_deposits
  where seller_id=p_seller_id and id=(p_data->>'deposit_id')::uuid for update;
 if not found or v_deposit.voided_at is not null then
  raise exception '유효한 선입금을 찾을 수 없습니다.' using errcode='22023'; end if;
 select coalesce(sum(amount_krw),0) into v_used from public.broadcast_deposit_allocations
  where seller_id=p_seller_id and deposit_id=v_deposit.id and reversed_at is null;
 select coalesce(sum(amount_krw),0) into v_returned from public.broadcast_deposit_returns
  where seller_id=p_seller_id and deposit_id=v_deposit.id;
 if v_amount>v_deposit.amount_krw-v_used-v_returned then
  raise exception '미배분 선입금 잔액만 반환할 수 있습니다.' using errcode='22023'; end if;
 insert into public.broadcast_deposit_returns(seller_id,deposit_id,customer_id,amount_krw,
  receiver,transaction_ref,reason,returned_at,verified_by)
 values(p_seller_id,v_deposit.id,v_deposit.customer_id,v_amount,v_receiver,v_ref,
  v_reason,(p_data->>'returned_at')::timestamptz,auth.uid()) returning * into v_return;
 insert into public.broadcast_deposit_return_commands(seller_id,actor_id,key,payload,result)
 values(p_seller_id,auth.uid(),p_key,p_data,to_jsonb(v_return));
 return to_jsonb(v_return);
end $$;
revoke all on function public.broadcast_deposit_return(uuid,jsonb,uuid) from public,anon,service_role;
grant execute on function public.broadcast_deposit_return(uuid,jsonb,uuid) to authenticated;

create table public.broadcast_deposit_void_commands (
 seller_id uuid not null,actor_id uuid not null references auth.users(id),key uuid not null,
 deposit_id uuid not null,reason text not null,result jsonb not null,
 primary key(seller_id,actor_id,key)
);
alter table public.broadcast_deposit_void_commands enable row level security;
revoke all on public.broadcast_deposit_void_commands from public,anon,authenticated,service_role;
create function public.broadcast_deposit_void(p_seller_id uuid,p_deposit_id uuid,
 p_reason text,p_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_old public.broadcast_deposit_void_commands;v_deposit public.broadcast_deposits;
 v_result jsonb;begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_key is null or p_deposit_id is null or length(trim(coalesce(p_reason,''))) not between 1 and 500 then
  raise exception '선입금 정정 사유를 확인해주세요.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into v_old from public.broadcast_deposit_void_commands
  where seller_id=p_seller_id and actor_id=auth.uid() and key=p_key;
 if found then
  if v_old.deposit_id<>p_deposit_id or v_old.reason<>trim(p_reason) then
   raise exception '같은 선입금 정정 키로 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
  return v_old.result;
 end if;
 select * into v_deposit from public.broadcast_deposits
  where seller_id=p_seller_id and id=p_deposit_id for update;
 if not found or v_deposit.voided_at is not null then
  raise exception '정정할 선입금을 찾을 수 없습니다.' using errcode='22023'; end if;
 if exists(select 1 from public.broadcast_deposit_allocations a
  where a.seller_id=p_seller_id and a.deposit_id=p_deposit_id and a.reversed_at is null)
  or exists(select 1 from public.broadcast_deposit_returns r
   where r.seller_id=p_seller_id and r.deposit_id=p_deposit_id) then
  raise exception '청구 배분 또는 실제 반환이 있는 선입금은 정정할 수 없습니다.' using errcode='22023'; end if;
 update public.broadcast_deposits set voided_at=clock_timestamp(),voided_by=auth.uid(),
  void_reason=trim(p_reason) where id=p_deposit_id returning * into v_deposit;
 v_result:=jsonb_build_object('deposit_id',v_deposit.id,'voided_at',v_deposit.voided_at,
  'reason',v_deposit.void_reason);
 insert into public.broadcast_deposit_void_commands(seller_id,actor_id,key,deposit_id,reason,result)
 values(p_seller_id,auth.uid(),p_key,p_deposit_id,trim(p_reason),v_result);
 return v_result;
end $$;
revoke all on function public.broadcast_deposit_void(uuid,uuid,text,uuid) from public,anon,service_role;
grant execute on function public.broadcast_deposit_void(uuid,uuid,text,uuid) to authenticated;

create or replace function public.broadcast_billing_command(p_seller_id uuid,p_command text,p_data jsonb,p_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_old public.broadcast_billing_commands; v_customer uuid; v_session public.broadcast_sessions;
 v_invoice public.broadcast_invoices; v_deposit public.broadcast_deposits;
 v_line public.broadcast_order_lines; v_destination public.broadcast_customer_destinations;
 v_id uuid; v_result jsonb; v_subtotal bigint; v_count bigint; v_ship_krw integer;
 v_ship_cny integer; v_deposit_krw integer; v_total_krw bigint; v_total_cny bigint;
 v_available integer; v_take integer; v_remaining bigint; v_country text;
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_key is null or p_data is null or jsonb_typeof(p_data)<>'object' then
  raise exception '청구 명령을 확인해주세요.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into v_old from public.broadcast_billing_commands
 where seller_id=p_seller_id and actor_id=auth.uid() and key=p_key;
 if found then
  if v_old.command<>p_command or v_old.payload<>p_data then
   raise exception '같은 명령 키로 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
  return v_old.result;
 end if;
 if p_command='destination.country' then
  v_customer:=(p_data->>'customer_id')::uuid;v_country:=p_data->>'country';
  if v_country is null or v_country not in ('KR','CN') then
   raise exception '배송국가를 확인해주세요.' using errcode='22023'; end if;
  perform 1 from public.broadcast_customers where seller_id=p_seller_id and id=v_customer;
  if not found then raise exception '고객을 찾을 수 없습니다.' using errcode='22023'; end if;
  perform 1 from public.broadcast_invoices where seller_id=p_seller_id and customer_id=v_customer
   and status='issued' limit 1;
  if found then raise exception '발행된 청구의 배송국가는 판본 정정으로 변경해주세요.' using errcode='22023'; end if;
  insert into public.broadcast_customer_destinations(seller_id,customer_id,country)
  values(p_seller_id,v_customer,v_country)
  on conflict(seller_id,customer_id) do update set country=excluded.country,
   version=broadcast_customer_destinations.version+1,updated_at=clock_timestamp()
  returning to_jsonb(broadcast_customer_destinations.*) into v_result;
 elsif p_command='deposit.verify' then
  v_customer:=(p_data->>'customer_id')::uuid;
  insert into public.broadcast_deposits(seller_id,customer_id,amount_krw,receiver,
   transaction_ref,received_at,verified_by)
  values(p_seller_id,v_customer,(p_data->>'amount_krw')::integer,
   trim(p_data->>'receiver'),trim(p_data->>'transaction_ref'),
   (p_data->>'received_at')::timestamptz,auth.uid())
  returning * into v_deposit;
  v_result:=to_jsonb(v_deposit);
 elsif p_command='invoice.issue' then
  v_customer:=(p_data->>'customer_id')::uuid;
  select * into v_session from public.broadcast_sessions
   where seller_id=p_seller_id and id=(p_data->>'session_id')::uuid;
  if not found then raise exception '방송을 찾을 수 없습니다.' using errcode='22023'; end if;
  select * into v_destination from public.broadcast_customer_destinations
   where seller_id=p_seller_id and customer_id=v_customer;
  if not found then raise exception '배송국가를 먼저 선택해주세요.' using errcode='22023'; end if;
  select coalesce(sum(o.quantity::bigint*o.unit_price_krw),0),
   coalesce(sum(case when coalesce((o.original->'product'->>'shipping_excluded')::boolean,false)
     then 0 else o.quantity end),0)
   into v_subtotal,v_count from public.broadcast_order_lines o
   where o.seller_id=p_seller_id and o.customer_id=v_customer and o.session_id=v_session.id
    and o.invoice_id is null and not o.cancelled and not o.payment_locked;
  if v_subtotal=0 and not exists(select 1 from public.broadcast_order_lines o
   where o.seller_id=p_seller_id and o.customer_id=v_customer and o.session_id=v_session.id
    and o.invoice_id is null and not o.cancelled) then
   raise exception '청구할 주문이 없습니다.' using errcode='22023'; end if;
  v_ship_krw:=case when v_count>=v_session.free_shipping_count then 0 else v_session.shipping_krw end;
  v_ship_cny:=case when v_count>=v_session.free_shipping_count then 0 else v_session.shipping_cny_fen end;
  v_remaining:=v_subtotal+case when v_destination.country='KR' then v_ship_krw
    else round(v_ship_cny::numeric/100*v_session.exchange_rate)::integer end;
  v_deposit_krw:=0;
  for v_deposit in select * from public.broadcast_deposits
    where seller_id=p_seller_id and customer_id=v_customer and voided_at is null order by received_at,id loop
   select v_deposit.amount_krw-coalesce((select sum(r.amount_krw) from public.broadcast_deposit_returns r where r.seller_id=p_seller_id and r.deposit_id=v_deposit.id),0)-coalesce(sum(a.amount_krw),0) into v_available
   from public.broadcast_deposit_allocations a where a.seller_id=p_seller_id
    and a.deposit_id=v_deposit.id and a.reversed_at is null;
   v_take:=least(v_available,v_remaining);
   if v_take>0 then
    v_deposit_krw:=v_deposit_krw+v_take;v_remaining:=v_remaining-v_take;
   end if;
  end loop;
  v_total_krw:=v_remaining;
  v_total_cny:=round(v_total_krw::numeric*100/v_session.exchange_rate);
  v_id:=gen_random_uuid();
  insert into public.broadcast_invoices(id,seller_id,customer_id,session_id,series_id,version,
   snapshot,subtotal_krw,shipping_krw,shipping_cny_fen,deposit_krw,total_krw,total_cny_fen)
  values(v_id,p_seller_id,v_customer,v_session.id,v_id,1,
   jsonb_build_object('exchange_rate',v_session.exchange_rate,'country',v_destination.country,
    'free_shipping_count',v_session.free_shipping_count,'shipping_krw',v_ship_krw,
    'shipping_cny_fen',v_ship_cny),v_subtotal,v_ship_krw,v_ship_cny,
   v_deposit_krw,v_total_krw,v_total_cny);
  for v_line in select * from public.broadcast_order_lines o where o.seller_id=p_seller_id
   and o.customer_id=v_customer and o.session_id=v_session.id and o.invoice_id is null
   and not o.cancelled and not o.payment_locked order by o.sequence for update loop
   insert into public.broadcast_invoice_lines(seller_id,invoice_id,order_line_id,snapshot)
   values(p_seller_id,v_id,v_line.id,to_jsonb(v_line));
   update public.broadcast_order_lines set invoice_id=v_id where id=v_line.id;
  end loop;
  v_remaining:=v_deposit_krw;
  for v_deposit in select * from public.broadcast_deposits
    where seller_id=p_seller_id and customer_id=v_customer and voided_at is null order by received_at,id loop
   select v_deposit.amount_krw-coalesce((select sum(r.amount_krw) from public.broadcast_deposit_returns r where r.seller_id=p_seller_id and r.deposit_id=v_deposit.id),0)-coalesce(sum(a.amount_krw),0) into v_available
   from public.broadcast_deposit_allocations a where a.seller_id=p_seller_id
    and a.deposit_id=v_deposit.id and a.reversed_at is null;
   v_take:=least(v_available,v_remaining);
   if v_take>0 then
    insert into public.broadcast_deposit_allocations(seller_id,deposit_id,invoice_id,amount_krw)
     values(p_seller_id,v_deposit.id,v_id,v_take);
    v_remaining:=v_remaining-v_take;
   end if;
  end loop;
  select to_jsonb(i) into v_result from public.broadcast_invoices i where id=v_id;
 else raise exception '지원하지 않는 청구 명령입니다.' using errcode='22023';
 end if;
 insert into public.broadcast_billing_commands(seller_id,actor_id,key,command,payload,result)
 values(p_seller_id,auth.uid(),p_key,p_command,p_data,v_result);
 return v_result;
end $$;

create or replace function public.broadcast_billing_preview(p_seller_id uuid,p_customer_id uuid,p_session_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if not exists(select 1 from public.broadcast_customers c where c.seller_id=p_seller_id and c.id=p_customer_id)
  or not exists(select 1 from public.broadcast_sessions s where s.seller_id=p_seller_id and s.id=p_session_id) then
  raise exception '고객 또는 방송을 찾을 수 없습니다.' using errcode='22023'; end if;
 return jsonb_build_object(
  'orders',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'product_title',o.product_title,
   'color',o.color,'size',o.size,'quantity',o.quantity,'unit_price_krw',o.unit_price_krw)
   order by o.sequence) from public.broadcast_order_lines o
   where o.seller_id=p_seller_id and o.customer_id=p_customer_id and o.session_id=p_session_id
    and o.invoice_id is null and not o.cancelled and not o.payment_locked),'[]'::jsonb),
  'country',(select d.country from public.broadcast_customer_destinations d
   where d.seller_id=p_seller_id and d.customer_id=p_customer_id),
  'deposit_available_krw',coalesce((select sum(d.amount_krw-
   coalesce((select sum(a.amount_krw) from public.broadcast_deposit_allocations a
    where a.seller_id=d.seller_id and a.deposit_id=d.id and a.reversed_at is null),0)-
   coalesce((select sum(r.amount_krw) from public.broadcast_deposit_returns r
    where r.seller_id=d.seller_id and r.deposit_id=d.id),0))
   from public.broadcast_deposits d where d.seller_id=p_seller_id and d.customer_id=p_customer_id
    and d.voided_at is null),0),
  'deposits',coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'amount_krw',d.amount_krw,
   'available_krw',d.amount_krw-
    coalesce((select sum(a.amount_krw) from public.broadcast_deposit_allocations a
     where a.seller_id=d.seller_id and a.deposit_id=d.id and a.reversed_at is null),0)-
    coalesce((select sum(r.amount_krw) from public.broadcast_deposit_returns r
     where r.seller_id=d.seller_id and r.deposit_id=d.id),0)) order by d.received_at,d.id)
   from public.broadcast_deposits d where d.seller_id=p_seller_id
    and d.customer_id=p_customer_id and d.voided_at is null),'[]'::jsonb));
end $$;

create function public.broadcast_guest_deposit_returns(p_locator uuid,p_session_hash text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_device public.broadcast_customer_devices;begin
 select d.* into v_device from public.broadcast_customer_devices d
 join public.broadcast_customer_links l on l.seller_id=d.seller_id and l.customer_id=d.customer_id
 where l.locator=p_locator and d.session_hash=p_session_hash and d.revoked_at is null
  and d.expires_at>clock_timestamp();
 if not found then raise exception '이 기기에서 선입금 반환을 볼 수 없습니다.' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'amount_krw',r.amount_krw,
  'reason',r.reason,'returned_at',r.returned_at) order by r.returned_at,r.id)
  from public.broadcast_deposit_returns r where r.seller_id=v_device.seller_id
   and r.customer_id=v_device.customer_id),'[]'::jsonb);
end $$;
revoke all on function public.broadcast_guest_deposit_returns(uuid,text) from public,anon,authenticated;
grant execute on function public.broadcast_guest_deposit_returns(uuid,text) to service_role;
commit;
