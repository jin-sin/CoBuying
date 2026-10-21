-- B08 customer-first overdue purchase detail; read-only and manager scoped.
begin;
create function public.broadcast_missing_detail(p_seller_id uuid,p_customer_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object(
  'product_title',o.product_title,'color',o.color,'size',o.size,
  'supplier',po.supplier,'ordered_at',po.ordered_at,
  'days',floor(extract(epoch from (clock_timestamp()-po.ordered_at))/86400)::integer,
  'missing_quantity',pa.quantity-coalesce((select sum(sa.quantity)
    from public.broadcast_stock_allocations sa where sa.seller_id=pa.seller_id
     and sa.purchase_allocation_id=pa.id),0)) order by po.ordered_at,o.sequence)
 from public.broadcast_purchase_allocations pa join public.broadcast_order_lines o
  on o.seller_id=pa.seller_id and o.id=pa.order_line_id
 join public.broadcast_purchase_items pi on pi.seller_id=pa.seller_id and pi.id=pa.purchase_item_id
 join public.broadcast_purchase_orders po on po.seller_id=pi.seller_id and po.id=pi.purchase_order_id
 where pa.seller_id=p_seller_id and o.customer_id=p_customer_id
  and po.ordered_at<clock_timestamp()-interval '14 days'
  and pa.quantity>coalesce((select sum(sa.quantity) from public.broadcast_stock_allocations sa
   where sa.seller_id=pa.seller_id and sa.purchase_allocation_id=pa.id),0)
 ),'[]'::jsonb);
end $$;
revoke all on function public.broadcast_missing_detail(uuid,uuid) from public,anon,service_role;
grant execute on function public.broadcast_missing_detail(uuid,uuid) to authenticated;
commit;
