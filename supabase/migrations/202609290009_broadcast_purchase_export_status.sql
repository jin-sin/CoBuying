-- B05: supplier workbook reads live arrival and missing quantities from the same purchase rows.
begin;
create or replace function public.broadcast_purchase_tables(p_seller_id uuid,p_purchase_order_id uuid)
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
   'quantity',i.quantity,
   'latest_received_quantity',coalesce((select a.good_quantity+a.defect_quantity
    from public.broadcast_arrivals a where a.seller_id=i.seller_id
     and a.purchase_item_id=i.id and a.exchange_of_defect_id is null
    order by a.received_at desc,a.id desc limit 1),0),
   'cumulative_received_quantity',coalesce((select sum(a.good_quantity+a.defect_quantity)
    from public.broadcast_arrivals a where a.seller_id=i.seller_id
     and a.purchase_item_id=i.id and a.exchange_of_defect_id is null),0),
   'remaining_missing_quantity',i.quantity-coalesce((select sum(a.good_quantity+a.defect_quantity)
    from public.broadcast_arrivals a where a.seller_id=i.seller_id
     and a.purchase_item_id=i.id and a.exchange_of_defect_id is null),0),
   'defect_exchange_quantity',coalesce((select sum(d.quantity) from public.broadcast_defect_exchanges d
    join public.broadcast_arrivals a on a.seller_id=d.seller_id and a.id=d.arrival_id
    where a.seller_id=i.seller_id and a.purchase_item_id=i.id and d.status='waiting'),0),
   'note','') order by i.id)
   from public.broadcast_purchase_items i join public.broadcast_purchase_orders p
    on p.seller_id=i.seller_id and p.id=i.purchase_order_id
   join public.broadcast_products pr on pr.seller_id=i.seller_id and pr.id=i.product_id
   where i.seller_id=p_seller_id and i.purchase_order_id=p_purchase_order_id),'[]'::jsonb),
  'customers',coalesce((select jsonb_agg(jsonb_build_object('item_id',i.id,
   'product_title',o.product_title,'color',o.color,'size',o.size,
   'quantity',a.quantity,'customer_id',c.id,'nickname',c.nickname,
   'payment_confirmed',true,'status',case
    when coalesce((select sum(sl.quantity) from public.broadcast_shipment_lines sl
     join public.broadcast_stock_allocations sa on sa.seller_id=sl.seller_id
      and sa.id=sl.stock_allocation_id where sa.seller_id=a.seller_id
      and sa.purchase_allocation_id=a.id),0)>=a.quantity then '출고완료'
    when coalesce((select sum(sl.quantity) from public.broadcast_shipment_lines sl
     join public.broadcast_stock_allocations sa on sa.seller_id=sl.seller_id
      and sa.id=sl.stock_allocation_id where sa.seller_id=a.seller_id
      and sa.purchase_allocation_id=a.id),0)>0 then '부분출고'
    when coalesce((select sum(sa.quantity) from public.broadcast_stock_allocations sa
     where sa.seller_id=a.seller_id and sa.purchase_allocation_id=a.id),0)>=a.quantity then '입고'
    when coalesce((select sum(sa.quantity) from public.broadcast_stock_allocations sa
     where sa.seller_id=a.seller_id and sa.purchase_allocation_id=a.id),0)>0 then '부분입고'
    else '미송' end,'note',o.note) order by o.sequence)
   from public.broadcast_purchase_allocations a join public.broadcast_purchase_items i
    on i.seller_id=a.seller_id and i.id=a.purchase_item_id
   join public.broadcast_order_lines o on o.seller_id=a.seller_id and o.id=a.order_line_id
   join public.broadcast_customers c on c.seller_id=o.seller_id and c.id=o.customer_id
   where a.seller_id=p_seller_id and i.purchase_order_id=p_purchase_order_id),'[]'::jsonb));
end $$;
commit;
