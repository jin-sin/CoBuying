-- B03: apply a customer's billed-line change in the same transaction as invoice reissue.
begin;
create table public.broadcast_invoice_detail_commands (
 seller_id uuid not null,actor_id uuid not null references auth.users(id),
 key uuid not null,invoice_id uuid not null,request_id uuid,
 change jsonb not null,reason text not null,result jsonb not null,
 primary key(seller_id,actor_id,key)
);
alter table public.broadcast_invoice_detail_commands enable row level security;
revoke all on public.broadcast_invoice_detail_commands from public,anon,authenticated,service_role;

create or replace function public.broadcast_customer_request_page(p_seller_id uuid,
 p_status text default 'pending',p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_status is null or p_status not in ('pending','accepted','declined') then
  raise exception '요청 상태를 확인해주세요.' using errcode='22023'; end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at,x.id)
  from (select r.id,r.customer_id,c.nickname,r.kind,r.product_id,r.order_line_id,
   coalesce(r.product_snapshot->>'title',o.product_title) as product_title,
   o.color as current_color,o.size as current_size,o.quantity as current_quantity,
   o.unit_price_krw as current_unit_price_krw,o.version as current_version,
   o.invoice_id,o.session_id,r.raw_text,r.reserved_sequence,
   r.status,r.created_at,r.resolution
   from public.broadcast_customer_requests r join public.broadcast_customers c
    on c.seller_id=r.seller_id and c.id=r.customer_id
   left join public.broadcast_order_lines o on o.seller_id=r.seller_id and o.id=r.order_line_id
   where r.seller_id=p_seller_id and r.status=p_status
   order by r.created_at,r.id limit least(greatest(coalesce(p_limit,50),1),100)) x),'[]'::jsonb);
end $$;

create function public.broadcast_invoice_revise_request(p_seller_id uuid,p_invoice_id uuid,
 p_request_id uuid,p_change jsonb,p_reason text,p_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_old public.broadcast_invoice_detail_commands;v_invoice public.broadcast_invoices;
 v_request public.broadcast_customer_requests;v_line public.broadcast_order_lines;
 v_updated public.broadcast_order_lines;v_before jsonb;v_created jsonb;
 v_new public.broadcast_invoices;v_result jsonb;v_cancel boolean;
 v_quantity integer;v_price integer;v_color text;v_size text;
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_key is null or p_change is null or jsonb_typeof(p_change)<>'object' or
  length(trim(coalesce(p_reason,''))) not between 1 and 500 then
  raise exception '정정 내용과 사유를 확인해주세요.' using errcode='22023'; end if;
 v_cancel:=coalesce((p_change->>'cancelled')::boolean,false);
 if v_cancel then
  v_quantity:=null;v_price:=null;v_color:=null;v_size:=null;
 else
  v_quantity:=(p_change->>'quantity')::integer;
  v_price:=(p_change->>'unit_price_krw')::integer;
  v_color:=trim(coalesce(p_change->>'color',''));
  v_size:=trim(coalesce(p_change->>'size',''));
  if v_quantity is null or v_price is null or
   v_quantity not between 1 and 999 or v_price<0 or
   length(v_color)>80 or length(v_size)>80 then
   raise exception '상품 옵션·수량·가격을 확인해주세요.' using errcode='22023'; end if;
 end if;
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into v_old from public.broadcast_invoice_detail_commands
  where seller_id=p_seller_id and actor_id=auth.uid() and key=p_key;
 if found then
  if v_old.invoice_id<>p_invoice_id or v_old.request_id is distinct from p_request_id
   or v_old.change<>p_change or v_old.reason<>trim(p_reason) then
   raise exception '같은 명령 키로 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
  return v_old.result;
 end if;
 if p_request_id is not null then
  select * into v_request from public.broadcast_customer_requests
   where seller_id=p_seller_id and id=p_request_id for update;
  if not found or v_request.status<>'pending' or v_request.kind<>'change' then
   raise exception '처리 대기 중인 고객 수정 요청이 아닙니다.' using errcode='22023'; end if;
 elsif p_change->>'order_line_id' is null then
  raise exception '정정할 주문행을 선택해주세요.' using errcode='22023';
 end if;
 select * into v_invoice from public.broadcast_invoices
  where seller_id=p_seller_id and id=p_invoice_id
   and (p_request_id is null or customer_id=v_request.customer_id)
   and status='issued' for update;
 if not found then raise exception '현재 청구서를 찾을 수 없습니다.' using errcode='22023'; end if;
 if exists(select 1 from public.broadcast_evidence e where e.seller_id=p_seller_id
  and e.invoice_id=p_invoice_id) or
  exists(select 1 from public.broadcast_receipts r where r.seller_id=p_seller_id
   and r.invoice_id=p_invoice_id) or
  exists(select 1 from public.broadcast_purchase_allocations pa
   join public.broadcast_invoice_lines il on il.seller_id=pa.seller_id
    and il.order_line_id=pa.order_line_id where il.invoice_id=p_invoice_id) then
  raise exception '증빙·입금·발주가 진행된 정산서는 정정할 수 없습니다.' using errcode='22023'; end if;
 select * into v_line from public.broadcast_order_lines where seller_id=p_seller_id
  and id=case when p_request_id is null then (p_change->>'order_line_id')::uuid
   else v_request.order_line_id end and invoice_id=p_invoice_id for update;
 if not found or v_line.payment_locked or v_line.cancelled or
  (p_change->>'expected_version')::integer is distinct from v_line.version then
  raise exception '청구 상품이 변경되었습니다. 다시 확인해주세요.' using errcode='40001'; end if;
 perform 1 from public.broadcast_order_lines o
  join public.broadcast_invoice_lines il on il.seller_id=o.seller_id
   and il.order_line_id=o.id where il.invoice_id=p_invoice_id
   and o.seller_id=p_seller_id for update of o;
 if exists(select 1 from public.broadcast_order_lines o
  join public.broadcast_invoice_lines il on il.seller_id=o.seller_id
   and il.order_line_id=o.id where il.invoice_id=p_invoice_id
   and (o.payment_locked or o.invoice_id<>p_invoice_id)) then
  raise exception '청구 상품이 변경되거나 입금 진행 중입니다.' using errcode='22023'; end if;
 update public.broadcast_deposit_allocations set reversed_at=clock_timestamp()
 where seller_id=p_seller_id and invoice_id=p_invoice_id and reversed_at is null;
 update public.broadcast_invoices set status='superseded' where id=p_invoice_id;
 update public.broadcast_order_lines set invoice_id=null
 where seller_id=p_seller_id and invoice_id=p_invoice_id;
 v_before:=to_jsonb(v_line);
 if v_cancel then
  update public.broadcast_order_lines set cancelled=true,version=version+1
   where id=v_line.id returning * into v_updated;
 else
  update public.broadcast_order_lines set color=v_color,size=v_size,quantity=v_quantity,
   unit_price_krw=v_price,version=version+1 where id=v_line.id returning * into v_updated;
 end if;
 insert into public.broadcast_audit(seller_id,actor_id,command,entity_id,
  before_value,after_value,reason)
 values(p_seller_id,auth.uid(),case when p_request_id is null then 'invoice_seller_revision'
  else 'invoice_request_revision' end,v_line.id,
  v_before,to_jsonb(v_updated),trim(p_reason));
 if not exists(select 1 from public.broadcast_invoice_lines il
  join public.broadcast_order_lines o on o.seller_id=il.seller_id and o.id=il.order_line_id
  where il.seller_id=p_seller_id and il.invoice_id=v_invoice.id and not o.cancelled) then
  update public.broadcast_invoices set status='void',
   snapshot=snapshot||jsonb_build_object('revision_reason',trim(p_reason),
    'customer_request_id',p_request_id) where id=v_invoice.id;
  v_result:=jsonb_build_object('status','void','invoice_id',v_invoice.id,
   'customer_request_id',p_request_id);
 else
  v_created:=public.broadcast_billing_command(p_seller_id,'invoice.issue',
   jsonb_build_object('customer_id',v_invoice.customer_id,'session_id',v_invoice.session_id),
   gen_random_uuid());
  update public.broadcast_invoices set series_id=v_invoice.series_id,
   version=v_invoice.version+1,
   snapshot=snapshot||jsonb_build_object('revised_from',v_invoice.id,
    'revision_reason',trim(p_reason),'customer_request_id',p_request_id)
  where id=(v_created->>'id')::uuid returning * into v_new;
  v_result:=to_jsonb(v_new);
 end if;
 if p_request_id is not null then
  update public.broadcast_customer_requests set status='accepted',
   result_line_id=v_line.id,resolution=trim(p_reason),resolved_at=clock_timestamp(),
   resolved_by=auth.uid() where id=v_request.id;
 end if;
 insert into public.broadcast_invoice_detail_commands
  (seller_id,actor_id,key,invoice_id,request_id,change,reason,result)
 values(p_seller_id,auth.uid(),p_key,p_invoice_id,p_request_id,p_change,trim(p_reason),v_result);
 return v_result;
end $$;
revoke all on function public.broadcast_invoice_revise_request(uuid,uuid,uuid,jsonb,text,uuid)
 from public,anon,service_role;
grant execute on function public.broadcast_invoice_revise_request(uuid,uuid,uuid,jsonb,text,uuid)
 to authenticated;
commit;
