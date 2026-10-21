-- B03 first slice: immutable issued invoices, verified KRW deposits and address versions.
begin;
create table public.broadcast_customer_destinations (
 seller_id uuid not null, customer_id uuid not null,
 country text not null check(country in ('KR','CN')),
 address jsonb, version integer not null default 1,
 updated_at timestamptz not null default clock_timestamp(),
 primary key(seller_id,customer_id),
 foreign key(seller_id,customer_id) references public.broadcast_customers(seller_id,id),
 check(address is null or jsonb_typeof(address)='object')
);
create table public.broadcast_deposits (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,customer_id uuid not null,
 amount_krw integer not null check(amount_krw>0),receiver text not null check(length(trim(receiver)) between 1 and 100),
 transaction_ref text not null check(length(trim(transaction_ref)) between 1 and 200),received_at timestamptz not null,
 verified_by uuid not null references auth.users(id),
 created_at timestamptz not null default clock_timestamp(),
 unique(seller_id,receiver,transaction_ref),unique(seller_id,id),
 foreign key(seller_id,customer_id) references public.broadcast_customers(seller_id,id)
);
create table public.broadcast_invoices (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,customer_id uuid not null,
 session_id uuid not null,series_id uuid not null,version integer not null,
 status text not null default 'issued' check(status in ('issued','superseded','void')),
 snapshot jsonb not null,subtotal_krw bigint not null check(subtotal_krw>=0),
 shipping_krw integer not null check(shipping_krw>=0),
 shipping_cny_fen integer not null check(shipping_cny_fen>=0),
 deposit_krw integer not null check(deposit_krw>=0),
 total_krw bigint not null check(total_krw>=0),
 total_cny_fen bigint not null check(total_cny_fen>=0),
 accepted_at timestamptz,
 issued_at timestamptz not null default clock_timestamp(),
 unique(seller_id,id),unique(seller_id,series_id,version),
 foreign key(seller_id,customer_id) references public.broadcast_customers(seller_id,id),
 foreign key(seller_id,session_id) references public.broadcast_sessions(seller_id,id)
);
create unique index broadcast_one_issued_series on public.broadcast_invoices(seller_id,series_id) where status='issued';
create table public.broadcast_invoice_lines (
 seller_id uuid not null,invoice_id uuid not null,order_line_id uuid not null,
 snapshot jsonb not null,primary key(invoice_id,order_line_id),
 foreign key(seller_id,invoice_id) references public.broadcast_invoices(seller_id,id),
 foreign key(seller_id,order_line_id) references public.broadcast_order_lines(seller_id,id)
);
create table public.broadcast_deposit_allocations (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,
 deposit_id uuid not null,invoice_id uuid not null,
 amount_krw integer not null check(amount_krw>0),
 reversed_at timestamptz,
 created_at timestamptz not null default clock_timestamp(),
 foreign key(seller_id,deposit_id) references public.broadcast_deposits(seller_id,id),
 foreign key(seller_id,invoice_id) references public.broadcast_invoices(seller_id,id)
);
create index broadcast_deposit_allocations_balance on public.broadcast_deposit_allocations(seller_id,deposit_id) where reversed_at is null;
create table public.broadcast_billing_commands (
 seller_id uuid not null,actor_id uuid not null references auth.users(id),
 key uuid not null,command text not null,payload jsonb not null,result jsonb not null,
 primary key(seller_id,actor_id,key)
);
do $$ declare t text; begin
 foreach t in array array['broadcast_customer_destinations','broadcast_deposits',
 'broadcast_invoices','broadcast_invoice_lines','broadcast_deposit_allocations','broadcast_billing_commands'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated,service_role',t);
 end loop;
end $$;

create function public.broadcast_billing_command(p_seller_id uuid,p_command text,p_data jsonb,p_key uuid)
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
    where seller_id=p_seller_id and customer_id=v_customer order by received_at,id loop
   select v_deposit.amount_krw-coalesce(sum(a.amount_krw),0) into v_available
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
    where seller_id=p_seller_id and customer_id=v_customer order by received_at,id loop
   select v_deposit.amount_krw-coalesce(sum(a.amount_krw),0) into v_available
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
revoke all on function public.broadcast_billing_command(uuid,text,jsonb,uuid) from public,anon,service_role;
grant execute on function public.broadcast_billing_command(uuid,text,jsonb,uuid) to authenticated;

create function public.broadcast_guest_billing(p_locator uuid,p_session_hash text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v_device public.broadcast_customer_devices; begin
 select d.* into v_device from public.broadcast_customer_devices d
 join public.broadcast_customer_links l on l.seller_id=d.seller_id and l.customer_id=d.customer_id
 where l.locator=p_locator and d.session_hash=p_session_hash and d.revoked_at is null
  and d.expires_at>clock_timestamp();
 if not found then raise exception '이 기기에서는 청구를 볼 수 없습니다.' using errcode='42501'; end if;
 return jsonb_build_object(
  'destination',(select to_jsonb(d)-'seller_id'-'customer_id' from public.broadcast_customer_destinations d
   where d.seller_id=v_device.seller_id and d.customer_id=v_device.customer_id),
  'invoices',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'session_id',i.session_id,
   'version',i.version,'status',i.status,'snapshot',i.snapshot,
   'subtotal_krw',i.subtotal_krw,'shipping_krw',i.shipping_krw,
   'shipping_cny_fen',i.shipping_cny_fen,'deposit_krw',i.deposit_krw,
   'total_krw',i.total_krw,'total_cny_fen',i.total_cny_fen,
   'issued_at',i.issued_at,'accepted_at',i.accepted_at,
   'lines',coalesce((select jsonb_agg(jsonb_build_object('id',l.order_line_id,
    'product_title',l.snapshot->>'product_title','product_number',(l.snapshot->>'product_number')::integer,
    'color',l.snapshot->>'color','size',l.snapshot->>'size',
    'quantity',(l.snapshot->>'quantity')::integer,
    'unit_price_krw',(l.snapshot->>'unit_price_krw')::integer)
    order by (l.snapshot->>'sequence')::bigint)
    from public.broadcast_invoice_lines l where l.invoice_id=i.id),'[]'::jsonb))
   order by i.issued_at desc,i.id)
   from public.broadcast_invoices i where i.seller_id=v_device.seller_id
    and i.customer_id=v_device.customer_id),'[]'::jsonb));
end $$;

create function public.broadcast_guest_address(p_locator uuid,p_session_hash text,
 p_address jsonb,p_expected_version integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_device public.broadcast_customer_devices; v_destination public.broadcast_customer_destinations;
begin
 select d.* into v_device from public.broadcast_customer_devices d
 join public.broadcast_customer_links l on l.seller_id=d.seller_id and l.customer_id=d.customer_id
 where l.locator=p_locator and d.session_hash=p_session_hash and d.revoked_at is null
  and d.expires_at>clock_timestamp();
 if not found then raise exception '이 기기에서는 주소를 변경할 수 없습니다.' using errcode='42501'; end if;
 if p_address is null or jsonb_typeof(p_address)<>'object' or
  p_address->>'country' is null or p_address->>'country' not in ('KR','CN') or
  length(trim(coalesce(p_address->>'recipient',''))) not between 1 and 100 or
  length(trim(coalesce(p_address->>'phone',''))) not between 1 and 40 or
  length(trim(coalesce(p_address->>'region',''))) not between 1 and 200 or
  length(trim(coalesce(p_address->>'detail',''))) not between 1 and 300 then
  raise exception '배송주소를 확인해주세요.' using errcode='22023'; end if;
 select * into v_destination from public.broadcast_customer_destinations
 where seller_id=v_device.seller_id and customer_id=v_device.customer_id for update;
 if not found or v_destination.country<>p_address->>'country' then
  raise exception '정산서의 배송국가와 주소를 확인해주세요.' using errcode='22023'; end if;
 if p_expected_version is distinct from v_destination.version then
  raise exception '주소가 변경되었습니다. 다시 확인해주세요.' using errcode='40001'; end if;
 perform 1 from public.broadcast_invoices where seller_id=v_device.seller_id
  and customer_id=v_device.customer_id and status='issued' limit 1;
 if not found then raise exception '정산서 발행 후 주소를 입력할 수 있습니다.' using errcode='22023'; end if;
 perform 1 from public.broadcast_order_lines where seller_id=v_device.seller_id
  and customer_id=v_device.customer_id and payment_locked limit 1;
 if found then raise exception '입금 진행 후 주소 변경은 판매자에게 요청해주세요.' using errcode='22023'; end if;
 update public.broadcast_customer_destinations set address=p_address,version=version+1,
  updated_at=clock_timestamp() where seller_id=v_device.seller_id and customer_id=v_device.customer_id
 returning * into v_destination;
 return jsonb_build_object('version',v_destination.version,'country',v_destination.country,
  'address',v_destination.address);
end $$;

create function public.broadcast_guest_invoice_accept(p_locator uuid,p_session_hash text,p_invoice_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_device public.broadcast_customer_devices; v_invoice public.broadcast_invoices;
 v_destination public.broadcast_customer_destinations; begin
 select d.* into v_device from public.broadcast_customer_devices d
 join public.broadcast_customer_links l on l.seller_id=d.seller_id and l.customer_id=d.customer_id
 where l.locator=p_locator and d.session_hash=p_session_hash and d.revoked_at is null
  and d.expires_at>clock_timestamp();
 if not found then raise exception '이 기기에서는 정산서를 확인할 수 없습니다.' using errcode='42501'; end if;
 select * into v_invoice from public.broadcast_invoices where seller_id=v_device.seller_id
  and customer_id=v_device.customer_id and id=p_invoice_id for update;
 if not found or v_invoice.status<>'issued' then
  raise exception '확인 가능한 정산서가 아닙니다.' using errcode='22023'; end if;
 select * into v_destination from public.broadcast_customer_destinations
 where seller_id=v_device.seller_id and customer_id=v_device.customer_id;
 if v_destination.address is null then
  raise exception '배송주소를 먼저 입력해주세요.' using errcode='22023'; end if;
 update public.broadcast_invoices set accepted_at=coalesce(accepted_at,clock_timestamp())
 where id=v_invoice.id returning * into v_invoice;
 return jsonb_build_object('invoice_id',v_invoice.id,'accepted_at',v_invoice.accepted_at);
end $$;

revoke all on function public.broadcast_guest_billing(uuid,text),
 public.broadcast_guest_address(uuid,text,jsonb,integer),
 public.broadcast_guest_invoice_accept(uuid,text,uuid) from public,anon,authenticated;
grant execute on function public.broadcast_guest_billing(uuid,text),
 public.broadcast_guest_address(uuid,text,jsonb,integer),
 public.broadcast_guest_invoice_accept(uuid,text,uuid) to service_role;
commit;
