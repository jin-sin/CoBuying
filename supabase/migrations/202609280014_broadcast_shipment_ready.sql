-- B07 manager view of allocated, good and not-yet-shipped units.
begin;
create function public.broadcast_shipment_ready(p_seller_id uuid,p_customer_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object(
  'stock_allocation_id',x.stock_allocation_id,'customer_id',x.customer_id,
  'nickname',x.nickname,'product_title',x.product_title,'color',x.color,
  'size',x.size,'available_quantity',x.available_quantity)
  order by x.nickname,x.order_sequence,x.stock_allocation_id)
 from (select sa.id as stock_allocation_id,o.customer_id,c.nickname,
  o.product_title,o.color,o.size,o.sequence as order_sequence,
  sa.quantity-coalesce((select sum(sl.quantity) from public.broadcast_shipment_lines sl
   where sl.seller_id=sa.seller_id and sl.stock_allocation_id=sa.id),0) as available_quantity
  from public.broadcast_stock_allocations sa join public.broadcast_purchase_allocations pa
   on pa.seller_id=sa.seller_id and pa.id=sa.purchase_allocation_id
  join public.broadcast_order_lines o on o.seller_id=pa.seller_id and o.id=pa.order_line_id
  join public.broadcast_customers c on c.seller_id=o.seller_id and c.id=o.customer_id
  where sa.seller_id=p_seller_id and (p_customer_id is null or o.customer_id=p_customer_id)
 ) x where x.available_quantity>0),'[]'::jsonb);
end $$;
revoke all on function public.broadcast_shipment_ready(uuid,uuid) from public,anon,service_role;
grant execute on function public.broadcast_shipment_ready(uuid,uuid) to authenticated;
commit;
