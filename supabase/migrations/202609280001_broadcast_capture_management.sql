-- B01 follow-up: apply after 202609230001 on an existing TEST database.
-- No production deployment is part of local development.
begin;
alter table public.broadcast_sessions drop constraint if exists broadcast_sessions_status_check;
alter table public.broadcast_sessions add constraint broadcast_sessions_status_check
 check(status in ('draft','open','closed','archived'));
alter table public.broadcast_sessions add column if not exists version integer not null default 1;
alter table public.broadcast_products add column if not exists deleted_at timestamptz;
create or replace function public.broadcast_command(p_seller_id uuid,p_command text,p_data jsonb,p_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 permission text; previous public.broadcast_commands;
 session_row public.broadcast_sessions; product_row public.broadcast_products; neighbor public.broadcast_products;
 order_row public.broadcast_order_lines; result jsonb; old_value jsonb;
 entity uuid; product_number integer; days integer; why text; session_date date; new_status text;
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
 if p_command in ('session.create','session.update','order.revise') and permission<>'manager' then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 case p_command
 when 'customer.create' then
  insert into public.broadcast_customers(seller_id,nickname,wechat_note)
  values(p_seller_id,trim(p_data->>'nickname'),coalesce(trim(p_data->>'wechat_note'),'')) returning id,to_jsonb(broadcast_customers.*) into entity,result;
 when 'session.create' then
  days:=coalesce((p_data->>'management_days')::integer,3);
  session_date:=coalesce((p_data->>'broadcast_date')::date,(now() at time zone 'Asia/Seoul')::date);
  new_status:=coalesce(p_data->>'status','open');
  if new_status='open' and (session_date+days)::timestamp at time zone 'Asia/Seoul'<=clock_timestamp() then
   raise exception '접수 기한이 지난 방송을 열 수 없습니다.'; end if;
  insert into public.broadcast_sessions(seller_id,title,kind,broadcast_date,exchange_rate,shipping_krw,shipping_cny_fen,free_shipping_count,management_days,closes_at,status)
  values(p_seller_id,trim(p_data->>'title'),p_data->>'kind',session_date,(p_data->>'exchange_rate')::numeric,
   coalesce((p_data->>'shipping_krw')::integer,4000),coalesce((p_data->>'shipping_cny_fen')::integer,3000),
   coalesce((p_data->>'free_shipping_count')::integer,5),days,
   (session_date+days)::timestamp at time zone 'Asia/Seoul',new_status)
  returning id,to_jsonb(broadcast_sessions.*) into entity,result;
 when 'session.update' then
  select * into session_row from public.broadcast_sessions where id=(p_data->>'id')::uuid and seller_id=p_seller_id for update;
  if not found then raise exception '방송을 찾을 수 없습니다.'; end if;
  if (p_data->>'version')::integer is distinct from session_row.version then raise exception '방송이 변경되었습니다. 새로 확인해주세요.' using errcode='40001'; end if;
  days:=coalesce((p_data->>'management_days')::integer,session_row.management_days);
  session_date:=coalesce((p_data->>'broadcast_date')::date,session_row.broadcast_date);
  new_status:=coalesce(p_data->>'status',session_row.status);
  if new_status='open' and (session_date+days)::timestamp at time zone 'Asia/Seoul'<=clock_timestamp() then
   raise exception '접수 기한이 지난 방송을 열 수 없습니다.'; end if;
  old_value:=to_jsonb(session_row);
  update public.broadcast_sessions set title=coalesce(trim(p_data->>'title'),title),kind=coalesce(p_data->>'kind',kind),
   broadcast_date=session_date,exchange_rate=coalesce((p_data->>'exchange_rate')::numeric,exchange_rate),
   shipping_krw=coalesce((p_data->>'shipping_krw')::integer,shipping_krw),
   shipping_cny_fen=coalesce((p_data->>'shipping_cny_fen')::integer,shipping_cny_fen),
   free_shipping_count=coalesce((p_data->>'free_shipping_count')::integer,free_shipping_count),
   management_days=days,closes_at=(session_date+days)::timestamp at time zone 'Asia/Seoul',status=new_status,version=version+1
  where id=session_row.id returning id,to_jsonb(broadcast_sessions.*) into entity,result;
 when 'product.create' then
  select * into session_row from public.broadcast_sessions where id=(p_data->>'session_id')::uuid and seller_id=p_seller_id for update;
  if not found or session_row.status not in ('draft','open') then raise exception '준비 중이거나 열린 방송을 선택해주세요.'; end if;
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
  if product_row.deleted_at is not null then raise exception '삭제한 상품은 먼저 복구해주세요.'; end if;
  if (p_data->>'version')::integer is distinct from product_row.version then raise exception '상품이 변경되었습니다. 새로 확인해주세요.' using errcode='40001'; end if;
  old_value:=to_jsonb(product_row);
  update public.broadcast_products set visible=coalesce((p_data->>'visible')::boolean,false),
   in_outfit=coalesce((p_data->>'in_outfit')::boolean,false),version=version+1 where id=product_row.id
  returning id,to_jsonb(broadcast_products.*) into entity,result;
 when 'product.update' then
  select * into product_row from public.broadcast_products where id=(p_data->>'id')::uuid and seller_id=p_seller_id for update;
  if not found then raise exception '상품을 찾을 수 없습니다.'; end if;
  if product_row.deleted_at is not null then raise exception '삭제한 상품은 먼저 복구해주세요.'; end if;
  if (p_data->>'version')::integer is distinct from product_row.version then raise exception '상품이 변경되었습니다. 새로 확인해주세요.' using errcode='40001'; end if;
  perform 1 from public.broadcast_order_lines where seller_id=p_seller_id and product_id=product_row.id limit 1;
  if found then raise exception '접수 이력이 있는 상품은 원본을 바꿀 수 없습니다. 주문별로 정정해주세요.'; end if;
  old_value:=to_jsonb(product_row);
  update public.broadcast_products set supplier=trim(p_data->>'supplier'),title=trim(p_data->>'title'),
   price_krw=(p_data->>'price_krw')::integer,
   colors=array(select jsonb_array_elements_text(coalesce(p_data->'colors','[]'::jsonb))),
   sizes=array(select jsonb_array_elements_text(coalesce(p_data->'sizes','[]'::jsonb))),
   shipping_excluded=coalesce((p_data->>'shipping_excluded')::boolean,false),
   quantity_limited=coalesce((p_data->>'quantity_limited')::boolean,false),
   available_quantity=(p_data->>'available_quantity')::integer,
   visible=false,in_outfit=false,version=version+1
  where id=product_row.id returning id,to_jsonb(broadcast_products.*) into entity,result;
 when 'product.archive' then
  select * into product_row from public.broadcast_products where id=(p_data->>'id')::uuid and seller_id=p_seller_id for update;
  if not found then raise exception '상품을 찾을 수 없습니다.'; end if;
  if product_row.deleted_at is not null then raise exception '이미 삭제한 상품입니다.'; end if;
  if (p_data->>'version')::integer is distinct from product_row.version then raise exception '상품이 변경되었습니다. 새로 확인해주세요.' using errcode='40001'; end if;
  perform 1 from public.broadcast_order_lines where seller_id=p_seller_id and product_id=product_row.id limit 1;
  if found then raise exception '접수 이력이 있어 삭제할 수 없습니다.'; end if;
  old_value:=to_jsonb(product_row);
  update public.broadcast_products set deleted_at=clock_timestamp(),visible=false,in_outfit=false,version=version+1
  where id=product_row.id returning id,to_jsonb(broadcast_products.*) into entity,result;
 when 'product.restore' then
  select * into product_row from public.broadcast_products where id=(p_data->>'id')::uuid and seller_id=p_seller_id for update;
  if not found then raise exception '상품을 찾을 수 없습니다.'; end if;
  if product_row.deleted_at is null then raise exception '삭제한 상품이 아닙니다.'; end if;
  if (p_data->>'version')::integer is distinct from product_row.version then raise exception '상품이 변경되었습니다. 새로 확인해주세요.' using errcode='40001'; end if;
  old_value:=to_jsonb(product_row);
  update public.broadcast_products set deleted_at=null,visible=false,in_outfit=false,version=version+1
  where id=product_row.id returning id,to_jsonb(broadcast_products.*) into entity,result;
 when 'product.reorder' then
  select * into product_row from public.broadcast_products where id=(p_data->>'id')::uuid and seller_id=p_seller_id for update;
  if not found or product_row.deleted_at is not null then raise exception '상품을 찾을 수 없습니다.'; end if;
  if (p_data->>'version')::integer is distinct from product_row.version then raise exception '상품이 변경되었습니다. 새로 확인해주세요.' using errcode='40001'; end if;
  if p_data->>'direction'='up' then
   select * into neighbor from public.broadcast_products where seller_id=p_seller_id and session_id=product_row.session_id and deleted_at is null and public_order<product_row.public_order order by public_order desc,number desc limit 1 for update;
  elsif p_data->>'direction'='down' then
   select * into neighbor from public.broadcast_products where seller_id=p_seller_id and session_id=product_row.session_id and deleted_at is null and public_order>product_row.public_order order by public_order,number limit 1 for update;
  else raise exception '공개 순서를 확인해주세요.' using errcode='22023'; end if;
  if not found then raise exception '이동할 상품이 없습니다.'; end if;
  old_value:=jsonb_build_object('moved',to_jsonb(product_row),'neighbor',to_jsonb(neighbor));
  update public.broadcast_products set public_order=neighbor.public_order,version=version+1 where id=product_row.id;
  update public.broadcast_products set public_order=product_row.public_order,version=version+1 where id=neighbor.id;
  select jsonb_build_object('moved',to_jsonb(p),'neighbor',to_jsonb(n)) into result from public.broadcast_products p,public.broadcast_products n where p.id=product_row.id and n.id=neighbor.id;
  entity:=product_row.id;
 when 'order.create' then
  select * into session_row from public.broadcast_sessions where id=(p_data->>'session_id')::uuid and seller_id=p_seller_id for update;
  if not found or session_row.status<>'open' or session_row.closes_at<=clock_timestamp()
   or (session_row.broadcast_date::timestamp at time zone 'Asia/Seoul')>clock_timestamp() then raise exception '접수 가능한 방송이 아닙니다.'; end if;
  perform 1 from public.broadcast_customers where id=(p_data->>'customer_id')::uuid and seller_id=p_seller_id;
  if not found then raise exception '고객을 찾을 수 없습니다.' using errcode='42501'; end if;
  select * into product_row from public.broadcast_products where id=(p_data->>'product_id')::uuid and seller_id=p_seller_id and session_id=session_row.id;
  if not found or product_row.deleted_at is not null then raise exception '같은 방송의 판매 가능 상품을 선택해주세요.'; end if;
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
commit;
