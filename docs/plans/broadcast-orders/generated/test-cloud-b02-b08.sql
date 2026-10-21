-- TEST PROJECT ONLY: orendam-broadcast-test (kshysvfxcjtixfveimai).
-- Apply in the test project's SQL Editor after visually checking the project label.
-- Requires the existing B01 baseline; stops when B02 is already present.
-- Run the separate Storage bucket SQL files after this transaction.
begin;
do $$ begin
 if to_regclass('public.broadcast_sessions') is null then
  raise exception 'B01 baseline missing'; end if;
 if to_regclass('public.broadcast_customer_devices') is not null then
  raise exception 'B02 already present; inspect applied migrations before retrying'; end if;
end $$;

-- ===== 202609280004_broadcast_customer_access.sql =====
-- B02 first slice: customer locator, one-device approval and scoped view.
-- The guest functions are server-gateway only; never expose a service_role key
-- or a customer session hash to a browser.

create table public.broadcast_customer_links (
 locator uuid primary key default gen_random_uuid(),
 seller_id uuid not null,
 customer_id uuid not null,
 created_at timestamptz not null default clock_timestamp(),
 unique(seller_id,customer_id),
 foreign key(seller_id,customer_id) references public.broadcast_customers(seller_id,id)
);
create table public.broadcast_access_requests (
 id uuid primary key default gen_random_uuid(),
 seller_id uuid not null,
 customer_id uuid not null,
 pending_hash text not null check(pending_hash ~ '^[a-f0-9]{64}$'),
 status text not null default 'pending' check(status in ('pending','approved','active','rejected')),
 activation_hash text check(activation_hash ~ '^[a-f0-9]{64}$'),
 created_at timestamptz not null default clock_timestamp(),
 request_expires_at timestamptz not null default clock_timestamp()+interval '48 hours',
 activation_expires_at timestamptz,
 approved_at timestamptz,
 activated_at timestamptz,
 foreign key(seller_id,customer_id) references public.broadcast_customers(seller_id,id)
);
create index broadcast_access_pending on public.broadcast_access_requests(seller_id,status,created_at);
create table public.broadcast_customer_devices (
 id uuid primary key default gen_random_uuid(),
 seller_id uuid not null,
 customer_id uuid not null,
 request_id uuid not null unique references public.broadcast_access_requests(id),
 session_hash text not null unique check(session_hash ~ '^[a-f0-9]{64}$'),
 created_at timestamptz not null default clock_timestamp(),
 expires_at timestamptz not null default clock_timestamp()+interval '30 days',
 revoked_at timestamptz,
 foreign key(seller_id,customer_id) references public.broadcast_customers(seller_id,id)
);
create index broadcast_devices_customer on public.broadcast_customer_devices(seller_id,customer_id);

alter table public.broadcast_customer_links enable row level security;
alter table public.broadcast_access_requests enable row level security;
alter table public.broadcast_customer_devices enable row level security;
revoke all on public.broadcast_customer_links,public.broadcast_access_requests,public.broadcast_customer_devices from public,anon,authenticated,service_role;

create function public.broadcast_customer_link(p_seller_id uuid,p_customer_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_locator uuid; begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 insert into public.broadcast_customer_links(seller_id,customer_id)
 select p_seller_id,c.id from public.broadcast_customers c
 where c.seller_id=p_seller_id and c.id=p_customer_id
 on conflict(seller_id,customer_id) do nothing;
 select l.locator into v_locator from public.broadcast_customer_links l
 where l.seller_id=p_seller_id and l.customer_id=p_customer_id;
 if v_locator is null then raise exception '고객을 찾을 수 없습니다.' using errcode='22023'; end if;
 return jsonb_build_object('locator',v_locator);
end $$;

create function public.broadcast_access_request(p_locator uuid,p_pending_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_link public.broadcast_customer_links; v_request public.broadcast_access_requests; begin
 if p_pending_hash is null or p_pending_hash !~ '^[a-f0-9]{64}$' then
  raise exception '기기 확인값이 잘못됐습니다.' using errcode='22023'; end if;
 select * into v_link from public.broadcast_customer_links where locator=p_locator;
 if not found then raise exception '링크를 확인해주세요.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_locator::text,0));
 select * into v_request from public.broadcast_access_requests
 where seller_id=v_link.seller_id and customer_id=v_link.customer_id and pending_hash=p_pending_hash
  and status in ('pending','approved') and request_expires_at>clock_timestamp()
 order by created_at desc limit 1;
 if found then return jsonb_build_object('request_id',v_request.id,'status',v_request.status); end if;
 if (select count(*) from public.broadcast_access_requests
     where seller_id=v_link.seller_id and customer_id=v_link.customer_id
      and created_at>clock_timestamp()-interval '24 hours')>=3 then
  raise exception '요청 횟수를 초과했습니다. 판매자에게 문의해주세요.' using errcode='P0001'; end if;
 insert into public.broadcast_access_requests(seller_id,customer_id,pending_hash)
 values(v_link.seller_id,v_link.customer_id,p_pending_hash) returning * into v_request;
 return jsonb_build_object('request_id',v_request.id,'status','pending');
end $$;

create function public.broadcast_access_approve(p_seller_id uuid,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_request public.broadcast_access_requests; v_locator uuid; v_token uuid; begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 select * into v_request from public.broadcast_access_requests
 where id=p_request_id and seller_id=p_seller_id for update;
 if not found or v_request.status not in ('pending','approved')
  or v_request.request_expires_at<=clock_timestamp() then
  raise exception '처리 가능한 기기 요청이 아닙니다.' using errcode='22023'; end if;
 v_token:=pg_catalog.gen_random_uuid();
 update public.broadcast_access_requests set status='approved',
  activation_hash=pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(v_token::text,'UTF8')),'hex'),
  activation_expires_at=clock_timestamp()+interval '30 minutes',approved_at=clock_timestamp()
 where id=p_request_id;
 select locator into v_locator from public.broadcast_customer_links
 where seller_id=p_seller_id and customer_id=v_request.customer_id;
 return jsonb_build_object('request_id',p_request_id,'locator',v_locator,
  'activation_token',v_token,'expires_at',clock_timestamp()+interval '30 minutes');
end $$;

create function public.broadcast_access_activate(
 p_request_id uuid,p_pending_hash text,p_token_hash text,p_session_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_request public.broadcast_access_requests; v_device public.broadcast_customer_devices; v_locator uuid; begin
 if p_pending_hash !~ '^[a-f0-9]{64}$' or p_token_hash !~ '^[a-f0-9]{64}$'
  or p_session_hash !~ '^[a-f0-9]{64}$' then
  raise exception '활성화 입력값이 잘못됐습니다.' using errcode='22023'; end if;
 select * into v_request from public.broadcast_access_requests where id=p_request_id for update;
 if not found or v_request.pending_hash<>p_pending_hash or v_request.activation_hash<>p_token_hash
  or v_request.activation_expires_at<=clock_timestamp() then
  raise exception '활성화할 수 없습니다. 기존 기기와 링크를 확인해주세요.' using errcode='42501'; end if;
 select locator into v_locator from public.broadcast_customer_links
 where seller_id=v_request.seller_id and customer_id=v_request.customer_id;
 if v_request.status='active' then
  select * into v_device from public.broadcast_customer_devices where request_id=p_request_id;
  if v_device.session_hash=p_session_hash and v_device.revoked_at is null and v_device.expires_at>clock_timestamp() then
   return jsonb_build_object('locator',v_locator,'device_id',v_device.id); end if;
  raise exception '이미 사용한 활성화 링크입니다.' using errcode='42501';
 end if;
 if v_request.status<>'approved' then raise exception '승인 전 기기 요청입니다.' using errcode='42501'; end if;
 insert into public.broadcast_customer_devices(seller_id,customer_id,request_id,session_hash)
 values(v_request.seller_id,v_request.customer_id,p_request_id,p_session_hash) returning * into v_device;
 update public.broadcast_access_requests set status='active',activated_at=clock_timestamp()
 where id=p_request_id;
 return jsonb_build_object('locator',v_locator,'device_id',v_device.id);
end $$;

create function public.broadcast_guest_view(p_locator uuid,p_session_hash text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v_device public.broadcast_customer_devices; begin
 select d.* into v_device from public.broadcast_customer_devices d
 join public.broadcast_customer_links l on l.seller_id=d.seller_id and l.customer_id=d.customer_id
 where l.locator=p_locator and d.session_hash=p_session_hash and d.revoked_at is null
  and d.expires_at>clock_timestamp();
 if not found then raise exception '이 기기에서는 고객 정보를 볼 수 없습니다.' using errcode='42501'; end if;
 return jsonb_build_object(
  'customer',jsonb_build_object('nickname',(select c.nickname from public.broadcast_customers c
   where c.seller_id=v_device.seller_id and c.id=v_device.customer_id)),
  'sessions',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'title',s.title,'broadcast_date',s.broadcast_date)
   order by s.broadcast_date desc,s.id) from public.broadcast_sessions s
   where s.seller_id=v_device.seller_id and s.status='open' and s.closes_at>clock_timestamp()),'[]'::jsonb),
  'products',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'session_id',p.session_id,
   'number',p.number,'title',p.title,'price_krw',p.price_krw,'colors',p.colors,'sizes',p.sizes,
   'in_outfit',p.in_outfit) order by p.in_outfit desc,p.public_order,p.number)
   from public.broadcast_products p join public.broadcast_sessions s
    on s.seller_id=p.seller_id and s.id=p.session_id
   where p.seller_id=v_device.seller_id and p.visible and p.deleted_at is null
    and s.status='open' and s.closes_at>clock_timestamp()),'[]'::jsonb),
  'orders',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'session_id',o.session_id,
   'product_number',o.product_number,'product_title',o.product_title,'color',o.color,
   'size',o.size,'quantity',o.quantity,'unit_price_krw',o.unit_price_krw,
   'cancelled',o.cancelled,'version',o.version) order by o.sequence desc)
   from public.broadcast_order_lines o where o.seller_id=v_device.seller_id
    and o.customer_id=v_device.customer_id),'[]'::jsonb));
end $$;

create function public.broadcast_access_overview(p_seller_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 return jsonb_build_object(
  'requests',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'customer_id',r.customer_id,
    'nickname',c.nickname,'status',r.status,'created_at',r.created_at,'request_expires_at',r.request_expires_at)
    order by r.created_at desc) from public.broadcast_access_requests r
    join public.broadcast_customers c on c.seller_id=r.seller_id and c.id=r.customer_id
    where r.seller_id=p_seller_id and r.status in ('pending','approved')
     and r.request_expires_at>clock_timestamp()),'[]'::jsonb),
  'devices',coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'customer_id',d.customer_id,
    'nickname',c.nickname,'expires_at',d.expires_at,'created_at',d.created_at)
    order by d.created_at desc) from public.broadcast_customer_devices d
    join public.broadcast_customers c on c.seller_id=d.seller_id and c.id=d.customer_id
    where d.seller_id=p_seller_id and d.revoked_at is null and d.expires_at>clock_timestamp()),'[]'::jsonb));
end $$;

create function public.broadcast_access_revoke(p_seller_id uuid,p_device_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_device public.broadcast_customer_devices; begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 update public.broadcast_customer_devices set revoked_at=coalesce(revoked_at,clock_timestamp())
 where id=p_device_id and seller_id=p_seller_id returning * into v_device;
 if not found then raise exception '기기를 찾을 수 없습니다.' using errcode='22023'; end if;
 return jsonb_build_object('device_id',v_device.id,'revoked',true);
end $$;

revoke all on function public.broadcast_customer_link(uuid,uuid),public.broadcast_access_approve(uuid,uuid),
 public.broadcast_access_overview(uuid),public.broadcast_access_revoke(uuid,uuid) from public,anon,service_role;
grant execute on function public.broadcast_customer_link(uuid,uuid),public.broadcast_access_approve(uuid,uuid),
 public.broadcast_access_overview(uuid),public.broadcast_access_revoke(uuid,uuid) to authenticated;
revoke all on function public.broadcast_access_request(uuid,text),
 public.broadcast_access_activate(uuid,text,text,text),public.broadcast_guest_view(uuid,text) from public,anon,authenticated;
grant execute on function public.broadcast_access_request(uuid,text),
 public.broadcast_access_activate(uuid,text,text,text),public.broadcast_guest_view(uuid,text) to service_role;

-- ===== 202609280005_broadcast_customer_requests.sql =====
-- B02: keep the customer's one-line original until an operator resolves it.

create table public.broadcast_customer_requests (
 id uuid primary key default gen_random_uuid(),
 seller_id uuid not null,
 customer_id uuid not null,
 kind text not null check(kind in ('addition','change')),
 product_id uuid,
 order_line_id uuid,
 product_snapshot jsonb,
 raw_text text not null check(length(trim(raw_text)) between 1 and 500),
 request_key uuid not null,
 reserved_sequence bigint unique,
 status text not null default 'pending' check(status in ('pending','accepted','declined')),
 result_line_id uuid,
 resolution text not null default '',
 created_at timestamptz not null default clock_timestamp(),
 resolved_at timestamptz,
 resolved_by uuid references auth.users(id),
 unique(seller_id,customer_id,request_key),
 foreign key(seller_id,customer_id) references public.broadcast_customers(seller_id,id),
 foreign key(seller_id,product_id) references public.broadcast_products(seller_id,id),
 foreign key(seller_id,order_line_id) references public.broadcast_order_lines(seller_id,id),
 check((kind='addition' and product_id is not null and order_line_id is null and reserved_sequence is not null and product_snapshot is not null)
    or (kind='change' and order_line_id is not null and product_id is null and reserved_sequence is null))
);
create index broadcast_customer_requests_staff on public.broadcast_customer_requests(seller_id,status,created_at,id);
create index broadcast_customer_requests_customer on public.broadcast_customer_requests(seller_id,customer_id,created_at desc);
create table public.broadcast_customer_request_actions (
 seller_id uuid not null,
 actor_id uuid not null references auth.users(id),
 action_key uuid not null,
 request_id uuid not null references public.broadcast_customer_requests(id),
 action text not null,
 payload jsonb not null,
 result jsonb not null,
 primary key(seller_id,actor_id,action_key)
);
alter table public.broadcast_customer_requests enable row level security;
alter table public.broadcast_customer_request_actions enable row level security;
revoke all on public.broadcast_customer_requests,public.broadcast_customer_request_actions
 from public,anon,authenticated,service_role;

create function public.broadcast_guest_request(
 p_locator uuid,p_session_hash text,p_kind text,p_target_id uuid,p_raw_text text,p_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_device public.broadcast_customer_devices; v_product public.broadcast_products;
 v_line public.broadcast_order_lines; v_request public.broadcast_customer_requests;
 v_session public.broadcast_sessions; v_raw text;
begin
 if p_key is null or p_target_id is null or p_kind is null or p_kind not in ('addition','change') then
  raise exception '요청값을 확인해주세요.' using errcode='22023'; end if;
 v_raw:=trim(coalesce(p_raw_text,''));
 if length(v_raw) not between 1 and 500 then
  raise exception '요청 내용을 입력해주세요.' using errcode='22023'; end if;
 select d.* into v_device from public.broadcast_customer_devices d
 join public.broadcast_customer_links l on l.seller_id=d.seller_id and l.customer_id=d.customer_id
 where l.locator=p_locator and d.session_hash=p_session_hash and d.revoked_at is null
  and d.expires_at>clock_timestamp();
 if not found then raise exception '이 기기에서는 주문을 요청할 수 없습니다.' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended(v_device.customer_id::text||p_key::text,0));
 select * into v_request from public.broadcast_customer_requests
 where seller_id=v_device.seller_id and customer_id=v_device.customer_id and request_key=p_key;
 if found then
  if v_request.kind<>p_kind or v_request.raw_text<>v_raw or
   coalesce(v_request.product_id,v_request.order_line_id)<>p_target_id then
   raise exception '같은 요청 키로 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
  return jsonb_build_object('id',v_request.id,'status',v_request.status,
   'reserved_sequence',v_request.reserved_sequence);
 end if;
 if p_kind='addition' then
  select * into v_product from public.broadcast_products
  where id=p_target_id and seller_id=v_device.seller_id and visible and deleted_at is null;
  if not found then raise exception '공개 중인 상품을 선택해주세요.' using errcode='22023'; end if;
  select * into v_session from public.broadcast_sessions
  where id=v_product.session_id and seller_id=v_device.seller_id;
  if v_session.status<>'open' or v_session.closes_at<=clock_timestamp() then
   raise exception '추가 주문 기간이 끝났습니다.' using errcode='22023'; end if;
  insert into public.broadcast_customer_requests(seller_id,customer_id,kind,product_id,
   product_snapshot,raw_text,request_key,reserved_sequence)
  values(v_device.seller_id,v_device.customer_id,p_kind,p_target_id,to_jsonb(v_product),v_raw,p_key,
   nextval(pg_get_serial_sequence('public.broadcast_order_lines','sequence')))
  returning * into v_request;
 else
  select * into v_line from public.broadcast_order_lines
  where id=p_target_id and seller_id=v_device.seller_id and customer_id=v_device.customer_id;
  if not found or v_line.cancelled then raise exception '변경할 주문을 찾을 수 없습니다.' using errcode='22023'; end if;
  if v_line.payment_locked then raise exception '입금이 진행된 주문은 변경할 수 없습니다.' using errcode='22023'; end if;
  insert into public.broadcast_customer_requests(seller_id,customer_id,kind,order_line_id,raw_text,request_key)
  values(v_device.seller_id,v_device.customer_id,p_kind,p_target_id,v_raw,p_key)
  returning * into v_request;
 end if;
 return jsonb_build_object('id',v_request.id,'status','pending',
  'reserved_sequence',v_request.reserved_sequence);
end $$;

create function public.broadcast_guest_requests(p_locator uuid,p_session_hash text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v_device public.broadcast_customer_devices; begin
 select d.* into v_device from public.broadcast_customer_devices d
 join public.broadcast_customer_links l on l.seller_id=d.seller_id and l.customer_id=d.customer_id
 where l.locator=p_locator and d.session_hash=p_session_hash and d.revoked_at is null
  and d.expires_at>clock_timestamp();
 if not found then raise exception '이 기기에서는 요청을 볼 수 없습니다.' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'kind',r.kind,
  'product_id',r.product_id,'order_line_id',r.order_line_id,'raw_text',r.raw_text,
  'status',r.status,'resolution',r.resolution,'created_at',r.created_at,
  'result_line_id',r.result_line_id) order by r.created_at desc,r.id)
  from public.broadcast_customer_requests r where r.seller_id=v_device.seller_id
   and r.customer_id=v_device.customer_id),'[]'::jsonb);
end $$;

create function public.broadcast_customer_request_page(p_seller_id uuid,p_status text default 'pending',p_limit integer default 50)
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
   o.version as current_version,r.raw_text,r.reserved_sequence,
   r.status,r.created_at,r.resolution
   from public.broadcast_customer_requests r join public.broadcast_customers c
    on c.seller_id=r.seller_id and c.id=r.customer_id
   left join public.broadcast_order_lines o on o.seller_id=r.seller_id and o.id=r.order_line_id
   where r.seller_id=p_seller_id and r.status=p_status
   order by r.created_at,r.id limit least(greatest(coalesce(p_limit,50),1),100)) x),'[]'::jsonb);
end $$;

create function public.broadcast_customer_request_review(
 p_seller_id uuid,p_request_id uuid,p_action text,p_data jsonb,p_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_old public.broadcast_customer_request_actions; v_request public.broadcast_customer_requests;
 v_line public.broadcast_order_lines; v_product public.broadcast_products;
 v_result jsonb; v_before jsonb; v_resolution text;
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_key is null or p_action is null or p_action not in ('accept','decline') or p_data is null or jsonb_typeof(p_data)<>'object' then
  raise exception '처리 요청값을 확인해주세요.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into v_old from public.broadcast_customer_request_actions
 where seller_id=p_seller_id and actor_id=auth.uid() and action_key=p_key;
 if found then
  if v_old.request_id<>p_request_id or v_old.action<>p_action or v_old.payload<>p_data then
   raise exception '같은 처리 키로 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
  return v_old.result;
 end if;
 select * into v_request from public.broadcast_customer_requests
 where seller_id=p_seller_id and id=p_request_id for update;
 if not found or v_request.status<>'pending' then
  raise exception '처리 대기 중인 요청이 아닙니다.' using errcode='22023'; end if;
 v_resolution:=trim(coalesce(p_data->>'resolution',''));
 if p_action='decline' then
  if length(v_resolution) not between 1 and 500 then
   raise exception '반려 사유를 입력해주세요.' using errcode='22023'; end if;
  update public.broadcast_customer_requests set status='declined',resolution=v_resolution,
   resolved_at=clock_timestamp(),resolved_by=auth.uid()
  where id=p_request_id returning to_jsonb(broadcast_customer_requests.*) into v_result;
 elsif v_request.kind='addition' then
  select * into v_product from public.broadcast_products
  where seller_id=p_seller_id and id=v_request.product_id for update;
  if not found or v_product.deleted_at is not null or
   v_product.title is distinct from v_request.product_snapshot->>'title' or
   v_product.supplier is distinct from v_request.product_snapshot->>'supplier' or
   v_product.price_krw is distinct from (v_request.product_snapshot->>'price_krw')::integer then
   raise exception '상품 정보가 바뀌었습니다. 요청을 반려하고 다시 접수해주세요.' using errcode='40001'; end if;
  if length(trim(coalesce(p_data->>'color','')))>80 or length(trim(coalesce(p_data->>'size','')))>80 then
   raise exception '옵션을 확인해주세요.' using errcode='22023'; end if;
  insert into public.broadcast_order_lines(sequence,seller_id,session_id,customer_id,product_id,
   created_at,created_by,source,product_title,product_number,supplier,unit_price_krw,
   color,size,quantity,note,original)
  overriding system value values(v_request.reserved_sequence,p_seller_id,
   (v_request.product_snapshot->>'session_id')::uuid,v_request.customer_id,v_request.product_id,
   v_request.created_at,auth.uid(),'customer_addition',v_request.product_snapshot->>'title',
   (v_request.product_snapshot->>'number')::integer,v_request.product_snapshot->>'supplier',
   (v_request.product_snapshot->>'price_krw')::integer,trim(coalesce(p_data->>'color','')),
   trim(coalesce(p_data->>'size','')),(p_data->>'quantity')::integer,'',
   jsonb_build_object('product',v_request.product_snapshot,'raw_text',v_request.raw_text,
    'customer_request_id',v_request.id))
  returning * into v_line;
  update public.broadcast_customer_requests set status='accepted',result_line_id=v_line.id,
   resolved_at=clock_timestamp(),resolved_by=auth.uid(),resolution=v_resolution
  where id=p_request_id;
  v_result:=jsonb_build_object('request_id',p_request_id,'status','accepted','order_line_id',v_line.id,
   'sequence',v_line.sequence);
  insert into public.broadcast_audit(seller_id,actor_id,command,entity_id,after_value,reason)
  values(p_seller_id,auth.uid(),'customer_addition',v_line.id,to_jsonb(v_line),v_request.raw_text);
 else
  select * into v_line from public.broadcast_order_lines
  where seller_id=p_seller_id and id=v_request.order_line_id for update;
  if not found or v_line.payment_locked or v_line.invoice_id is not null then
   raise exception '청구 또는 송금 중인 주문은 이 처리 화면에서 변경할 수 없습니다.' using errcode='22023'; end if;
  if (p_data->>'expected_version')::integer is distinct from v_line.version then
   raise exception '주문이 변경되었습니다. 새로 확인해주세요.' using errcode='40001'; end if;
  v_before:=to_jsonb(v_line);
  update public.broadcast_order_lines set color=trim(coalesce(p_data->>'color','')),
   size=trim(coalesce(p_data->>'size','')),quantity=(p_data->>'quantity')::integer,
   cancelled=coalesce((p_data->>'cancelled')::boolean,false),version=version+1
  where id=v_line.id returning * into v_line;
  update public.broadcast_customer_requests set status='accepted',result_line_id=v_line.id,
   resolved_at=clock_timestamp(),resolved_by=auth.uid(),resolution=v_resolution
  where id=p_request_id;
  v_result:=jsonb_build_object('request_id',p_request_id,'status','accepted','order_line_id',v_line.id,
   'version',v_line.version);
  insert into public.broadcast_audit(seller_id,actor_id,command,entity_id,before_value,after_value,reason)
  values(p_seller_id,auth.uid(),'customer_change_approved',v_line.id,v_before,to_jsonb(v_line),v_request.raw_text);
 end if;
 insert into public.broadcast_customer_request_actions(seller_id,actor_id,action_key,request_id,action,payload,result)
 values(p_seller_id,auth.uid(),p_key,p_request_id,p_action,p_data,v_result);
 return v_result;
end $$;

revoke all on function public.broadcast_guest_request(uuid,text,text,uuid,text,uuid),
 public.broadcast_guest_requests(uuid,text) from public,anon,authenticated;
grant execute on function public.broadcast_guest_request(uuid,text,text,uuid,text,uuid),
 public.broadcast_guest_requests(uuid,text) to service_role;
revoke all on function public.broadcast_customer_request_page(uuid,text,integer),
 public.broadcast_customer_request_review(uuid,uuid,text,jsonb,uuid) from public,anon,service_role;
grant execute on function public.broadcast_customer_request_page(uuid,text,integer),
 public.broadcast_customer_request_review(uuid,uuid,text,jsonb,uuid) to authenticated;

-- ===== 202609280006_broadcast_billing.sql =====
-- B03 first slice: immutable issued invoices, verified KRW deposits and address versions.

create table public.broadcast_customer_destinations (
 seller_id uuid not null, customer_id uuid not null,
 country text not null check(country in ('KR','CN')),
 address jsonb, version integer not null default 1,
 updated_at timestamptz not null default clock_timestamp(),
 primary key(seller_id,customer_id),
 foreign key(seller_id,customer_id) references public.broadcast_customers(seller_id,id),
 check(address is null or jsonb_typeof(address)='object')
);
create table public.broadcast_deposits (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,customer_id uuid not null,
 amount_krw integer not null check(amount_krw>0),receiver text not null check(length(trim(receiver)) between 1 and 100),
 transaction_ref text not null check(length(trim(transaction_ref)) between 1 and 200),received_at timestamptz not null,
 verified_by uuid not null references auth.users(id),
 created_at timestamptz not null default clock_timestamp(),
 unique(seller_id,receiver,transaction_ref),unique(seller_id,id),
 foreign key(seller_id,customer_id) references public.broadcast_customers(seller_id,id)
);
create table public.broadcast_invoices (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,customer_id uuid not null,
 session_id uuid not null,series_id uuid not null,version integer not null,
 status text not null default 'issued' check(status in ('issued','superseded','void')),
 snapshot jsonb not null,subtotal_krw bigint not null check(subtotal_krw>=0),
 shipping_krw integer not null check(shipping_krw>=0),
 shipping_cny_fen integer not null check(shipping_cny_fen>=0),
 deposit_krw integer not null check(deposit_krw>=0),
 total_krw bigint not null check(total_krw>=0),
 total_cny_fen bigint not null check(total_cny_fen>=0),
 accepted_at timestamptz,
 issued_at timestamptz not null default clock_timestamp(),
 unique(seller_id,id),unique(seller_id,series_id,version),
 foreign key(seller_id,customer_id) references public.broadcast_customers(seller_id,id),
 foreign key(seller_id,session_id) references public.broadcast_sessions(seller_id,id)
);
create unique index broadcast_one_issued_series on public.broadcast_invoices(seller_id,series_id) where status='issued';
create table public.broadcast_invoice_lines (
 seller_id uuid not null,invoice_id uuid not null,order_line_id uuid not null,
 snapshot jsonb not null,primary key(invoice_id,order_line_id),
 foreign key(seller_id,invoice_id) references public.broadcast_invoices(seller_id,id),
 foreign key(seller_id,order_line_id) references public.broadcast_order_lines(seller_id,id)
);
create table public.broadcast_deposit_allocations (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,
 deposit_id uuid not null,invoice_id uuid not null,
 amount_krw integer not null check(amount_krw>0),
 reversed_at timestamptz,
 created_at timestamptz not null default clock_timestamp(),
 foreign key(seller_id,deposit_id) references public.broadcast_deposits(seller_id,id),
 foreign key(seller_id,invoice_id) references public.broadcast_invoices(seller_id,id)
);
create index broadcast_deposit_allocations_balance on public.broadcast_deposit_allocations(seller_id,deposit_id) where reversed_at is null;
create table public.broadcast_billing_commands (
 seller_id uuid not null,actor_id uuid not null references auth.users(id),
 key uuid not null,command text not null,payload jsonb not null,result jsonb not null,
 primary key(seller_id,actor_id,key)
);
do $$ declare t text; begin
 foreach t in array array['broadcast_customer_destinations','broadcast_deposits',
 'broadcast_invoices','broadcast_invoice_lines','broadcast_deposit_allocations','broadcast_billing_commands'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated,service_role',t);
 end loop;
end $$;

create function public.broadcast_billing_command(p_seller_id uuid,p_command text,p_data jsonb,p_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_old public.broadcast_billing_commands; v_customer uuid; v_session public.broadcast_sessions;
 v_invoice public.broadcast_invoices; v_deposit public.broadcast_deposits;
 v_line public.broadcast_order_lines; v_destination public.broadcast_customer_destinations;
 v_id uuid; v_result jsonb; v_subtotal bigint; v_count bigint; v_ship_krw integer;
 v_ship_cny integer; v_deposit_krw integer; v_total_krw bigint; v_total_cny bigint;
 v_available integer; v_take integer; v_remaining bigint; v_country text;
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_key is null or p_data is null or jsonb_typeof(p_data)<>'object' then
  raise exception '청구 명령을 확인해주세요.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into v_old from public.broadcast_billing_commands
 where seller_id=p_seller_id and actor_id=auth.uid() and key=p_key;
 if found then
  if v_old.command<>p_command or v_old.payload<>p_data then
   raise exception '같은 명령 키로 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
  return v_old.result;
 end if;
 if p_command='destination.country' then
  v_customer:=(p_data->>'customer_id')::uuid;v_country:=p_data->>'country';
  if v_country is null or v_country not in ('KR','CN') then
   raise exception '배송국가를 확인해주세요.' using errcode='22023'; end if;
  perform 1 from public.broadcast_customers where seller_id=p_seller_id and id=v_customer;
  if not found then raise exception '고객을 찾을 수 없습니다.' using errcode='22023'; end if;
  perform 1 from public.broadcast_invoices where seller_id=p_seller_id and customer_id=v_customer
   and status='issued' limit 1;
  if found then raise exception '발행된 청구의 배송국가는 판본 정정으로 변경해주세요.' using errcode='22023'; end if;
  insert into public.broadcast_customer_destinations(seller_id,customer_id,country)
  values(p_seller_id,v_customer,v_country)
  on conflict(seller_id,customer_id) do update set country=excluded.country,
   version=broadcast_customer_destinations.version+1,updated_at=clock_timestamp()
  returning to_jsonb(broadcast_customer_destinations.*) into v_result;
 elsif p_command='deposit.verify' then
  v_customer:=(p_data->>'customer_id')::uuid;
  insert into public.broadcast_deposits(seller_id,customer_id,amount_krw,receiver,
   transaction_ref,received_at,verified_by)
  values(p_seller_id,v_customer,(p_data->>'amount_krw')::integer,
   trim(p_data->>'receiver'),trim(p_data->>'transaction_ref'),
   (p_data->>'received_at')::timestamptz,auth.uid())
  returning * into v_deposit;
  v_result:=to_jsonb(v_deposit);
 elsif p_command='invoice.issue' then
  v_customer:=(p_data->>'customer_id')::uuid;
  select * into v_session from public.broadcast_sessions
   where seller_id=p_seller_id and id=(p_data->>'session_id')::uuid;
  if not found then raise exception '방송을 찾을 수 없습니다.' using errcode='22023'; end if;
  select * into v_destination from public.broadcast_customer_destinations
   where seller_id=p_seller_id and customer_id=v_customer;
  if not found then raise exception '배송국가를 먼저 선택해주세요.' using errcode='22023'; end if;
  select coalesce(sum(o.quantity::bigint*o.unit_price_krw),0),
   coalesce(sum(case when coalesce((o.original->'product'->>'shipping_excluded')::boolean,false)
     then 0 else o.quantity end),0)
   into v_subtotal,v_count from public.broadcast_order_lines o
   where o.seller_id=p_seller_id and o.customer_id=v_customer and o.session_id=v_session.id
    and o.invoice_id is null and not o.cancelled and not o.payment_locked;
  if v_subtotal=0 and not exists(select 1 from public.broadcast_order_lines o
   where o.seller_id=p_seller_id and o.customer_id=v_customer and o.session_id=v_session.id
    and o.invoice_id is null and not o.cancelled) then
   raise exception '청구할 주문이 없습니다.' using errcode='22023'; end if;
  v_ship_krw:=case when v_count>=v_session.free_shipping_count then 0 else v_session.shipping_krw end;
  v_ship_cny:=case when v_count>=v_session.free_shipping_count then 0 else v_session.shipping_cny_fen end;
  v_remaining:=v_subtotal+case when v_destination.country='KR' then v_ship_krw
    else round(v_ship_cny::numeric/100*v_session.exchange_rate)::integer end;
  v_deposit_krw:=0;
  for v_deposit in select * from public.broadcast_deposits
    where seller_id=p_seller_id and customer_id=v_customer order by received_at,id loop
   select v_deposit.amount_krw-coalesce(sum(a.amount_krw),0) into v_available
   from public.broadcast_deposit_allocations a where a.seller_id=p_seller_id
    and a.deposit_id=v_deposit.id and a.reversed_at is null;
   v_take:=least(v_available,v_remaining);
   if v_take>0 then
    v_deposit_krw:=v_deposit_krw+v_take;v_remaining:=v_remaining-v_take;
   end if;
  end loop;
  v_total_krw:=v_remaining;
  v_total_cny:=round(v_total_krw::numeric*100/v_session.exchange_rate);
  v_id:=gen_random_uuid();
  insert into public.broadcast_invoices(id,seller_id,customer_id,session_id,series_id,version,
   snapshot,subtotal_krw,shipping_krw,shipping_cny_fen,deposit_krw,total_krw,total_cny_fen)
  values(v_id,p_seller_id,v_customer,v_session.id,v_id,1,
   jsonb_build_object('exchange_rate',v_session.exchange_rate,'country',v_destination.country,
    'free_shipping_count',v_session.free_shipping_count,'shipping_krw',v_ship_krw,
    'shipping_cny_fen',v_ship_cny),v_subtotal,v_ship_krw,v_ship_cny,
   v_deposit_krw,v_total_krw,v_total_cny);
  for v_line in select * from public.broadcast_order_lines o where o.seller_id=p_seller_id
   and o.customer_id=v_customer and o.session_id=v_session.id and o.invoice_id is null
   and not o.cancelled and not o.payment_locked order by o.sequence for update loop
   insert into public.broadcast_invoice_lines(seller_id,invoice_id,order_line_id,snapshot)
   values(p_seller_id,v_id,v_line.id,to_jsonb(v_line));
   update public.broadcast_order_lines set invoice_id=v_id where id=v_line.id;
  end loop;
  v_remaining:=v_deposit_krw;
  for v_deposit in select * from public.broadcast_deposits
    where seller_id=p_seller_id and customer_id=v_customer order by received_at,id loop
   select v_deposit.amount_krw-coalesce(sum(a.amount_krw),0) into v_available
   from public.broadcast_deposit_allocations a where a.seller_id=p_seller_id
    and a.deposit_id=v_deposit.id and a.reversed_at is null;
   v_take:=least(v_available,v_remaining);
   if v_take>0 then
    insert into public.broadcast_deposit_allocations(seller_id,deposit_id,invoice_id,amount_krw)
     values(p_seller_id,v_deposit.id,v_id,v_take);
    v_remaining:=v_remaining-v_take;
   end if;
  end loop;
  select to_jsonb(i) into v_result from public.broadcast_invoices i where id=v_id;
 else raise exception '지원하지 않는 청구 명령입니다.' using errcode='22023';
 end if;
 insert into public.broadcast_billing_commands(seller_id,actor_id,key,command,payload,result)
 values(p_seller_id,auth.uid(),p_key,p_command,p_data,v_result);
 return v_result;
end $$;
revoke all on function public.broadcast_billing_command(uuid,text,jsonb,uuid) from public,anon,service_role;
grant execute on function public.broadcast_billing_command(uuid,text,jsonb,uuid) to authenticated;

create function public.broadcast_guest_billing(p_locator uuid,p_session_hash text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v_device public.broadcast_customer_devices; begin
 select d.* into v_device from public.broadcast_customer_devices d
 join public.broadcast_customer_links l on l.seller_id=d.seller_id and l.customer_id=d.customer_id
 where l.locator=p_locator and d.session_hash=p_session_hash and d.revoked_at is null
  and d.expires_at>clock_timestamp();
 if not found then raise exception '이 기기에서는 청구를 볼 수 없습니다.' using errcode='42501'; end if;
 return jsonb_build_object(
  'destination',(select to_jsonb(d)-'seller_id'-'customer_id' from public.broadcast_customer_destinations d
   where d.seller_id=v_device.seller_id and d.customer_id=v_device.customer_id),
  'invoices',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'session_id',i.session_id,
   'version',i.version,'status',i.status,'snapshot',i.snapshot,
   'subtotal_krw',i.subtotal_krw,'shipping_krw',i.shipping_krw,
   'shipping_cny_fen',i.shipping_cny_fen,'deposit_krw',i.deposit_krw,
   'total_krw',i.total_krw,'total_cny_fen',i.total_cny_fen,
   'issued_at',i.issued_at,'accepted_at',i.accepted_at,
   'lines',coalesce((select jsonb_agg(jsonb_build_object('id',l.order_line_id,
    'product_title',l.snapshot->>'product_title','product_number',(l.snapshot->>'product_number')::integer,
    'color',l.snapshot->>'color','size',l.snapshot->>'size',
    'quantity',(l.snapshot->>'quantity')::integer,
    'unit_price_krw',(l.snapshot->>'unit_price_krw')::integer)
    order by (l.snapshot->>'sequence')::bigint)
    from public.broadcast_invoice_lines l where l.invoice_id=i.id),'[]'::jsonb))
   order by i.issued_at desc,i.id)
   from public.broadcast_invoices i where i.seller_id=v_device.seller_id
    and i.customer_id=v_device.customer_id),'[]'::jsonb));
end $$;

create function public.broadcast_guest_address(p_locator uuid,p_session_hash text,
 p_address jsonb,p_expected_version integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_device public.broadcast_customer_devices; v_destination public.broadcast_customer_destinations;
begin
 select d.* into v_device from public.broadcast_customer_devices d
 join public.broadcast_customer_links l on l.seller_id=d.seller_id and l.customer_id=d.customer_id
 where l.locator=p_locator and d.session_hash=p_session_hash and d.revoked_at is null
  and d.expires_at>clock_timestamp();
 if not found then raise exception '이 기기에서는 주소를 변경할 수 없습니다.' using errcode='42501'; end if;
 if p_address is null or jsonb_typeof(p_address)<>'object' or
  p_address->>'country' is null or p_address->>'country' not in ('KR','CN') or
  length(trim(coalesce(p_address->>'recipient',''))) not between 1 and 100 or
  length(trim(coalesce(p_address->>'phone',''))) not between 1 and 40 or
  length(trim(coalesce(p_address->>'region',''))) not between 1 and 200 or
  length(trim(coalesce(p_address->>'detail',''))) not between 1 and 300 then
  raise exception '배송주소를 확인해주세요.' using errcode='22023'; end if;
 select * into v_destination from public.broadcast_customer_destinations
 where seller_id=v_device.seller_id and customer_id=v_device.customer_id for update;
 if not found or v_destination.country<>p_address->>'country' then
  raise exception '정산서의 배송국가와 주소를 확인해주세요.' using errcode='22023'; end if;
 if p_expected_version is distinct from v_destination.version then
  raise exception '주소가 변경되었습니다. 다시 확인해주세요.' using errcode='40001'; end if;
 perform 1 from public.broadcast_invoices where seller_id=v_device.seller_id
  and customer_id=v_device.customer_id and status='issued' limit 1;
 if not found then raise exception '정산서 발행 후 주소를 입력할 수 있습니다.' using errcode='22023'; end if;
 perform 1 from public.broadcast_order_lines where seller_id=v_device.seller_id
  and customer_id=v_device.customer_id and payment_locked limit 1;
 if found then raise exception '입금 진행 후 주소 변경은 판매자에게 요청해주세요.' using errcode='22023'; end if;
 update public.broadcast_customer_destinations set address=p_address,version=version+1,
  updated_at=clock_timestamp() where seller_id=v_device.seller_id and customer_id=v_device.customer_id
 returning * into v_destination;
 return jsonb_build_object('version',v_destination.version,'country',v_destination.country,
  'address',v_destination.address);
end $$;

create function public.broadcast_guest_invoice_accept(p_locator uuid,p_session_hash text,p_invoice_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_device public.broadcast_customer_devices; v_invoice public.broadcast_invoices;
 v_destination public.broadcast_customer_destinations; begin
 select d.* into v_device from public.broadcast_customer_devices d
 join public.broadcast_customer_links l on l.seller_id=d.seller_id and l.customer_id=d.customer_id
 where l.locator=p_locator and d.session_hash=p_session_hash and d.revoked_at is null
  and d.expires_at>clock_timestamp();
 if not found then raise exception '이 기기에서는 정산서를 확인할 수 없습니다.' using errcode='42501'; end if;
 select * into v_invoice from public.broadcast_invoices where seller_id=v_device.seller_id
  and customer_id=v_device.customer_id and id=p_invoice_id for update;
 if not found or v_invoice.status<>'issued' then
  raise exception '확인 가능한 정산서가 아닙니다.' using errcode='22023'; end if;
 select * into v_destination from public.broadcast_customer_destinations
 where seller_id=v_device.seller_id and customer_id=v_device.customer_id;
 if v_destination.address is null then
  raise exception '배송주소를 먼저 입력해주세요.' using errcode='22023'; end if;
 update public.broadcast_invoices set accepted_at=coalesce(accepted_at,clock_timestamp())
 where id=v_invoice.id returning * into v_invoice;
 return jsonb_build_object('invoice_id',v_invoice.id,'accepted_at',v_invoice.accepted_at);
end $$;

revoke all on function public.broadcast_guest_billing(uuid,text),
 public.broadcast_guest_address(uuid,text,jsonb,integer),
 public.broadcast_guest_invoice_accept(uuid,text,uuid) from public,anon,authenticated;
grant execute on function public.broadcast_guest_billing(uuid,text),
 public.broadcast_guest_address(uuid,text,jsonb,integer),
 public.broadcast_guest_invoice_accept(uuid,text,uuid) to service_role;

-- ===== 202609280007_broadcast_payments.sql =====
-- B04 first slice: private evidence references, manual receipt verification and refund ledger.

alter table public.broadcast_invoices add column selected_currency text
 check(selected_currency in ('KRW','CNY'));
create table public.broadcast_evidence (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,
 customer_id uuid not null,invoice_id uuid not null,request_key uuid not null,
 object_key text not null unique,content_type text not null check(content_type in ('image/jpeg','image/png','image/webp')),
 expected_size integer not null check(expected_size between 1 and 5242880),
 actual_size integer,sha256 text check(sha256 ~ '^[a-f0-9]{64}$'),
 status text not null default 'reserved' check(status in ('reserved','stored')),
 created_at timestamptz not null default clock_timestamp(),stored_at timestamptz,
 unique(seller_id,customer_id,request_key),unique(seller_id,id),
 foreign key(seller_id,customer_id) references public.broadcast_customers(seller_id,id),
 foreign key(seller_id,invoice_id) references public.broadcast_invoices(seller_id,id)
);
create table public.broadcast_receipts (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,
 customer_id uuid not null,invoice_id uuid not null,evidence_id uuid not null unique,
 currency text not null check(currency in ('KRW','CNY')),
 claimed_minor bigint not null check(claimed_minor>0),confirmed_minor bigint check(confirmed_minor>0),
 payer_name text not null default '',receiver text,transaction_ref text,
 status text not null default 'pending_review' check(status in ('pending_review','needs_info','confirmed','rejected')),
 created_at timestamptz not null default clock_timestamp(),confirmed_at timestamptz,
 confirmed_by uuid references auth.users(id),
 unique(seller_id,id),
 foreign key(seller_id,customer_id) references public.broadcast_customers(seller_id,id),
 foreign key(seller_id,invoice_id) references public.broadcast_invoices(seller_id,id),
 foreign key(seller_id,evidence_id) references public.broadcast_evidence(seller_id,id),
 check((status='confirmed' and confirmed_minor is not null and receiver is not null and transaction_ref is not null
   and confirmed_at is not null and confirmed_by is not null)
   or status<>'confirmed')
);
create unique index broadcast_receipt_transaction on public.broadcast_receipts(seller_id,receiver,transaction_ref)
 where status='confirmed';
create table public.broadcast_refunds (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,
 invoice_id uuid not null,currency text not null check(currency in ('KRW','CNY')),
 amount_minor bigint not null check(amount_minor>0),reason text not null check(length(trim(reason)) between 1 and 500),
 status text not null default 'planned' check(status in ('planned','confirmed')),
 actual_transaction_ref text,created_by uuid not null references auth.users(id),
 confirmed_by uuid references auth.users(id),confirmed_at timestamptz,
 created_at timestamptz not null default clock_timestamp(),
 unique(seller_id,id),foreign key(seller_id,invoice_id) references public.broadcast_invoices(seller_id,id)
);
create unique index broadcast_refund_transaction on public.broadcast_refunds(seller_id,actual_transaction_ref)
 where status='confirmed';
create table public.broadcast_payment_commands (
 seller_id uuid not null,actor_id uuid not null references auth.users(id),key uuid not null,
 command text not null,payload jsonb not null,result jsonb not null,
 primary key(seller_id,actor_id,key)
);
do $$ declare t text; begin
 foreach t in array array['broadcast_evidence','broadcast_receipts','broadcast_refunds','broadcast_payment_commands'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated,service_role',t);
 end loop;
end $$;

create function public.broadcast_guest_evidence_reserve(p_locator uuid,p_session_hash text,
 p_invoice_id uuid,p_key uuid,p_content_type text,p_size integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_device public.broadcast_customer_devices;v_invoice public.broadcast_invoices;
 v_evidence public.broadcast_evidence;begin
 select d.* into v_device from public.broadcast_customer_devices d
 join public.broadcast_customer_links l on l.seller_id=d.seller_id and l.customer_id=d.customer_id
 where l.locator=p_locator and d.session_hash=p_session_hash and d.revoked_at is null
  and d.expires_at>clock_timestamp();
 if not found then raise exception '이 기기에서 증빙을 제출할 수 없습니다.' using errcode='42501'; end if;
 if p_key is null or p_content_type not in ('image/jpeg','image/png','image/webp')
  or p_size not between 1 and 5242880 then raise exception '증빙 파일을 확인해주세요.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(v_device.seller_id::text,0));
 select * into v_invoice from public.broadcast_invoices where id=p_invoice_id
  and seller_id=v_device.seller_id and customer_id=v_device.customer_id for update;
 if not found or v_invoice.status<>'issued' or v_invoice.accepted_at is null or v_invoice.total_krw=0 then
  raise exception '송금 확인 가능한 정산서가 아닙니다.' using errcode='22023'; end if;
 select * into v_evidence from public.broadcast_evidence where seller_id=v_device.seller_id
  and customer_id=v_device.customer_id and request_key=p_key;
 if found then
  if v_evidence.invoice_id<>p_invoice_id or v_evidence.content_type<>p_content_type
   or v_evidence.expected_size<>p_size then
   raise exception '같은 업로드 키로 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
 else
  insert into public.broadcast_evidence(seller_id,customer_id,invoice_id,request_key,
   object_key,content_type,expected_size)
  values(v_device.seller_id,v_device.customer_id,p_invoice_id,p_key,
   'broadcast-evidence/'||v_device.seller_id||'/'||gen_random_uuid(),p_content_type,p_size)
  returning * into v_evidence;
 end if;
 return jsonb_build_object('evidence_id',v_evidence.id,'object_key',v_evidence.object_key,
  'status',v_evidence.status,'sha256',v_evidence.sha256);
end $$;

create function public.broadcast_evidence_stored(p_evidence_id uuid,p_size integer,p_sha256 text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_evidence public.broadcast_evidence;begin
 select * into v_evidence from public.broadcast_evidence where id=p_evidence_id for update;
 if not found or p_size<>v_evidence.expected_size or p_sha256 is null
  or p_sha256 !~ '^[a-f0-9]{64}$' then
  raise exception '업로드 결과를 확인해주세요.' using errcode='22023'; end if;
 if v_evidence.status='stored' then
  if v_evidence.sha256<>p_sha256 then raise exception '저장된 파일이 다릅니다.' using errcode='22023'; end if;
  return jsonb_build_object('evidence_id',v_evidence.id,'status','stored');
 end if;
 update public.broadcast_evidence set status='stored',actual_size=p_size,sha256=p_sha256,
  stored_at=clock_timestamp() where id=p_evidence_id;
 return jsonb_build_object('evidence_id',p_evidence_id,'status','stored');
end $$;

create function public.broadcast_guest_receipt_submit(p_locator uuid,p_session_hash text,
 p_evidence_id uuid,p_currency text,p_claimed_minor bigint,p_payer_name text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_device public.broadcast_customer_devices;v_evidence public.broadcast_evidence;
 v_invoice public.broadcast_invoices;v_receipt public.broadcast_receipts;begin
 select d.* into v_device from public.broadcast_customer_devices d
 join public.broadcast_customer_links l on l.seller_id=d.seller_id and l.customer_id=d.customer_id
 where l.locator=p_locator and d.session_hash=p_session_hash and d.revoked_at is null
  and d.expires_at>clock_timestamp();
 if not found then raise exception '이 기기에서 송금을 신고할 수 없습니다.' using errcode='42501'; end if;
 if p_currency is null or p_currency not in ('KRW','CNY') or p_claimed_minor is null
  or p_claimed_minor<=0 or length(coalesce(p_payer_name,''))>100 then
  raise exception '송금 정보를 확인해주세요.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(v_device.seller_id::text,0));
 select * into v_evidence from public.broadcast_evidence where id=p_evidence_id
  and seller_id=v_device.seller_id and customer_id=v_device.customer_id;
 if not found or v_evidence.status<>'stored' then
  raise exception '저장 완료된 증빙을 선택해주세요.' using errcode='22023'; end if;
 select * into v_receipt from public.broadcast_receipts where evidence_id=p_evidence_id;
 if found then
  if v_receipt.currency<>p_currency or v_receipt.claimed_minor<>p_claimed_minor
   or v_receipt.payer_name<>trim(coalesce(p_payer_name,'')) then
   raise exception '같은 증빙의 송금 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
  return jsonb_build_object('receipt_id',v_receipt.id,'status',v_receipt.status);
 end if;
 select * into v_invoice from public.broadcast_invoices where id=v_evidence.invoice_id for update;
 if v_invoice.status<>'issued' or v_invoice.accepted_at is null
  or (v_invoice.selected_currency is not null and v_invoice.selected_currency<>p_currency) then
  raise exception '청구 통화와 상태를 확인해주세요.' using errcode='22023'; end if;
 update public.broadcast_invoices set selected_currency=p_currency where id=v_invoice.id;
 insert into public.broadcast_receipts(seller_id,customer_id,invoice_id,evidence_id,currency,
  claimed_minor,payer_name)
 values(v_device.seller_id,v_device.customer_id,v_invoice.id,p_evidence_id,p_currency,
  p_claimed_minor,trim(coalesce(p_payer_name,''))) returning * into v_receipt;
 update public.broadcast_order_lines set payment_locked=true
  where seller_id=v_device.seller_id and invoice_id=v_invoice.id;
 return jsonb_build_object('receipt_id',v_receipt.id,'status','pending_review');
end $$;

create function public.broadcast_payment_command(p_seller_id uuid,p_command text,p_data jsonb,p_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_old public.broadcast_payment_commands;v_receipt public.broadcast_receipts;
 v_invoice public.broadcast_invoices;v_refund public.broadcast_refunds;v_result jsonb;
 v_confirmed bigint;v_reserved bigint;v_due bigint;v_currency text;v_ref text;v_receiver text;
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_key is null or p_data is null or jsonb_typeof(p_data)<>'object' then
  raise exception '입금 확인 명령을 확인해주세요.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into v_old from public.broadcast_payment_commands where seller_id=p_seller_id
  and actor_id=auth.uid() and key=p_key;
 if found then
  if v_old.command<>p_command or v_old.payload<>p_data then
   raise exception '같은 명령 키로 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
  return v_old.result;
 end if;
 if p_command='receipt.confirm' then
  select * into v_receipt from public.broadcast_receipts where seller_id=p_seller_id
   and id=(p_data->>'receipt_id')::uuid for update;
  if not found or v_receipt.status not in ('pending_review','needs_info') then
   raise exception '확인 대기 중인 입금이 아닙니다.' using errcode='22023'; end if;
  v_receiver:=trim(coalesce(p_data->>'receiver',''));v_ref:=trim(coalesce(p_data->>'transaction_ref',''));
  if length(v_receiver) not between 1 and 100 or length(v_ref) not between 1 and 200 then
   raise exception '실제 수취 계정과 거래번호를 입력해주세요.' using errcode='22023'; end if;
  perform 1 from public.broadcast_deposits where seller_id=p_seller_id
   and receiver=v_receiver and transaction_ref=v_ref limit 1;
  if found then raise exception '이미 선입금으로 확인한 거래입니다.' using errcode='23505'; end if;
  update public.broadcast_receipts set status='confirmed',
   confirmed_minor=(p_data->>'confirmed_minor')::bigint,
   receiver=v_receiver,transaction_ref=v_ref,confirmed_at=clock_timestamp(),confirmed_by=auth.uid()
  where id=v_receipt.id returning * into v_receipt;
  v_result:=to_jsonb(v_receipt);
 elsif p_command='receipt.reject' then
  select * into v_receipt from public.broadcast_receipts where seller_id=p_seller_id
   and id=(p_data->>'receipt_id')::uuid for update;
  if not found or v_receipt.status not in ('pending_review','needs_info') then
   raise exception '확인 대기 중인 입금이 아닙니다.' using errcode='22023'; end if;
  update public.broadcast_receipts set status='rejected' where id=v_receipt.id returning * into v_receipt;
  v_result:=to_jsonb(v_receipt);
 elsif p_command='refund.plan' then
  select * into v_invoice from public.broadcast_invoices where seller_id=p_seller_id
   and id=(p_data->>'invoice_id')::uuid for update;
  if not found or v_invoice.selected_currency is null then
   raise exception '환불할 정산서를 찾을 수 없습니다.' using errcode='22023'; end if;
  v_due:=case when v_invoice.selected_currency='KRW' then v_invoice.total_krw else v_invoice.total_cny_fen end;
  select coalesce(sum(confirmed_minor),0) into v_confirmed from public.broadcast_receipts
   where seller_id=p_seller_id and invoice_id=v_invoice.id and status='confirmed';
  select coalesce(sum(amount_minor),0) into v_reserved from public.broadcast_refunds
   where seller_id=p_seller_id and invoice_id=v_invoice.id and status in ('planned','confirmed');
  if (p_data->>'amount_minor')::bigint<=0 or
   (p_data->>'amount_minor')::bigint>v_confirmed-v_due-v_reserved then
   raise exception '초과 수취 범위 안에서만 환불을 예약할 수 있습니다.' using errcode='22023'; end if;
  insert into public.broadcast_refunds(seller_id,invoice_id,currency,amount_minor,reason,created_by)
  values(p_seller_id,v_invoice.id,v_invoice.selected_currency,
   (p_data->>'amount_minor')::bigint,trim(p_data->>'reason'),auth.uid()) returning * into v_refund;
  v_result:=to_jsonb(v_refund);
 elsif p_command='refund.confirm' then
  select * into v_refund from public.broadcast_refunds where seller_id=p_seller_id
   and id=(p_data->>'refund_id')::uuid for update;
  if not found or v_refund.status<>'planned' then
   raise exception '예약된 환불이 아닙니다.' using errcode='22023'; end if;
  v_ref:=trim(coalesce(p_data->>'transaction_ref',''));
  if length(v_ref) not between 1 and 200 then
   raise exception '실제 환불 거래번호를 입력해주세요.' using errcode='22023'; end if;
  update public.broadcast_refunds set status='confirmed',actual_transaction_ref=v_ref,
   confirmed_by=auth.uid(),confirmed_at=clock_timestamp() where id=v_refund.id returning * into v_refund;
  v_result:=to_jsonb(v_refund);
 else raise exception '지원하지 않는 입금 명령입니다.' using errcode='22023'; end if;
 insert into public.broadcast_payment_commands(seller_id,actor_id,key,command,payload,result)
 values(p_seller_id,auth.uid(),p_key,p_command,p_data,v_result);
 return v_result;
end $$;

create function public.broadcast_guest_payment_summary(p_locator uuid,p_session_hash text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_device public.broadcast_customer_devices;begin
 select d.* into v_device from public.broadcast_customer_devices d
 join public.broadcast_customer_links l on l.seller_id=d.seller_id and l.customer_id=d.customer_id
 where l.locator=p_locator and d.session_hash=p_session_hash and d.revoked_at is null
  and d.expires_at>clock_timestamp();
 if not found then raise exception '이 기기에서 입금 정보를 볼 수 없습니다.' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('invoice_id',i.id,
  'currency',i.selected_currency,'due_minor',case when i.selected_currency='CNY' then i.total_cny_fen else i.total_krw end,
  'confirmed_minor',coalesce((select sum(r.confirmed_minor) from public.broadcast_receipts r
   where r.invoice_id=i.id and r.status='confirmed'),0),
  'pending_count',(select count(*) from public.broadcast_receipts r where r.invoice_id=i.id
   and r.status in ('pending_review','needs_info')),
  'refund_confirmed_minor',coalesce((select sum(f.amount_minor) from public.broadcast_refunds f
   where f.invoice_id=i.id and f.status='confirmed'),0)) order by i.issued_at desc)
  from public.broadcast_invoices i where i.seller_id=v_device.seller_id
   and i.customer_id=v_device.customer_id and i.status='issued'),'[]'::jsonb);
end $$;

create function public.broadcast_receipt_page(p_seller_id uuid,p_status text default 'pending_review')
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_status is null or p_status not in ('pending_review','needs_info','confirmed','rejected') then
  raise exception '입금 상태를 확인해주세요.' using errcode='22023'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'customer_id',r.customer_id,
  'nickname',c.nickname,'invoice_id',r.invoice_id,'currency',r.currency,
  'claimed_minor',r.claimed_minor,'payer_name',r.payer_name,
  'status',r.status,'created_at',r.created_at,'object_key',e.object_key,
  'content_type',e.content_type) order by r.created_at,r.id)
  from public.broadcast_receipts r join public.broadcast_customers c
   on c.seller_id=r.seller_id and c.id=r.customer_id
  join public.broadcast_evidence e on e.seller_id=r.seller_id and e.id=r.evidence_id
  where r.seller_id=p_seller_id and r.status=p_status),'[]'::jsonb);
end $$;

revoke all on function public.broadcast_guest_evidence_reserve(uuid,text,uuid,uuid,text,integer),
 public.broadcast_evidence_stored(uuid,integer,text),
 public.broadcast_guest_receipt_submit(uuid,text,uuid,text,bigint,text),
 public.broadcast_guest_payment_summary(uuid,text) from public,anon,authenticated;
grant execute on function public.broadcast_guest_evidence_reserve(uuid,text,uuid,uuid,text,integer),
 public.broadcast_evidence_stored(uuid,integer,text),
 public.broadcast_guest_receipt_submit(uuid,text,uuid,text,bigint,text),
 public.broadcast_guest_payment_summary(uuid,text) to service_role;
revoke all on function public.broadcast_payment_command(uuid,text,jsonb,uuid) from public,anon,service_role;
grant execute on function public.broadcast_payment_command(uuid,text,jsonb,uuid) to authenticated;
revoke all on function public.broadcast_receipt_page(uuid,text) from public,anon,service_role;
grant execute on function public.broadcast_receipt_page(uuid,text) to authenticated;

-- ===== 202609280008_broadcast_procurement.sql =====
-- B05 first slice: paid-only supplier batches and linked customer allocation.

create table public.broadcast_purchase_orders (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,
 supplier text not null,batch_key uuid not null,
 ordered_at timestamptz not null default clock_timestamp(),
 unique(seller_id,id),unique(seller_id,batch_key,supplier)
);
create table public.broadcast_purchase_items (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,
 purchase_order_id uuid not null,product_id uuid not null,
 color text not null,size text not null,quantity integer not null check(quantity>0),
 unique(seller_id,id),unique(purchase_order_id,product_id,color,size),
 foreign key(seller_id,purchase_order_id) references public.broadcast_purchase_orders(seller_id,id),
 foreign key(seller_id,product_id) references public.broadcast_products(seller_id,id)
);
create table public.broadcast_purchase_allocations (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,
 purchase_item_id uuid not null,order_line_id uuid not null,
 quantity integer not null check(quantity>0),created_at timestamptz not null default clock_timestamp(),
 unique(seller_id,id),unique(purchase_item_id,order_line_id),
 foreign key(seller_id,purchase_item_id) references public.broadcast_purchase_items(seller_id,id),
 foreign key(seller_id,order_line_id) references public.broadcast_order_lines(seller_id,id)
);
create table public.broadcast_purchase_commands (
 seller_id uuid not null,actor_id uuid not null references auth.users(id),key uuid not null,
 payload jsonb not null,result jsonb not null,primary key(seller_id,actor_id,key)
);
do $$ declare t text; begin
 foreach t in array array['broadcast_purchase_orders','broadcast_purchase_items',
 'broadcast_purchase_allocations','broadcast_purchase_commands'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated,service_role',t);
 end loop;
end $$;

create function public.broadcast_purchase_preview(p_seller_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 return coalesce((with eligible as (
  select o.id,o.supplier,o.product_id,o.color,o.size,
   o.quantity-coalesce((select sum(a.quantity) from public.broadcast_purchase_allocations a
    where a.seller_id=o.seller_id and a.order_line_id=o.id),0) as remaining
  from public.broadcast_order_lines o join public.broadcast_invoices i
   on i.seller_id=o.seller_id and i.id=o.invoice_id
  join public.broadcast_customer_destinations d on d.seller_id=i.seller_id and d.customer_id=i.customer_id
  where o.seller_id=p_seller_id and not o.cancelled and i.status='issued'
   and i.accepted_at is not null and d.address is not null
   and (case when i.selected_currency='CNY' then i.total_cny_fen else i.total_krw end)
    <=coalesce((select sum(r.confirmed_minor) from public.broadcast_receipts r
      where r.seller_id=i.seller_id and r.invoice_id=i.id and r.status='confirmed'),0)
 ) select jsonb_agg(jsonb_build_object('supplier',x.supplier,'product_id',x.product_id,
  'color',x.color,'size',x.size,'quantity',x.quantity) order by x.supplier,x.product_id,x.color,x.size)
 from (select supplier,product_id,color,size,sum(remaining) as quantity
  from eligible where remaining>0 group by supplier,product_id,color,size) x),'[]'::jsonb);
end $$;

create function public.broadcast_purchase_commit(p_seller_id uuid,p_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_old public.broadcast_purchase_commands;v_line record;
 v_order_id uuid;v_item_id uuid;v_remaining integer;v_count integer:=0;v_result jsonb;
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_key is null then raise exception '발주 키가 필요합니다.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into v_old from public.broadcast_purchase_commands where seller_id=p_seller_id
  and actor_id=auth.uid() and key=p_key;
 if found then return v_old.result; end if;
 for v_line in
  select o.*,o.quantity-coalesce((select sum(a.quantity) from public.broadcast_purchase_allocations a
   where a.seller_id=p_seller_id and a.order_line_id=o.id),0) as remaining
  from public.broadcast_order_lines o join public.broadcast_invoices i
   on i.seller_id=o.seller_id and i.id=o.invoice_id
  join public.broadcast_customer_destinations d on d.seller_id=i.seller_id and d.customer_id=i.customer_id
  where o.seller_id=p_seller_id and not o.cancelled and i.status='issued'
   and i.accepted_at is not null and d.address is not null
   and (case when i.selected_currency='CNY' then i.total_cny_fen else i.total_krw end)
    <=coalesce((select sum(r.confirmed_minor) from public.broadcast_receipts r
      where r.seller_id=i.seller_id and r.invoice_id=i.id and r.status='confirmed'),0)
  order by o.sequence
 loop
  v_remaining:=v_line.remaining;
  if v_remaining<=0 then continue; end if;
  insert into public.broadcast_purchase_orders(seller_id,supplier,batch_key)
  values(p_seller_id,v_line.supplier,p_key)
  on conflict(seller_id,batch_key,supplier) do update set supplier=excluded.supplier
  returning id into v_order_id;
  insert into public.broadcast_purchase_items(seller_id,purchase_order_id,product_id,color,size,quantity)
  values(p_seller_id,v_order_id,v_line.product_id,v_line.color,v_line.size,v_remaining)
  on conflict(purchase_order_id,product_id,color,size) do update
   set quantity=broadcast_purchase_items.quantity+excluded.quantity
  returning id into v_item_id;
  insert into public.broadcast_purchase_allocations(seller_id,purchase_item_id,order_line_id,quantity)
  values(p_seller_id,v_item_id,v_line.id,v_remaining);
  v_count:=v_count+1;
 end loop;
 v_result:=jsonb_build_object('batch_key',p_key,'order_line_count',v_count,
  'purchase_orders',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'supplier',p.supplier)
   order by p.supplier) from public.broadcast_purchase_orders p
   where p.seller_id=p_seller_id and p.batch_key=p_key),'[]'::jsonb));
 insert into public.broadcast_purchase_commands(seller_id,actor_id,key,payload,result)
 values(p_seller_id,auth.uid(),p_key,'{}'::jsonb,v_result);
 return v_result;
end $$;

create function public.broadcast_purchase_tables(p_seller_id uuid,p_purchase_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if not exists(select 1 from public.broadcast_purchase_orders p
  where p.seller_id=p_seller_id and p.id=p_purchase_order_id) then
  raise exception '발주를 찾을 수 없습니다.' using errcode='22023'; end if;
 return jsonb_build_object(
  'supplier',coalesce((select jsonb_agg(jsonb_build_object('item_id',i.id,
   'supplier',p.supplier,'product_title',pr.title,'color',i.color,'size',i.size,
   'quantity',i.quantity) order by i.id)
   from public.broadcast_purchase_items i join public.broadcast_purchase_orders p
    on p.seller_id=i.seller_id and p.id=i.purchase_order_id
   join public.broadcast_products pr on pr.seller_id=i.seller_id and pr.id=i.product_id
   where i.seller_id=p_seller_id and i.purchase_order_id=p_purchase_order_id),'[]'::jsonb),
  'customers',coalesce((select jsonb_agg(jsonb_build_object('item_id',i.id,
   'product_title',o.product_title,'color',o.color,'size',o.size,
   'quantity',a.quantity,'customer_id',c.id,'nickname',c.nickname,
   'payment_confirmed',true,'status','ordered','note',o.note) order by o.sequence)
   from public.broadcast_purchase_allocations a join public.broadcast_purchase_items i
    on i.seller_id=a.seller_id and i.id=a.purchase_item_id
   join public.broadcast_order_lines o on o.seller_id=a.seller_id and o.id=a.order_line_id
   join public.broadcast_customers c on c.seller_id=o.seller_id and c.id=o.customer_id
   where a.seller_id=p_seller_id and i.purchase_order_id=p_purchase_order_id),'[]'::jsonb));
end $$;

revoke all on function public.broadcast_purchase_preview(uuid),
 public.broadcast_purchase_commit(uuid,uuid),public.broadcast_purchase_tables(uuid,uuid)
 from public,anon,service_role;
grant execute on function public.broadcast_purchase_preview(uuid),
 public.broadcast_purchase_commit(uuid,uuid),public.broadcast_purchase_tables(uuid,uuid)
 to authenticated;

-- ===== 202609280009_broadcast_arrivals.sql =====
-- B06 first slice: quantity events and original-order allocation.

create table public.broadcast_arrivals (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,
 purchase_item_id uuid not null,request_key uuid not null,
 good_quantity integer not null default 0 check(good_quantity>=0),
 defect_quantity integer not null default 0 check(defect_quantity>=0),
 received_at timestamptz not null default clock_timestamp(),
 recorded_by uuid not null references auth.users(id),
 unique(seller_id,id),unique(seller_id,request_key),
 check(good_quantity+defect_quantity>0),
 foreign key(seller_id,purchase_item_id) references public.broadcast_purchase_items(seller_id,id)
);
create table public.broadcast_stock_allocations (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,
 purchase_allocation_id uuid not null,arrival_id uuid not null,
 quantity integer not null check(quantity>0),created_at timestamptz not null default clock_timestamp(),
 unique(seller_id,id),unique(purchase_allocation_id,arrival_id),
 foreign key(seller_id,purchase_allocation_id) references public.broadcast_purchase_allocations(seller_id,id),
 foreign key(seller_id,arrival_id) references public.broadcast_arrivals(seller_id,id)
);
create table public.broadcast_defect_exchanges (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,
 arrival_id uuid not null,quantity integer not null check(quantity>0),
 status text not null default 'waiting' check(status in ('waiting','replaced')),
 replaced_at timestamptz,
 unique(seller_id,id),foreign key(seller_id,arrival_id) references public.broadcast_arrivals(seller_id,id)
);
alter table public.broadcast_arrivals add column exchange_of_defect_id uuid unique
 references public.broadcast_defect_exchanges(id);
create table public.broadcast_inventory_commands (
 seller_id uuid not null,actor_id uuid not null references auth.users(id),key uuid not null,
 command text not null,payload jsonb not null,result jsonb not null,
 primary key(seller_id,actor_id,key)
);
do $$ declare t text; begin
 foreach t in array array['broadcast_arrivals','broadcast_stock_allocations',
 'broadcast_defect_exchanges','broadcast_inventory_commands'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated,service_role',t);
 end loop;
end $$;

create function public.broadcast_inventory_command(p_seller_id uuid,p_command text,p_data jsonb,p_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_old public.broadcast_inventory_commands;v_item public.broadcast_purchase_items;
 v_arrival public.broadcast_arrivals;v_defect public.broadcast_defect_exchanges;
 v_ordered integer;v_received integer;
 v_available integer;v_need integer;v_take integer;v_alloc record;v_source record;
 v_result jsonb;v_count integer:=0;
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_key is null or p_data is null or jsonb_typeof(p_data)<>'object' then
  raise exception '입고 명령을 확인해주세요.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into v_old from public.broadcast_inventory_commands where seller_id=p_seller_id
  and actor_id=auth.uid() and key=p_key;
 if found then
  if v_old.command<>p_command or v_old.payload<>p_data then
   raise exception '같은 입고 키로 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
  return v_old.result;
 end if;
 select * into v_item from public.broadcast_purchase_items
  where seller_id=p_seller_id and id=(p_data->>'purchase_item_id')::uuid for update;
 if not found then raise exception '발주 항목을 찾을 수 없습니다.' using errcode='22023'; end if;
 if p_command='arrival.record' then
  v_received:=coalesce((select sum(a.good_quantity+a.defect_quantity)
   from public.broadcast_arrivals a where a.seller_id=p_seller_id and a.purchase_item_id=v_item.id
    and a.exchange_of_defect_id is null),0);
  v_ordered:=v_item.quantity;
  if coalesce((p_data->>'good_quantity')::integer,0)<0 or
   coalesce((p_data->>'defect_quantity')::integer,0)<0 or
   coalesce((p_data->>'good_quantity')::integer,0)+coalesce((p_data->>'defect_quantity')::integer,0)<1 or
   v_received+coalesce((p_data->>'good_quantity')::integer,0)+
    coalesce((p_data->>'defect_quantity')::integer,0)>v_ordered then
   raise exception '발주 잔량을 넘는 입고입니다.' using errcode='22023'; end if;
  insert into public.broadcast_arrivals(seller_id,purchase_item_id,request_key,
   good_quantity,defect_quantity,recorded_by)
  values(p_seller_id,v_item.id,p_key,coalesce((p_data->>'good_quantity')::integer,0),
   coalesce((p_data->>'defect_quantity')::integer,0),auth.uid()) returning * into v_arrival;
  if v_arrival.defect_quantity>0 then
   insert into public.broadcast_defect_exchanges(seller_id,arrival_id,quantity)
   values(p_seller_id,v_arrival.id,v_arrival.defect_quantity);
  end if;
  v_result:=jsonb_build_object('arrival_id',v_arrival.id,'good_quantity',v_arrival.good_quantity,
   'defect_quantity',v_arrival.defect_quantity,'remaining_unreceived',
   v_ordered-v_received-v_arrival.good_quantity-v_arrival.defect_quantity);
 elsif p_command='exchange.receive' then
  select d.* into v_defect from public.broadcast_defect_exchanges d
   join public.broadcast_arrivals a on a.seller_id=d.seller_id and a.id=d.arrival_id
   where d.seller_id=p_seller_id and d.id=(p_data->>'defect_id')::uuid
    and a.purchase_item_id=v_item.id for update;
  if not found or v_defect.status<>'waiting' or
   (p_data->>'quantity')::integer is distinct from v_defect.quantity then
   raise exception '교환 대기 수량을 확인해주세요.' using errcode='22023'; end if;
  insert into public.broadcast_arrivals(seller_id,purchase_item_id,request_key,
   good_quantity,defect_quantity,recorded_by,exchange_of_defect_id)
  values(p_seller_id,v_item.id,p_key,v_defect.quantity,0,auth.uid(),v_defect.id)
  returning * into v_arrival;
  update public.broadcast_defect_exchanges set status='replaced',replaced_at=clock_timestamp()
   where id=v_defect.id;
  v_result:=jsonb_build_object('arrival_id',v_arrival.id,'replaced_quantity',v_defect.quantity);
 elsif p_command='allocation.commit' then
  for v_source in select a.*,a.good_quantity-
    coalesce((select sum(sa.quantity) from public.broadcast_stock_allocations sa
     where sa.seller_id=p_seller_id and sa.arrival_id=a.id),0) as available
   from public.broadcast_arrivals a where a.seller_id=p_seller_id
    and a.purchase_item_id=v_item.id order by a.received_at,a.id loop
   v_available:=v_source.available;
   if v_available<=0 then continue; end if;
   for v_alloc in select pa.*,o.sequence,
     pa.quantity-coalesce((select sum(sa.quantity) from public.broadcast_stock_allocations sa
      where sa.seller_id=p_seller_id and sa.purchase_allocation_id=pa.id),0) as need
    from public.broadcast_purchase_allocations pa join public.broadcast_order_lines o
     on o.seller_id=pa.seller_id and o.id=pa.order_line_id
    where pa.seller_id=p_seller_id and pa.purchase_item_id=v_item.id
    order by o.sequence loop
    v_need:=v_alloc.need;v_take:=least(v_available,v_need);
    if v_take<=0 then continue; end if;
    insert into public.broadcast_stock_allocations(seller_id,purchase_allocation_id,arrival_id,quantity)
    values(p_seller_id,v_alloc.id,v_source.id,v_take);
    v_available:=v_available-v_take;v_count:=v_count+1;
    if v_available=0 then exit; end if;
   end loop;
  end loop;
  v_result:=jsonb_build_object('purchase_item_id',v_item.id,'allocation_events',v_count);
 else raise exception '지원하지 않는 입고 명령입니다.' using errcode='22023'; end if;
 insert into public.broadcast_inventory_commands(seller_id,actor_id,key,command,payload,result)
 values(p_seller_id,auth.uid(),p_key,p_command,p_data,v_result);
 return v_result;
end $$;

create function public.broadcast_inventory_status(p_seller_id uuid,p_purchase_item_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_item public.broadcast_purchase_items;begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 select * into v_item from public.broadcast_purchase_items
  where seller_id=p_seller_id and id=p_purchase_item_id;
 if not found then raise exception '발주 항목을 찾을 수 없습니다.' using errcode='22023'; end if;
 return jsonb_build_object('purchase_item_id',v_item.id,'ordered',v_item.quantity,
  'arrived_good',coalesce((select sum(good_quantity) from public.broadcast_arrivals
   where seller_id=p_seller_id and purchase_item_id=v_item.id),0),
  'defect_waiting',coalesce((select sum(d.quantity) from public.broadcast_defect_exchanges d
   join public.broadcast_arrivals a on a.seller_id=d.seller_id and a.id=d.arrival_id
   where a.seller_id=p_seller_id and a.purchase_item_id=v_item.id and d.status='waiting'),0),
  'allocated',coalesce((select sum(sa.quantity) from public.broadcast_stock_allocations sa
   join public.broadcast_arrivals a on a.seller_id=sa.seller_id and a.id=sa.arrival_id
   where a.seller_id=p_seller_id and a.purchase_item_id=v_item.id),0),
  'unreceived',v_item.quantity-coalesce((select sum(a.good_quantity+a.defect_quantity)
   from public.broadcast_arrivals a where a.seller_id=p_seller_id and a.purchase_item_id=v_item.id
    and a.exchange_of_defect_id is null),0));
end $$;

revoke all on function public.broadcast_inventory_command(uuid,text,jsonb,uuid),
 public.broadcast_inventory_status(uuid,uuid) from public,anon,service_role;
grant execute on function public.broadcast_inventory_command(uuid,text,jsonb,uuid),
 public.broadcast_inventory_status(uuid,uuid) to authenticated;

-- ===== 202609280010_broadcast_shipments.sql =====
-- B07 first slice: only assigned good units ship, with immutable address and multiple tracking numbers.

create table public.broadcast_shipments (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,customer_id uuid not null,
 request_key uuid not null,address_snapshot jsonb not null,
 carrier text not null check(length(trim(carrier)) between 1 and 100),
 tracking_number text not null check(length(trim(tracking_number)) between 1 and 150),
 shipped_at timestamptz not null default clock_timestamp(),
 additional_customer_shipping_minor integer not null default 0 check(additional_customer_shipping_minor=0),
 created_by uuid not null references auth.users(id),
 unique(seller_id,id),unique(seller_id,request_key),
 foreign key(seller_id,customer_id) references public.broadcast_customers(seller_id,id)
);
create table public.broadcast_shipment_lines (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,
 shipment_id uuid not null,stock_allocation_id uuid not null,
 quantity integer not null check(quantity>0),
 unique(shipment_id,stock_allocation_id),
 foreign key(seller_id,shipment_id) references public.broadcast_shipments(seller_id,id),
 foreign key(seller_id,stock_allocation_id) references public.broadcast_stock_allocations(seller_id,id)
);
alter table public.broadcast_shipments enable row level security;
alter table public.broadcast_shipment_lines enable row level security;
revoke all on public.broadcast_shipments,public.broadcast_shipment_lines from public,anon,authenticated,service_role;

create function public.broadcast_shipment_create(p_seller_id uuid,p_data jsonb,p_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_shipment public.broadcast_shipments;v_address public.broadcast_customer_destinations;
 v_line jsonb;v_stock public.broadcast_stock_allocations;v_customer uuid;
 v_qty integer;v_used integer;v_count integer:=0;v_existing public.broadcast_shipments;
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_key is null or p_data is null or jsonb_typeof(p_data)<>'object'
  or jsonb_typeof(p_data->'lines')<>'array' or jsonb_array_length(p_data->'lines')<1 then
  raise exception '출고 상품을 확인해주세요.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into v_existing from public.broadcast_shipments where seller_id=p_seller_id and request_key=p_key;
 if found then
  if v_existing.customer_id<>(p_data->>'customer_id')::uuid or
   v_existing.carrier<>trim(p_data->>'carrier') or
   v_existing.tracking_number<>trim(p_data->>'tracking_number') or
   (select jsonb_agg(jsonb_build_object('stock_allocation_id',l.stock_allocation_id,
    'quantity',l.quantity) order by l.stock_allocation_id)
    from public.broadcast_shipment_lines l where l.seller_id=p_seller_id and l.shipment_id=v_existing.id)
   <>(select jsonb_agg(jsonb_build_object('stock_allocation_id',(x->>'stock_allocation_id')::uuid,
    'quantity',(x->>'quantity')::integer) order by (x->>'stock_allocation_id')::uuid)
    from jsonb_array_elements(p_data->'lines') x) then
   raise exception '같은 출고 키로 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
  return jsonb_build_object('shipment_id',v_existing.id,'tracking_number',v_existing.tracking_number,
   'line_count',(select count(*) from public.broadcast_shipment_lines l
    where l.seller_id=p_seller_id and l.shipment_id=v_existing.id));
 end if;
 v_customer:=(p_data->>'customer_id')::uuid;
 select * into v_address from public.broadcast_customer_destinations
  where seller_id=p_seller_id and customer_id=v_customer;
 if not found or v_address.address is null then
  raise exception '배송주소를 확인해주세요.' using errcode='22023'; end if;
 insert into public.broadcast_shipments(seller_id,customer_id,request_key,address_snapshot,
  carrier,tracking_number,created_by)
 values(p_seller_id,v_customer,p_key,v_address.address,trim(p_data->>'carrier'),
  trim(p_data->>'tracking_number'),auth.uid()) returning * into v_shipment;
 for v_line in select value from jsonb_array_elements(p_data->'lines') loop
  v_qty:=(v_line->>'quantity')::integer;
  select sa.* into v_stock from public.broadcast_stock_allocations sa
  join public.broadcast_purchase_allocations pa on pa.seller_id=sa.seller_id
   and pa.id=sa.purchase_allocation_id
  join public.broadcast_order_lines o on o.seller_id=pa.seller_id and o.id=pa.order_line_id
  where sa.seller_id=p_seller_id and sa.id=(v_line->>'stock_allocation_id')::uuid
   and o.customer_id=v_customer;
  if not found or v_qty is null or v_qty<1 then
   raise exception '고객에게 배정된 정상 상품을 선택해주세요.' using errcode='22023'; end if;
  select coalesce(sum(sl.quantity),0) into v_used from public.broadcast_shipment_lines sl
   where sl.seller_id=p_seller_id and sl.stock_allocation_id=v_stock.id;
  if v_qty>v_stock.quantity-v_used then
   raise exception '출고 가능 수량을 넘었습니다.' using errcode='22023'; end if;
  insert into public.broadcast_shipment_lines(seller_id,shipment_id,stock_allocation_id,quantity)
  values(p_seller_id,v_shipment.id,v_stock.id,v_qty);
  v_count:=v_count+1;
 end loop;
 return jsonb_build_object('shipment_id',v_shipment.id,'tracking_number',v_shipment.tracking_number,
  'line_count',v_count);
end $$;

create function public.broadcast_guest_shipments(p_locator uuid,p_session_hash text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_device public.broadcast_customer_devices;begin
 select d.* into v_device from public.broadcast_customer_devices d
 join public.broadcast_customer_links l on l.seller_id=d.seller_id and l.customer_id=d.customer_id
 where l.locator=p_locator and d.session_hash=p_session_hash and d.revoked_at is null
  and d.expires_at>clock_timestamp();
 if not found then raise exception '이 기기에서 출고를 볼 수 없습니다.' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'shipped_at',s.shipped_at,
  'carrier',s.carrier,'tracking_number',s.tracking_number,
  'lines',coalesce((select jsonb_agg(jsonb_build_object('order_line_id',o.id,
   'product_title',o.product_title,'color',o.color,'size',o.size,'quantity',sl.quantity))
   from public.broadcast_shipment_lines sl join public.broadcast_stock_allocations sa
    on sa.seller_id=sl.seller_id and sa.id=sl.stock_allocation_id
   join public.broadcast_purchase_allocations pa on pa.seller_id=sa.seller_id and pa.id=sa.purchase_allocation_id
   join public.broadcast_order_lines o on o.seller_id=pa.seller_id and o.id=pa.order_line_id
   where sl.seller_id=s.seller_id and sl.shipment_id=s.id),'[]'::jsonb))
  order by s.shipped_at desc,s.id)
  from public.broadcast_shipments s where s.seller_id=v_device.seller_id
   and s.customer_id=v_device.customer_id),'[]'::jsonb);
end $$;

revoke all on function public.broadcast_shipment_create(uuid,jsonb,uuid) from public,anon,service_role;
grant execute on function public.broadcast_shipment_create(uuid,jsonb,uuid) to authenticated;
revoke all on function public.broadcast_guest_shipments(uuid,text) from public,anon,authenticated;
grant execute on function public.broadcast_guest_shipments(uuid,text) to service_role;

-- ===== 202609280011_broadcast_tasks.sql =====
-- B08 first slice: derived work queue; reading never resolves a task.

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

-- ===== 202609280012_broadcast_purchase_page.sql =====
-- B05 manager-only purchase history for export and arrival work.

create or replace function public.broadcast_purchase_preview(p_seller_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 return coalesce((with eligible as (
  select o.id,o.supplier,o.product_id,o.product_title,o.color,o.size,
   o.quantity-coalesce((select sum(a.quantity) from public.broadcast_purchase_allocations a
    where a.seller_id=o.seller_id and a.order_line_id=o.id),0) as remaining
  from public.broadcast_order_lines o join public.broadcast_invoices i
   on i.seller_id=o.seller_id and i.id=o.invoice_id
  join public.broadcast_customer_destinations d on d.seller_id=i.seller_id and d.customer_id=i.customer_id
  where o.seller_id=p_seller_id and not o.cancelled and i.status='issued'
   and i.accepted_at is not null and d.address is not null
   and (case when i.selected_currency='CNY' then i.total_cny_fen else i.total_krw end)
    <=coalesce((select sum(r.confirmed_minor) from public.broadcast_receipts r
      where r.seller_id=i.seller_id and r.invoice_id=i.id and r.status='confirmed'),0)
 ) select jsonb_agg(jsonb_build_object('supplier',x.supplier,'product_id',x.product_id,
  'product_title',x.product_title,'color',x.color,'size',x.size,'quantity',x.quantity)
  order by x.supplier,x.product_title,x.color,x.size)
 from (select supplier,product_id,product_title,color,size,sum(remaining) as quantity
  from eligible where remaining>0 group by supplier,product_id,product_title,color,size) x),'[]'::jsonb);
end $$;
create function public.broadcast_purchase_page(p_seller_id uuid,p_limit integer default 50,
 p_before timestamptz default null,p_before_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_items jsonb;v_last jsonb;
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_limit<1 or p_limit>100 or (p_before is null)<>(p_before_id is null) then
  raise exception '페이지 인자가 올바르지 않습니다.' using errcode='22023'; end if;
 with page as (
  select p.id,p.supplier,p.ordered_at,
   (select coalesce(sum(i.quantity),0) from public.broadcast_purchase_items i
    where i.seller_id=p.seller_id and i.purchase_order_id=p.id) as quantity
  from public.broadcast_purchase_orders p where p.seller_id=p_seller_id
   and (p_before is null or (p.ordered_at,p.id)<(p_before,p_before_id))
  order by p.ordered_at desc,p.id desc limit p_limit
 ) select coalesce(jsonb_agg(to_jsonb(page) order by ordered_at desc,id desc),'[]'::jsonb)
 into v_items from page;
 select value into v_last from jsonb_array_elements(v_items) value
  order by (value->>'ordered_at') asc,(value->>'id') asc limit 1;
 return jsonb_build_object('items',v_items,'next_before',v_last->>'ordered_at',
  'next_before_id',v_last->>'id');
end $$;
revoke all on function public.broadcast_purchase_page(uuid,integer,timestamptz,uuid)
 from public,anon,service_role;
grant execute on function public.broadcast_purchase_page(uuid,integer,timestamptz,uuid)
 to authenticated;

-- ===== 202609280013_broadcast_missing_detail.sql =====
-- B08 customer-first overdue purchase detail; read-only and manager scoped.

create function public.broadcast_missing_detail(p_seller_id uuid,p_customer_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object(
  'product_title',o.product_title,'color',o.color,'size',o.size,
  'supplier',po.supplier,'ordered_at',po.ordered_at,
  'days',floor(extract(epoch from (clock_timestamp()-po.ordered_at))/86400)::integer,
  'missing_quantity',pa.quantity-coalesce((select sum(sa.quantity)
    from public.broadcast_stock_allocations sa where sa.seller_id=pa.seller_id
     and sa.purchase_allocation_id=pa.id),0)) order by po.ordered_at,o.sequence)
 from public.broadcast_purchase_allocations pa join public.broadcast_order_lines o
  on o.seller_id=pa.seller_id and o.id=pa.order_line_id
 join public.broadcast_purchase_items pi on pi.seller_id=pa.seller_id and pi.id=pa.purchase_item_id
 join public.broadcast_purchase_orders po on po.seller_id=pi.seller_id and po.id=pi.purchase_order_id
 where pa.seller_id=p_seller_id and o.customer_id=p_customer_id
  and po.ordered_at<clock_timestamp()-interval '14 days'
  and pa.quantity>coalesce((select sum(sa.quantity) from public.broadcast_stock_allocations sa
   where sa.seller_id=pa.seller_id and sa.purchase_allocation_id=pa.id),0)
 ),'[]'::jsonb);
end $$;
revoke all on function public.broadcast_missing_detail(uuid,uuid) from public,anon,service_role;
grant execute on function public.broadcast_missing_detail(uuid,uuid) to authenticated;

-- ===== 202609280014_broadcast_shipment_ready.sql =====
-- B07 manager view of allocated, good and not-yet-shipped units.

create function public.broadcast_shipment_ready(p_seller_id uuid,p_customer_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object(
  'stock_allocation_id',x.stock_allocation_id,'customer_id',x.customer_id,
  'nickname',x.nickname,'product_title',x.product_title,'color',x.color,
  'size',x.size,'available_quantity',x.available_quantity)
  order by x.nickname,x.order_sequence,x.stock_allocation_id)
 from (select sa.id as stock_allocation_id,o.customer_id,c.nickname,
  o.product_title,o.color,o.size,o.sequence as order_sequence,
  sa.quantity-coalesce((select sum(sl.quantity) from public.broadcast_shipment_lines sl
   where sl.seller_id=sa.seller_id and sl.stock_allocation_id=sa.id),0) as available_quantity
  from public.broadcast_stock_allocations sa join public.broadcast_purchase_allocations pa
   on pa.seller_id=sa.seller_id and pa.id=sa.purchase_allocation_id
  join public.broadcast_order_lines o on o.seller_id=pa.seller_id and o.id=pa.order_line_id
  join public.broadcast_customers c on c.seller_id=o.seller_id and c.id=o.customer_id
  where sa.seller_id=p_seller_id and (p_customer_id is null or o.customer_id=p_customer_id)
 ) x where x.available_quantity>0),'[]'::jsonb);
end $$;
revoke all on function public.broadcast_shipment_ready(uuid,uuid) from public,anon,service_role;
grant execute on function public.broadcast_shipment_ready(uuid,uuid) to authenticated;

-- ===== 202609280015_broadcast_defect_page.sql =====
-- B06 manager-only outstanding exchanges.

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

-- ===== 202609280016_broadcast_billing_preview.sql =====
-- B03 manager review before issuing an invoice; the issue command remains authoritative.

create function public.broadcast_billing_preview(p_seller_id uuid,p_customer_id uuid,p_session_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if not exists(select 1 from public.broadcast_customers c where c.seller_id=p_seller_id and c.id=p_customer_id)
  or not exists(select 1 from public.broadcast_sessions s where s.seller_id=p_seller_id and s.id=p_session_id) then
  raise exception '고객 또는 방송을 찾을 수 없습니다.' using errcode='22023'; end if;
 return jsonb_build_object(
  'orders',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'product_title',o.product_title,
   'color',o.color,'size',o.size,'quantity',o.quantity,'unit_price_krw',o.unit_price_krw)
   order by o.sequence) from public.broadcast_order_lines o
   where o.seller_id=p_seller_id and o.customer_id=p_customer_id and o.session_id=p_session_id
    and o.invoice_id is null and not o.cancelled and not o.payment_locked),'[]'::jsonb),
  'country',(select d.country from public.broadcast_customer_destinations d
   where d.seller_id=p_seller_id and d.customer_id=p_customer_id),
  'deposit_available_krw',coalesce((select sum(d.amount_krw-
   coalesce((select sum(a.amount_krw) from public.broadcast_deposit_allocations a
    where a.seller_id=d.seller_id and a.deposit_id=d.id and a.reversed_at is null),0))
   from public.broadcast_deposits d where d.seller_id=p_seller_id and d.customer_id=p_customer_id),0));
end $$;
revoke all on function public.broadcast_billing_preview(uuid,uuid,uuid) from public,anon,service_role;
grant execute on function public.broadcast_billing_preview(uuid,uuid,uuid) to authenticated;

-- ===== 202609290001_broadcast_receipt_supplement.sql =====
-- B04: a requested replacement belongs to the original receipt, not a new payment.

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

-- ===== 202609290002_broadcast_receivers.sql =====
-- B03: seller-verified receiving instructions are captured on invoice issue.

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

-- ===== 202609290003_broadcast_invoice_revision.sql =====
-- B03: exclude billed lines and atomically issue the next invoice version.

create table public.broadcast_invoice_revision_commands (
 seller_id uuid not null,actor_id uuid not null references auth.users(id),
 key uuid not null,invoice_id uuid not null,excluded_line_ids uuid[] not null,
 reason text not null,result jsonb not null,
 primary key(seller_id,actor_id,key)
);
alter table public.broadcast_invoice_revision_commands enable row level security;
revoke all on public.broadcast_invoice_revision_commands from public,anon,authenticated,service_role;

create function public.broadcast_invoice_revision_preview(p_seller_id uuid,p_customer_id uuid,
 p_session_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_invoice public.broadcast_invoices;
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 select * into v_invoice from public.broadcast_invoices
 where seller_id=p_seller_id and customer_id=p_customer_id and session_id=p_session_id
  and status='issued' order by issued_at desc,id desc limit 1;
 if not found then return null; end if;
 return jsonb_build_object('id',v_invoice.id,'version',v_invoice.version,
  'total_krw',v_invoice.total_krw,'accepted_at',v_invoice.accepted_at,
  'locked',exists(select 1 from public.broadcast_evidence e
   where e.seller_id=p_seller_id and e.invoice_id=v_invoice.id)
   or exists(select 1 from public.broadcast_order_lines o
    where o.seller_id=p_seller_id and o.invoice_id=v_invoice.id and o.payment_locked)
   or exists(select 1 from public.broadcast_receipts r
   where r.seller_id=p_seller_id and r.invoice_id=v_invoice.id)
   or exists(select 1 from public.broadcast_purchase_allocations pa
    join public.broadcast_invoice_lines il on il.seller_id=pa.seller_id
     and il.order_line_id=pa.order_line_id where il.invoice_id=v_invoice.id),
  'lines',coalesce((select jsonb_agg(jsonb_build_object('id',il.order_line_id,
   'product_title',il.snapshot->>'product_title','color',il.snapshot->>'color',
   'size',il.snapshot->>'size','quantity',(il.snapshot->>'quantity')::integer,
   'unit_price_krw',(il.snapshot->>'unit_price_krw')::integer)
   order by (il.snapshot->>'sequence')::bigint)
   from public.broadcast_invoice_lines il where il.invoice_id=v_invoice.id),'[]'::jsonb));
end $$;

create function public.broadcast_invoice_revise(p_seller_id uuid,p_invoice_id uuid,
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
revoke all on function public.broadcast_invoice_revision_preview(uuid,uuid,uuid),
 public.broadcast_invoice_revise(uuid,uuid,uuid[],text,uuid) from public,anon,service_role;
grant execute on function public.broadcast_invoice_revision_preview(uuid,uuid,uuid),
 public.broadcast_invoice_revise(uuid,uuid,uuid[],text,uuid) to authenticated;

-- ===== 202609290004_broadcast_invoice_request_revision.sql =====
-- B03: apply a customer's billed-line change in the same transaction as invoice reissue.

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

-- ===== 202609290005_broadcast_deposit_returns.sql =====
-- B03: actual KRW deposit returns reduce only unallocated balance.

alter table public.broadcast_deposits add column voided_at timestamptz,
 add column voided_by uuid references auth.users(id),
 add column void_reason text;
create table public.broadcast_deposit_returns (
 id uuid primary key default gen_random_uuid(),seller_id uuid not null,
 deposit_id uuid not null,customer_id uuid not null,
 amount_krw integer not null check(amount_krw>0),
 receiver text not null check(length(trim(receiver)) between 1 and 100),
 transaction_ref text not null check(length(trim(transaction_ref)) between 1 and 200),
 reason text not null check(length(trim(reason)) between 1 and 500),
 returned_at timestamptz not null,verified_by uuid not null references auth.users(id),
 created_at timestamptz not null default clock_timestamp(),
 unique(seller_id,id),unique(seller_id,receiver,transaction_ref),
 foreign key(seller_id,deposit_id) references public.broadcast_deposits(seller_id,id),
 foreign key(seller_id,customer_id) references public.broadcast_customers(seller_id,id)
);
alter table public.broadcast_deposit_returns enable row level security;
revoke all on public.broadcast_deposit_returns from public,anon,authenticated,service_role;
create table public.broadcast_deposit_return_commands (
 seller_id uuid not null,actor_id uuid not null references auth.users(id),
 key uuid not null,payload jsonb not null,result jsonb not null,
 primary key(seller_id,actor_id,key)
);
alter table public.broadcast_deposit_return_commands enable row level security;
revoke all on public.broadcast_deposit_return_commands from public,anon,authenticated,service_role;

create function public.broadcast_deposit_return(p_seller_id uuid,p_data jsonb,p_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_old public.broadcast_deposit_return_commands;v_deposit public.broadcast_deposits;
 v_return public.broadcast_deposit_returns;v_used bigint;v_returned bigint;
 v_amount integer;v_receiver text;v_ref text;v_reason text;
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_key is null or p_data is null or jsonb_typeof(p_data)<>'object' then
  raise exception '선입금 반환 내용을 확인해주세요.' using errcode='22023'; end if;
 v_amount:=(p_data->>'amount_krw')::integer;
 v_receiver:=trim(coalesce(p_data->>'receiver',''));
 v_ref:=trim(coalesce(p_data->>'transaction_ref',''));
 v_reason:=trim(coalesce(p_data->>'reason',''));
 if v_amount is null or v_amount<=0 or length(v_receiver) not between 1 and 100
  or length(v_ref) not between 1 and 200 or length(v_reason) not between 1 and 500
  or (p_data->>'returned_at')::timestamptz is null then
  raise exception '실제 반환 거래와 금액·사유를 확인해주세요.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into v_old from public.broadcast_deposit_return_commands
  where seller_id=p_seller_id and actor_id=auth.uid() and key=p_key;
 if found then
  if v_old.payload<>p_data then
   raise exception '같은 명령 키로 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
  return v_old.result;
 end if;
 select * into v_deposit from public.broadcast_deposits
  where seller_id=p_seller_id and id=(p_data->>'deposit_id')::uuid for update;
 if not found or v_deposit.voided_at is not null then
  raise exception '유효한 선입금을 찾을 수 없습니다.' using errcode='22023'; end if;
 select coalesce(sum(amount_krw),0) into v_used from public.broadcast_deposit_allocations
  where seller_id=p_seller_id and deposit_id=v_deposit.id and reversed_at is null;
 select coalesce(sum(amount_krw),0) into v_returned from public.broadcast_deposit_returns
  where seller_id=p_seller_id and deposit_id=v_deposit.id;
 if v_amount>v_deposit.amount_krw-v_used-v_returned then
  raise exception '미배분 선입금 잔액만 반환할 수 있습니다.' using errcode='22023'; end if;
 insert into public.broadcast_deposit_returns(seller_id,deposit_id,customer_id,amount_krw,
  receiver,transaction_ref,reason,returned_at,verified_by)
 values(p_seller_id,v_deposit.id,v_deposit.customer_id,v_amount,v_receiver,v_ref,
  v_reason,(p_data->>'returned_at')::timestamptz,auth.uid()) returning * into v_return;
 insert into public.broadcast_deposit_return_commands(seller_id,actor_id,key,payload,result)
 values(p_seller_id,auth.uid(),p_key,p_data,to_jsonb(v_return));
 return to_jsonb(v_return);
end $$;
revoke all on function public.broadcast_deposit_return(uuid,jsonb,uuid) from public,anon,service_role;
grant execute on function public.broadcast_deposit_return(uuid,jsonb,uuid) to authenticated;

create table public.broadcast_deposit_void_commands (
 seller_id uuid not null,actor_id uuid not null references auth.users(id),key uuid not null,
 deposit_id uuid not null,reason text not null,result jsonb not null,
 primary key(seller_id,actor_id,key)
);
alter table public.broadcast_deposit_void_commands enable row level security;
revoke all on public.broadcast_deposit_void_commands from public,anon,authenticated,service_role;
create function public.broadcast_deposit_void(p_seller_id uuid,p_deposit_id uuid,
 p_reason text,p_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_old public.broadcast_deposit_void_commands;v_deposit public.broadcast_deposits;
 v_result jsonb;begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_key is null or p_deposit_id is null or length(trim(coalesce(p_reason,''))) not between 1 and 500 then
  raise exception '선입금 정정 사유를 확인해주세요.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into v_old from public.broadcast_deposit_void_commands
  where seller_id=p_seller_id and actor_id=auth.uid() and key=p_key;
 if found then
  if v_old.deposit_id<>p_deposit_id or v_old.reason<>trim(p_reason) then
   raise exception '같은 선입금 정정 키로 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
  return v_old.result;
 end if;
 select * into v_deposit from public.broadcast_deposits
  where seller_id=p_seller_id and id=p_deposit_id for update;
 if not found or v_deposit.voided_at is not null then
  raise exception '정정할 선입금을 찾을 수 없습니다.' using errcode='22023'; end if;
 if exists(select 1 from public.broadcast_deposit_allocations a
  where a.seller_id=p_seller_id and a.deposit_id=p_deposit_id and a.reversed_at is null)
  or exists(select 1 from public.broadcast_deposit_returns r
   where r.seller_id=p_seller_id and r.deposit_id=p_deposit_id) then
  raise exception '청구 배분 또는 실제 반환이 있는 선입금은 정정할 수 없습니다.' using errcode='22023'; end if;
 update public.broadcast_deposits set voided_at=clock_timestamp(),voided_by=auth.uid(),
  void_reason=trim(p_reason) where id=p_deposit_id returning * into v_deposit;
 v_result:=jsonb_build_object('deposit_id',v_deposit.id,'voided_at',v_deposit.voided_at,
  'reason',v_deposit.void_reason);
 insert into public.broadcast_deposit_void_commands(seller_id,actor_id,key,deposit_id,reason,result)
 values(p_seller_id,auth.uid(),p_key,p_deposit_id,trim(p_reason),v_result);
 return v_result;
end $$;
revoke all on function public.broadcast_deposit_void(uuid,uuid,text,uuid) from public,anon,service_role;
grant execute on function public.broadcast_deposit_void(uuid,uuid,text,uuid) to authenticated;

create or replace function public.broadcast_billing_command(p_seller_id uuid,p_command text,p_data jsonb,p_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_old public.broadcast_billing_commands; v_customer uuid; v_session public.broadcast_sessions;
 v_invoice public.broadcast_invoices; v_deposit public.broadcast_deposits;
 v_line public.broadcast_order_lines; v_destination public.broadcast_customer_destinations;
 v_id uuid; v_result jsonb; v_subtotal bigint; v_count bigint; v_ship_krw integer;
 v_ship_cny integer; v_deposit_krw integer; v_total_krw bigint; v_total_cny bigint;
 v_available integer; v_take integer; v_remaining bigint; v_country text;
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_key is null or p_data is null or jsonb_typeof(p_data)<>'object' then
  raise exception '청구 명령을 확인해주세요.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into v_old from public.broadcast_billing_commands
 where seller_id=p_seller_id and actor_id=auth.uid() and key=p_key;
 if found then
  if v_old.command<>p_command or v_old.payload<>p_data then
   raise exception '같은 명령 키로 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
  return v_old.result;
 end if;
 if p_command='destination.country' then
  v_customer:=(p_data->>'customer_id')::uuid;v_country:=p_data->>'country';
  if v_country is null or v_country not in ('KR','CN') then
   raise exception '배송국가를 확인해주세요.' using errcode='22023'; end if;
  perform 1 from public.broadcast_customers where seller_id=p_seller_id and id=v_customer;
  if not found then raise exception '고객을 찾을 수 없습니다.' using errcode='22023'; end if;
  perform 1 from public.broadcast_invoices where seller_id=p_seller_id and customer_id=v_customer
   and status='issued' limit 1;
  if found then raise exception '발행된 청구의 배송국가는 판본 정정으로 변경해주세요.' using errcode='22023'; end if;
  insert into public.broadcast_customer_destinations(seller_id,customer_id,country)
  values(p_seller_id,v_customer,v_country)
  on conflict(seller_id,customer_id) do update set country=excluded.country,
   version=broadcast_customer_destinations.version+1,updated_at=clock_timestamp()
  returning to_jsonb(broadcast_customer_destinations.*) into v_result;
 elsif p_command='deposit.verify' then
  v_customer:=(p_data->>'customer_id')::uuid;
  insert into public.broadcast_deposits(seller_id,customer_id,amount_krw,receiver,
   transaction_ref,received_at,verified_by)
  values(p_seller_id,v_customer,(p_data->>'amount_krw')::integer,
   trim(p_data->>'receiver'),trim(p_data->>'transaction_ref'),
   (p_data->>'received_at')::timestamptz,auth.uid())
  returning * into v_deposit;
  v_result:=to_jsonb(v_deposit);
 elsif p_command='invoice.issue' then
  v_customer:=(p_data->>'customer_id')::uuid;
  select * into v_session from public.broadcast_sessions
   where seller_id=p_seller_id and id=(p_data->>'session_id')::uuid;
  if not found then raise exception '방송을 찾을 수 없습니다.' using errcode='22023'; end if;
  select * into v_destination from public.broadcast_customer_destinations
   where seller_id=p_seller_id and customer_id=v_customer;
  if not found then raise exception '배송국가를 먼저 선택해주세요.' using errcode='22023'; end if;
  select coalesce(sum(o.quantity::bigint*o.unit_price_krw),0),
   coalesce(sum(case when coalesce((o.original->'product'->>'shipping_excluded')::boolean,false)
     then 0 else o.quantity end),0)
   into v_subtotal,v_count from public.broadcast_order_lines o
   where o.seller_id=p_seller_id and o.customer_id=v_customer and o.session_id=v_session.id
    and o.invoice_id is null and not o.cancelled and not o.payment_locked;
  if v_subtotal=0 and not exists(select 1 from public.broadcast_order_lines o
   where o.seller_id=p_seller_id and o.customer_id=v_customer and o.session_id=v_session.id
    and o.invoice_id is null and not o.cancelled) then
   raise exception '청구할 주문이 없습니다.' using errcode='22023'; end if;
  v_ship_krw:=case when v_count>=v_session.free_shipping_count then 0 else v_session.shipping_krw end;
  v_ship_cny:=case when v_count>=v_session.free_shipping_count then 0 else v_session.shipping_cny_fen end;
  v_remaining:=v_subtotal+case when v_destination.country='KR' then v_ship_krw
    else round(v_ship_cny::numeric/100*v_session.exchange_rate)::integer end;
  v_deposit_krw:=0;
  for v_deposit in select * from public.broadcast_deposits
    where seller_id=p_seller_id and customer_id=v_customer and voided_at is null order by received_at,id loop
   select v_deposit.amount_krw-coalesce((select sum(r.amount_krw) from public.broadcast_deposit_returns r where r.seller_id=p_seller_id and r.deposit_id=v_deposit.id),0)-coalesce(sum(a.amount_krw),0) into v_available
   from public.broadcast_deposit_allocations a where a.seller_id=p_seller_id
    and a.deposit_id=v_deposit.id and a.reversed_at is null;
   v_take:=least(v_available,v_remaining);
   if v_take>0 then
    v_deposit_krw:=v_deposit_krw+v_take;v_remaining:=v_remaining-v_take;
   end if;
  end loop;
  v_total_krw:=v_remaining;
  v_total_cny:=round(v_total_krw::numeric*100/v_session.exchange_rate);
  v_id:=gen_random_uuid();
  insert into public.broadcast_invoices(id,seller_id,customer_id,session_id,series_id,version,
   snapshot,subtotal_krw,shipping_krw,shipping_cny_fen,deposit_krw,total_krw,total_cny_fen)
  values(v_id,p_seller_id,v_customer,v_session.id,v_id,1,
   jsonb_build_object('exchange_rate',v_session.exchange_rate,'country',v_destination.country,
    'free_shipping_count',v_session.free_shipping_count,'shipping_krw',v_ship_krw,
    'shipping_cny_fen',v_ship_cny),v_subtotal,v_ship_krw,v_ship_cny,
   v_deposit_krw,v_total_krw,v_total_cny);
  for v_line in select * from public.broadcast_order_lines o where o.seller_id=p_seller_id
   and o.customer_id=v_customer and o.session_id=v_session.id and o.invoice_id is null
   and not o.cancelled and not o.payment_locked order by o.sequence for update loop
   insert into public.broadcast_invoice_lines(seller_id,invoice_id,order_line_id,snapshot)
   values(p_seller_id,v_id,v_line.id,to_jsonb(v_line));
   update public.broadcast_order_lines set invoice_id=v_id where id=v_line.id;
  end loop;
  v_remaining:=v_deposit_krw;
  for v_deposit in select * from public.broadcast_deposits
    where seller_id=p_seller_id and customer_id=v_customer and voided_at is null order by received_at,id loop
   select v_deposit.amount_krw-coalesce((select sum(r.amount_krw) from public.broadcast_deposit_returns r where r.seller_id=p_seller_id and r.deposit_id=v_deposit.id),0)-coalesce(sum(a.amount_krw),0) into v_available
   from public.broadcast_deposit_allocations a where a.seller_id=p_seller_id
    and a.deposit_id=v_deposit.id and a.reversed_at is null;
   v_take:=least(v_available,v_remaining);
   if v_take>0 then
    insert into public.broadcast_deposit_allocations(seller_id,deposit_id,invoice_id,amount_krw)
     values(p_seller_id,v_deposit.id,v_id,v_take);
    v_remaining:=v_remaining-v_take;
   end if;
  end loop;
  select to_jsonb(i) into v_result from public.broadcast_invoices i where id=v_id;
 else raise exception '지원하지 않는 청구 명령입니다.' using errcode='22023';
 end if;
 insert into public.broadcast_billing_commands(seller_id,actor_id,key,command,payload,result)
 values(p_seller_id,auth.uid(),p_key,p_command,p_data,v_result);
 return v_result;
end $$;

create or replace function public.broadcast_billing_preview(p_seller_id uuid,p_customer_id uuid,p_session_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if not exists(select 1 from public.broadcast_customers c where c.seller_id=p_seller_id and c.id=p_customer_id)
  or not exists(select 1 from public.broadcast_sessions s where s.seller_id=p_seller_id and s.id=p_session_id) then
  raise exception '고객 또는 방송을 찾을 수 없습니다.' using errcode='22023'; end if;
 return jsonb_build_object(
  'orders',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'product_title',o.product_title,
   'color',o.color,'size',o.size,'quantity',o.quantity,'unit_price_krw',o.unit_price_krw)
   order by o.sequence) from public.broadcast_order_lines o
   where o.seller_id=p_seller_id and o.customer_id=p_customer_id and o.session_id=p_session_id
    and o.invoice_id is null and not o.cancelled and not o.payment_locked),'[]'::jsonb),
  'country',(select d.country from public.broadcast_customer_destinations d
   where d.seller_id=p_seller_id and d.customer_id=p_customer_id),
  'deposit_available_krw',coalesce((select sum(d.amount_krw-
   coalesce((select sum(a.amount_krw) from public.broadcast_deposit_allocations a
    where a.seller_id=d.seller_id and a.deposit_id=d.id and a.reversed_at is null),0)-
   coalesce((select sum(r.amount_krw) from public.broadcast_deposit_returns r
    where r.seller_id=d.seller_id and r.deposit_id=d.id),0))
   from public.broadcast_deposits d where d.seller_id=p_seller_id and d.customer_id=p_customer_id
    and d.voided_at is null),0),
  'deposits',coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'amount_krw',d.amount_krw,
   'available_krw',d.amount_krw-
    coalesce((select sum(a.amount_krw) from public.broadcast_deposit_allocations a
     where a.seller_id=d.seller_id and a.deposit_id=d.id and a.reversed_at is null),0)-
    coalesce((select sum(r.amount_krw) from public.broadcast_deposit_returns r
     where r.seller_id=d.seller_id and r.deposit_id=d.id),0)) order by d.received_at,d.id)
   from public.broadcast_deposits d where d.seller_id=p_seller_id
    and d.customer_id=p_customer_id and d.voided_at is null),'[]'::jsonb));
end $$;

create function public.broadcast_guest_deposit_returns(p_locator uuid,p_session_hash text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_device public.broadcast_customer_devices;begin
 select d.* into v_device from public.broadcast_customer_devices d
 join public.broadcast_customer_links l on l.seller_id=d.seller_id and l.customer_id=d.customer_id
 where l.locator=p_locator and d.session_hash=p_session_hash and d.revoked_at is null
  and d.expires_at>clock_timestamp();
 if not found then raise exception '이 기기에서 선입금 반환을 볼 수 없습니다.' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'amount_krw',r.amount_krw,
  'reason',r.reason,'returned_at',r.returned_at) order by r.returned_at,r.id)
  from public.broadcast_deposit_returns r where r.seller_id=v_device.seller_id
   and r.customer_id=v_device.customer_id),'[]'::jsonb);
end $$;
revoke all on function public.broadcast_guest_deposit_returns(uuid,text) from public,anon,authenticated;
grant execute on function public.broadcast_guest_deposit_returns(uuid,text) to service_role;

-- ===== 202609290006_broadcast_manager_address.sql =====
-- B03: seller correction after payment, without changing shipped address snapshots.

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

-- ===== 202609290007_broadcast_shipment_history.sql =====
-- B07: seller-only keyset history, including fully shipped customers.

create function public.broadcast_shipment_history(p_seller_id uuid,p_customer_id uuid default null,
 p_before_at timestamptz default null,p_before_id uuid default null,p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_items jsonb;v_cursor jsonb;begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if (p_before_at is null)<>(p_before_id is null) then
  raise exception '출고 페이지 커서를 확인해주세요.' using errcode='22023'; end if;
 with page as (
  select s.id,s.customer_id,c.nickname,s.shipped_at,s.carrier,s.tracking_number,
   s.address_snapshot,s.additional_customer_shipping_minor
  from public.broadcast_shipments s join public.broadcast_customers c
   on c.seller_id=s.seller_id and c.id=s.customer_id
  where s.seller_id=p_seller_id and (p_customer_id is null or s.customer_id=p_customer_id)
   and (p_before_at is null or (s.shipped_at,s.id)<(p_before_at,p_before_id))
  order by s.shipped_at desc,s.id desc limit least(greatest(coalesce(p_limit,50),1),100)
 ), detail as (
  select p.*,coalesce((select jsonb_agg(jsonb_build_object(
   'order_line_id',o.id,'product_title',o.product_title,'color',o.color,
   'size',o.size,'quantity',sl.quantity) order by o.sequence,sl.id)
   from public.broadcast_shipment_lines sl
   join public.broadcast_stock_allocations sa on sa.seller_id=sl.seller_id and sa.id=sl.stock_allocation_id
   join public.broadcast_purchase_allocations pa on pa.seller_id=sa.seller_id and pa.id=sa.purchase_allocation_id
   join public.broadcast_order_lines o on o.seller_id=pa.seller_id and o.id=pa.order_line_id
   where sl.seller_id=p_seller_id and sl.shipment_id=p.id),'[]'::jsonb) as lines
  from page p
 )
 select coalesce(jsonb_agg(to_jsonb(d) order by d.shipped_at desc,d.id desc),'[]'::jsonb)
 into v_items from detail d;
 select jsonb_build_object('shipped_at',s.shipped_at,'id',s.id) into v_cursor
 from public.broadcast_shipments s
 where s.seller_id=p_seller_id and (p_customer_id is null or s.customer_id=p_customer_id)
  and (p_before_at is null or (s.shipped_at,s.id)<(p_before_at,p_before_id))
 order by s.shipped_at desc,s.id desc
 offset least(greatest(coalesce(p_limit,50),1),100)-1 limit 1;
 if jsonb_array_length(v_items)<least(greatest(coalesce(p_limit,50),1),100) then v_cursor:=null; end if;
 return jsonb_build_object('items',v_items,'next_cursor',v_cursor);
end $$;
revoke all on function public.broadcast_shipment_history(uuid,uuid,timestamptz,uuid,integer)
 from public,anon,service_role;
grant execute on function public.broadcast_shipment_history(uuid,uuid,timestamptz,uuid,integer)
 to authenticated;

-- ===== 202609290008_broadcast_seller_invoice_correction.sql =====
-- B03: separate public RPC name for seller-initiated billed-line correction.

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

-- ===== 202609290009_broadcast_purchase_export_status.sql =====
-- B05: supplier workbook reads live arrival and missing quantities from the same purchase rows.

create or replace function public.broadcast_purchase_tables(p_seller_id uuid,p_purchase_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if public.broadcast_permission(p_seller_id) is distinct from 'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if not exists(select 1 from public.broadcast_purchase_orders p
  where p.seller_id=p_seller_id and p.id=p_purchase_order_id) then
  raise exception '발주를 찾을 수 없습니다.' using errcode='22023'; end if;
 return jsonb_build_object(
  'supplier',coalesce((select jsonb_agg(jsonb_build_object('item_id',i.id,
   'supplier',p.supplier,'product_title',pr.title,'color',i.color,'size',i.size,
   'quantity',i.quantity,
   'latest_received_quantity',coalesce((select a.good_quantity+a.defect_quantity
    from public.broadcast_arrivals a where a.seller_id=i.seller_id
     and a.purchase_item_id=i.id and a.exchange_of_defect_id is null
    order by a.received_at desc,a.id desc limit 1),0),
   'cumulative_received_quantity',coalesce((select sum(a.good_quantity+a.defect_quantity)
    from public.broadcast_arrivals a where a.seller_id=i.seller_id
     and a.purchase_item_id=i.id and a.exchange_of_defect_id is null),0),
   'remaining_missing_quantity',i.quantity-coalesce((select sum(a.good_quantity+a.defect_quantity)
    from public.broadcast_arrivals a where a.seller_id=i.seller_id
     and a.purchase_item_id=i.id and a.exchange_of_defect_id is null),0),
   'defect_exchange_quantity',coalesce((select sum(d.quantity) from public.broadcast_defect_exchanges d
    join public.broadcast_arrivals a on a.seller_id=d.seller_id and a.id=d.arrival_id
    where a.seller_id=i.seller_id and a.purchase_item_id=i.id and d.status='waiting'),0),
   'note','') order by i.id)
   from public.broadcast_purchase_items i join public.broadcast_purchase_orders p
    on p.seller_id=i.seller_id and p.id=i.purchase_order_id
   join public.broadcast_products pr on pr.seller_id=i.seller_id and pr.id=i.product_id
   where i.seller_id=p_seller_id and i.purchase_order_id=p_purchase_order_id),'[]'::jsonb),
  'customers',coalesce((select jsonb_agg(jsonb_build_object('item_id',i.id,
   'product_title',o.product_title,'color',o.color,'size',o.size,
   'quantity',a.quantity,'customer_id',c.id,'nickname',c.nickname,
   'payment_confirmed',true,'status',case
    when coalesce((select sum(sl.quantity) from public.broadcast_shipment_lines sl
     join public.broadcast_stock_allocations sa on sa.seller_id=sl.seller_id
      and sa.id=sl.stock_allocation_id where sa.seller_id=a.seller_id
      and sa.purchase_allocation_id=a.id),0)>=a.quantity then '출고완료'
    when coalesce((select sum(sl.quantity) from public.broadcast_shipment_lines sl
     join public.broadcast_stock_allocations sa on sa.seller_id=sl.seller_id
      and sa.id=sl.stock_allocation_id where sa.seller_id=a.seller_id
      and sa.purchase_allocation_id=a.id),0)>0 then '부분출고'
    when coalesce((select sum(sa.quantity) from public.broadcast_stock_allocations sa
     where sa.seller_id=a.seller_id and sa.purchase_allocation_id=a.id),0)>=a.quantity then '입고'
    when coalesce((select sum(sa.quantity) from public.broadcast_stock_allocations sa
     where sa.seller_id=a.seller_id and sa.purchase_allocation_id=a.id),0)>0 then '부분입고'
    else '미송' end,'note',o.note) order by o.sequence)
   from public.broadcast_purchase_allocations a join public.broadcast_purchase_items i
    on i.seller_id=a.seller_id and i.id=a.purchase_item_id
   join public.broadcast_order_lines o on o.seller_id=a.seller_id and o.id=a.order_line_id
   join public.broadcast_customers c on c.seller_id=o.seller_id and c.id=o.customer_id
   where a.seller_id=p_seller_id and i.purchase_order_id=p_purchase_order_id),'[]'::jsonb));
end $$;

-- ===== 202609290010_broadcast_receiver_qr.sql =====
-- B03: immutable private QR object reference captured by invoice snapshot.

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

-- ===== 202609290011_broadcast_invoice_country_revision.sql =====
-- B03: unpaid invoice country correction recalculates shipping and requires a new address/acceptance.

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

-- ===== 202609290012_broadcast_invoice_full_exclusion.sql =====
-- B03: void a fully excluded invoice instead of attempting an empty reissue.

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
