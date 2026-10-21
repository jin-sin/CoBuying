-- B03: immutable private QR object reference captured by invoice snapshot.
begin;
alter table public.broadcast_receiver_settings add column private_qr_content_type text
 check(private_qr_content_type in ('image/png','image/jpeg'));
create function public.broadcast_receiver_qr_reset() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.holder is distinct from old.holder or
  new.instructions is distinct from old.instructions or
  new.active is distinct from old.active then
  new.private_qr_object_id:=null;new.private_qr_content_type:=null;
 end if;
 return new;
end $$;
create trigger broadcast_receiver_qr_reset before update on public.broadcast_receiver_settings
for each row execute function public.broadcast_receiver_qr_reset();
revoke all on function public.broadcast_receiver_qr_reset() from public,anon,authenticated,service_role;
create table public.broadcast_receiver_qr_commands (
 seller_id uuid not null,actor_id uuid not null references auth.users(id),key uuid not null,
 method text not null,object_id uuid not null,content_type text not null,result jsonb not null,
 primary key(seller_id,actor_id,key)
);
alter table public.broadcast_receiver_qr_commands enable row level security;
revoke all on public.broadcast_receiver_qr_commands from public,anon,authenticated,service_role;
create function public.broadcast_receiver_qr_attach(p_seller_id uuid,p_method text,
 p_object_id uuid,p_content_type text,p_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_old public.broadcast_receiver_qr_commands;v_setting public.broadcast_receiver_settings;
 v_path text;v_result jsonb;begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_key is null or p_object_id is null or p_method not in ('wechat','alipay') or
  p_content_type not in ('image/png','image/jpeg') then
  raise exception '수취 QR 파일을 확인해주세요.' using errcode='22023'; end if;
 v_path:=p_seller_id::text||'/'||p_object_id::text||case when p_content_type='image/png' then '.png' else '.jpg' end;
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into v_old from public.broadcast_receiver_qr_commands
  where seller_id=p_seller_id and actor_id=auth.uid() and key=p_key;
 if found then
  if v_old.method<>p_method or v_old.object_id<>p_object_id or v_old.content_type<>p_content_type then
   raise exception '같은 QR 등록 키로 파일을 바꿀 수 없습니다.' using errcode='22023'; end if;
  return v_old.result;
 end if;
 perform 1 from storage.objects where bucket_id='broadcast-receiver-qr' and name=v_path;
 if not found then raise exception '업로드된 비공개 QR을 찾을 수 없습니다.' using errcode='22023'; end if;
 update public.broadcast_receiver_settings set private_qr_object_id=p_object_id,
  private_qr_content_type=p_content_type,version=version+1,updated_at=clock_timestamp()
 where seller_id=p_seller_id and method=p_method and active and verified_at is not null
 returning * into v_setting;
 if not found then raise exception '확인된 수취 안내를 먼저 활성화해주세요.' using errcode='22023'; end if;
 v_result:=jsonb_build_object('method',p_method,'object_id',p_object_id,'version',v_setting.version);
 insert into public.broadcast_receiver_qr_commands(seller_id,actor_id,key,method,
  object_id,content_type,result)
 values(p_seller_id,auth.uid(),p_key,p_method,p_object_id,p_content_type,v_result);
 return v_result;
end $$;
create or replace function public.broadcast_invoice_capture_receivers() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_snapshots jsonb;begin
 select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'method',r.method,
  'currency',r.currency,'holder',r.holder,'instructions',r.instructions,
  'private_qr_object_id',r.private_qr_object_id,
  'private_qr_content_type',r.private_qr_content_type,
  'verified_at',r.verified_at,'version',r.version,'captured_at',clock_timestamp())
  order by r.method),'[]'::jsonb) into v_snapshots
 from public.broadcast_receiver_settings r
 where r.seller_id=new.seller_id and r.active and r.verified_at is not null;
 new.snapshot:=new.snapshot||jsonb_build_object('receiver_snapshots',v_snapshots);
 return new;
end $$;
create or replace function public.broadcast_receiver_page(p_seller_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'method',r.method,
  'currency',r.currency,'holder',r.holder,'instructions',r.instructions,
  'active',r.active,'version',r.version,'verified_at',r.verified_at,
  'has_qr',r.private_qr_object_id is not null) order by r.method)
  from public.broadcast_receiver_settings r where r.seller_id=p_seller_id),'[]'::jsonb);
end $$;
create function public.broadcast_guest_receiver_qr(p_locator uuid,p_session_hash text,
 p_invoice_id uuid,p_method text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v_device public.broadcast_customer_devices;v_invoice public.broadcast_invoices;
 v_receiver jsonb;v_id uuid;v_type text;v_path text;begin
 select d.* into v_device from public.broadcast_customer_devices d
 join public.broadcast_customer_links l on l.seller_id=d.seller_id and l.customer_id=d.customer_id
 where l.locator=p_locator and d.session_hash=p_session_hash and d.revoked_at is null
  and d.expires_at>clock_timestamp();
 if not found then raise exception '이 기기에서는 수취 QR을 볼 수 없습니다.' using errcode='42501'; end if;
 select * into v_invoice from public.broadcast_invoices
  where seller_id=v_device.seller_id and customer_id=v_device.customer_id
   and id=p_invoice_id and status='issued';
 if not found then raise exception '현재 정산서를 찾을 수 없습니다.' using errcode='22023'; end if;
 select x.value into v_receiver from jsonb_array_elements(
  coalesce(v_invoice.snapshot->'receiver_snapshots','[]'::jsonb)) x
 where x.value->>'method'=p_method and x.value->>'private_qr_object_id' is not null;
 if not found then raise exception '이 정산서에는 수취 QR이 없습니다.' using errcode='22023'; end if;
 v_id:=(v_receiver->>'private_qr_object_id')::uuid;
 v_type:=v_receiver->>'private_qr_content_type';
 if v_type not in ('image/png','image/jpeg') then
  raise exception 'QR 파일 형식을 확인해주세요.' using errcode='22023'; end if;
 v_path:=v_invoice.seller_id::text||'/'||v_id::text||case when v_type='image/png' then '.png' else '.jpg' end;
 return jsonb_build_object('object_key',v_path,'content_type',v_type);
end $$;
revoke all on function public.broadcast_receiver_qr_attach(uuid,text,uuid,text,uuid)
 from public,anon,service_role;
grant execute on function public.broadcast_receiver_qr_attach(uuid,text,uuid,text,uuid)
 to authenticated;
revoke all on function public.broadcast_guest_receiver_qr(uuid,text,uuid,text)
 from public,anon,authenticated;
grant execute on function public.broadcast_guest_receiver_qr(uuid,text,uuid,text)
 to service_role;
commit;
