-- B08 first slice: derived work queue; reading never resolves a task.
begin;
create table public.broadcast_address_events (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,customer_id uuid not null,
 before_address jsonb,after_address jsonb not null,
 created_at timestamptz not null default clock_timestamp(),
 resolved_at timestamptz,resolved_by uuid references auth.users(id),
 foreign key(seller_id,customer_id) references public.broadcast_customers(seller_id,id)
);
alter table public.broadcast_address_events enable row level security;
revoke all on public.broadcast_address_events from public,anon,authenticated,service_role;
create function public.broadcast_address_event_capture() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.address is distinct from old.address and new.address is not null then
  insert into public.broadcast_address_events(seller_id,customer_id,before_address,after_address)
  values(new.seller_id,new.customer_id,old.address,new.address);
 end if;
 return new;
end $$;
create trigger broadcast_destination_changed after update of address
on public.broadcast_customer_destinations for each row
execute function public.broadcast_address_event_capture();
revoke all on function public.broadcast_address_event_capture() from public,anon,authenticated,service_role;

create function public.broadcast_tasks(p_seller_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v_tasks jsonb:='[]'::jsonb;begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 select v_tasks||coalesce(jsonb_agg(jsonb_build_object('type','customer_request','source_id',r.id,
  'customer_id',r.customer_id,'nickname',c.nickname,'kind',r.kind,'created_at',r.created_at)
  order by r.created_at),'[]'::jsonb) into v_tasks
 from public.broadcast_customer_requests r join public.broadcast_customers c
  on c.seller_id=r.seller_id and c.id=r.customer_id
 where r.seller_id=p_seller_id and r.status='pending';
 select v_tasks||coalesce(jsonb_agg(jsonb_build_object('type','access_request','source_id',r.id,
  'customer_id',r.customer_id,'nickname',c.nickname,'created_at',r.created_at)
  order by r.created_at),'[]'::jsonb) into v_tasks
 from public.broadcast_access_requests r join public.broadcast_customers c
  on c.seller_id=r.seller_id and c.id=r.customer_id
 where r.seller_id=p_seller_id and r.status='pending' and r.request_expires_at>clock_timestamp();
 select v_tasks||coalesce(jsonb_agg(jsonb_build_object('type','receipt_review','source_id',r.id,
  'customer_id',r.customer_id,'nickname',c.nickname,'status',r.status,'created_at',r.created_at)
  order by r.created_at),'[]'::jsonb) into v_tasks
 from public.broadcast_receipts r join public.broadcast_customers c
  on c.seller_id=r.seller_id and c.id=r.customer_id
 where r.seller_id=p_seller_id and r.status in ('pending_review','needs_info');
 select v_tasks||coalesce(jsonb_agg(jsonb_build_object('type','address_change','source_id',e.id,
  'customer_id',e.customer_id,'nickname',c.nickname,'created_at',e.created_at)
  order by e.created_at),'[]'::jsonb) into v_tasks
 from public.broadcast_address_events e join public.broadcast_customers c
  on c.seller_id=e.seller_id and c.id=e.customer_id
 where e.seller_id=p_seller_id and e.resolved_at is null;
 select v_tasks||coalesce(jsonb_agg(jsonb_build_object('type','unpaid_72h','source_id',i.id,
  'customer_id',i.customer_id,'nickname',c.nickname,'issued_at',i.issued_at)
  order by i.issued_at),'[]'::jsonb) into v_tasks
 from public.broadcast_invoices i join public.broadcast_customers c
  on c.seller_id=i.seller_id and c.id=i.customer_id
 where i.seller_id=p_seller_id and i.status='issued'
  and i.issued_at<=clock_timestamp()-interval '72 hours'
  and i.total_krw>0
  and not exists(select 1 from public.broadcast_receipts r where r.seller_id=i.seller_id
   and r.invoice_id=i.id and r.status in ('pending_review','needs_info','confirmed'));
 select v_tasks||coalesce(jsonb_agg(jsonb_build_object('type','missing_14d','source_id',x.customer_id,
  'customer_id',x.customer_id,'nickname',x.nickname,'quantity',x.missing_quantity,
  'oldest_ordered_at',x.oldest_ordered_at) order by x.oldest_ordered_at),'[]'::jsonb) into v_tasks
 from (select c.id as customer_id,c.nickname,sum(pa.quantity-
    coalesce((select sum(sa.quantity) from public.broadcast_stock_allocations sa
     where sa.seller_id=pa.seller_id and sa.purchase_allocation_id=pa.id),0)) as missing_quantity,
   min(po.ordered_at) as oldest_ordered_at
   from public.broadcast_purchase_allocations pa join public.broadcast_order_lines o
    on o.seller_id=pa.seller_id and o.id=pa.order_line_id
   join public.broadcast_customers c on c.seller_id=o.seller_id and c.id=o.customer_id
   join public.broadcast_purchase_items pi on pi.seller_id=pa.seller_id and pi.id=pa.purchase_item_id
   join public.broadcast_purchase_orders po on po.seller_id=pi.seller_id and po.id=pi.purchase_order_id
   where pa.seller_id=p_seller_id and po.ordered_at<clock_timestamp()-interval '14 days'
   group by c.id,c.nickname
   having sum(pa.quantity-coalesce((select sum(sa.quantity) from public.broadcast_stock_allocations sa
     where sa.seller_id=pa.seller_id and sa.purchase_allocation_id=pa.id),0))>0) x;
 return v_tasks;
end $$;

create function public.broadcast_task_resolve_address(p_seller_id uuid,p_event_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_event public.broadcast_address_events;begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 update public.broadcast_address_events set resolved_at=coalesce(resolved_at,clock_timestamp()),
  resolved_by=coalesce(resolved_by,auth.uid())
 where seller_id=p_seller_id and id=p_event_id returning * into v_event;
 if not found then raise exception '주소 알림을 찾을 수 없습니다.' using errcode='22023'; end if;
 return jsonb_build_object('event_id',v_event.id,'resolved_at',v_event.resolved_at);
end $$;

create table public.broadcast_cancellation_commands (
 seller_id uuid not null,actor_id uuid not null references auth.users(id),key uuid not null,
 invoice_id uuid not null,reason text not null,result jsonb not null,primary key(seller_id,actor_id,key)
);
alter table public.broadcast_cancellation_commands enable row level security;
revoke all on public.broadcast_cancellation_commands from public,anon,authenticated,service_role;
create function public.broadcast_invoice_cancel(p_seller_id uuid,p_invoice_id uuid,p_reason text,p_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_old public.broadcast_cancellation_commands;v_invoice public.broadcast_invoices;
 v_result jsonb;begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_key is null or length(trim(coalesce(p_reason,''))) not between 1 and 500 then
  raise exception '취소 사유를 입력해주세요.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into v_old from public.broadcast_cancellation_commands where seller_id=p_seller_id
  and actor_id=auth.uid() and key=p_key;
 if found then
  if v_old.invoice_id<>p_invoice_id or v_old.reason<>trim(p_reason) then
   raise exception '같은 취소 키로 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
  return v_old.result;
 end if;
 select * into v_invoice from public.broadcast_invoices where seller_id=p_seller_id
  and id=p_invoice_id for update;
 if not found or v_invoice.status<>'issued' then
  raise exception '취소 가능한 청구가 아닙니다.' using errcode='22023'; end if;
 if exists(select 1 from public.broadcast_receipts where seller_id=p_seller_id
  and invoice_id=p_invoice_id and status in ('pending_review','needs_info','confirmed')) then
  raise exception '입금 확인 중이거나 실제 수취가 있어 취소할 수 없습니다.' using errcode='22023'; end if;
 if exists(select 1 from public.broadcast_purchase_allocations pa
  join public.broadcast_order_lines o on o.seller_id=pa.seller_id and o.id=pa.order_line_id
  where pa.seller_id=p_seller_id and o.invoice_id=p_invoice_id) then
  raise exception '발주된 청구는 이 화면에서 취소할 수 없습니다.' using errcode='22023'; end if;
 update public.broadcast_invoices set status='void' where id=p_invoice_id;
 update public.broadcast_deposit_allocations set reversed_at=clock_timestamp()
  where seller_id=p_seller_id and invoice_id=p_invoice_id and reversed_at is null;
 update public.broadcast_order_lines set cancelled=true,version=version+1
  where seller_id=p_seller_id and invoice_id=p_invoice_id;
 v_result:=jsonb_build_object('invoice_id',p_invoice_id,'status','void');
 insert into public.broadcast_cancellation_commands(seller_id,actor_id,key,invoice_id,reason,result)
 values(p_seller_id,auth.uid(),p_key,p_invoice_id,trim(p_reason),v_result);
 return v_result;
end $$;

revoke all on function public.broadcast_tasks(uuid),public.broadcast_task_resolve_address(uuid,uuid),
 public.broadcast_invoice_cancel(uuid,uuid,text,uuid) from public,anon,service_role;
grant execute on function public.broadcast_tasks(uuid),public.broadcast_task_resolve_address(uuid,uuid),
 public.broadcast_invoice_cancel(uuid,uuid,text,uuid) to authenticated;
commit;
