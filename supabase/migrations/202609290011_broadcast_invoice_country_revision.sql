-- B03: unpaid invoice country correction recalculates shipping and requires a new address/acceptance.
begin;
create table public.broadcast_invoice_country_commands (
 seller_id uuid not null,actor_id uuid not null references auth.users(id),key uuid not null,
 invoice_id uuid not null,country text not null,reason text not null,result jsonb not null,
 primary key(seller_id,actor_id,key)
);
alter table public.broadcast_invoice_country_commands enable row level security;
revoke all on public.broadcast_invoice_country_commands from public,anon,authenticated,service_role;
create function public.broadcast_invoice_country_revise(p_seller_id uuid,p_invoice_id uuid,
 p_country text,p_reason text,p_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_old public.broadcast_invoice_country_commands;v_invoice public.broadcast_invoices;
 v_destination public.broadcast_customer_destinations;v_created jsonb;
 v_new public.broadcast_invoices;v_result jsonb;begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_key is null or p_invoice_id is null or p_country is null or p_country not in ('KR','CN') or
  length(trim(coalesce(p_reason,''))) not between 1 and 500 then
  raise exception '배송국가와 정정 사유를 확인해주세요.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into v_old from public.broadcast_invoice_country_commands
  where seller_id=p_seller_id and actor_id=auth.uid() and key=p_key;
 if found then
  if v_old.invoice_id<>p_invoice_id or v_old.country<>p_country or
   v_old.reason<>trim(p_reason) then
   raise exception '같은 국가 정정 키로 내용을 바꿀 수 없습니다.' using errcode='22023'; end if;
  return v_old.result;
 end if;
 select * into v_invoice from public.broadcast_invoices where seller_id=p_seller_id
  and id=p_invoice_id and status='issued' for update;
 if not found then raise exception '현재 청구서를 찾을 수 없습니다.' using errcode='22023'; end if;
 select * into v_destination from public.broadcast_customer_destinations
  where seller_id=p_seller_id and customer_id=v_invoice.customer_id for update;
 if not found or v_destination.country=p_country then
  raise exception '새 배송국가를 확인해주세요.' using errcode='22023'; end if;
 if exists(select 1 from public.broadcast_evidence e where e.seller_id=p_seller_id
  and e.invoice_id=p_invoice_id) or
  exists(select 1 from public.broadcast_receipts r where r.seller_id=p_seller_id
   and r.invoice_id=p_invoice_id) or
  exists(select 1 from public.broadcast_order_lines o where o.seller_id=p_seller_id
   and o.invoice_id=p_invoice_id and o.payment_locked) or
  exists(select 1 from public.broadcast_purchase_allocations pa
   join public.broadcast_invoice_lines il on il.seller_id=pa.seller_id
    and il.order_line_id=pa.order_line_id where il.invoice_id=p_invoice_id) then
  raise exception '증빙·입금·발주가 진행된 정산서는 국가를 자동 정정할 수 없습니다.' using errcode='22023'; end if;
 perform 1 from public.broadcast_order_lines o where o.seller_id=p_seller_id
  and o.invoice_id=p_invoice_id for update;
 update public.broadcast_deposit_allocations set reversed_at=clock_timestamp()
  where seller_id=p_seller_id and invoice_id=p_invoice_id and reversed_at is null;
 update public.broadcast_invoices set status='superseded' where id=p_invoice_id;
 update public.broadcast_order_lines set invoice_id=null
  where seller_id=p_seller_id and invoice_id=p_invoice_id;
 update public.broadcast_customer_destinations set country=p_country,address=null,
  version=version+1,updated_at=clock_timestamp()
  where seller_id=p_seller_id and customer_id=v_invoice.customer_id;
 v_created:=public.broadcast_billing_command(p_seller_id,'invoice.issue',
  jsonb_build_object('customer_id',v_invoice.customer_id,'session_id',v_invoice.session_id),
  gen_random_uuid());
 update public.broadcast_invoices set series_id=v_invoice.series_id,
  version=v_invoice.version+1,
  snapshot=snapshot||jsonb_build_object('revised_from',v_invoice.id,
   'revision_reason',trim(p_reason),'old_country',v_destination.country)
 where id=(v_created->>'id')::uuid returning * into v_new;
 v_result:=to_jsonb(v_new);
 insert into public.broadcast_invoice_country_commands(seller_id,actor_id,key,invoice_id,
  country,reason,result) values(p_seller_id,auth.uid(),p_key,p_invoice_id,p_country,
  trim(p_reason),v_result);
 return v_result;
end $$;
revoke all on function public.broadcast_invoice_country_revise(uuid,uuid,text,text,uuid)
 from public,anon,service_role;
grant execute on function public.broadcast_invoice_country_revise(uuid,uuid,text,text,uuid)
 to authenticated;
commit;
