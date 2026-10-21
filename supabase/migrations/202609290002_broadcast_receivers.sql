-- B03: seller-verified receiving instructions are captured on invoice issue.
begin;
create table public.broadcast_receiver_settings (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,
 method text not null check(method in ('bank','wechat','alipay')),
 currency text not null check(currency in ('KRW','CNY')),
 holder text not null check(length(trim(holder)) between 1 and 100),
 instructions text not null check(length(trim(instructions)) between 1 and 500),
 private_qr_object_id uuid,
 verified_by uuid references auth.users(id),verified_at timestamptz,
 active boolean not null default false,version integer not null default 1,
 updated_at timestamptz not null default clock_timestamp(),
 unique(seller_id,method),unique(seller_id,id),
 check((method='bank' and currency='KRW') or
  (method in ('wechat','alipay') and currency='CNY')),
 check(not active or (verified_by is not null and verified_at is not null))
);
alter table public.broadcast_receiver_settings enable row level security;
revoke all on public.broadcast_receiver_settings from public,anon,authenticated,service_role;
create table public.broadcast_receiver_commands (
 seller_id uuid not null,actor_id uuid not null references auth.users(id),
 key uuid not null,payload jsonb not null,result jsonb not null,
 primary key(seller_id,actor_id,key)
);
alter table public.broadcast_receiver_commands enable row level security;
revoke all on public.broadcast_receiver_commands from public,anon,authenticated,service_role;

create function public.broadcast_receiver_command(p_seller_id uuid,p_data jsonb,p_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_old public.broadcast_receiver_commands;v_setting public.broadcast_receiver_settings;
 v_method text;v_holder text;v_instructions text;v_active boolean;v_currency text;
 v_result jsonb;
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_key is null or p_data is null or jsonb_typeof(p_data)<>'object' then
  raise exception '수취 안내 요청을 확인해주세요.' using errcode='22023'; end if;
 v_method:=p_data->>'method';v_holder:=trim(coalesce(p_data->>'holder',''));
 v_instructions:=trim(coalesce(p_data->>'instructions',''));
 v_active:=coalesce((p_data->>'active')::boolean,false);
 if v_method is null or v_method not in ('bank','wechat','alipay') or
  length(v_holder) not between 1 and 100 or
  length(v_instructions) not between 1 and 500 then
  raise exception '수취 수단·명의·안내를 확인해주세요.' using errcode='22023'; end if;
 if v_active and (p_data->>'verified') is distinct from 'true' then
  raise exception '실제 수취 계정을 확인한 뒤 활성화해주세요.' using errcode='22023'; end if;
 v_currency:=case when v_method='bank' then 'KRW' else 'CNY' end;
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into v_old from public.broadcast_receiver_commands
  where seller_id=p_seller_id and actor_id=auth.uid() and key=p_key;
 if found then
  if v_old.payload<>p_data then
   raise exception '같은 명령 키로 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
  return v_old.result;
 end if;
 insert into public.broadcast_receiver_settings(seller_id,method,currency,holder,
  instructions,verified_by,verified_at,active)
 values(p_seller_id,v_method,v_currency,v_holder,v_instructions,
  case when v_active then auth.uid() end,
  case when v_active then clock_timestamp() end,v_active)
 on conflict(seller_id,method) do update set holder=excluded.holder,
  instructions=excluded.instructions,verified_by=excluded.verified_by,
  verified_at=excluded.verified_at,active=excluded.active,
  version=broadcast_receiver_settings.version+1,updated_at=clock_timestamp()
 returning * into v_setting;
 v_result:=jsonb_build_object('id',v_setting.id,'method',v_setting.method,
  'currency',v_setting.currency,'holder',v_setting.holder,
  'instructions',v_setting.instructions,'active',v_setting.active,
  'version',v_setting.version,'verified_at',v_setting.verified_at);
 insert into public.broadcast_receiver_commands(seller_id,actor_id,key,payload,result)
 values(p_seller_id,auth.uid(),p_key,p_data,v_result);
 return v_result;
end $$;

create function public.broadcast_receiver_page(p_seller_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'method',r.method,
  'currency',r.currency,'holder',r.holder,'instructions',r.instructions,
  'active',r.active,'version',r.version,'verified_at',r.verified_at)
  order by r.method) from public.broadcast_receiver_settings r
  where r.seller_id=p_seller_id),'[]'::jsonb);
end $$;

create function public.broadcast_invoice_capture_receivers() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_snapshots jsonb;
begin
 select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'method',r.method,
  'currency',r.currency,'holder',r.holder,'instructions',r.instructions,
  'private_qr_object_id',r.private_qr_object_id,'verified_at',r.verified_at,
  'version',r.version,'captured_at',clock_timestamp()) order by r.method),'[]'::jsonb)
 into v_snapshots from public.broadcast_receiver_settings r
 where r.seller_id=new.seller_id and r.active and r.verified_at is not null;
 new.snapshot:=new.snapshot||jsonb_build_object('receiver_snapshots',v_snapshots);
 return new;
end $$;
create trigger broadcast_invoice_receiver_snapshot before insert on public.broadcast_invoices
for each row execute function public.broadcast_invoice_capture_receivers();

revoke all on function public.broadcast_receiver_command(uuid,jsonb,uuid),
 public.broadcast_receiver_page(uuid) from public,anon,service_role;
grant execute on function public.broadcast_receiver_command(uuid,jsonb,uuid),
 public.broadcast_receiver_page(uuid) to authenticated;
commit;
