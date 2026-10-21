-- B01: staff capture only. Apply to a TEST Supabase after existing schema.
-- Never append this to production schema or run against production as part of tests.
begin;
create table public.broadcast_memberships (
 seller_id uuid not null references public.seller_profiles(user_id),
 user_id uuid not null references auth.users(id),
 role text not null check(role in ('assistant','manager')),
 primary key(seller_id,user_id)
);
create table public.broadcast_customers (
 id uuid primary key default gen_random_uuid(),
 seller_id uuid not null references public.seller_profiles(user_id),
 nickname text not null check(length(trim(nickname)) between 1 and 80),
 wechat_note text not null default '' check(length(wechat_note)<=200),
 created_at timestamptz not null default clock_timestamp(),
 unique(seller_id,id)
);
create index broadcast_customers_seller on public.broadcast_customers(seller_id);
create table public.broadcast_sessions (
 id uuid primary key default gen_random_uuid(),
 seller_id uuid not null references public.seller_profiles(user_id),
 title text not null check(length(trim(title)) between 1 and 100),
 kind text not null check(kind in ('new','special')),
 broadcast_date date not null default (now() at time zone 'Asia/Seoul')::date,
 exchange_rate numeric(12,4) not null check(exchange_rate>0), -- KRW per 1 CNY
 shipping_krw integer not null default 4000 check(shipping_krw>=0),
 shipping_cny_fen integer not null default 3000 check(shipping_cny_fen>=0),
 free_shipping_count integer not null default 5 check(free_shipping_count>0),
 management_days integer not null default 3 check(management_days between 1 and 30),
 closes_at timestamptz not null,
 status text not null default 'open' check(status in ('open','closed','archived')),
 next_product_number integer not null default 1,
 created_at timestamptz not null default clock_timestamp(),
 unique(seller_id,id)
);
create table public.broadcast_products (
 id uuid primary key default gen_random_uuid(), seller_id uuid not null,
 session_id uuid not null, number integer not null check(number>0),
 supplier text not null check(length(trim(supplier)) between 1 and 100),
 title text not null check(length(trim(title)) between 1 and 100),
 price_krw integer not null check(price_krw between 0 and 100000000),
 colors text[] not null default '{}', sizes text[] not null default '{}',
 visible boolean not null default false, in_outfit boolean not null default false,
 public_order integer not null, shipping_excluded boolean not null default false,
 quantity_limited boolean not null default false,
 available_quantity integer check(available_quantity>=0),
 version integer not null default 1,
 unique(seller_id,id), unique(session_id,number), unique(seller_id,session_id,id),
 foreign key(seller_id,session_id) references public.broadcast_sessions(seller_id,id),
 check(not in_outfit or visible),
 check(not quantity_limited or available_quantity is not null)
);
create table public.broadcast_order_lines (
 id uuid primary key default gen_random_uuid(), seller_id uuid not null,
 session_id uuid not null, customer_id uuid not null, product_id uuid not null,
 sequence bigint generated always as identity unique,
 created_at timestamptz not null default clock_timestamp(),
 created_by uuid not null references auth.users(id),
 source text not null check(source in ('broadcast_assistant','seller_input','customer_addition')),
 product_title text not null, product_number integer not null, supplier text not null,
 unit_price_krw integer not null check(unit_price_krw>=0),
 color text not null check(length(color)<=80), size text not null check(length(size)<=80),
 quantity integer not null check(quantity between 1 and 999),
 note text not null default '' check(length(note)<=500),
 original jsonb not null, cancelled boolean not null default false,
 version integer not null default 1,
 invoice_id uuid, payment_locked boolean not null default false,
 unique(seller_id,id),
 foreign key(seller_id,customer_id) references public.broadcast_customers(seller_id,id),
 foreign key(seller_id,session_id,product_id) references public.broadcast_products(seller_id,session_id,id)
);
create index broadcast_lines_customer on public.broadcast_order_lines(seller_id,customer_id,sequence);
create table public.broadcast_audit (
 id bigint generated always as identity primary key,
 seller_id uuid not null references public.seller_profiles(user_id),
 actor_id uuid not null references auth.users(id),
 command text not null, entity_id uuid not null,
 before_value jsonb, after_value jsonb not null,
 reason text not null default '', created_at timestamptz not null default clock_timestamp()
);
create table public.broadcast_commands (
 seller_id uuid not null references public.seller_profiles(user_id),
 actor_id uuid not null references auth.users(id), key uuid not null,
 command text not null, payload jsonb not null, result jsonb not null,
 created_at timestamptz not null default clock_timestamp(),
 primary key(seller_id,actor_id,key)
);

create function public.broadcast_permission(p_seller_id uuid) returns text
language sql stable security definer set search_path='' as $$
 select case when auth.uid()=s.user_id then 'manager'
 else (select m.role from public.broadcast_memberships m where m.seller_id=s.user_id and m.user_id=auth.uid()) end
 from public.seller_profiles s where s.user_id=p_seller_id and s.status='approved';
$$;
revoke all on function public.broadcast_permission(uuid) from public,anon;
grant execute on function public.broadcast_permission(uuid) to authenticated;

do $$ declare t text; begin
 foreach t in array array['broadcast_memberships','broadcast_customers','broadcast_sessions','broadcast_products','broadcast_order_lines','broadcast_audit','broadcast_commands'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated',t);
 end loop;
 foreach t in array array['broadcast_customers','broadcast_sessions','broadcast_products','broadcast_order_lines'] loop
  execute format('grant select on public.%I to authenticated',t);
  execute format('create policy staff_read on public.%I for select to authenticated using(public.broadcast_permission(seller_id) is not null)',t);
 end loop;
end $$;

create function public.broadcast_workspace(p_seller_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare permission text; begin
 permission:=public.broadcast_permission(p_seller_id);
 if permission is null then raise exception '방송 관리 권한이 없습니다.' using errcode='42501'; end if;
 return jsonb_build_object('role',permission,
 'customers',coalesce((select jsonb_agg(to_jsonb(c) order by c.nickname,c.id) from public.broadcast_customers c where c.seller_id=p_seller_id),'[]'::jsonb),
 'sessions',coalesce((select jsonb_agg(to_jsonb(s) order by s.created_at desc) from public.broadcast_sessions s where s.seller_id=p_seller_id),'[]'::jsonb),
 'products',coalesce((select jsonb_agg(to_jsonb(p) order by p.number) from public.broadcast_products p where p.seller_id=p_seller_id),'[]'::jsonb),
 'orders',coalesce((select jsonb_agg(to_jsonb(o) order by o.sequence desc) from public.broadcast_order_lines o where o.seller_id=p_seller_id),'[]'::jsonb));
end $$;
revoke all on function public.broadcast_workspace(uuid) from public,anon;
grant execute on function public.broadcast_workspace(uuid) to authenticated;

create function public.broadcast_command(p_seller_id uuid,p_command text,p_data jsonb,p_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 permission text; previous public.broadcast_commands;
 session_row public.broadcast_sessions; product_row public.broadcast_products;
 order_row public.broadcast_order_lines; result jsonb; old_value jsonb;
 entity uuid; product_number integer; days integer; why text;
begin
 permission:=public.broadcast_permission(p_seller_id);
 if permission is null then raise exception '방송 관리 권한이 없습니다.' using errcode='42501'; end if;
 if p_key is null or p_data is null or jsonb_typeof(p_data)<>'object' or p_command is null then
  raise exception '요청 키와 입력값이 필요합니다.' using errcode='22023'; end if;
 -- All B01 writes use the same seller lock, including replay check and numbering.
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into previous from public.broadcast_commands where seller_id=p_seller_id and actor_id=auth.uid() and key=p_key;
 if found then
  if previous.command<>p_command or previous.payload<>p_data then raise exception '같은 저장 키로 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
  return previous.result;
 end if;
 if p_command in ('session.create','order.revise') and permission<>'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 case p_command
 when 'customer.create' then
  insert into public.broadcast_customers(seller_id,nickname,wechat_note)
  values(p_seller_id,trim(p_data->>'nickname'),coalesce(trim(p_data->>'wechat_note'),'')) returning id,to_jsonb(broadcast_customers.*) into entity,result;
 when 'session.create' then
  days:=coalesce((p_data->>'management_days')::integer,3);
  insert into public.broadcast_sessions(seller_id,title,kind,exchange_rate,shipping_krw,shipping_cny_fen,free_shipping_count,management_days,closes_at)
  values(p_seller_id,trim(p_data->>'title'),p_data->>'kind',(p_data->>'exchange_rate')::numeric,
   coalesce((p_data->>'shipping_krw')::integer,4000),coalesce((p_data->>'shipping_cny_fen')::integer,3000),
   coalesce((p_data->>'free_shipping_count')::integer,5),days,clock_timestamp()+make_interval(days=>days))
  returning id,to_jsonb(broadcast_sessions.*) into entity,result;
 when 'product.create' then
  select * into session_row from public.broadcast_sessions where id=(p_data->>'session_id')::uuid and seller_id=p_seller_id for update;
  if not found or session_row.status<>'open' then raise exception '열린 방송을 선택해주세요.'; end if;
  product_number:=session_row.next_product_number;
  update public.broadcast_sessions set next_product_number=next_product_number+1 where id=session_row.id;
  insert into public.broadcast_products(seller_id,session_id,number,public_order,supplier,title,price_krw,colors,sizes,shipping_excluded,quantity_limited,available_quantity)
  values(p_seller_id,session_row.id,product_number,product_number,trim(p_data->>'supplier'),trim(p_data->>'title'),(p_data->>'price_krw')::integer,
   array(select jsonb_array_elements_text(coalesce(p_data->'colors','[]'::jsonb))),
   array(select jsonb_array_elements_text(coalesce(p_data->'sizes','[]'::jsonb))),
   coalesce((p_data->>'shipping_excluded')::boolean,false),coalesce((p_data->>'quantity_limited')::boolean,false),(p_data->>'available_quantity')::integer)
  returning id,to_jsonb(broadcast_products.*) into entity,result;
 when 'product.publish' then
  select * into product_row from public.broadcast_products where id=(p_data->>'id')::uuid and seller_id=p_seller_id for update;
  if not found then raise exception '상품을 찾을 수 없습니다.'; end if;
  if (p_data->>'version')::integer is distinct from product_row.version then raise exception '상품이 변경되었습니다. 새로 확인해주세요.' using errcode='40001'; end if;
  old_value:=to_jsonb(product_row);
  update public.broadcast_products set visible=coalesce((p_data->>'visible')::boolean,false),
   in_outfit=coalesce((p_data->>'in_outfit')::boolean,false),version=version+1 where id=product_row.id
  returning id,to_jsonb(broadcast_products.*) into entity,result;
 when 'order.create' then
  select * into session_row from public.broadcast_sessions where id=(p_data->>'session_id')::uuid and seller_id=p_seller_id for update;
  if not found or session_row.status<>'open' or session_row.closes_at<=clock_timestamp() then raise exception '접수 가능한 방송이 아닙니다.'; end if;
  perform 1 from public.broadcast_customers where id=(p_data->>'customer_id')::uuid and seller_id=p_seller_id;
  if not found then raise exception '고객을 찾을 수 없습니다.' using errcode='42501'; end if;
  select * into product_row from public.broadcast_products where id=(p_data->>'product_id')::uuid and seller_id=p_seller_id and session_id=session_row.id;
  if not found then raise exception '같은 방송의 상품을 선택해주세요.'; end if;
  insert into public.broadcast_order_lines(seller_id,session_id,customer_id,product_id,created_by,source,
   product_title,product_number,supplier,unit_price_krw,color,size,quantity,note,original)
  values(p_seller_id,session_row.id,(p_data->>'customer_id')::uuid,product_row.id,auth.uid(),
   case when permission='assistant' then 'broadcast_assistant' else 'seller_input' end,
   product_row.title,product_row.number,product_row.supplier,product_row.price_krw,
   trim(coalesce(p_data->>'color','')),trim(coalesce(p_data->>'size','')),(p_data->>'quantity')::integer,coalesce(p_data->>'note',''),
   jsonb_build_object('product',to_jsonb(product_row),'color',trim(coalesce(p_data->>'color','')),'size',trim(coalesce(p_data->>'size','')),
    'quantity',(p_data->>'quantity')::integer,'note',coalesce(p_data->>'note','')))
  returning id,to_jsonb(broadcast_order_lines.*) into entity,result;
 when 'order.revise' then
  select * into order_row from public.broadcast_order_lines where id=(p_data->>'id')::uuid and seller_id=p_seller_id for update;
  if not found then raise exception '주문을 찾을 수 없습니다.'; end if;
  if order_row.payment_locked or order_row.invoice_id is not null then raise exception '청구 또는 송금 진행 주문은 이 화면에서 수정할 수 없습니다.'; end if;
  if (p_data->>'version')::integer is distinct from order_row.version then raise exception '주문이 변경되었습니다. 새로 확인해주세요.' using errcode='40001'; end if;
  why:=trim(coalesce(p_data->>'reason',''));
  if length(why)<1 or length(why)>500 then raise exception '수정 사유를 입력해주세요.'; end if;
  old_value:=to_jsonb(order_row);
  update public.broadcast_order_lines set color=trim(coalesce(p_data->>'color','')),size=trim(coalesce(p_data->>'size','')),
   quantity=(p_data->>'quantity')::integer,note=coalesce(p_data->>'note',''),cancelled=coalesce((p_data->>'cancelled')::boolean,false),version=version+1
  where id=order_row.id returning id,to_jsonb(broadcast_order_lines.*) into entity,result;
 else raise exception '지원하지 않는 작업입니다.' using errcode='22023';
 end case;
 insert into public.broadcast_audit(seller_id,actor_id,command,entity_id,before_value,after_value,reason)
 values(p_seller_id,auth.uid(),case when p_command='order.revise' then 'seller_edit' else p_command end,entity,old_value,result,coalesce(why,''));
 insert into public.broadcast_commands(seller_id,actor_id,key,command,payload,result) values(p_seller_id,auth.uid(),p_key,p_command,p_data,result);
 return result;
end $$;
revoke all on function public.broadcast_command(uuid,text,jsonb,uuid) from public,anon;
grant execute on function public.broadcast_command(uuid,text,jsonb,uuid) to authenticated;
commit;
