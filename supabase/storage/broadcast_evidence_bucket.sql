-- Create the private bucket in the Supabase Storage Dashboard first.
-- Required bucket: broadcast-evidence; max 5242880 bytes; MIME: image/jpeg, image/png, image/webp.
-- Storage metadata is read-only here; this file installs only the RLS policy.
do $$ begin
 if not exists(select 1 from storage.buckets where id='broadcast-evidence'
  and public=false and file_size_limit>0 and file_size_limit<=5242880
  and allowed_mime_types @> array['image/jpeg','image/png','image/webp']::text[]) then
  raise exception 'Create private bucket broadcast-evidence with the documented limits before applying this policy';
 end if;
end $$;

create or replace function public.broadcast_can_read_evidence(p_object_key text)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.broadcast_evidence e
  where e.object_key=p_object_key and public.broadcast_permission(e.seller_id)='manager');
$$;
revoke all on function public.broadcast_can_read_evidence(text) from public,anon,service_role;
grant execute on function public.broadcast_can_read_evidence(text) to authenticated;
drop policy if exists broadcast_staff_evidence_read on storage.objects;
create policy broadcast_staff_evidence_read on storage.objects for select to authenticated
 using(bucket_id='broadcast-evidence' and public.broadcast_can_read_evidence(name));
