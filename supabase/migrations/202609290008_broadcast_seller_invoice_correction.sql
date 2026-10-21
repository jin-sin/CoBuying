-- B03: separate public RPC name for seller-initiated billed-line correction.
begin;
create or replace function public.broadcast_invoice_revision_preview(p_seller_id uuid,
 p_customer_id uuid,p_session_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v_invoice public.broadcast_invoices;begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 select * into v_invoice from public.broadcast_invoices where seller_id=p_seller_id
  and customer_id=p_customer_id and session_id=p_session_id and status='issued'
  order by issued_at desc,id desc limit 1;
 if not found then return null; end if;
 return jsonb_build_object('id',v_invoice.id,'version',v_invoice.version,
  'total_krw',v_invoice.total_krw,'accepted_at',v_invoice.accepted_at,
  'locked',exists(select 1 from public.broadcast_evidence e where e.seller_id=p_seller_id
   and e.invoice_id=v_invoice.id)
   or exists(select 1 from public.broadcast_order_lines o where o.seller_id=p_seller_id
    and o.invoice_id=v_invoice.id and o.payment_locked)
   or exists(select 1 from public.broadcast_receipts r where r.seller_id=p_seller_id
    and r.invoice_id=v_invoice.id)
   or exists(select 1 from public.broadcast_purchase_allocations pa
    join public.broadcast_invoice_lines il on il.seller_id=pa.seller_id
     and il.order_line_id=pa.order_line_id where il.invoice_id=v_invoice.id),
  'lines',coalesce((select jsonb_agg(jsonb_build_object('id',il.order_line_id,
   'product_title',il.snapshot->>'product_title','color',o.color,'size',o.size,
   'quantity',o.quantity,'unit_price_krw',o.unit_price_krw,'current_version',o.version)
   order by (il.snapshot->>'sequence')::bigint)
   from public.broadcast_invoice_lines il join public.broadcast_order_lines o
    on o.seller_id=il.seller_id and o.id=il.order_line_id
   where il.invoice_id=v_invoice.id),'[]'::jsonb));
end $$;
create function public.broadcast_invoice_revise_line(p_seller_id uuid,p_invoice_id uuid,
 p_change jsonb,p_reason text,p_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 return public.broadcast_invoice_revise_request(p_seller_id,p_invoice_id,null,
  p_change,p_reason,p_key);
end $$;
revoke all on function public.broadcast_invoice_revise_line(uuid,uuid,jsonb,text,uuid)
 from public,anon,service_role;
grant execute on function public.broadcast_invoice_revise_line(uuid,uuid,jsonb,text,uuid)
 to authenticated;
commit;
