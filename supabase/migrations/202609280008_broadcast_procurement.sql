-- B05 first slice: paid-only supplier batches and linked customer allocation.
begin;
create table public.broadcast_purchase_orders (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,
 supplier text not null,batch_key uuid not null,
 ordered_at timestamptz not null default clock_timestamp(),
 unique(seller_id,id),unique(seller_id,batch_key,supplier)
);
create table public.broadcast_purchase_items (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,
 purchase_order_id uuid not null,product_id uuid not null,
 color text not null,size text not null,quantity integer not null check(quantity>0),
 unique(seller_id,id),unique(purchase_order_id,product_id,color,size),
 foreign key(seller_id,purchase_order_id) references public.broadcast_purchase_orders(seller_id,id),
 foreign key(seller_id,product_id) references public.broadcast_products(seller_id,id)
);
create table public.broadcast_purchase_allocations (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,
 purchase_item_id uuid not null,order_line_id uuid not null,
 quantity integer not null check(quantity>0),created_at timestamptz not null default clock_timestamp(),
 unique(seller_id,id),unique(purchase_item_id,order_line_id),
 foreign key(seller_id,purchase_item_id) references public.broadcast_purchase_items(seller_id,id),
 foreign key(seller_id,order_line_id) references public.broadcast_order_lines(seller_id,id)
);
create table public.broadcast_purchase_commands (
 seller_id uuid not null,actor_id uuid not null references auth.users(id),key uuid not null,
 payload jsonb not null,result jsonb not null,primary key(seller_id,actor_id,key)
);
do $$ declare t text; begin
 foreach t in array array['broadcast_purchase_orders','broadcast_purchase_items',
 'broadcast_purchase_allocations','broadcast_purchase_commands'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated,service_role',t);
 end loop;
end $$;

create function public.broadcast_purchase_preview(p_seller_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 return coalesce((with eligible as (
  select o.id,o.supplier,o.product_id,o.color,o.size,
   o.quantity-coalesce((select sum(a.quantity) from public.broadcast_purchase_allocations a
    where a.seller_id=o.seller_id and a.order_line_id=o.id),0) as remaining
  from public.broadcast_order_lines o join public.broadcast_invoices i
   on i.seller_id=o.seller_id and i.id=o.invoice_id
  join public.broadcast_customer_destinations d on d.seller_id=i.seller_id and d.customer_id=i.customer_id
  where o.seller_id=p_seller_id and not o.cancelled and i.status='issued'
   and i.accepted_at is not null and d.address is not null
   and (case when i.selected_currency='CNY' then i.total_cny_fen else i.total_krw end)
    <=coalesce((select sum(r.confirmed_minor) from public.broadcast_receipts r
      where r.seller_id=i.seller_id and r.invoice_id=i.id and r.status='confirmed'),0)
 ) select jsonb_agg(jsonb_build_object('supplier',x.supplier,'product_id',x.product_id,
  'color',x.color,'size',x.size,'quantity',x.quantity) order by x.supplier,x.product_id,x.color,x.size)
 from (select supplier,product_id,color,size,sum(remaining) as quantity
  from eligible where remaining>0 group by supplier,product_id,color,size) x),'[]'::jsonb);
end $$;

create function public.broadcast_purchase_commit(p_seller_id uuid,p_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_old public.broadcast_purchase_commands;v_line record;
 v_order_id uuid;v_item_id uuid;v_remaining integer;v_count integer:=0;v_result jsonb;
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_key is null then raise exception '발주 키가 필요합니다.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into v_old from public.broadcast_purchase_commands where seller_id=p_seller_id
  and actor_id=auth.uid() and key=p_key;
 if found then return v_old.result; end if;
 for v_line in
  select o.*,o.quantity-coalesce((select sum(a.quantity) from public.broadcast_purchase_allocations a
   where a.seller_id=p_seller_id and a.order_line_id=o.id),0) as remaining
  from public.broadcast_order_lines o join public.broadcast_invoices i
   on i.seller_id=o.seller_id and i.id=o.invoice_id
  join public.broadcast_customer_destinations d on d.seller_id=i.seller_id and d.customer_id=i.customer_id
  where o.seller_id=p_seller_id and not o.cancelled and i.status='issued'
   and i.accepted_at is not null and d.address is not null
   and (case when i.selected_currency='CNY' then i.total_cny_fen else i.total_krw end)
    <=coalesce((select sum(r.confirmed_minor) from public.broadcast_receipts r
      where r.seller_id=i.seller_id and r.invoice_id=i.id and r.status='confirmed'),0)
  order by o.sequence
 loop
  v_remaining:=v_line.remaining;
  if v_remaining<=0 then continue; end if;
  insert into public.broadcast_purchase_orders(seller_id,supplier,batch_key)
  values(p_seller_id,v_line.supplier,p_key)
  on conflict(seller_id,batch_key,supplier) do update set supplier=excluded.supplier
  returning id into v_order_id;
  insert into public.broadcast_purchase_items(seller_id,purchase_order_id,product_id,color,size,quantity)
  values(p_seller_id,v_order_id,v_line.product_id,v_line.color,v_line.size,v_remaining)
  on conflict(purchase_order_id,product_id,color,size) do update
   set quantity=broadcast_purchase_items.quantity+excluded.quantity
  returning id into v_item_id;
  insert into public.broadcast_purchase_allocations(seller_id,purchase_item_id,order_line_id,quantity)
  values(p_seller_id,v_item_id,v_line.id,v_remaining);
  v_count:=v_count+1;
 end loop;
 v_result:=jsonb_build_object('batch_key',p_key,'order_line_count',v_count,
  'purchase_orders',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'supplier',p.supplier)
   order by p.supplier) from public.broadcast_purchase_orders p
   where p.seller_id=p_seller_id and p.batch_key=p_key),'[]'::jsonb));
 insert into public.broadcast_purchase_commands(seller_id,actor_id,key,payload,result)
 values(p_seller_id,auth.uid(),p_key,'{}'::jsonb,v_result);
 return v_result;
end $$;

create function public.broadcast_purchase_tables(p_seller_id uuid,p_purchase_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if not exists(select 1 from public.broadcast_purchase_orders p
  where p.seller_id=p_seller_id and p.id=p_purchase_order_id) then
  raise exception '발주를 찾을 수 없습니다.' using errcode='22023'; end if;
 return jsonb_build_object(
  'supplier',coalesce((select jsonb_agg(jsonb_build_object('item_id',i.id,
   'supplier',p.supplier,'product_title',pr.title,'color',i.color,'size',i.size,
   'quantity',i.quantity) order by i.id)
   from public.broadcast_purchase_items i join public.broadcast_purchase_orders p
    on p.seller_id=i.seller_id and p.id=i.purchase_order_id
   join public.broadcast_products pr on pr.seller_id=i.seller_id and pr.id=i.product_id
   where i.seller_id=p_seller_id and i.purchase_order_id=p_purchase_order_id),'[]'::jsonb),
  'customers',coalesce((select jsonb_agg(jsonb_build_object('item_id',i.id,
   'product_title',o.product_title,'color',o.color,'size',o.size,
   'quantity',a.quantity,'customer_id',c.id,'nickname',c.nickname,
   'payment_confirmed',true,'status','ordered','note',o.note) order by o.sequence)
   from public.broadcast_purchase_allocations a join public.broadcast_purchase_items i
    on i.seller_id=a.seller_id and i.id=a.purchase_item_id
   join public.broadcast_order_lines o on o.seller_id=a.seller_id and o.id=a.order_line_id
   join public.broadcast_customers c on c.seller_id=o.seller_id and c.id=o.customer_id
   where a.seller_id=p_seller_id and i.purchase_order_id=p_purchase_order_id),'[]'::jsonb));
end $$;

revoke all on function public.broadcast_purchase_preview(uuid),
 public.broadcast_purchase_commit(uuid,uuid),public.broadcast_purchase_tables(uuid,uuid)
 from public,anon,service_role;
grant execute on function public.broadcast_purchase_preview(uuid),
 public.broadcast_purchase_commit(uuid,uuid),public.broadcast_purchase_tables(uuid,uuid)
 to authenticated;
commit;
