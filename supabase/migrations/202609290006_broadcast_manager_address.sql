-- B03: seller correction after payment, without changing shipped address snapshots.
begin;
create table public.broadcast_manager_address_commands (
 seller_id uuid not null, actor_id uuid not null references auth.users(id),
 key uuid not null, customer_id uuid not null,
 expected_version integer not null, address jsonb not null, reason text not null,
 before_address jsonb, result jsonb not null,
 created_at timestamptz not null default clock_timestamp(),
 primary key(seller_id,actor_id,key),
 foreign key(seller_id,customer_id) references public.broadcast_customers(seller_id,id)
);
alter table public.broadcast_manager_address_commands enable row level security;
revoke all on public.broadcast_manager_address_commands from public,anon,authenticated,service_role;

create or replace function public.broadcast_address_event_capture() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if current_setting('broadcast.manager_address_correction',true)='on' then
  return new;
 end if;
 if new.address is distinct from old.address and new.address is not null then
  insert into public.broadcast_address_events(seller_id,customer_id,before_address,after_address)
  values(new.seller_id,new.customer_id,old.address,new.address);
 end if;
 return new;
end $$;

create function public.broadcast_manager_address(p_seller_id uuid,p_customer_id uuid,
 p_address jsonb,p_expected_version integer,p_reason text,p_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_old public.broadcast_manager_address_commands;
 v_destination public.broadcast_customer_destinations;
 v_before jsonb;v_result jsonb;
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_key is null or p_customer_id is null or p_expected_version is null or
  length(trim(coalesce(p_reason,''))) not between 1 and 500 or
  p_address is null or jsonb_typeof(p_address)<>'object' or
  p_address->>'country' not in ('KR','CN') or
  length(trim(coalesce(p_address->>'recipient',''))) not between 1 and 100 or
  length(trim(coalesce(p_address->>'phone',''))) not between 1 and 40 or
  length(trim(coalesce(p_address->>'region',''))) not between 1 and 200 or
  length(trim(coalesce(p_address->>'detail',''))) not between 1 and 300 then
  raise exception '배송주소와 정정 사유를 확인해주세요.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into v_old from public.broadcast_manager_address_commands
  where seller_id=p_seller_id and actor_id=auth.uid() and key=p_key;
 if found then
  if v_old.customer_id<>p_customer_id or v_old.address<>p_address or
    v_old.expected_version<>p_expected_version or v_old.reason<>trim(p_reason) then
   raise exception '같은 주소 정정 키로 내용을 바꿀 수 없습니다.' using errcode='22023'; end if;
  return v_old.result;
 end if;
 select * into v_destination from public.broadcast_customer_destinations
  where seller_id=p_seller_id and customer_id=p_customer_id for update;
 if not found then raise exception '고객 배송국가를 먼저 설정해주세요.' using errcode='22023'; end if;
 if v_destination.version<>p_expected_version then
  raise exception '주소가 변경되었습니다. 다시 확인해주세요.' using errcode='40001'; end if;
 if v_destination.country<>p_address->>'country' then
  raise exception '청구서 배송국가와 주소 국가가 다릅니다.' using errcode='22023'; end if;
 perform 1 from public.broadcast_invoices where seller_id=p_seller_id
  and customer_id=p_customer_id and status='issued' limit 1;
 if not found then raise exception '정산서 발행 후 주소를 입력할 수 있습니다.' using errcode='22023'; end if;
 v_before:=v_destination.address;
 perform set_config('broadcast.manager_address_correction','on',true);
 update public.broadcast_customer_destinations set address=p_address,version=version+1,
  updated_at=clock_timestamp() where seller_id=p_seller_id and customer_id=p_customer_id
  returning * into v_destination;
 perform set_config('broadcast.manager_address_correction','off',true);
 update public.broadcast_address_events set resolved_at=clock_timestamp(),resolved_by=auth.uid()
  where seller_id=p_seller_id and customer_id=p_customer_id and resolved_at is null;
 v_result:=jsonb_build_object('customer_id',p_customer_id,'version',v_destination.version,
  'address',v_destination.address,'reason',trim(p_reason));
 insert into public.broadcast_manager_address_commands(seller_id,actor_id,key,customer_id,
  expected_version,address,reason,before_address,result)
 values(p_seller_id,auth.uid(),p_key,p_customer_id,p_expected_version,p_address,
  trim(p_reason),v_before,v_result);
 return v_result;
end $$;

create function public.broadcast_manager_destination(p_seller_id uuid,p_customer_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_destination public.broadcast_customer_destinations;begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 select * into v_destination from public.broadcast_customer_destinations
  where seller_id=p_seller_id and customer_id=p_customer_id;
 if not found then return null; end if;
 return jsonb_build_object('customer_id',p_customer_id,'country',v_destination.country,
  'address',v_destination.address,'version',v_destination.version);
end $$;
revoke all on function public.broadcast_manager_address(uuid,uuid,jsonb,integer,text,uuid),
 public.broadcast_manager_destination(uuid,uuid) from public,anon,service_role;
grant execute on function public.broadcast_manager_address(uuid,uuid,jsonb,integer,text,uuid),
 public.broadcast_manager_destination(uuid,uuid) to authenticated;
commit;
