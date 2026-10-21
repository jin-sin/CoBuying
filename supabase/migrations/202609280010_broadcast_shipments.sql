-- B07 first slice: only assigned good units ship, with immutable address and multiple tracking numbers.
begin;
create table public.broadcast_shipments (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,customer_id uuid not null,
 request_key uuid not null,address_snapshot jsonb not null,
 carrier text not null check(length(trim(carrier)) between 1 and 100),
 tracking_number text not null check(length(trim(tracking_number)) between 1 and 150),
 shipped_at timestamptz not null default clock_timestamp(),
 additional_customer_shipping_minor integer not null default 0 check(additional_customer_shipping_minor=0),
 created_by uuid not null references auth.users(id),
 unique(seller_id,id),unique(seller_id,request_key),
 foreign key(seller_id,customer_id) references public.broadcast_customers(seller_id,id)
);
create table public.broadcast_shipment_lines (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,
 shipment_id uuid not null,stock_allocation_id uuid not null,
 quantity integer not null check(quantity>0),
 unique(shipment_id,stock_allocation_id),
 foreign key(seller_id,shipment_id) references public.broadcast_shipments(seller_id,id),
 foreign key(seller_id,stock_allocation_id) references public.broadcast_stock_allocations(seller_id,id)
);
alter table public.broadcast_shipments enable row level security;
alter table public.broadcast_shipment_lines enable row level security;
revoke all on public.broadcast_shipments,public.broadcast_shipment_lines from public,anon,authenticated,service_role;

create function public.broadcast_shipment_create(p_seller_id uuid,p_data jsonb,p_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_shipment public.broadcast_shipments;v_address public.broadcast_customer_destinations;
 v_line jsonb;v_stock public.broadcast_stock_allocations;v_customer uuid;
 v_qty integer;v_used integer;v_count integer:=0;v_existing public.broadcast_shipments;
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_key is null or p_data is null or jsonb_typeof(p_data)<>'object'
  or jsonb_typeof(p_data->'lines')<>'array' or jsonb_array_length(p_data->'lines')<1 then
  raise exception '출고 상품을 확인해주세요.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into v_existing from public.broadcast_shipments where seller_id=p_seller_id and request_key=p_key;
 if found then
  if v_existing.customer_id<>(p_data->>'customer_id')::uuid or
   v_existing.carrier<>trim(p_data->>'carrier') or
   v_existing.tracking_number<>trim(p_data->>'tracking_number') or
   (select jsonb_agg(jsonb_build_object('stock_allocation_id',l.stock_allocation_id,
    'quantity',l.quantity) order by l.stock_allocation_id)
    from public.broadcast_shipment_lines l where l.seller_id=p_seller_id and l.shipment_id=v_existing.id)
   <>(select jsonb_agg(jsonb_build_object('stock_allocation_id',(x->>'stock_allocation_id')::uuid,
    'quantity',(x->>'quantity')::integer) order by (x->>'stock_allocation_id')::uuid)
    from jsonb_array_elements(p_data->'lines') x) then
   raise exception '같은 출고 키로 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
  return jsonb_build_object('shipment_id',v_existing.id,'tracking_number',v_existing.tracking_number,
   'line_count',(select count(*) from public.broadcast_shipment_lines l
    where l.seller_id=p_seller_id and l.shipment_id=v_existing.id));
 end if;
 v_customer:=(p_data->>'customer_id')::uuid;
 select * into v_address from public.broadcast_customer_destinations
  where seller_id=p_seller_id and customer_id=v_customer;
 if not found or v_address.address is null then
  raise exception '배송주소를 확인해주세요.' using errcode='22023'; end if;
 insert into public.broadcast_shipments(seller_id,customer_id,request_key,address_snapshot,
  carrier,tracking_number,created_by)
 values(p_seller_id,v_customer,p_key,v_address.address,trim(p_data->>'carrier'),
  trim(p_data->>'tracking_number'),auth.uid()) returning * into v_shipment;
 for v_line in select value from jsonb_array_elements(p_data->'lines') loop
  v_qty:=(v_line->>'quantity')::integer;
  select sa.* into v_stock from public.broadcast_stock_allocations sa
  join public.broadcast_purchase_allocations pa on pa.seller_id=sa.seller_id
   and pa.id=sa.purchase_allocation_id
  join public.broadcast_order_lines o on o.seller_id=pa.seller_id and o.id=pa.order_line_id
  where sa.seller_id=p_seller_id and sa.id=(v_line->>'stock_allocation_id')::uuid
   and o.customer_id=v_customer;
  if not found or v_qty is null or v_qty<1 then
   raise exception '고객에게 배정된 정상 상품을 선택해주세요.' using errcode='22023'; end if;
  select coalesce(sum(sl.quantity),0) into v_used from public.broadcast_shipment_lines sl
   where sl.seller_id=p_seller_id and sl.stock_allocation_id=v_stock.id;
  if v_qty>v_stock.quantity-v_used then
   raise exception '출고 가능 수량을 넘었습니다.' using errcode='22023'; end if;
  insert into public.broadcast_shipment_lines(seller_id,shipment_id,stock_allocation_id,quantity)
  values(p_seller_id,v_shipment.id,v_stock.id,v_qty);
  v_count:=v_count+1;
 end loop;
 return jsonb_build_object('shipment_id',v_shipment.id,'tracking_number',v_shipment.tracking_number,
  'line_count',v_count);
end $$;

create function public.broadcast_guest_shipments(p_locator uuid,p_session_hash text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_device public.broadcast_customer_devices;begin
 select d.* into v_device from public.broadcast_customer_devices d
 join public.broadcast_customer_links l on l.seller_id=d.seller_id and l.customer_id=d.customer_id
 where l.locator=p_locator and d.session_hash=p_session_hash and d.revoked_at is null
  and d.expires_at>clock_timestamp();
 if not found then raise exception '이 기기에서 출고를 볼 수 없습니다.' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'shipped_at',s.shipped_at,
  'carrier',s.carrier,'tracking_number',s.tracking_number,
  'lines',coalesce((select jsonb_agg(jsonb_build_object('order_line_id',o.id,
   'product_title',o.product_title,'color',o.color,'size',o.size,'quantity',sl.quantity))
   from public.broadcast_shipment_lines sl join public.broadcast_stock_allocations sa
    on sa.seller_id=sl.seller_id and sa.id=sl.stock_allocation_id
   join public.broadcast_purchase_allocations pa on pa.seller_id=sa.seller_id and pa.id=sa.purchase_allocation_id
   join public.broadcast_order_lines o on o.seller_id=pa.seller_id and o.id=pa.order_line_id
   where sl.seller_id=s.seller_id and sl.shipment_id=s.id),'[]'::jsonb))
  order by s.shipped_at desc,s.id)
  from public.broadcast_shipments s where s.seller_id=v_device.seller_id
   and s.customer_id=v_device.customer_id),'[]'::jsonb);
end $$;

revoke all on function public.broadcast_shipment_create(uuid,jsonb,uuid) from public,anon,service_role;
grant execute on function public.broadcast_shipment_create(uuid,jsonb,uuid) to authenticated;
revoke all on function public.broadcast_guest_shipments(uuid,text) from public,anon,authenticated;
grant execute on function public.broadcast_guest_shipments(uuid,text) to service_role;
commit;
