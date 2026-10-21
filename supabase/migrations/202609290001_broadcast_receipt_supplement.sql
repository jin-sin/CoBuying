-- B04: a requested replacement belongs to the original receipt, not a new payment.
begin;
alter table public.broadcast_receipts add column clarification_reason text;
create table public.broadcast_receipt_evidence_history (
 seller_id uuid not null,receipt_id uuid not null,evidence_id uuid not null,
 attached_at timestamptz not null default clock_timestamp(),
 primary key(receipt_id,evidence_id),
 unique(seller_id,evidence_id),
 foreign key(seller_id,receipt_id) references public.broadcast_receipts(seller_id,id),
 foreign key(seller_id,evidence_id) references public.broadcast_evidence(seller_id,id)
);
insert into public.broadcast_receipt_evidence_history(seller_id,receipt_id,evidence_id)
select seller_id,id,evidence_id from public.broadcast_receipts;
alter table public.broadcast_receipt_evidence_history enable row level security;
revoke all on public.broadcast_receipt_evidence_history from public,anon,authenticated,service_role;

create function public.broadcast_receipt_evidence_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_op='INSERT' then
  perform 1 from public.broadcast_receipt_evidence_history
   where seller_id=new.seller_id and evidence_id=new.evidence_id;
  if found then raise exception '이미 제출한 증빙입니다.' using errcode='23505'; end if;
  return new;
 end if;
 if old.status='needs_info' and new.status='confirmed' then
  raise exception '증빙 보완을 받은 뒤 수취를 확인해주세요.' using errcode='22023'; end if;
 return new;
end $$;
create trigger broadcast_receipt_evidence_before_insert before insert on public.broadcast_receipts
for each row execute function public.broadcast_receipt_evidence_guard();
create trigger broadcast_receipt_evidence_before_update before update on public.broadcast_receipts
for each row execute function public.broadcast_receipt_evidence_guard();
create function public.broadcast_receipt_record_initial_evidence() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 insert into public.broadcast_receipt_evidence_history(seller_id,receipt_id,evidence_id)
 values(new.seller_id,new.id,new.evidence_id);
 return new;
end $$;
create trigger broadcast_receipt_initial_evidence after insert on public.broadcast_receipts
for each row execute function public.broadcast_receipt_record_initial_evidence();

create table public.broadcast_receipt_clarification_commands (
 seller_id uuid not null,actor_id uuid not null references auth.users(id),key uuid not null,
 receipt_id uuid not null,reason text not null,result jsonb not null,
 primary key(seller_id,actor_id,key)
);
alter table public.broadcast_receipt_clarification_commands enable row level security;
revoke all on public.broadcast_receipt_clarification_commands from public,anon,authenticated,service_role;

create function public.broadcast_receipt_request_info(p_seller_id uuid,p_receipt_id uuid,
 p_reason text,p_key uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_old public.broadcast_receipt_clarification_commands;
 v_receipt public.broadcast_receipts;v_result jsonb;
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_key is null or length(trim(coalesce(p_reason,''))) not between 1 and 500 then
  raise exception '보완 사유를 입력해주세요.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into v_old from public.broadcast_receipt_clarification_commands
  where seller_id=p_seller_id and actor_id=auth.uid() and key=p_key;
 if found then
  if v_old.receipt_id<>p_receipt_id or v_old.reason<>trim(p_reason) then
   raise exception '같은 명령 키로 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
  return v_old.result;
 end if;
 select * into v_receipt from public.broadcast_receipts
  where seller_id=p_seller_id and id=p_receipt_id for update;
 if not found or v_receipt.status<>'pending_review' then
  raise exception '확인 대기 중인 입금만 보완 요청할 수 있습니다.' using errcode='22023'; end if;
 update public.broadcast_receipts set status='needs_info',clarification_reason=trim(p_reason)
  where id=p_receipt_id returning * into v_receipt;
 v_result:=jsonb_build_object('receipt_id',v_receipt.id,'status',v_receipt.status,
  'clarification_reason',v_receipt.clarification_reason);
 insert into public.broadcast_receipt_clarification_commands
  (seller_id,actor_id,key,receipt_id,reason,result)
 values(p_seller_id,auth.uid(),p_key,p_receipt_id,trim(p_reason),v_result);
 return v_result;
end $$;

create function public.broadcast_guest_receipt_supplement(p_locator uuid,p_session_hash text,
 p_receipt_id uuid,p_evidence_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_device public.broadcast_customer_devices;v_receipt public.broadcast_receipts;
 v_evidence public.broadcast_evidence;v_result jsonb;
begin
 select d.* into v_device from public.broadcast_customer_devices d
 join public.broadcast_customer_links l on l.seller_id=d.seller_id and l.customer_id=d.customer_id
 where l.locator=p_locator and d.session_hash=p_session_hash and d.revoked_at is null
  and d.expires_at>clock_timestamp();
 if not found then raise exception '이 기기에서 증빙을 보완할 수 없습니다.' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended(v_device.seller_id::text,0));
 select * into v_receipt from public.broadcast_receipts where seller_id=v_device.seller_id
  and customer_id=v_device.customer_id and id=p_receipt_id for update;
 if not found then raise exception '입금 신고를 찾을 수 없습니다.' using errcode='22023'; end if;
 select * into v_evidence from public.broadcast_evidence where seller_id=v_device.seller_id
  and customer_id=v_device.customer_id and invoice_id=v_receipt.invoice_id
  and id=p_evidence_id and status='stored';
 if not found then raise exception '같은 정산서의 저장 완료된 증빙을 선택해주세요.' using errcode='22023'; end if;
 if v_receipt.status='pending_review' and v_receipt.evidence_id=p_evidence_id then
  return jsonb_build_object('receipt_id',v_receipt.id,'status',v_receipt.status);
 end if;
 if v_receipt.status<>'needs_info' then
  raise exception '보완 요청 중인 입금이 아닙니다.' using errcode='22023'; end if;
 perform 1 from public.broadcast_receipt_evidence_history
  where receipt_id=p_receipt_id and evidence_id=p_evidence_id;
 if found then raise exception '이전에 제출한 증빙을 다시 사용할 수 없습니다.' using errcode='22023'; end if;
 perform 1 from public.broadcast_receipts where evidence_id=p_evidence_id;
 if found then raise exception '이미 다른 입금에 사용한 증빙입니다.' using errcode='22023'; end if;
 insert into public.broadcast_receipt_evidence_history(seller_id,receipt_id,evidence_id)
 values(v_device.seller_id,p_receipt_id,p_evidence_id);
 update public.broadcast_receipts set evidence_id=p_evidence_id,status='pending_review',
  clarification_reason=null where id=p_receipt_id returning * into v_receipt;
 return jsonb_build_object('receipt_id',v_receipt.id,'status',v_receipt.status);
end $$;

create function public.broadcast_guest_receipt_needs_info(p_locator uuid,p_session_hash text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_device public.broadcast_customer_devices;begin
 select d.* into v_device from public.broadcast_customer_devices d
 join public.broadcast_customer_links l on l.seller_id=d.seller_id and l.customer_id=d.customer_id
 where l.locator=p_locator and d.session_hash=p_session_hash and d.revoked_at is null
  and d.expires_at>clock_timestamp();
 if not found then raise exception '이 기기에서 입금 정보를 볼 수 없습니다.' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('receipt_id',r.id,'invoice_id',r.invoice_id,
  'currency',r.currency,'claimed_minor',r.claimed_minor,'reason',r.clarification_reason)
  order by r.created_at,r.id) from public.broadcast_receipts r
  where r.seller_id=v_device.seller_id and r.customer_id=v_device.customer_id
   and r.status='needs_info'),'[]'::jsonb);
end $$;
revoke all on function public.broadcast_receipt_request_info(uuid,uuid,text,uuid) from public,anon,service_role;
grant execute on function public.broadcast_receipt_request_info(uuid,uuid,text,uuid) to authenticated;
revoke all on function public.broadcast_guest_receipt_supplement(uuid,text,uuid,uuid),
 public.broadcast_guest_receipt_needs_info(uuid,text) from public,anon,authenticated;
grant execute on function public.broadcast_guest_receipt_supplement(uuid,text,uuid,uuid),
 public.broadcast_guest_receipt_needs_info(uuid,text) to service_role;
commit;
