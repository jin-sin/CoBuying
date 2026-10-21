-- B06 manager-only outstanding exchanges.
begin;
create function public.broadcast_defect_page(p_seller_id uuid,p_purchase_item_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'quantity',d.quantity,
  'status',d.status,'received_at',a.received_at) order by a.received_at,d.id)
 from public.broadcast_defect_exchanges d join public.broadcast_arrivals a
  on a.seller_id=d.seller_id and a.id=d.arrival_id
 where d.seller_id=p_seller_id and a.purchase_item_id=p_purchase_item_id
  and d.status='waiting'),'[]'::jsonb);
end $$;
revoke all on function public.broadcast_defect_page(uuid,uuid) from public,anon,service_role;
grant execute on function public.broadcast_defect_page(uuid,uuid) to authenticated;
commit;
