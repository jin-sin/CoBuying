-- Create the private bucket in the Supabase Storage Dashboard first.
-- Required bucket: broadcast-receiver-qr; max 2097152 bytes; MIME: image/png, image/jpeg.
-- Storage metadata is read-only here; this file installs only the RLS policy.
do $$ begin
 if not exists(select 1 from storage.buckets where id='broadcast-receiver-qr'
  and public=false and file_size_limit>0 and file_size_limit<=2097152
  and allowed_mime_types @> array['image/png','image/jpeg']::text[]) then
  raise exception 'Create private bucket broadcast-receiver-qr with the documented limits before applying this policy';
 end if;
end $$;

create or replace function public.broadcast_can_upload_receiver_qr(p_object_key text)
returns boolean language plpgsql stable security definer set search_path='' as $$
begin
 if p_object_key !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.(png|jpg)$' then return false; end if;
 return public.broadcast_permission(split_part(p_object_key,'/',1)::uuid)='manager';
exception when invalid_text_representation then return false;
end $$;
revoke all on function public.broadcast_can_upload_receiver_qr(text) from public,anon,service_role;
grant execute on function public.broadcast_can_upload_receiver_qr(text) to authenticated;
drop policy if exists broadcast_receiver_qr_insert on storage.objects;
create policy broadcast_receiver_qr_insert on storage.objects for insert to authenticated
 with check(bucket_id='broadcast-receiver-qr' and public.broadcast_can_upload_receiver_qr(name));
