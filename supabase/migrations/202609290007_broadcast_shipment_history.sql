-- B07: seller-only keyset history, including fully shipped customers.
begin;
create function public.broadcast_shipment_history(p_seller_id uuid,p_customer_id uuid default null,
 p_before_at timestamptz default null,p_before_id uuid default null,p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_items jsonb;v_cursor jsonb;begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if (p_before_at is null)<>(p_before_id is null) then
  raise exception '출고 페이지 커서를 확인해주세요.' using errcode='22023'; end if;
 with page as (
  select s.id,s.customer_id,c.nickname,s.shipped_at,s.carrier,s.tracking_number,
   s.address_snapshot,s.additional_customer_shipping_minor
  from public.broadcast_shipments s join public.broadcast_customers c
   on c.seller_id=s.seller_id and c.id=s.customer_id
  where s.seller_id=p_seller_id and (p_customer_id is null or s.customer_id=p_customer_id)
   and (p_before_at is null or (s.shipped_at,s.id)<(p_before_at,p_before_id))
  order by s.shipped_at desc,s.id desc limit least(greatest(coalesce(p_limit,50),1),100)
 ), detail as (
  select p.*,coalesce((select jsonb_agg(jsonb_build_object(
   'order_line_id',o.id,'product_title',o.product_title,'color',o.color,
   'size',o.size,'quantity',sl.quantity) order by o.sequence,sl.id)
   from public.broadcast_shipment_lines sl
   join public.broadcast_stock_allocations sa on sa.seller_id=sl.seller_id and sa.id=sl.stock_allocation_id
   join public.broadcast_purchase_allocations pa on pa.seller_id=sa.seller_id and pa.id=sa.purchase_allocation_id
   join public.broadcast_order_lines o on o.seller_id=pa.seller_id and o.id=pa.order_line_id
   where sl.seller_id=p_seller_id and sl.shipment_id=p.id),'[]'::jsonb) as lines
  from page p
 )
 select coalesce(jsonb_agg(to_jsonb(d) order by d.shipped_at desc,d.id desc),'[]'::jsonb)
 into v_items from detail d;
 select jsonb_build_object('shipped_at',s.shipped_at,'id',s.id) into v_cursor
 from public.broadcast_shipments s
 where s.seller_id=p_seller_id and (p_customer_id is null or s.customer_id=p_customer_id)
  and (p_before_at is null or (s.shipped_at,s.id)<(p_before_at,p_before_id))
 order by s.shipped_at desc,s.id desc
 offset least(greatest(coalesce(p_limit,50),1),100)-1 limit 1;
 if jsonb_array_length(v_items)<least(greatest(coalesce(p_limit,50),1),100) then v_cursor:=null; end if;
 return jsonb_build_object('items',v_items,'next_cursor',v_cursor);
end $$;
revoke all on function public.broadcast_shipment_history(uuid,uuid,timestamptz,uuid,integer)
 from public,anon,service_role;
grant execute on function public.broadcast_shipment_history(uuid,uuid,timestamptz,uuid,integer)
 to authenticated;
commit;
