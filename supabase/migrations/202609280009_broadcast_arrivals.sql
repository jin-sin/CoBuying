-- B06 first slice: quantity events and original-order allocation.
begin;
create table public.broadcast_arrivals (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,
 purchase_item_id uuid not null,request_key uuid not null,
 good_quantity integer not null default 0 check(good_quantity>=0),
 defect_quantity integer not null default 0 check(defect_quantity>=0),
 received_at timestamptz not null default clock_timestamp(),
 recorded_by uuid not null references auth.users(id),
 unique(seller_id,id),unique(seller_id,request_key),
 check(good_quantity+defect_quantity>0),
 foreign key(seller_id,purchase_item_id) references public.broadcast_purchase_items(seller_id,id)
);
create table public.broadcast_stock_allocations (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,
 purchase_allocation_id uuid not null,arrival_id uuid not null,
 quantity integer not null check(quantity>0),created_at timestamptz not null default clock_timestamp(),
 unique(seller_id,id),unique(purchase_allocation_id,arrival_id),
 foreign key(seller_id,purchase_allocation_id) references public.broadcast_purchase_allocations(seller_id,id),
 foreign key(seller_id,arrival_id) references public.broadcast_arrivals(seller_id,id)
);
create table public.broadcast_defect_exchanges (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,
 arrival_id uuid not null,quantity integer not null check(quantity>0),
 status text not null default 'waiting' check(status in ('waiting','replaced')),
 replaced_at timestamptz,
 unique(seller_id,id),foreign key(seller_id,arrival_id) references public.broadcast_arrivals(seller_id,id)
);
alter table public.broadcast_arrivals add column exchange_of_defect_id uuid unique
 references public.broadcast_defect_exchanges(id);
create table public.broadcast_inventory_commands (
 seller_id uuid not null,actor_id uuid not null references auth.users(id),key uuid not null,
 command text not null,payload jsonb not null,result jsonb not null,
 primary key(seller_id,actor_id,key)
);
do $$ declare t text; begin
 foreach t in array array['broadcast_arrivals','broadcast_stock_allocations',
 'broadcast_defect_exchanges','broadcast_inventory_commands'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated,service_role',t);
 end loop;
end $$;

create function public.broadcast_inventory_command(p_seller_id uuid,p_command text,p_data jsonb,p_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_old public.broadcast_inventory_commands;v_item public.broadcast_purchase_items;
 v_arrival public.broadcast_arrivals;v_defect public.broadcast_defect_exchanges;
 v_ordered integer;v_received integer;
 v_available integer;v_need integer;v_take integer;v_alloc record;v_source record;
 v_result jsonb;v_count integer:=0;
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_key is null or p_data is null or jsonb_typeof(p_data)<>'object' then
  raise exception '입고 명령을 확인해주세요.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into v_old from public.broadcast_inventory_commands where seller_id=p_seller_id
  and actor_id=auth.uid() and key=p_key;
 if found then
  if v_old.command<>p_command or v_old.payload<>p_data then
   raise exception '같은 입고 키로 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
  return v_old.result;
 end if;
 select * into v_item from public.broadcast_purchase_items
  where seller_id=p_seller_id and id=(p_data->>'purchase_item_id')::uuid for update;
 if not found then raise exception '발주 항목을 찾을 수 없습니다.' using errcode='22023'; end if;
 if p_command='arrival.record' then
  v_received:=coalesce((select sum(a.good_quantity+a.defect_quantity)
   from public.broadcast_arrivals a where a.seller_id=p_seller_id and a.purchase_item_id=v_item.id
    and a.exchange_of_defect_id is null),0);
  v_ordered:=v_item.quantity;
  if coalesce((p_data->>'good_quantity')::integer,0)<0 or
   coalesce((p_data->>'defect_quantity')::integer,0)<0 or
   coalesce((p_data->>'good_quantity')::integer,0)+coalesce((p_data->>'defect_quantity')::integer,0)<1 or
   v_received+coalesce((p_data->>'good_quantity')::integer,0)+
    coalesce((p_data->>'defect_quantity')::integer,0)>v_ordered then
   raise exception '발주 잔량을 넘는 입고입니다.' using errcode='22023'; end if;
  insert into public.broadcast_arrivals(seller_id,purchase_item_id,request_key,
   good_quantity,defect_quantity,recorded_by)
  values(p_seller_id,v_item.id,p_key,coalesce((p_data->>'good_quantity')::integer,0),
   coalesce((p_data->>'defect_quantity')::integer,0),auth.uid()) returning * into v_arrival;
  if v_arrival.defect_quantity>0 then
   insert into public.broadcast_defect_exchanges(seller_id,arrival_id,quantity)
   values(p_seller_id,v_arrival.id,v_arrival.defect_quantity);
  end if;
  v_result:=jsonb_build_object('arrival_id',v_arrival.id,'good_quantity',v_arrival.good_quantity,
   'defect_quantity',v_arrival.defect_quantity,'remaining_unreceived',
   v_ordered-v_received-v_arrival.good_quantity-v_arrival.defect_quantity);
 elsif p_command='exchange.receive' then
  select d.* into v_defect from public.broadcast_defect_exchanges d
   join public.broadcast_arrivals a on a.seller_id=d.seller_id and a.id=d.arrival_id
   where d.seller_id=p_seller_id and d.id=(p_data->>'defect_id')::uuid
    and a.purchase_item_id=v_item.id for update;
  if not found or v_defect.status<>'waiting' or
   (p_data->>'quantity')::integer is distinct from v_defect.quantity then
   raise exception '교환 대기 수량을 확인해주세요.' using errcode='22023'; end if;
  insert into public.broadcast_arrivals(seller_id,purchase_item_id,request_key,
   good_quantity,defect_quantity,recorded_by,exchange_of_defect_id)
  values(p_seller_id,v_item.id,p_key,v_defect.quantity,0,auth.uid(),v_defect.id)
  returning * into v_arrival;
  update public.broadcast_defect_exchanges set status='replaced',replaced_at=clock_timestamp()
   where id=v_defect.id;
  v_result:=jsonb_build_object('arrival_id',v_arrival.id,'replaced_quantity',v_defect.quantity);
 elsif p_command='allocation.commit' then
  for v_source in select a.*,a.good_quantity-
    coalesce((select sum(sa.quantity) from public.broadcast_stock_allocations sa
     where sa.seller_id=p_seller_id and sa.arrival_id=a.id),0) as available
   from public.broadcast_arrivals a where a.seller_id=p_seller_id
    and a.purchase_item_id=v_item.id order by a.received_at,a.id loop
   v_available:=v_source.available;
   if v_available<=0 then continue; end if;
   for v_alloc in select pa.*,o.sequence,
     pa.quantity-coalesce((select sum(sa.quantity) from public.broadcast_stock_allocations sa
      where sa.seller_id=p_seller_id and sa.purchase_allocation_id=pa.id),0) as need
    from public.broadcast_purchase_allocations pa join public.broadcast_order_lines o
     on o.seller_id=pa.seller_id and o.id=pa.order_line_id
    where pa.seller_id=p_seller_id and pa.purchase_item_id=v_item.id
    order by o.sequence loop
    v_need:=v_alloc.need;v_take:=least(v_available,v_need);
    if v_take<=0 then continue; end if;
    insert into public.broadcast_stock_allocations(seller_id,purchase_allocation_id,arrival_id,quantity)
    values(p_seller_id,v_alloc.id,v_source.id,v_take);
    v_available:=v_available-v_take;v_count:=v_count+1;
    if v_available=0 then exit; end if;
   end loop;
  end loop;
  v_result:=jsonb_build_object('purchase_item_id',v_item.id,'allocation_events',v_count);
 else raise exception '지원하지 않는 입고 명령입니다.' using errcode='22023'; end if;
 insert into public.broadcast_inventory_commands(seller_id,actor_id,key,command,payload,result)
 values(p_seller_id,auth.uid(),p_key,p_command,p_data,v_result);
 return v_result;
end $$;

create function public.broadcast_inventory_status(p_seller_id uuid,p_purchase_item_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_item public.broadcast_purchase_items;begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 select * into v_item from public.broadcast_purchase_items
  where seller_id=p_seller_id and id=p_purchase_item_id;
 if not found then raise exception '발주 항목을 찾을 수 없습니다.' using errcode='22023'; end if;
 return jsonb_build_object('purchase_item_id',v_item.id,'ordered',v_item.quantity,
  'arrived_good',coalesce((select sum(good_quantity) from public.broadcast_arrivals
   where seller_id=p_seller_id and purchase_item_id=v_item.id),0),
  'defect_waiting',coalesce((select sum(d.quantity) from public.broadcast_defect_exchanges d
   join public.broadcast_arrivals a on a.seller_id=d.seller_id and a.id=d.arrival_id
   where a.seller_id=p_seller_id and a.purchase_item_id=v_item.id and d.status='waiting'),0),
  'allocated',coalesce((select sum(sa.quantity) from public.broadcast_stock_allocations sa
   join public.broadcast_arrivals a on a.seller_id=sa.seller_id and a.id=sa.arrival_id
   where a.seller_id=p_seller_id and a.purchase_item_id=v_item.id),0),
  'unreceived',v_item.quantity-coalesce((select sum(a.good_quantity+a.defect_quantity)
   from public.broadcast_arrivals a where a.seller_id=p_seller_id and a.purchase_item_id=v_item.id
    and a.exchange_of_defect_id is null),0));
end $$;

revoke all on function public.broadcast_inventory_command(uuid,text,jsonb,uuid),
 public.broadcast_inventory_status(uuid,uuid) from public,anon,service_role;
grant execute on function public.broadcast_inventory_command(uuid,text,jsonb,uuid),
 public.broadcast_inventory_status(uuid,uuid) to authenticated;
commit;
