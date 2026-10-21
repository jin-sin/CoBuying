-- B01: bounded staff lists. Apply after the three earlier broadcast migrations.
begin;
create index broadcast_lines_session_sequence on public.broadcast_order_lines(seller_id,session_id,sequence desc);
create index broadcast_customers_name_id on public.broadcast_customers(seller_id,nickname,id);

create or replace function public.broadcast_workspace(p_seller_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare permission text; begin
 permission:=public.broadcast_permission(p_seller_id);
 if permission is null then raise exception '방송 관리 권한이 없습니다.' using errcode='42501'; end if;
 return jsonb_build_object('role',permission,
  'customers','[]'::jsonb,
  'sessions',coalesce((select jsonb_agg(to_jsonb(s) order by s.created_at desc,s.id) from public.broadcast_sessions s where s.seller_id=p_seller_id),'[]'::jsonb),
  'products',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('has_orders',exists(select 1 from public.broadcast_order_lines o where o.seller_id=p_seller_id and o.product_id=p.id)) order by p.number) from public.broadcast_products p where p.seller_id=p_seller_id),'[]'::jsonb),
  'orders','[]'::jsonb);
end $$;

create function public.broadcast_customer_page(p_seller_id uuid,p_query text default '',p_after_nickname text default null,p_after_id uuid default null,p_limit integer default 20) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare items jsonb; last_name text; last_id uuid; begin
 if public.broadcast_permission(p_seller_id) is null then raise exception '방송 관리 권한이 없습니다.' using errcode='42501'; end if;
 if (p_after_nickname is null) <> (p_after_id is null) then raise exception '잘못된 페이지 위치입니다.' using errcode='22023'; end if;
 if length(coalesce(p_query,''))>80 then raise exception '검색어가 너무 깁니다.' using errcode='22023'; end if;
 with bounded as (
  select c.* from public.broadcast_customers c
  where c.seller_id=p_seller_id and (coalesce(p_query,'')='' or position(p_query in c.nickname)>0)
   and (p_after_id is null or (c.nickname,c.id)>(p_after_nickname,p_after_id))
  order by c.nickname,c.id limit least(greatest(coalesce(p_limit,20),1),50)
 )
 select coalesce(jsonb_agg(to_jsonb(b) order by b.nickname,b.id),'[]'::jsonb) into items from bounded b;
 if jsonb_array_length(items)>0 then
  last_name:=items->(jsonb_array_length(items)-1)->>'nickname';
  last_id:=(items->(jsonb_array_length(items)-1)->>'id')::uuid;
 end if;
 return jsonb_build_object('items',items,'next_nickname',case when exists(
  select 1 from public.broadcast_customers c where c.seller_id=p_seller_id
   and (coalesce(p_query,'')='' or position(p_query in c.nickname)>0)
   and last_id is not null and (c.nickname,c.id)>(last_name,last_id)) then last_name else null end,
  'next_id',case when exists(
  select 1 from public.broadcast_customers c where c.seller_id=p_seller_id
   and (coalesce(p_query,'')='' or position(p_query in c.nickname)>0)
   and last_id is not null and (c.nickname,c.id)>(last_name,last_id)) then last_id else null end);
end $$;

create function public.broadcast_order_page(p_seller_id uuid,p_session_id uuid,p_before_sequence bigint default null,p_limit integer default 30) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare items jsonb; last_sequence bigint; begin
 if public.broadcast_permission(p_seller_id) is null then raise exception '방송 관리 권한이 없습니다.' using errcode='42501'; end if;
 if not exists(select 1 from public.broadcast_sessions s where s.seller_id=p_seller_id and s.id=p_session_id) then
  raise exception '방송을 찾을 수 없습니다.' using errcode='22023'; end if;
 with bounded as (
  select o.*,c.nickname from public.broadcast_order_lines o
  join public.broadcast_customers c on c.seller_id=o.seller_id and c.id=o.customer_id
  where o.seller_id=p_seller_id and o.session_id=p_session_id and (p_before_sequence is null or o.sequence<p_before_sequence)
  order by o.sequence desc limit least(greatest(coalesce(p_limit,30),1),50)
 ) select coalesce(jsonb_agg(to_jsonb(b) order by b.sequence desc),'[]'::jsonb) into items from bounded b;
 if jsonb_array_length(items)>0 then last_sequence:=(items->(jsonb_array_length(items)-1)->>'sequence')::bigint; end if;
 return jsonb_build_object('items',items,'next_before_sequence',case when exists(
  select 1 from public.broadcast_order_lines o where o.seller_id=p_seller_id and o.session_id=p_session_id
   and last_sequence is not null and o.sequence<last_sequence) then last_sequence else null end);
end $$;
revoke all on function public.broadcast_customer_page(uuid,text,text,uuid,integer),public.broadcast_order_page(uuid,uuid,bigint,integer) from public,anon;
grant execute on function public.broadcast_customer_page(uuid,text,text,uuid,integer),public.broadcast_order_page(uuid,uuid,bigint,integer) to authenticated;
commit;
