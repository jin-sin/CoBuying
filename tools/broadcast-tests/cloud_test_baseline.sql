-- Disposable isolated Supabase test project only. The operating app already
-- owns seller_profiles; never apply this baseline to the operating database.
create table if not exists public.seller_profiles (
  user_id uuid primary key references auth.users(id),
  status text not null check (status in ('pending', 'approved', 'rejected'))
);
alter table public.seller_profiles enable row level security;
revoke all on public.seller_profiles from anon, authenticated;
