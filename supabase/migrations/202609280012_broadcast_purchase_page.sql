-- B05 manager-only purchase history for export and arrival work.
begin;
create or replace function public.broadcast_purchase_preview(p_seller_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 return coalesce((with eligible as (
  select o.id,o.supplier,o.product_id,o.product_title,o.color,o.size,
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
  'product_title',x.product_title,'color',x.color,'size',x.size,'quantity',x.quantity)
  order by x.supplier,x.product_title,x.color,x.size)
 from (select supplier,product_id,product_title,color,size,sum(remaining) as quantity
  from eligible where remaining>0 group by supplier,product_id,product_title,color,size) x),'[]'::jsonb);
end $$;
create function public.broadcast_purchase_page(p_seller_id uuid,p_limit integer default 50,
 p_before timestamptz default null,p_before_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_items jsonb;v_last jsonb;
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_limit<1 or p_limit>100 or (p_before is null)<>(p_before_id is null) then
  raise exception '페이지 인자가 올바르지 않습니다.' using errcode='22023'; end if;
 with page as (
  select p.id,p.supplier,p.ordered_at,
   (select coalesce(sum(i.quantity),0) from public.broadcast_purchase_items i
    where i.seller_id=p.seller_id and i.purchase_order_id=p.id) as quantity
  from public.broadcast_purchase_orders p where p.seller_id=p_seller_id
   and (p_before is null or (p.ordered_at,p.id)<(p_before,p_before_id))
  order by p.ordered_at desc,p.id desc limit p_limit
 ) select coalesce(jsonb_agg(to_jsonb(page) order by ordered_at desc,id desc),'[]'::jsonb)
 into v_items from page;
 select value into v_last from jsonb_array_elements(v_items) value
  order by (value->>'ordered_at') asc,(value->>'id') asc limit 1;
 return jsonb_build_object('items',v_items,'next_before',v_last->>'ordered_at',
  'next_before_id',v_last->>'id');
end $$;
revoke all on function public.broadcast_purchase_page(uuid,integer,timestamptz,uuid)
 from public,anon,service_role;
grant execute on function public.broadcast_purchase_page(uuid,integer,timestamptz,uuid)
 to authenticated;
commit;
