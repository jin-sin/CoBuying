-- B03: void a fully excluded invoice instead of attempting an empty reissue.
begin;
create or replace function public.broadcast_invoice_revise(p_seller_id uuid,p_invoice_id uuid,
 p_excluded_line_ids uuid[],p_reason text,p_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_old public.broadcast_invoice_revision_commands;
 v_invoice public.broadcast_invoices;v_new public.broadcast_invoices;
 v_line public.broadcast_order_lines;v_before jsonb;v_result jsonb;v_created jsonb;
 v_excluded uuid[];v_count integer;
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_key is null or length(trim(coalesce(p_reason,''))) not between 1 and 500 then
  raise exception '정정 사유를 입력해주세요.' using errcode='22023'; end if;
 v_excluded:=coalesce(p_excluded_line_ids,array[]::uuid[]);
 if cardinality(v_excluded)<>cardinality(array(select distinct x from unnest(v_excluded) x)) then
  raise exception '제외 상품이 중복되었습니다.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into v_old from public.broadcast_invoice_revision_commands
  where seller_id=p_seller_id and actor_id=auth.uid() and key=p_key;
 if found then
  if v_old.invoice_id<>p_invoice_id or v_old.excluded_line_ids<>v_excluded
   or v_old.reason<>trim(p_reason) then
   raise exception '같은 명령 키로 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
  return v_old.result;
 end if;
 select * into v_invoice from public.broadcast_invoices where seller_id=p_seller_id
  and id=p_invoice_id for update;
 if not found or v_invoice.status<>'issued' then
  raise exception '현재 발행된 정산서만 정정할 수 있습니다.' using errcode='22023'; end if;
 if exists(select 1 from public.broadcast_evidence e where e.seller_id=p_seller_id
  and e.invoice_id=p_invoice_id) or
  exists(select 1 from public.broadcast_receipts r where r.seller_id=p_seller_id
   and r.invoice_id=p_invoice_id) or
  exists(select 1 from public.broadcast_purchase_allocations pa
   join public.broadcast_invoice_lines il on il.seller_id=pa.seller_id
    and il.order_line_id=pa.order_line_id where il.invoice_id=p_invoice_id) then
  raise exception '증빙·입금·발주가 진행된 정산서는 정정할 수 없습니다.' using errcode='22023'; end if;
 select count(*) into v_count from unnest(v_excluded) x
  join public.broadcast_invoice_lines il on il.invoice_id=p_invoice_id
   and il.order_line_id=x;
 if v_count<>cardinality(v_excluded) then
  raise exception '제외할 상품이 현재 정산서에 없습니다.' using errcode='22023'; end if;
 perform 1 from public.broadcast_order_lines o
  join public.broadcast_invoice_lines il on il.seller_id=o.seller_id
   and il.order_line_id=o.id where il.invoice_id=p_invoice_id
  and o.seller_id=p_seller_id for update of o;
 if exists(select 1 from public.broadcast_order_lines o
  join public.broadcast_invoice_lines il on il.seller_id=o.seller_id
   and il.order_line_id=o.id where il.invoice_id=p_invoice_id
   and (o.payment_locked or o.invoice_id<>p_invoice_id)) then
  raise exception '청구 상품이 이미 변경되거나 입금 진행 중입니다.' using errcode='22023'; end if;
 update public.broadcast_deposit_allocations set reversed_at=clock_timestamp()
 where seller_id=p_seller_id and invoice_id=p_invoice_id and reversed_at is null;
 update public.broadcast_invoices set status='superseded' where id=p_invoice_id;
 for v_line in select o.* from public.broadcast_order_lines o
  join public.broadcast_invoice_lines il on il.seller_id=o.seller_id
   and il.order_line_id=o.id where il.invoice_id=p_invoice_id
   order by o.sequence loop
  v_before:=to_jsonb(v_line);
  if v_line.id=any(v_excluded) then
   update public.broadcast_order_lines set invoice_id=null,cancelled=true,version=version+1
    where id=v_line.id returning * into v_line;
   insert into public.broadcast_audit(seller_id,actor_id,command,entity_id,
    before_value,after_value,reason)
   values(p_seller_id,auth.uid(),'invoice_revision_exclude',v_line.id,
    v_before,to_jsonb(v_line),trim(p_reason));
  else
   update public.broadcast_order_lines set invoice_id=null where id=v_line.id;
  end if;
 end loop;
 if not exists(select 1 from public.broadcast_invoice_lines il
  join public.broadcast_order_lines o on o.seller_id=il.seller_id and o.id=il.order_line_id
  where il.seller_id=p_seller_id and il.invoice_id=v_invoice.id and not o.cancelled) then
  update public.broadcast_invoices set status='void',
   snapshot=snapshot||jsonb_build_object('revision_reason',trim(p_reason))
   where id=v_invoice.id;
  v_result:=jsonb_build_object('status','void','invoice_id',v_invoice.id);
  insert into public.broadcast_invoice_revision_commands
   (seller_id,actor_id,key,invoice_id,excluded_line_ids,reason,result)
   values(p_seller_id,auth.uid(),p_key,p_invoice_id,v_excluded,trim(p_reason),v_result);
  return v_result;
 end if;
 v_created:=public.broadcast_billing_command(p_seller_id,'invoice.issue',
  jsonb_build_object('customer_id',v_invoice.customer_id,'session_id',v_invoice.session_id),
  gen_random_uuid());
 update public.broadcast_invoices set series_id=v_invoice.series_id,
  version=v_invoice.version+1,
  snapshot=snapshot||jsonb_build_object('revised_from',v_invoice.id,
   'revision_reason',trim(p_reason))
 where id=(v_created->>'id')::uuid returning * into v_new;
 v_result:=to_jsonb(v_new);
 insert into public.broadcast_invoice_revision_commands
  (seller_id,actor_id,key,invoice_id,excluded_line_ids,reason,result)
 values(p_seller_id,auth.uid(),p_key,p_invoice_id,v_excluded,trim(p_reason),v_result);
 return v_result;
end $$;
commit;
