-- ============================================================
-- CoBuying (공동구매 마켓플레이스) DB 스키마
-- 셀러 입점형: 셀러가 상품을 등록하고, 플랫폼이 수수료를 가져간다.
-- Supabase 셀프호스팅 (시놀로지 NAS) 기준
-- Supabase Studio > SQL Editor 에서 실행하세요.
-- ============================================================

-- ------------------------------------------------------------
-- 1. 프로필 (auth.users 1:1)
--    role은 admin 여부만 관리. 셀러 여부는 seller_profiles로 판단.
-- ------------------------------------------------------------
create table if not exists public.profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  nickname   text,
  phone      text,
  role       text not null default 'customer' check (role in ('customer', 'admin')),
  created_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, nickname)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_admin()
returns boolean
language sql
security definer set search_path = public
stable
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  );
$$;

-- ------------------------------------------------------------
-- 2. 셀러 프로필 (신청 → 관리자 승인 → 상품 등록 가능)
--    정산 계좌와 수수료율 포함
-- ------------------------------------------------------------
create table if not exists public.seller_profiles (
  user_id         uuid primary key references auth.users (id) on delete cascade,
  shop_name       text not null,
  bank_name       text not null,           -- 정산 은행
  bank_account    text not null,           -- 정산 계좌번호
  account_holder  text not null,           -- 예금주
  contact_phone   text not null default '',
  commission_rate numeric(5,2) not null default 10.00
                    check (commission_rate >= 0 and commission_rate <= 100),
  status          text not null default 'pending'
                    check (status in ('pending', 'approved', 'rejected', 'suspended')),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create or replace function public.is_approved_seller()
returns boolean
language sql
security definer set search_path = public
stable
as $$
  select exists (
    select 1 from public.seller_profiles
    where user_id = auth.uid() and status = 'approved'
  );
$$;

-- 셀러 본인이 status/commission_rate를 바꾸지 못하도록 방지
create or replace function public.protect_seller_privileges()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if not public.is_admin() then
    if new.status is distinct from old.status
       or new.commission_rate is distinct from old.commission_rate then
      raise exception '승인 상태와 수수료율은 관리자만 변경할 수 있습니다.';
    end if;
  end if;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_protect_seller_privileges on public.seller_profiles;
create trigger trg_protect_seller_privileges
  before update on public.seller_profiles
  for each row execute function public.protect_seller_privileges();

-- ------------------------------------------------------------
-- 3. 상품 (셀러 소유, 판매 기한 포함)
-- ------------------------------------------------------------
create table if not exists public.products (
  id             uuid primary key default gen_random_uuid(),
  seller_id      uuid not null references auth.users (id) on delete restrict,
  shop_name      text not null default '',                    -- 등록 시점 스냅샷 (트리거로 자동 입력)
  title          text not null,
  description    text not null default '',
  price          integer not null check (price >= 0),          -- 공동구매가 (원)
  original_price integer check (original_price >= 0),          -- 정가 (할인표시용, 선택)
  stock          integer not null default 0 check (stock >= 0),
  image_urls     text[] not null default '{}',
  starts_at      timestamptz not null default now(),           -- 판매 시작
  ends_at        timestamptz not null,                         -- 판매 마감 (하루, 이틀 또는 그 이상)
  status         text not null default 'active' check (status in ('active', 'closed', 'hidden')),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create index if not exists idx_products_active on public.products (status, ends_at desc);
create index if not exists idx_products_seller on public.products (seller_id, created_at desc);

-- 상품 등록 시 상호명 스냅샷 자동 입력 (계좌번호 등 민감정보는 노출하지 않음)
create or replace function public.set_product_shop_name()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  new.shop_name := coalesce(
    (select shop_name from public.seller_profiles where user_id = new.seller_id),
    '운영자'
  );
  return new;
end;
$$;

drop trigger if exists trg_set_product_shop_name on public.products;
create trigger trg_set_product_shop_name
  before insert on public.products
  for each row execute function public.set_product_shop_name();

-- 현재 구매 가능한 상품만 보여주는 뷰 (기한 지난 상품 자동 제외)
create or replace view public.active_products
with (security_invoker = true) as
  select * from public.products
  where status = 'active'
    and starts_at <= now()
    and ends_at > now();

-- ------------------------------------------------------------
-- 4. 장바구니
-- ------------------------------------------------------------
create table if not exists public.cart_items (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  product_id uuid not null references public.products (id) on delete cascade,
  quantity   integer not null default 1 check (quantity > 0),
  created_at timestamptz not null default now(),
  unique (user_id, product_id)
);

-- ------------------------------------------------------------
-- 5. 주문
-- ------------------------------------------------------------
create table if not exists public.orders (
  id              uuid primary key default gen_random_uuid(),
  order_number    text not null unique,
  user_id         uuid not null references auth.users (id) on delete restrict,
  status          text not null default 'pending_payment' check (status in
                    ('pending_payment', 'paid', 'preparing', 'shipped', 'delivered', 'cancelled')),
  payment_method  text not null check (payment_method in ('card', 'bank_transfer')),
  total_amount    integer not null check (total_amount >= 0),
  depositor_name  text,                    -- 무통장입금 시 입금자명
  receiver_name   text not null,
  receiver_phone  text not null,
  postcode        text not null default '',
  address1        text not null,
  address2        text not null default '',
  memo            text not null default '',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists idx_orders_user on public.orders (user_id, created_at desc);

-- 주문 아이템: 셀러/수수료를 주문 시점 스냅샷으로 저장 (정산 근거)
create table if not exists public.order_items (
  id              uuid primary key default gen_random_uuid(),
  order_id        uuid not null references public.orders (id) on delete cascade,
  product_id      uuid references public.products (id) on delete set null,
  seller_id       uuid not null references auth.users (id) on delete restrict,
  product_title   text not null,
  unit_price      integer not null,
  quantity        integer not null check (quantity > 0),
  commission_rate numeric(5,2) not null default 0,   -- 주문 시점 수수료율
  fee_amount      integer not null default 0          -- 플랫폼 수수료 (원)
);

create index if not exists idx_order_items_order on public.order_items (order_id);
create index if not exists idx_order_items_seller on public.order_items (seller_id);

-- 셀러가 자기 상품이 포함된 주문을 볼 수 있는지 (RLS 재귀 방지용 security definer)
create or replace function public.is_seller_of_order(p_order_id uuid)
returns boolean
language sql
security definer set search_path = public
stable
as $$
  select exists (
    select 1 from public.order_items
    where order_id = p_order_id and seller_id = auth.uid()
  );
$$;

-- ------------------------------------------------------------
-- 6. 주문 생성 RPC
--    재고/기한 검증 + 재고 차감 + 수수료 스냅샷 + 장바구니 정리 (한 트랜잭션)
--    items: [{"product_id": "...", "quantity": 2}, ...]
-- ------------------------------------------------------------
create or replace function public.create_order(
  p_payment_method text,
  p_receiver_name  text,
  p_receiver_phone text,
  p_postcode       text,
  p_address1       text,
  p_address2       text,
  p_memo           text,
  p_depositor_name text,
  p_items          jsonb
)
returns uuid
language plpgsql
security definer set search_path = public
as $$
declare
  v_user_id  uuid := auth.uid();
  v_order_id uuid;
  v_total    integer := 0;
  v_item     jsonb;
  v_product  public.products%rowtype;
  v_qty      integer;
  v_rate     numeric(5,2);
  v_fee      integer;
begin
  if v_user_id is null then
    raise exception '로그인이 필요합니다.';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception '주문 상품이 없습니다.';
  end if;

  insert into public.orders
    (order_number, user_id, payment_method, total_amount, depositor_name,
     receiver_name, receiver_phone, postcode, address1, address2, memo)
  values
    ('CB' || to_char(now(), 'YYMMDD') || '-' || upper(substr(gen_random_uuid()::text, 1, 6)),
     v_user_id, p_payment_method, 0, p_depositor_name,
     p_receiver_name, p_receiver_phone, p_postcode, p_address1, p_address2, coalesce(p_memo, ''))
  returning id into v_order_id;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_qty := (v_item ->> 'quantity')::integer;

    -- 행 잠금으로 동시 주문 시 재고 초과 방지
    select * into v_product
    from public.products
    where id = (v_item ->> 'product_id')::uuid
    for update;

    if not found then
      raise exception '존재하지 않는 상품입니다.';
    end if;
    if v_product.status <> 'active' or v_product.ends_at <= now() then
      raise exception '판매가 마감된 상품입니다: %', v_product.title;
    end if;
    if v_product.stock < v_qty then
      raise exception '재고가 부족합니다: % (남은 수량 %)', v_product.title, v_product.stock;
    end if;

    update public.products set stock = stock - v_qty, updated_at = now()
    where id = v_product.id;

    -- 주문 시점 수수료율 스냅샷 (관리자 직접 등록 상품은 수수료 0)
    v_rate := coalesce(
      (select commission_rate from public.seller_profiles
       where user_id = v_product.seller_id and status = 'approved'),
      0
    );
    v_fee := round(v_product.price * v_qty * v_rate / 100.0);

    insert into public.order_items
      (order_id, product_id, seller_id, product_title, unit_price, quantity,
       commission_rate, fee_amount)
    values
      (v_order_id, v_product.id, v_product.seller_id, v_product.title,
       v_product.price, v_qty, v_rate, v_fee);

    v_total := v_total + v_product.price * v_qty;
  end loop;

  update public.orders set total_amount = v_total where id = v_order_id;

  delete from public.cart_items
  where user_id = v_user_id
    and product_id in (select (i ->> 'product_id')::uuid from jsonb_array_elements(p_items) i);

  return v_order_id;
end;
$$;

-- ------------------------------------------------------------
-- 7. 셀러 정산 집계 뷰
--    security_invoker: 셀러는 RLS에 의해 자기 판매분만 보인다.
-- ------------------------------------------------------------
create or replace view public.seller_settlements
with (security_invoker = true) as
  select oi.seller_id,
         count(distinct o.id)                                as order_count,
         sum(oi.unit_price * oi.quantity)::bigint            as gross_sales,   -- 총 판매액
         sum(oi.fee_amount)::bigint                          as total_fees,    -- 플랫폼 수수료
         sum(oi.unit_price * oi.quantity - oi.fee_amount)::bigint as net_payout -- 셀러 지급액
  from public.order_items oi
  join public.orders o on o.id = oi.order_id
  where o.status in ('paid', 'preparing', 'shipped', 'delivered')
  group by oi.seller_id;

-- ------------------------------------------------------------
-- 8. RLS (Row Level Security)
-- ------------------------------------------------------------
alter table public.profiles        enable row level security;
alter table public.seller_profiles enable row level security;
alter table public.products        enable row level security;
alter table public.cart_items      enable row level security;
alter table public.orders          enable row level security;
alter table public.order_items     enable row level security;

-- profiles
drop policy if exists "profiles_select" on public.profiles;
create policy "profiles_select" on public.profiles
  for select using (id = auth.uid() or public.is_admin());
drop policy if exists "profiles_update" on public.profiles;
create policy "profiles_update" on public.profiles
  for update using (id = auth.uid() or public.is_admin())
  with check ((id = auth.uid() and role = 'customer') or public.is_admin());

-- seller_profiles: 본인 신청/조회/수정 (status·수수료율 변경은 트리거가 차단), 관리자 전체
drop policy if exists "seller_profiles_select" on public.seller_profiles;
create policy "seller_profiles_select" on public.seller_profiles
  for select using (user_id = auth.uid() or public.is_admin());
drop policy if exists "seller_profiles_insert" on public.seller_profiles;
create policy "seller_profiles_insert" on public.seller_profiles
  for insert with check (user_id = auth.uid() and status = 'pending');
drop policy if exists "seller_profiles_update" on public.seller_profiles;
create policy "seller_profiles_update" on public.seller_profiles
  for update using (user_id = auth.uid() or public.is_admin());

-- products: 조회는 누구나(숨김 제외), 쓰기는 승인된 셀러(자기 상품만) 또는 관리자
drop policy if exists "products_select" on public.products;
create policy "products_select" on public.products
  for select using (status <> 'hidden' or seller_id = auth.uid() or public.is_admin());
drop policy if exists "products_write" on public.products;
drop policy if exists "products_insert" on public.products;
create policy "products_insert" on public.products
  for insert with check (
    (public.is_approved_seller() and seller_id = auth.uid()) or public.is_admin()
  );
drop policy if exists "products_update" on public.products;
create policy "products_update" on public.products
  for update using (seller_id = auth.uid() or public.is_admin())
  with check (seller_id = auth.uid() or public.is_admin());
drop policy if exists "products_delete" on public.products;
create policy "products_delete" on public.products
  for delete using (seller_id = auth.uid() or public.is_admin());

-- cart_items: 본인 것만
drop policy if exists "cart_owner" on public.cart_items;
create policy "cart_owner" on public.cart_items
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- orders: 구매자 본인 + 자기 상품이 포함된 셀러 + 관리자 (생성은 create_order RPC로만)
drop policy if exists "orders_select" on public.orders;
create policy "orders_select" on public.orders
  for select using (
    user_id = auth.uid()
    or public.is_admin()
    or public.is_seller_of_order(id)
  );
drop policy if exists "orders_admin_update" on public.orders;
create policy "orders_admin_update" on public.orders
  for update using (public.is_admin());

-- order_items: 구매자 본인 주문 + 셀러 자기 판매분 + 관리자
drop policy if exists "order_items_select" on public.order_items;
create policy "order_items_select" on public.order_items
  for select using (
    seller_id = auth.uid()
    or exists (select 1 from public.orders o where o.id = order_id and o.user_id = auth.uid())
    or public.is_admin()
  );

-- ------------------------------------------------------------
-- 9. 스토리지 버킷 (상품 이미지): 읽기 공개, 쓰기는 승인 셀러/관리자
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('product-images', 'product-images', true)
on conflict (id) do nothing;

drop policy if exists "product_images_read" on storage.objects;
create policy "product_images_read" on storage.objects
  for select using (bucket_id = 'product-images');
drop policy if exists "product_images_admin_write" on storage.objects;
drop policy if exists "product_images_write" on storage.objects;
create policy "product_images_write" on storage.objects
  for all using (
    bucket_id = 'product-images' and (public.is_approved_seller() or public.is_admin())
  )
  with check (
    bucket_id = 'product-images' and (public.is_approved_seller() or public.is_admin())
  );

-- ------------------------------------------------------------
-- 10. 판매 기한 만료 자동 처리 (pg_cron, 5분마다)
-- ------------------------------------------------------------
create extension if not exists pg_cron;

select cron.schedule(
  'close-expired-products',
  '*/5 * * * *',
  $$ update public.products set status = 'closed', updated_at = now()
     where status = 'active' and ends_at <= now() $$
);

-- ------------------------------------------------------------
-- 11. 최초 관리자 지정 (본인 계정으로 가입 후 이메일을 바꿔 실행)
-- ------------------------------------------------------------
-- update public.profiles set role = 'admin'
-- where id = (select id from auth.users where email = 's.conast@gmail.com');

-- ------------------------------------------------------------
-- 12. 셀러 지급(정산 이체) 기록 — 잔액 차감용
-- ------------------------------------------------------------
create table if not exists public.seller_payouts (
  id         uuid primary key default gen_random_uuid(),
  seller_id  uuid not null references auth.users (id) on delete restrict,
  amount     integer not null check (amount > 0),
  memo       text not null default '',
  paid_at    timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index if not exists idx_seller_payouts_seller
  on public.seller_payouts (seller_id, paid_at desc);

alter table public.seller_payouts enable row level security;

drop policy if exists "payouts_select" on public.seller_payouts;
create policy "payouts_select" on public.seller_payouts
  for select using (seller_id = auth.uid() or public.is_admin());
drop policy if exists "payouts_admin_write" on public.seller_payouts;
create policy "payouts_admin_write" on public.seller_payouts
  for all using (public.is_admin()) with check (public.is_admin());

-- 정산 잔액 뷰: 누적 정산액(seller_settlements) - 지급 합계 = 미지급 잔액
create or replace view public.seller_balances
with (security_invoker = true) as
  select s.seller_id,
         s.order_count,
         s.gross_sales,
         s.total_fees,
         s.net_payout,
         coalesce(p.total_paid, 0)::bigint          as total_paid,
         (s.net_payout - coalesce(p.total_paid, 0))::bigint as balance
  from public.seller_settlements s
  left join (
    select seller_id, sum(amount) as total_paid
    from public.seller_payouts
    group by seller_id
  ) p on p.seller_id = s.seller_id;

-- ------------------------------------------------------------
-- 13. 주문 취소 — 재고 복원 + 구매자 취소 RPC + 미입금 자동 만료
-- ------------------------------------------------------------
-- 취소로 전환될 때 재고 복원. 구매자 취소·관리자 취소·자동 만료가 모두
-- 이 트리거 하나로 처리된다. 배송 시작 전 상태에서의 취소만 재고를 되돌린다.
create or replace function public.restore_stock_on_cancel()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  update public.products p
  set stock = p.stock + oi.qty, updated_at = now()
  from (
    select product_id, sum(quantity) as qty
    from public.order_items
    where order_id = new.id and product_id is not null
    group by product_id
  ) oi
  where p.id = oi.product_id;
  return new;
end;
$$;

drop trigger if exists trg_restore_stock_on_cancel on public.orders;
create trigger trg_restore_stock_on_cancel
  after update of status on public.orders
  for each row
  when (old.status in ('pending_payment', 'paid', 'preparing')
        and new.status = 'cancelled')
  execute function public.restore_stock_on_cancel();

-- 구매자 본인 주문 취소 (입금 대기 상태만 가능)
create or replace function public.cancel_my_order(p_order_id uuid)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  v_order public.orders%rowtype;
begin
  if auth.uid() is null then
    raise exception '로그인이 필요합니다.';
  end if;

  select * into v_order
  from public.orders
  where id = p_order_id and user_id = auth.uid()
  for update;

  if not found then
    raise exception '주문을 찾을 수 없습니다.';
  end if;
  if v_order.status <> 'pending_payment' then
    raise exception '입금 대기 상태의 주문만 취소할 수 있습니다.';
  end if;

  update public.orders
  set status = 'cancelled', updated_at = now()
  where id = p_order_id;
end;
$$;

-- 24시간 내 미입금 주문 자동 취소 (재고 복원은 위 트리거가 처리)
select cron.schedule(
  'expire-unpaid-orders',
  '*/10 * * * *',
  $$ update public.orders set status = 'cancelled', updated_at = now()
     where status = 'pending_payment'
       and payment_method = 'bank_transfer'
       and created_at < now() - interval '24 hours' $$
);
