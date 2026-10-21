-- B02: keep the customer's one-line original until an operator resolves it.
begin;
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
commit;
