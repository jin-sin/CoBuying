-- B03 manager review before issuing an invoice; the issue command remains authoritative.
begin;
create function public.broadcast_billing_preview(p_seller_id uuid,p_customer_id uuid,p_session_id uuid)
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
    where a.seller_id=d.seller_id and a.deposit_id=d.id and a.reversed_at is null),0))
   from public.broadcast_deposits d where d.seller_id=p_seller_id and d.customer_id=p_customer_id),0));
end $$;
revoke all on function public.broadcast_billing_preview(uuid,uuid,uuid) from public,anon,service_role;
grant execute on function public.broadcast_billing_preview(uuid,uuid,uuid) to authenticated;
commit;
