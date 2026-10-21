-- B01 staff access. Apply only after the two earlier broadcast migrations.
begin;

create table public.broadcast_staff_invites (
 code uuid primary key default gen_random_uuid(),
 seller_id uuid not null references public.seller_profiles(user_id),
 role text not null default 'assistant' check(role = 'assistant'),
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default clock_timestamp(),
 expires_at timestamptz not null default (clock_timestamp() + interval '30 minutes'),
 claimed_by uuid references auth.users(id),
 claimed_at timestamptz
);
create index broadcast_staff_invites_seller on public.broadcast_staff_invites(seller_id,expires_at);
alter table public.broadcast_staff_invites enable row level security;
revoke all on public.broadcast_staff_invites from public,anon,authenticated;

create function public.broadcast_staff_overview(p_seller_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if public.broadcast_permission(p_seller_id) <> 'manager' or public.broadcast_permission(p_seller_id) is null then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 return jsonb_build_object(
  'members',coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'role',m.role) order by m.user_id)
   from public.broadcast_memberships m where m.seller_id=p_seller_id),'[]'::jsonb),
  'invites',coalesce((select jsonb_agg(jsonb_build_object('code',i.code,'expires_at',i.expires_at) order by i.created_at desc)
   from public.broadcast_staff_invites i where i.seller_id=p_seller_id and i.claimed_by is null and i.expires_at>clock_timestamp()),'[]'::jsonb));
end $$;
revoke all on function public.broadcast_staff_overview(uuid) from public,anon;
grant execute on function public.broadcast_staff_overview(uuid) to authenticated;

create function public.broadcast_staff_manage(p_seller_id uuid,p_action text,p_user_id uuid,p_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare prior public.broadcast_commands; answer jsonb; target uuid; old_role text;
begin
 if public.broadcast_permission(p_seller_id) <> 'manager' or public.broadcast_permission(p_seller_id) is null then
  raise exception '판매자 관리 권한이 필요합니다.' using errcode='42501'; end if;
 if p_key is null or p_action not in ('invite','remove') or p_action is null then
  raise exception '작업과 요청 키를 확인해주세요.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_seller_id::text,0));
 select * into prior from public.broadcast_commands where seller_id=p_seller_id and actor_id=auth.uid() and key=p_key;
 if found then
  if prior.command <> 'staff.'||p_action or prior.payload <> jsonb_build_object('user_id',p_user_id) then
   raise exception '같은 저장 키로 내용을 변경할 수 없습니다.' using errcode='22023'; end if;
  return prior.result;
 end if;
 if p_action='invite' then
  if p_user_id is not null then raise exception '초대에는 사용자 ID를 넣지 않습니다.' using errcode='22023'; end if;
  insert into public.broadcast_staff_invites(seller_id,created_by) values(p_seller_id,auth.uid())
   returning code into target;
  select jsonb_build_object('code',i.code,'expires_at',i.expires_at) into answer
   from public.broadcast_staff_invites i where i.code=target;
 else
  if p_user_id is null or p_user_id=p_seller_id or p_user_id=auth.uid() then
   raise exception '회수할 다른 담당자를 선택해주세요.' using errcode='22023'; end if;
  select role into old_role from public.broadcast_memberships where seller_id=p_seller_id and user_id=p_user_id for update;
  if old_role is null then raise exception '담당자를 찾을 수 없습니다.' using errcode='22023'; end if;
  if old_role='manager' and auth.uid()<>p_seller_id then
   raise exception '관리자 권한은 판매자 본인만 회수할 수 있습니다.' using errcode='42501'; end if;
  delete from public.broadcast_memberships where seller_id=p_seller_id and user_id=p_user_id;
  update public.broadcast_staff_invites set claimed_by=null,claimed_at=null,expires_at=clock_timestamp()
   where seller_id=p_seller_id and claimed_by=p_user_id;
  target:=p_user_id;
  answer:=jsonb_build_object('user_id',p_user_id,'removed',true);
 end if;
 insert into public.broadcast_audit(seller_id,actor_id,command,entity_id,after_value)
 values(p_seller_id,auth.uid(),'staff.'||p_action,target,answer);
 insert into public.broadcast_commands(seller_id,actor_id,key,command,payload,result)
 values(p_seller_id,auth.uid(),p_key,'staff.'||p_action,jsonb_build_object('user_id',p_user_id),answer);
 return answer;
end $$;
revoke all on function public.broadcast_staff_manage(uuid,text,uuid,uuid) from public,anon;
grant execute on function public.broadcast_staff_manage(uuid,text,uuid,uuid) to authenticated;

create function public.broadcast_staff_join(p_code uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare invite public.broadcast_staff_invites; member_role text;
begin
 if auth.uid() is null or p_code is null then raise exception '로그인이 필요합니다.' using errcode='42501'; end if;
 select * into invite from public.broadcast_staff_invites where code=p_code for update;
 if not found then raise exception '참여 코드를 찾을 수 없습니다.' using errcode='22023'; end if;
 if invite.claimed_by=auth.uid() then
  select role into member_role from public.broadcast_memberships where seller_id=invite.seller_id and user_id=auth.uid();
  if member_role is not null then return jsonb_build_object('seller_id',invite.seller_id,'role',member_role); end if;
 end if;
 if invite.claimed_by is not null or invite.expires_at<=clock_timestamp() or invite.seller_id=auth.uid() then
  raise exception '만료되었거나 사용된 참여 코드입니다.' using errcode='22023'; end if;
 if not exists(select 1 from public.seller_profiles s where s.user_id=invite.seller_id and s.status='approved') then
  raise exception '판매자 계정을 확인해주세요.' using errcode='42501'; end if;
 insert into public.broadcast_memberships(seller_id,user_id,role)
 values(invite.seller_id,auth.uid(),'assistant') on conflict(seller_id,user_id) do nothing;
 update public.broadcast_staff_invites set claimed_by=auth.uid(),claimed_at=clock_timestamp() where code=p_code;
 select role into member_role from public.broadcast_memberships where seller_id=invite.seller_id and user_id=auth.uid();
 insert into public.broadcast_audit(seller_id,actor_id,command,entity_id,after_value)
 values(invite.seller_id,auth.uid(),'staff.join',auth.uid(),jsonb_build_object('role',member_role));
 return jsonb_build_object('seller_id',invite.seller_id,'role',member_role);
end $$;
revoke all on function public.broadcast_staff_join(uuid) from public,anon;
grant execute on function public.broadcast_staff_join(uuid) to authenticated;
commit;
