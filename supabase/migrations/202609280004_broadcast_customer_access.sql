-- B02 first slice: customer locator, one-device approval and scoped view.
-- The guest functions are server-gateway only; never expose a service_role key
-- or a customer session hash to a browser.
begin;

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
commit;
