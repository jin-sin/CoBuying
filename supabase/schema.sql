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
  -- 정산 계좌는 신청 단계에서 받지 않는다. 아직 팔지도 않았는데 계좌부터 내라고 하면
  -- 입점 문턱이 크게 올라간다. 승인 후 셀러센터에서 등록하고, 미등록이면 배너로 알린다.
  bank_name       text not null default '',  -- 정산 은행
  bank_account    text not null default '',  -- 정산 계좌번호
  account_holder  text not null default '',  -- 예금주
  contact_phone   text not null default '',
  commission_rate numeric(5,2) not null default 10.00
                    check (commission_rate >= 0 and commission_rate <= 100),
  status          text not null default 'pending'
                    check (status in ('pending', 'approved', 'rejected', 'suspended')),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- 이미 만들어진 테이블에도 기본값을 적용 (create table if not exists는 기존 테이블을 안 고친다)
alter table public.seller_profiles alter column bank_name     set default '';
alter table public.seller_profiles alter column bank_account   set default '';
alter table public.seller_profiles alter column account_holder set default '';

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
  '1-59/5 * * * *',
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
  '2-59/10 * * * *',
  $$ update public.orders set status = 'cancelled', updated_at = now()
     where status = 'pending_payment'
       and payment_method = 'bank_transfer'
       and created_at < now() - interval '24 hours' $$
);

-- ------------------------------------------------------------
-- 14. 배송 상태 — 셀러가 자기 주문 아이템 단위로 관리
--     한 주문에 여러 셀러 상품이 섞일 수 있으므로 배송 상태는
--     아이템 단위이고, 주문 전체 상태는 가장 느린 단계로 자동 계산.
--     역할: 관리자 = 입금 확인·취소 / 셀러 = 배송 단계 진행
-- ------------------------------------------------------------
alter table public.order_items
  add column if not exists status text not null default 'preparing'
    check (status in ('preparing', 'shipped', 'delivered'));

create or replace function public.update_item_status(p_item_id uuid, p_status text)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  v_item  public.order_items%rowtype;
  v_order public.orders%rowtype;
  v_stage integer;
begin
  if p_status not in ('preparing', 'shipped', 'delivered') then
    raise exception '허용되지 않는 배송 상태입니다: %', p_status;
  end if;

  select * into v_item from public.order_items where id = p_item_id;
  if not found or (v_item.seller_id <> auth.uid() and not public.is_admin()) then
    raise exception '본인 판매 상품만 변경할 수 있습니다.';
  end if;

  -- 주문 행 잠금: 여러 셀러가 동시에 변경해도 재계산이 꼬이지 않게
  select * into v_order from public.orders where id = v_item.order_id for update;
  if v_order.status in ('pending_payment', 'cancelled') then
    raise exception '결제 완료된 주문만 배송 상태를 변경할 수 있습니다.';
  end if;

  update public.order_items set status = p_status where id = p_item_id;

  -- 주문 상태 = 아이템들 중 가장 느린 배송 단계
  select min(case status when 'preparing' then 1 when 'shipped' then 2 else 3 end)
    into v_stage
  from public.order_items
  where order_id = v_item.order_id;

  update public.orders
  set status = case v_stage when 1 then 'preparing'
                            when 2 then 'shipped'
                            else 'delivered' end,
      updated_at = now()
  where id = v_item.order_id;
end;
$$;

-- ------------------------------------------------------------
-- 15. 카드결제 (토스페이먼츠) — 승인은 서버(DB)에서 처리
--     클라이언트가 결제창 성공 리다이렉트로 받은 paymentKey를
--     confirm_card_payment RPC로 전달하면, DB가 http 확장으로
--     토스 승인 API를 호출해 금액 검증 후 주문을 paid로 바꾼다.
--     시크릿 키는 private 스키마에 저장 (PostgREST 비노출).
-- ------------------------------------------------------------
create extension if not exists http with schema extensions;

create schema if not exists private;

create table if not exists private.app_secrets (
  key   text primary key,
  value text not null
);

-- 토스페이먼츠 시크릿 키. 아래는 공개 문서용 테스트 키 —
-- 운영 전환 시 개발자센터 라이브 키로 update 할 것.
insert into private.app_secrets (key, value)
values ('toss_secret_key', 'test_sk_zXLkKEypNArWmo50nX3lmeaxYG5R')
on conflict (key) do nothing;

-- 결제 승인 기록
create table if not exists public.payments (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null unique references public.orders (id) on delete restrict,
  payment_key text not null unique,
  amount      integer not null,
  method      text not null default '',
  status      text not null default '',
  approved_at timestamptz,
  receipt_url text,
  raw         jsonb,
  created_at  timestamptz not null default now()
);

alter table public.payments enable row level security;

drop policy if exists "payments_select" on public.payments;
create policy "payments_select" on public.payments
  for select using (
    public.is_admin() or exists (
      select 1 from public.orders o
      where o.id = order_id and o.user_id = auth.uid()
    )
  );
-- insert/update 정책 없음 — confirm_card_payment RPC(security definer)만 기록

create or replace function public.confirm_card_payment(
  p_order_number text,
  p_payment_key  text,
  p_amount       integer
)
returns uuid
language plpgsql
security definer set search_path = public, extensions
as $fn$
declare
  v_order  public.orders%rowtype;
  v_secret text;
  v_cred   text;
  v_resp   http_response;
  v_json   jsonb;
begin
  if auth.uid() is null then
    raise exception '로그인이 필요합니다.';
  end if;

  select * into v_order
  from public.orders
  where order_number = p_order_number and user_id = auth.uid()
  for update;

  if not found then
    raise exception '주문을 찾을 수 없습니다.';
  end if;
  if v_order.payment_method <> 'card' then
    raise exception '카드결제 주문이 아닙니다.';
  end if;

  -- 성공 페이지 새로고침 등 중복 진입: 이미 같은 결제로 승인됐으면 성공 처리
  if v_order.status <> 'pending_payment' then
    if exists (select 1 from public.payments
               where order_id = v_order.id and payment_key = p_payment_key) then
      return v_order.id;
    end if;
    raise exception '결제 대기 상태의 주문이 아닙니다. (현재: %)', v_order.status;
  end if;

  -- 서버 저장 금액과 대조 — 클라이언트/리다이렉트 파라미터는 신뢰하지 않는다
  if v_order.total_amount <> p_amount then
    raise exception '결제 금액이 주문 금액과 다릅니다.';
  end if;

  select value into v_secret from private.app_secrets where key = 'toss_secret_key';
  if v_secret is null then
    raise exception '결제 설정이 없습니다. 관리자에게 문의하세요.';
  end if;
  v_cred := replace(encode(convert_to(v_secret || ':', 'utf8'), 'base64'), E'\n', '');

  perform http_set_curlopt('CURLOPT_TIMEOUT', '10');

  v_resp := http((
    'POST',
    'https://api.tosspayments.com/v1/payments/confirm',
    array[http_header('Authorization', 'Basic ' || v_cred)],
    'application/json',
    jsonb_build_object(
      'paymentKey', p_payment_key,
      'orderId',    p_order_number,
      'amount',     p_amount
    )::text
  )::http_request);

  v_json := v_resp.content::jsonb;

  -- 승인은 됐지만 DB 반영 전에 끊긴 재시도: 조회 API로 검증 후 통과
  if v_resp.status <> 200 and v_json ->> 'code' = 'ALREADY_PROCESSED_PAYMENT' then
    v_resp := http((
      'GET',
      'https://api.tosspayments.com/v1/payments/' || p_payment_key,
      array[http_header('Authorization', 'Basic ' || v_cred)],
      null, null
    )::http_request);
    v_json := v_resp.content::jsonb;
    if v_resp.status <> 200 or v_json ->> 'status' <> 'DONE'
       or v_json ->> 'orderId' <> p_order_number
       or (v_json ->> 'totalAmount')::integer <> p_amount then
      raise exception '결제 승인에 실패했습니다: %',
        coalesce(v_json ->> 'message', '알 수 없는 오류');
    end if;
  elsif v_resp.status <> 200 then
    raise exception '결제 승인에 실패했습니다: %',
      coalesce(v_json ->> 'message', 'HTTP ' || v_resp.status::text);
  end if;

  insert into public.payments
    (order_id, payment_key, amount, method, status, approved_at, receipt_url, raw)
  values
    (v_order.id, p_payment_key, p_amount,
     coalesce(v_json ->> 'method', ''),
     coalesce(v_json ->> 'status', ''),
     nullif(v_json ->> 'approvedAt', '')::timestamptz,
     v_json -> 'receipt' ->> 'url',
     v_json);

  update public.orders
  set status = 'paid', updated_at = now()
  where id = v_order.id;

  return v_order.id;
end;
$fn$;

-- 결제창까지 갔다가 이탈한 카드 주문은 1시간 후 자동 취소 (재고 복원은 취소 트리거)
select cron.schedule(
  'expire-unpaid-card-orders',
  '4-59/10 * * * *',
  $$ update public.orders set status = 'cancelled', updated_at = now()
     where status = 'pending_payment'
       and payment_method = 'card'
       and created_at < now() - interval '1 hour' $$
);

-- ------------------------------------------------------------
-- 16. 상품 옵션 (사이즈·색상·분쇄도 등)
--     옵션 정의는 products.options (jsonb):
--       [{"name":"사이즈","choices":[{"name":"S","extra":0},{"name":"L","extra":1000}]}]
--     재고는 상품 전체 단위 그대로. 구매자는 그룹마다 하나를 선택하고
--     선택 결과는 {"사이즈":"L"} 형태로 장바구니/주문 아이템에 저장된다.
--     추가금(extra)은 create_order가 서버에서 재계산한다.
-- ------------------------------------------------------------
alter table public.products
  add column if not exists options jsonb not null default '[]'::jsonb;

-- select * 뷰라 컬럼 추가 반영을 위해 재생성
create or replace view public.active_products
with (security_invoker = true) as
  select * from public.products
  where status = 'active'
    and starts_at <= now()
    and ends_at > now();

-- 같은 상품이라도 옵션 조합이 다르면 별도 장바구니 줄
alter table public.cart_items
  add column if not exists selected_options jsonb not null default '{}'::jsonb;
alter table public.cart_items
  drop constraint if exists cart_items_user_id_product_id_key;
create unique index if not exists idx_cart_items_unique
  on public.cart_items (user_id, product_id, selected_options);

-- 주문 아이템에 선택 옵션 스냅샷 (unit_price에는 추가금이 합산돼 있음)
alter table public.order_items
  add column if not exists selected_options jsonb not null default '{}'::jsonb;

-- create_order 갱신: 옵션 검증 + 추가금 합산 단가 + 선택 스냅샷 저장
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
  v_sel      jsonb;
  v_group    jsonb;
  v_choice   jsonb;
  v_unit     integer;
  v_snap     jsonb;
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

    -- 옵션 검증: 상품에 정의된 그룹마다 유효한 선택이 있어야 하고,
    -- 추가금은 클라이언트를 믿지 않고 여기서 합산한다.
    v_sel  := coalesce(v_item -> 'options', '{}'::jsonb);
    v_unit := v_product.price;
    v_snap := '{}'::jsonb;
    for v_group in select * from jsonb_array_elements(coalesce(v_product.options, '[]'::jsonb))
    loop
      v_choice := null;
      select c into v_choice
      from jsonb_array_elements(v_group -> 'choices') c
      where c ->> 'name' = v_sel ->> (v_group ->> 'name')
      limit 1;
      if v_choice is null then
        raise exception '옵션을 선택해 주세요: % (%)', v_group ->> 'name', v_product.title;
      end if;
      v_unit := v_unit + coalesce((v_choice ->> 'extra')::integer, 0);
      v_snap := v_snap || jsonb_build_object(v_group ->> 'name', v_choice ->> 'name');
    end loop;

    update public.products set stock = stock - v_qty, updated_at = now()
    where id = v_product.id;

    -- 주문 시점 수수료율 스냅샷 (관리자 직접 등록 상품은 수수료 0)
    v_rate := coalesce(
      (select commission_rate from public.seller_profiles
       where user_id = v_product.seller_id and status = 'approved'),
      0
    );
    v_fee := round(v_unit * v_qty * v_rate / 100.0);

    insert into public.order_items
      (order_id, product_id, seller_id, product_title, unit_price, quantity,
       commission_rate, fee_amount, selected_options)
    values
      (v_order_id, v_product.id, v_product.seller_id, v_product.title,
       v_unit, v_qty, v_rate, v_fee, v_snap);

    v_total := v_total + v_unit * v_qty;
  end loop;

  update public.orders set total_amount = v_total where id = v_order_id;

  delete from public.cart_items
  where user_id = v_user_id
    and product_id in (select (i ->> 'product_id')::uuid from jsonb_array_elements(p_items) i);

  return v_order_id;
end;
$$;

-- ------------------------------------------------------------
-- 17. 셀러 사업자 정보
--     입점 신청 시 사업자등록번호(필수)와 통신판매업 신고번호(선택)를 받는다.
--     형식 검증(10자리 체크섬)은 클라이언트에서 수행.
-- ------------------------------------------------------------
alter table public.seller_profiles
  add column if not exists business_number text not null default '',       -- 사업자등록번호 (숫자 10자리)
  add column if not exists online_sales_number text not null default '';   -- 통신판매업 신고번호 (선택)

-- ------------------------------------------------------------
-- 18. 상품 카테고리
--     카테고리 목록은 앱(lib/features/products/categories.dart)에서 관리.
-- ------------------------------------------------------------
alter table public.products
  add column if not exists category text not null default '기타';

create index if not exists idx_products_category on public.products (category);

-- select * 뷰라 컬럼 추가 반영을 위해 재생성
create or replace view public.active_products
with (security_invoker = true) as
  select * from public.products
  where status = 'active'
    and starts_at <= now()
    and ends_at > now();

-- ------------------------------------------------------------
-- 19. 인앱 알림
--     주문 상태 변경 트리거가 구매자/셀러 알림을 자동 생성한다.
--     클라이언트는 Realtime 스트림으로 구독 (배지 실시간 갱신).
-- ------------------------------------------------------------
create table if not exists public.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  title      text not null,
  body       text not null default '',
  link       text not null default '',   -- 탭하면 이동할 앱 라우트
  read_at    timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists idx_notifications_user
  on public.notifications (user_id, created_at desc);

alter table public.notifications enable row level security;

drop policy if exists "notifications_select" on public.notifications;
create policy "notifications_select" on public.notifications
  for select using (user_id = auth.uid());
drop policy if exists "notifications_update" on public.notifications;
create policy "notifications_update" on public.notifications
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());
-- insert 정책 없음 — 트리거(security definer)만 생성

-- Realtime 발행 대상에 추가 (이미 있으면 무시)
do $$
begin
  alter publication supabase_realtime add table public.notifications;
exception when duplicate_object then null;
end $$;

create or replace function public.notify_order_events()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  v_seller record;
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  if new.status = 'paid' then
    insert into public.notifications (user_id, title, body, link) values
      (new.user_id, '결제가 확인되었습니다',
       '주문 ' || new.order_number || ' 결제가 확인되었습니다. 판매자가 곧 배송을 준비합니다.',
       '/orders/' || new.id);
    for v_seller in
      select distinct seller_id from public.order_items where order_id = new.id
    loop
      insert into public.notifications (user_id, title, body, link) values
        (v_seller.seller_id, '새 주문이 들어왔습니다',
         '주문 ' || new.order_number || ' 결제가 완료되었습니다. 배송 목록을 확인해 주세요.',
         '/seller');
    end loop;

  elsif new.status = 'shipped' then
    insert into public.notifications (user_id, title, body, link) values
      (new.user_id, '상품이 발송되었습니다',
       '주문 ' || new.order_number || ' 상품이 모두 발송되었습니다.',
       '/orders/' || new.id);

  elsif new.status = 'delivered' then
    insert into public.notifications (user_id, title, body, link) values
      (new.user_id, '배송이 완료되었습니다',
       '주문 ' || new.order_number || ' 배송이 완료되었습니다.',
       '/orders/' || new.id);

  elsif new.status = 'cancelled' then
    insert into public.notifications (user_id, title, body, link) values
      (new.user_id, '주문이 취소되었습니다',
       case when old.status = 'pending_payment'
            then '주문 ' || new.order_number || '이(가) 취소되었습니다. 미입금 주문은 기한이 지나면 자동 취소됩니다.'
            else '주문 ' || new.order_number || '이(가) 취소되었습니다.' end
       -- 카드 환불이 실행된 취소면 환불 안내 덧붙임 (26절)
       || case when exists (select 1 from public.payments
                            where order_id = new.id and cancelled_at is not null)
               then ' 결제 금액은 카드사 절차에 따라 3~5영업일 내 환불됩니다.'
               else '' end,
       '/orders/' || new.id);
    -- 결제 이후 취소는 셀러에게도 알림
    if old.status <> 'pending_payment' then
      for v_seller in
        select distinct seller_id from public.order_items where order_id = new.id
      loop
        insert into public.notifications (user_id, title, body, link) values
          (v_seller.seller_id, '주문이 취소되었습니다',
           '주문 ' || new.order_number || '이(가) 취소되었습니다. 판매 내역을 확인해 주세요.',
           '/seller');
      end loop;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_notify_order_events on public.orders;
create trigger trg_notify_order_events
  after update of status on public.orders
  for each row execute function public.notify_order_events();

-- ------------------------------------------------------------
-- 20. 앱 설정 (점검 시간 안내 등)
--     서버(NAS)가 전원 스케줄로 꺼지는 시간대에 앱이 "break time" 안내를
--     띄우기 위한 키-값 설정. 클라이언트는 값을 캐시해 두고 서버가 꺼진
--     동안에도 마지막 설정으로 판단한다.
-- ------------------------------------------------------------
create table if not exists public.app_settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.app_settings enable row level security;

drop policy if exists "app_settings_select" on public.app_settings;
create policy "app_settings_select" on public.app_settings
  for select using (true);   -- 점검 안내는 로그인 전에도 보여야 함
drop policy if exists "app_settings_admin_write" on public.app_settings;
create policy "app_settings_admin_write" on public.app_settings
  for all using (public.is_admin()) with check (public.is_admin());

insert into public.app_settings (key, value) values
  ('maintenance',
   '{"enabled": true, "start": "02:00", "end": "08:00",
     "message": "break time ~ 지금은 서버 점검 시간이에요.\n아침에 다시 만나요!"}'::jsonb)
on conflict (key) do nothing;

-- ------------------------------------------------------------
-- 21. 상품 리뷰
--     배송 완료된 주문 아이템당 1건 (재구매하면 또 쓸 수 있음).
--     profiles는 본인만 조회 가능하므로 닉네임은 작성 시점에
--     마스킹된 스냅샷으로 저장한다 (예: "김**").
-- ------------------------------------------------------------
create table if not exists public.product_reviews (
  id            uuid primary key default gen_random_uuid(),
  product_id    uuid not null references public.products (id) on delete cascade,
  order_item_id uuid not null unique references public.order_items (id) on delete cascade,
  user_id       uuid not null references auth.users (id) on delete cascade,
  nickname      text not null default '',
  rating        integer not null check (rating between 1 and 5),
  content       text not null default '',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists idx_product_reviews_product
  on public.product_reviews (product_id, created_at desc);
create index if not exists idx_product_reviews_user
  on public.product_reviews (user_id, created_at desc);

-- 작성 시점 닉네임 스냅샷 (마스킹)
create or replace function public.set_review_nickname()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  v_nick text;
begin
  select nickname into v_nick from public.profiles where id = new.user_id;
  v_nick := coalesce(nullif(trim(v_nick), ''), '구매자');
  new.nickname := left(v_nick, 1) || repeat('*', least(greatest(char_length(v_nick) - 1, 1), 2));
  return new;
end;
$$;

drop trigger if exists trg_set_review_nickname on public.product_reviews;
create trigger trg_set_review_nickname
  before insert on public.product_reviews
  for each row execute function public.set_review_nickname();

-- 수정 시 대상 상품/주문 아이템/작성자·닉네임은 바꿀 수 없다 (평점·내용만 수정)
create or replace function public.protect_review_immutables()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if new.product_id    is distinct from old.product_id
     or new.order_item_id is distinct from old.order_item_id
     or new.user_id    is distinct from old.user_id
     or new.nickname   is distinct from old.nickname
     or new.created_at is distinct from old.created_at then
    raise exception '리뷰의 평점과 내용만 수정할 수 있습니다.';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_protect_review_immutables on public.product_reviews;
create trigger trg_protect_review_immutables
  before update on public.product_reviews
  for each row execute function public.protect_review_immutables();

alter table public.product_reviews enable row level security;

-- 조회는 누구나 (상품 상세는 로그인 전에도 보임)
drop policy if exists "reviews_select" on public.product_reviews;
create policy "reviews_select" on public.product_reviews
  for select using (true);

-- 작성: 본인 주문의 배송 완료된 아이템, 그 아이템의 상품에 대해서만
drop policy if exists "reviews_insert" on public.product_reviews;
create policy "reviews_insert" on public.product_reviews
  for insert with check (
    user_id = auth.uid()
    and exists (
      select 1
      from public.order_items oi
      join public.orders o on o.id = oi.order_id
      where oi.id = order_item_id
        and o.user_id = auth.uid()
        and oi.product_id = product_reviews.product_id
        and oi.status = 'delivered'
    )
  );

-- 수정: 본인만 (immutable 컬럼은 트리거가 차단)
drop policy if exists "reviews_update" on public.product_reviews;
create policy "reviews_update" on public.product_reviews
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 삭제: 본인 또는 관리자(부적절 리뷰 중재)
drop policy if exists "reviews_delete" on public.product_reviews;
create policy "reviews_delete" on public.product_reviews
  for delete using (user_id = auth.uid() or public.is_admin());

-- 상품별 평점 집계 뷰
create or replace view public.product_review_stats
with (security_invoker = true) as
  select product_id,
         count(*)::int                        as review_count,
         round(avg(rating)::numeric, 1)::float as avg_rating
  from public.product_reviews
  group by product_id;

-- ------------------------------------------------------------
-- 21-1. 리뷰 좋아요 (도움돼요)
--       리뷰 작성 동기 부여용. 리뷰당 사용자 1표, 본인 리뷰에는 불가.
-- ------------------------------------------------------------
create table if not exists public.review_likes (
  review_id  uuid not null references public.product_reviews (id) on delete cascade,
  user_id    uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (review_id, user_id)
);

alter table public.review_likes enable row level security;

-- 개수 표시는 로그인 전에도 필요
drop policy if exists "review_likes_select" on public.review_likes;
create policy "review_likes_select" on public.review_likes
  for select using (true);

-- 좋아요: 로그인 사용자, 본인 리뷰는 제외
drop policy if exists "review_likes_insert" on public.review_likes;
create policy "review_likes_insert" on public.review_likes
  for insert with check (
    user_id = auth.uid()
    and not exists (
      select 1 from public.product_reviews r
      where r.id = review_id and r.user_id = auth.uid()
    )
  );

-- 취소: 본인 것만
drop policy if exists "review_likes_delete" on public.review_likes;
create policy "review_likes_delete" on public.review_likes
  for delete using (user_id = auth.uid());

-- ------------------------------------------------------------
-- 22. 운송장 번호
--     셀러가 배송중 처리 시 택배사·운송장 번호를 입력하면
--     구매자 주문 상세에서 배송조회 링크로 보여준다.
--     택배사 목록·조회 URL은 앱(lib/features/orders/couriers.dart)에서 관리.
-- ------------------------------------------------------------
alter table public.order_items
  add column if not exists courier         text not null default '',
  add column if not exists tracking_number text not null default '';

-- update_item_status 확장: 운송장 파라미터 추가.
-- 시그니처가 다른 함수가 남아 있으면 PostgREST RPC 호출이 모호해지므로 기존 것을 drop.
drop function if exists public.update_item_status(uuid, text);

create or replace function public.update_item_status(
  p_item_id         uuid,
  p_status          text,
  p_courier         text default null,
  p_tracking_number text default null
)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  v_item  public.order_items%rowtype;
  v_order public.orders%rowtype;
  v_stage integer;
begin
  if p_status not in ('preparing', 'shipped', 'delivered') then
    raise exception '허용되지 않는 배송 상태입니다: %', p_status;
  end if;

  select * into v_item from public.order_items where id = p_item_id;
  if not found or (v_item.seller_id <> auth.uid() and not public.is_admin()) then
    raise exception '본인 판매 상품만 변경할 수 있습니다.';
  end if;

  -- 주문 행 잠금: 여러 셀러가 동시에 변경해도 재계산이 꼬이지 않게
  select * into v_order from public.orders where id = v_item.order_id for update;
  if v_order.status in ('pending_payment', 'cancelled') then
    raise exception '결제 완료된 주문만 배송 상태를 변경할 수 있습니다.';
  end if;

  update public.order_items
  set status          = p_status,
      courier         = coalesce(p_courier, courier),
      tracking_number = coalesce(p_tracking_number, tracking_number)
  where id = p_item_id;

  -- 주문 상태 = 아이템들 중 가장 느린 배송 단계
  select min(case status when 'preparing' then 1 when 'shipped' then 2 else 3 end)
    into v_stage
  from public.order_items
  where order_id = v_item.order_id;

  update public.orders
  set status = case v_stage when 1 then 'preparing'
                            when 2 then 'shipped'
                            else 'delivered' end,
      updated_at = now()
  where id = v_item.order_id;
end;
$$;

-- ------------------------------------------------------------
-- 23. 상품 타임세일 (셀러 예약 할인)
--     셀러가 상품에 할인가와 시간 구간을 예약하면 그 시간 동안
--     자동으로 할인가가 적용된다. 상품당 예약 1개 (덮어쓰기 방식).
--     적용가 판정은 서버(create_order)가 한다 — 클라이언트 금액 불신 원칙.
-- ------------------------------------------------------------
alter table public.products
  add column if not exists sale_price     integer check (sale_price >= 0),
  add column if not exists sale_starts_at timestamptz,
  add column if not exists sale_ends_at   timestamptz;

-- 세일가를 넣으려면 시간 구간도 온전해야 한다
alter table public.products
  drop constraint if exists products_time_sale_check;
alter table public.products
  add constraint products_time_sale_check check (
    sale_price is null
    or (sale_starts_at is not null and sale_ends_at is not null
        and sale_ends_at > sale_starts_at)
  );

-- select * 뷰라 컬럼 추가 반영을 위해 재생성
create or replace view public.active_products
with (security_invoker = true) as
  select * from public.products
  where status = 'active'
    and starts_at <= now()
    and ends_at > now();

-- 현재 시각의 적용 단가 (타임세일 중이면 세일가). create_order와 UI 공용 판정 기준.
create or replace function public.effective_price(p public.products)
returns integer
language sql
stable
as $$
  select case
    when p.sale_price is not null
     and p.sale_price < p.price
     and now() >= p.sale_starts_at
     and now() <  p.sale_ends_at
    then p.sale_price
    else p.price
  end;
$$;

-- create_order 갱신: 기본 단가를 effective_price로 산정 (옵션 추가금은 그 위에 합산)
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
  v_sel      jsonb;
  v_group    jsonb;
  v_choice   jsonb;
  v_unit     integer;
  v_snap     jsonb;
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

    -- 옵션 검증: 상품에 정의된 그룹마다 유효한 선택이 있어야 하고,
    -- 추가금은 클라이언트를 믿지 않고 여기서 합산한다.
    v_sel  := coalesce(v_item -> 'options', '{}'::jsonb);
    v_unit := public.effective_price(v_product);   -- 타임세일 반영 기본 단가
    v_snap := '{}'::jsonb;
    for v_group in select * from jsonb_array_elements(coalesce(v_product.options, '[]'::jsonb))
    loop
      v_choice := null;
      select c into v_choice
      from jsonb_array_elements(v_group -> 'choices') c
      where c ->> 'name' = v_sel ->> (v_group ->> 'name')
      limit 1;
      if v_choice is null then
        raise exception '옵션을 선택해 주세요: % (%)', v_group ->> 'name', v_product.title;
      end if;
      v_unit := v_unit + coalesce((v_choice ->> 'extra')::integer, 0);
      v_snap := v_snap || jsonb_build_object(v_group ->> 'name', v_choice ->> 'name');
    end loop;

    update public.products set stock = stock - v_qty, updated_at = now()
    where id = v_product.id;

    -- 주문 시점 수수료율 스냅샷 (관리자 직접 등록 상품은 수수료 0)
    v_rate := coalesce(
      (select commission_rate from public.seller_profiles
       where user_id = v_product.seller_id and status = 'approved'),
      0
    );
    v_fee := round(v_unit * v_qty * v_rate / 100.0);

    insert into public.order_items
      (order_id, product_id, seller_id, product_title, unit_price, quantity,
       commission_rate, fee_amount, selected_options)
    values
      (v_order_id, v_product.id, v_product.seller_id, v_product.title,
       v_unit, v_qty, v_rate, v_fee, v_snap);

    v_total := v_total + v_unit * v_qty;
  end loop;

  update public.orders set total_amount = v_total where id = v_order_id;

  delete from public.cart_items
  where user_id = v_user_id
    and product_id in (select (i ->> 'product_id')::uuid from jsonb_array_elements(p_items) i);

  return v_order_id;
end;
$$;

-- ------------------------------------------------------------
-- 24. 찜(위시리스트) + 타임세일 알림
--     찜한 상품의 타임세일이 시작되면 인앱 알림, 마감 1시간 전에
--     임박 알림을 보낸다 (90분 이하 짧은 세일은 시작 알림만).
--     중복 발송 방지는 products의 발송 마커 컬럼으로.
-- ------------------------------------------------------------
create table if not exists public.wishlists (
  user_id    uuid not null references auth.users (id) on delete cascade,
  product_id uuid not null references public.products (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, product_id)
);

create index if not exists idx_wishlists_product on public.wishlists (product_id);

alter table public.wishlists enable row level security;

drop policy if exists "wishlists_owner" on public.wishlists;
create policy "wishlists_owner" on public.wishlists
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 타임세일 알림 발송 마커
alter table public.products
  add column if not exists sale_start_notified_at timestamptz,
  add column if not exists sale_ending_notified_at timestamptz;

-- 세일 일정이 바뀌면 마커 초기화 (새 세일은 다시 알림)
create or replace function public.reset_sale_notify_markers()
returns trigger
language plpgsql
as $$
begin
  if new.sale_price     is distinct from old.sale_price
     or new.sale_starts_at is distinct from old.sale_starts_at
     or new.sale_ends_at   is distinct from old.sale_ends_at then
    new.sale_start_notified_at  := null;
    new.sale_ending_notified_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_reset_sale_notify_markers on public.products;
create trigger trg_reset_sale_notify_markers
  before update on public.products
  for each row execute function public.reset_sale_notify_markers();

-- 찜한 사용자에게 타임세일 시작·마감 임박 알림 (pg_cron이 1분마다 호출)
create or replace function public.notify_time_sales()
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  v_product record;
begin
  -- 세일 시작 알림
  for v_product in
    select * from public.products
    where status = 'active'
      and sale_price is not null and sale_price < price
      and now() >= sale_starts_at and now() < sale_ends_at
      and starts_at <= now() and ends_at > now()
      and sale_start_notified_at is null
  loop
    insert into public.notifications (user_id, title, body, link)
    select w.user_id,
           '⚡ 찜한 상품 타임세일 시작!',
           v_product.title || ' — ' || to_char(v_product.sale_price, 'FM999,999,999') || '원 (' ||
             to_char(v_product.sale_ends_at at time zone 'Asia/Seoul', 'HH24:MI') || ' 까지)',
           '/product/' || v_product.id
    from public.wishlists w
    where w.product_id = v_product.id;

    update public.products set sale_start_notified_at = now()
    where id = v_product.id;
  end loop;

  -- 마감 1시간 전 임박 알림 (90분 넘는 세일만 — 짧은 세일은 시작 알림으로 충분)
  for v_product in
    select * from public.products
    where status = 'active'
      and sale_price is not null and sale_price < price
      and now() >= sale_ends_at - interval '1 hour' and now() < sale_ends_at
      and sale_ends_at - sale_starts_at > interval '90 minutes'
      and starts_at <= now() and ends_at > now()
      and sale_ending_notified_at is null
  loop
    insert into public.notifications (user_id, title, body, link)
    select w.user_id,
           '⏰ 타임세일이 곧 끝나요',
           v_product.title || ' 세일이 ' ||
             to_char(v_product.sale_ends_at at time zone 'Asia/Seoul', 'HH24:MI') || '에 종료됩니다.',
           '/product/' || v_product.id
    from public.wishlists w
    where w.product_id = v_product.id;

    update public.products set sale_ending_notified_at = now()
    where id = v_product.id;
  end loop;
end;
$$;

select cron.schedule(
  'notify-time-sales',
  '* * * * *',
  $$ select public.notify_time_sales() $$
);

-- ------------------------------------------------------------
-- 25. FCM 푸시 알림
--     인앱 알림(notifications) insert를 트리거가 push_queue에 적재하고,
--     pg_cron이 1분마다 Cloudflare Worker(tools/cloudflare/push-worker)로
--     배치 전송한다. FCM v1 API는 OAuth(RS256 서명)가 필요해 DB에서 직접
--     못 부르므로 Worker가 Firebase 서비스 계정으로 대신 발송한다.
--     private.app_secrets에 push_worker_url / push_shared_secret을
--     등록해야 동작 — 미등록이면 큐만 비우고 조용히 건너뛴다.
-- ------------------------------------------------------------
create table if not exists public.push_tokens (
  token      text primary key,
  user_id    uuid not null references auth.users (id) on delete cascade,
  platform   text not null default '',   -- android / ios / web
  updated_at timestamptz not null default now()
);

create index if not exists idx_push_tokens_user on public.push_tokens (user_id);

-- 정책 없음 — 아래 security definer RPC로만 등록/해제
alter table public.push_tokens enable row level security;

-- 토큰 등록. 같은 기기에서 다른 계정으로 로그인하면 소유자가 바뀌므로
-- (RLS upsert로는 타인 row를 못 건드림) definer RPC로 이전 처리한다.
create or replace function public.register_push_token(
  p_token    text,
  p_platform text default ''
)
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception '로그인이 필요합니다.';
  end if;
  insert into public.push_tokens (token, user_id, platform)
  values (p_token, auth.uid(), p_platform)
  on conflict (token) do update
    set user_id = excluded.user_id,
        platform = excluded.platform,
        updated_at = now();
end;
$$;

-- 로그아웃 시 이 기기 토큰을 계정에서 분리
create or replace function public.unregister_push_token(p_token text)
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  delete from public.push_tokens
  where token = p_token and user_id = auth.uid();
end;
$$;

create table if not exists public.push_queue (
  id              bigint generated always as identity primary key,
  notification_id uuid not null references public.notifications (id) on delete cascade,
  created_at      timestamptz not null default now()
);

-- 정책 없음 — 트리거/크론 전용 내부 테이블
alter table public.push_queue enable row level security;

create or replace function public.enqueue_push()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  -- 등록된 기기가 없는 사용자는 큐에 쌓지 않는다
  if exists (select 1 from public.push_tokens where user_id = new.user_id) then
    insert into public.push_queue (notification_id) values (new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_enqueue_push on public.notifications;
create trigger trg_enqueue_push
  after insert on public.notifications
  for each row execute function public.enqueue_push();

create or replace function public.send_push_notifications()
returns void
language plpgsql
security definer set search_path = public, extensions
as $fn$
declare
  v_url     text;
  v_secret  text;
  v_ids     bigint[];
  v_batch   jsonb;
  v_resp    http_response;
  v_invalid jsonb;
begin
  select value into v_url    from private.app_secrets where key = 'push_worker_url';
  select value into v_secret from private.app_secrets where key = 'push_shared_secret';

  -- 푸시 미설정 상태 — 큐가 무한히 자라지 않게 비우기만 한다
  if v_url is null or v_secret is null then
    delete from public.push_queue;
    return;
  end if;

  -- 1시간 넘게 못 보낸 건 폐기 (푸시는 즉시성이 생명)
  delete from public.push_queue where created_at < now() - interval '1 hour';

  -- 한 번에 25건 — Worker 무료 플랜의 요청당 서브요청 50개 제한 고려
  -- (사용자당 기기 1~2개 가정). 남은 건 다음 분에 이어서 보낸다.
  select array_agg(distinct q.id),
         jsonb_agg(jsonb_build_object(
           'token', t.token,
           'title', n.title,
           'body',  n.body,
           'link',  n.link))
    into v_ids, v_batch
  from (select id, notification_id from public.push_queue
        order by id limit 25
        for update skip locked) q
  join public.notifications n on n.id = q.notification_id
  join public.push_tokens t on t.user_id = n.user_id;

  if v_batch is null then
    return;
  end if;

  perform http_set_curlopt('CURLOPT_TIMEOUT', '30');

  v_resp := http((
    'POST',
    v_url,
    array[http_header('Authorization', 'Bearer ' || v_secret)],
    'application/json',
    jsonb_build_object('messages', v_batch)::text
  )::http_request);

  -- 실패 시 큐 유지 → 다음 분에 재시도 (1시간 지나면 위에서 폐기)
  if v_resp.status <> 200 then
    raise warning 'push worker HTTP %: %', v_resp.status, left(v_resp.content, 200);
    return;
  end if;

  -- FCM이 무효(UNREGISTERED)라고 알려준 토큰 정리
  v_invalid := (v_resp.content::jsonb) -> 'invalid';
  if v_invalid is not null and jsonb_typeof(v_invalid) = 'array' then
    delete from public.push_tokens
    where token in (select jsonb_array_elements_text(v_invalid));
  end if;

  delete from public.push_queue where id = any (v_ids);
end;
$fn$;

-- 크론 전용 — 클라이언트가 임의로 발송을 트리거하지 못하게 차단
revoke execute on function public.send_push_notifications() from public, anon, authenticated;

select cron.schedule(
  'send-push-notifications',
  '* * * * *',
  $$ select public.send_push_notifications() $$
);

-- ------------------------------------------------------------
-- 26. 카드결제 환불
--     취소 시 토스 결제취소 API를 DB(http 확장)가 호출해 환불한다
--     (승인과 동일 패턴 — 15절). 환불 없이 카드 주문이 취소되는
--     경로는 가드 트리거가 차단한다.
--     구매자 = paid(셀러 준비 시작 전)까지 셀프 취소·자동 환불,
--     관리자 = admin_cancel_order로 배송 시작 전까지 취소·환불.
-- ------------------------------------------------------------
alter table public.payments add column if not exists cancelled_at timestamptz;

-- 내부 헬퍼: 승인된 카드 결제가 있으면 토스에 취소 요청하고 payments에 기록.
-- 결제 기록이 없거나(결제 전 취소) 이미 환불됐으면 조용히 통과 — 멱등.
create or replace function public.refund_card_payment(p_order_id uuid, p_reason text)
returns void
language plpgsql
security definer set search_path = public, extensions
as $fn$
declare
  v_pay    public.payments%rowtype;
  v_secret text;
  v_cred   text;
  v_resp   http_response;
  v_json   jsonb;
begin
  select * into v_pay from public.payments where order_id = p_order_id for update;
  if not found or v_pay.cancelled_at is not null then
    return;
  end if;

  select value into v_secret from private.app_secrets where key = 'toss_secret_key';
  if v_secret is null then
    raise exception '결제 설정이 없습니다. 관리자에게 문의하세요.';
  end if;
  v_cred := replace(encode(convert_to(v_secret || ':', 'utf8'), 'base64'), E'\n', '');

  perform http_set_curlopt('CURLOPT_TIMEOUT', '10');

  v_resp := http((
    'POST',
    'https://api.tosspayments.com/v1/payments/' || v_pay.payment_key || '/cancel',
    array[http_header('Authorization', 'Basic ' || v_cred)],
    'application/json',
    jsonb_build_object('cancelReason', p_reason)::text
  )::http_request);

  v_json := v_resp.content::jsonb;

  -- 이전 시도에서 토스 취소만 되고 DB 반영 전에 끊긴 재시도는 성공 처리
  if v_resp.status <> 200
     and coalesce(v_json ->> 'code', '') <> 'ALREADY_CANCELED_PAYMENT' then
    raise exception '결제 환불에 실패했습니다: %',
      coalesce(v_json ->> 'message', 'HTTP ' || v_resp.status::text);
  end if;

  update public.payments
  set status = 'CANCELED',
      cancelled_at = now(),
      raw = raw || jsonb_build_object('cancel', v_json)
  where id = v_pay.id;
end;
$fn$;

-- 취소 RPC 내부에서만 호출 (클라이언트 직접 호출 차단)
revoke execute on function public.refund_card_payment(uuid, text)
  from public, anon, authenticated;

-- 가드: 결제가 잡힌 카드 주문을 환불 없이 취소하는 모든 경로 차단.
-- (취소 RPC는 환불을 먼저 처리해 cancelled_at을 채운 뒤 상태를 바꾼다)
create or replace function public.block_unrefunded_card_cancel()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if exists (select 1 from public.payments
             where order_id = new.id and cancelled_at is null) then
    raise exception '카드 결제된 주문은 환불 처리(취소 버튼)로만 취소할 수 있습니다.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_block_unrefunded_card_cancel on public.orders;
create trigger trg_block_unrefunded_card_cancel
  before update of status on public.orders
  for each row
  when (new.status = 'cancelled' and old.status <> 'cancelled')
  execute function public.block_unrefunded_card_cancel();

-- 구매자 취소 확장: 입금 대기 외에 카드 결제 완료(paid) 상태도 허용.
-- 셀러가 배송 준비를 시작하면(order 상태가 preparing 이후) 관리자 문의로 안내.
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

  if v_order.status = 'pending_payment' then
    null; -- 결제 전 — 바로 취소
  elsif v_order.status = 'paid' and v_order.payment_method = 'card' then
    perform public.refund_card_payment(p_order_id, '구매자 주문 취소');
  else
    raise exception '이 상태에서는 직접 취소할 수 없습니다. 관리자에게 문의해 주세요.';
  end if;

  update public.orders
  set status = 'cancelled', updated_at = now()
  where id = p_order_id;
end;
$$;

-- 관리자 취소: 배송 시작 전까지, 카드 결제분은 자동 환불
create or replace function public.admin_cancel_order(p_order_id uuid)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  v_order public.orders%rowtype;
begin
  if not public.is_admin() then
    raise exception '관리자만 사용할 수 있습니다.';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception '주문을 찾을 수 없습니다.';
  end if;
  if v_order.status = 'cancelled' then
    return; -- 이미 취소됨 — 멱등
  end if;
  if v_order.status not in ('pending_payment', 'paid', 'preparing') then
    raise exception '배송이 시작된 주문은 취소할 수 없습니다.';
  end if;

  perform public.refund_card_payment(p_order_id, '관리자 주문 취소');

  update public.orders
  set status = 'cancelled', updated_at = now()
  where id = p_order_id;
end;
$$;

-- ------------------------------------------------------------
-- 27. 운영 헬스체크 (외부 모니터가 읽는 상태 신호)
--     NAS가 죽으면 DB로는 그 사실을 알릴 수 없다. 그래서 감시는 바깥
--     (Cloudflare Worker orange-man-monitor)에서 하고, DB는 바깥에서
--     확인할 수 없는 신호만 모아서 넘겨준다.
--     백업은 DSM 작업 스케줄러가 돌리는데 실패해도 조용하므로,
--     스크립트가 성공했을 때만 하트비트를 찍고 그게 늙으면 실패로 본다
--     (데드맨 스위치 — 스크립트가 아예 안 돈 경우도 같이 잡힌다).
-- ------------------------------------------------------------
create table if not exists public.ops_heartbeat (
  name   text primary key,
  at     timestamptz not null default now(),
  detail jsonb
);

-- 정책 없음 — 기록은 NAS 스크립트가 psql(superuser)로, 조회는 health_check가 한다
alter table public.ops_heartbeat enable row level security;

create or replace function public.record_heartbeat(p_name text, p_detail jsonb default null)
returns void
language sql
security definer set search_path = public
as $$
  insert into public.ops_heartbeat (name, at, detail)
  values (p_name, now(), p_detail)
  on conflict (name) do update set at = excluded.at, detail = excluded.detail;
$$;

revoke execute on function public.record_heartbeat(text, jsonb) from public, anon, authenticated;

-- 모니터가 5분마다 호출한다. anon 키만으로는 못 부르게 토큰을 함께 받는다
-- (anon 키는 클라이언트에 내장돼 공개된 값이라 그것만으로는 통제가 안 됨).
create or replace function public.health_check(p_token text)
returns jsonb
language plpgsql
security definer set search_path = public, cron
stable
as $fn$
declare
  v_token text;
begin
  select value into v_token from private.app_secrets where key = 'health_token';
  if v_token is null or p_token is distinct from v_token then
    raise exception '권한이 없습니다.';
  end if;

  return jsonb_build_object(
    'now', now(),
    -- 하트비트별 경과 초. 없으면 키 자체가 빠지므로 모니터가 '한 번도 안 돎'으로 처리
    'heartbeat_age', (
      select coalesce(
        jsonb_object_agg(name, round(extract(epoch from now() - at))), '{}'::jsonb)
      from public.ops_heartbeat
    ),
    -- pg_cron 잡별 마지막 성공 이후 경과 초 (잡이 멈추면 계속 커진다)
    'cron_age', (
      select coalesce(jsonb_object_agg(jobname, age), '{}'::jsonb)
      from (
        select j.jobname,
               round(extract(epoch from now() - max(d.end_time))) as age
        from cron.job j
        left join cron.job_run_details d
          on d.jobid = j.jobid and d.status = 'succeeded'
        group by j.jobname
      ) t
    ),
    -- 푸시 큐 적체 (Worker 발송이 막히면 쌓인다)
    'push_pending', (select count(*) from public.push_queue),
    'push_oldest_sec', (
      select coalesce(round(extract(epoch from now() - min(created_at))), 0)
      from public.push_queue
    ),
    'active_products', (select count(*) from public.active_products)
  );
end;
$fn$;

grant execute on function public.health_check(text) to anon, authenticated;

-- 모니터 Worker와 나눠 갖는 토큰. 고정된 기본값을 두면 그걸 그대로 쓰는 설치가
-- 생기므로 설치마다 임의로 만든다. 값 확인(Worker 시크릿에 넣을 때):
--   select value from private.app_secrets where key = 'health_token';
insert into private.app_secrets (key, value)
values ('health_token', encode(extensions.gen_random_bytes(24), 'hex'))
on conflict (key) do nothing;

-- ------------------------------------------------------------
-- 28. 셀러 전용 판매 링크 (공개 스토어프론트)
--     신규 마켓은 트래픽이 없다. 그래서 셀러가 **자기 손님**을 데려올 수 있는
--     주소를 준다 — 인스타 프로필·카톡 채널에 걸어두는 /s/{slug}.
--     그 손님이 다른 셀러 상품까지 보게 되면서 마켓 트래픽이 된다.
--
--     seller_profiles에는 정산 계좌·연락처가 있어 RLS를 열 수 없으므로,
--     공개용 칼럼만 뽑은 seller_shops 뷰를 따로 둔다 (비로그인도 조회).
-- ------------------------------------------------------------
alter table public.seller_profiles
  add column if not exists slug  text,
  add column if not exists intro text not null default '';

-- 링크 주소 형식: 영문 소문자·숫자·하이픈 2~20자, 첫 글자는 하이픈 불가
alter table public.seller_profiles
  drop constraint if exists seller_profiles_slug_format;
alter table public.seller_profiles
  add constraint seller_profiles_slug_format
    check (slug is null or slug ~ '^[a-z0-9][a-z0-9-]{1,19}$');

-- 대소문자 구분 없이 유일 (미설정 null은 여러 행 허용)
create unique index if not exists idx_seller_profiles_slug
  on public.seller_profiles (lower(slug));

-- 공개 스토어프론트가 읽는 뷰. security_invoker를 끄고(=뷰 소유자 권한으로 실행)
-- 계좌·연락처·사업자번호를 뺀 칼럼만 내보낸다. 승인된 셀러 + 링크 설정된 셀러만.
drop view if exists public.seller_shops;
create view public.seller_shops
with (security_invoker = false) as
  select user_id as seller_id, slug, shop_name, intro, created_at
  from public.seller_profiles
  where status = 'approved' and slug is not null;

grant select on public.seller_shops to anon, authenticated;

-- 링크 주소 설정. 형식·중복·예약어를 서버에서 검사해 사람이 읽을 오류를 돌려준다.
-- (테이블 update로도 바꿀 수 있지만 그러면 중복이 unique 위반 원문으로 튀어나온다)
create or replace function public.set_my_shop_slug(p_slug text)
returns text
language plpgsql
security definer set search_path = public
as $$
declare
  v_slug text := lower(trim(coalesce(p_slug, '')));
begin
  if not public.is_approved_seller() then
    raise exception '승인된 셀러만 판매 링크를 만들 수 있습니다.';
  end if;

  if v_slug !~ '^[a-z0-9][a-z0-9-]{1,19}$' then
    raise exception '링크 주소는 영문 소문자·숫자·하이픈 2~20자여야 합니다.';
  end if;

  -- 앱 라우트와 겹치면 링크가 엉뚱한 화면을 연다
  if v_slug = any (array[
      'admin', 'seller', 'partner', 'login', 'info', 'terms', 'privacy',
      'business', 'cart', 'checkout', 'orders', 'order', 'product', 'payment',
      'wishlist', 'notifications', 's', 'api', 'www', 'app', 'shop', 'help',
      'about', 'support', 'new', 'null']) then
    raise exception '사용할 수 없는 주소입니다.';
  end if;

  if exists (select 1 from public.seller_profiles
             where lower(slug) = v_slug and user_id <> auth.uid()) then
    raise exception '이미 다른 셀러가 쓰고 있는 주소입니다.';
  end if;

  update public.seller_profiles set slug = v_slug where user_id = auth.uid();
  return v_slug;
end;
$$;

revoke execute on function public.set_my_shop_slug(text) from public, anon;
grant execute on function public.set_my_shop_slug(text) to authenticated;

-- ------------------------------------------------------------
-- 29. 입점 수수료 0% (초기 셀러 유치)
--     인포크마켓이 3.45%(카드 결제 원가 수준)로 파는 시장에서 10%는 셀러가
--     계산기를 두드리는 순간 진다. 게다가 우리는 아직 트래픽도 없다.
--     셀러가 먼저 붙어야 마켓이 성립하므로 초기 요율은 0%로 간다.
--     카드 결제 원가(약 3%)는 플랫폼이 떠안는다.
--
--     나중에 요율을 올려도 지난 주문은 order_items에 스냅샷된 요율로 정산되므로
--     소급되지 않는다 (create_order가 주문 시점 요율을 박아둔다).
--     0%를 약속할 수 있는 근거가 이것이다.
-- ------------------------------------------------------------
alter table public.seller_profiles alter column commission_rate set default 0.00;

-- 기존 셀러도 0%로. 옛 기본값(10%)인 행만 건드려서 관리자가 개별 조정한
-- 요율은 덮어쓰지 않는다.
--
-- protect_seller_privileges 트리거는 auth.uid()가 없는 psql 세션을 '관리자 아님'
-- 으로 보고 수수료율 변경을 막는다. SQL Editor/psql로 돌리는 마이그레이션이라
-- 잠시 껐다 켠다. (트리거가 하던 updated_at 갱신은 직접 넣는다)
alter table public.seller_profiles disable trigger trg_protect_seller_privileges;

update public.seller_profiles
   set commission_rate = 0.00,
       updated_at = now()
 where commission_rate = 10.00;

alter table public.seller_profiles enable trigger trg_protect_seller_privileges;

-- ------------------------------------------------------------
-- 30. 최소 수량 공동구매 (MOQ)
--     인포크마켓 같은 '셀러 각자 스토어'가 구조적으로 못 하는 유일한 것이
--     수요 집계다. 목표 수량을 걸어두고 마감 때 미달이면 전원 취소·환불하면
--     셀러는 재고를 미리 쌓지 않고도 팔 수 있다.
--
--     판정 규칙 (운영자 결정):
--       * 모인 수량 = **입금 완료 이후** 주문만. 실제 돈이 들어온 수요라야
--         발주 근거가 된다.
--       * 판정 시점 = **마감 즉시**. 대신 MOQ 상품은 무통장 입금 기한을
--         24시간이 아니라 '공구 마감'으로 당겨서, 마감 순간 모든 게 확정되게
--         한다 (settle_group_buys가 세기 전에 미입금 주문을 먼저 취소한다).
--
--     환불: 현재 운영은 무통장입금만 켜져 있어 자동 환불이 불가능하다.
--     그래서 무산 건은 refund_requests에 쌓고 관리자가 계좌로 이체한 뒤
--     완료 처리한다. 카드 주문이면서 주문 전체가 취소되는 경우만
--     refund_card_payment로 자동 환불된다 (부분 취소는 토스 부분취소가
--     필요해 아직 수동 — 관리자 메모로 안내).
-- ------------------------------------------------------------

-- 목표 수량. 0이면 기존과 동일한 상시 판매라 기존 상품은 영향 없다.
alter table public.products
  add column if not exists min_quantity integer not null default 0;
alter table public.products drop constraint if exists products_min_quantity_check;
alter table public.products
  add constraint products_min_quantity_check check (min_quantity >= 0);

-- 판정 완료 표시 — 중복 판정·중복 알림을 막는다
alter table public.products
  add column if not exists moq_settled_at timestamptz;

-- 진행률 뷰와 판정 함수가 모두 product_id로 훑는다
create index if not exists idx_order_items_product
  on public.order_items (product_id);

-- 아이템 단위 취소 (무산분). 배송 단계 계산에서는 빼야 한다.
alter table public.order_items drop constraint if exists order_items_status_check;
alter table public.order_items
  add constraint order_items_status_check
    check (status in ('preparing', 'shipped', 'delivered', 'cancelled'));

-- ── 진행률 ────────────────────────────────────────────────────
-- 비로그인 손님도 봐야 하는데 order_items는 RLS로 본인 것만 보인다.
-- security_invoker를 꺼서 집계는 정확히 하되, 내보내는 건 상품별 **합계**
-- 하나뿐이라 개별 주문은 새지 않는다.
drop view if exists public.product_progress;
create view public.product_progress
with (security_invoker = false) as
  select p.id as product_id,
         p.min_quantity,
         coalesce((
           select sum(oi.quantity)
           from public.order_items oi
           join public.orders o on o.id = oi.order_id
           where oi.product_id = p.id
             and oi.status <> 'cancelled'
             and o.status in ('paid', 'preparing', 'shipped', 'delivered')
         ), 0)::integer as paid_quantity
  from public.products p;

grant select on public.product_progress to anon, authenticated;

-- ── 환불 대기 목록 ────────────────────────────────────────────
create table if not exists public.refund_requests (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references public.orders (id) on delete cascade,
  order_item_id uuid references public.order_items (id) on delete set null,
  amount        integer not null check (amount >= 0),
  reason        text not null default '',
  status        text not null default 'pending'
                  check (status in ('pending', 'done')),
  memo          text not null default '',
  created_at    timestamptz not null default now(),
  done_at       timestamptz
);

create index if not exists idx_refund_requests_status
  on public.refund_requests (status, created_at);

alter table public.refund_requests enable row level security;

-- 구매자도 자기 환불 진행 상황을 봐야 기다릴 수 있다. 쓰기는 관리자만.
drop policy if exists "refund_requests_select" on public.refund_requests;
create policy "refund_requests_select" on public.refund_requests
  for select using (
    public.is_admin()
    or exists (select 1 from public.orders o
               where o.id = order_id and o.user_id = auth.uid())
  );
drop policy if exists "refund_requests_update" on public.refund_requests;
create policy "refund_requests_update" on public.refund_requests
  for update using (public.is_admin()) with check (public.is_admin());

-- ── 기존 트리거 보정 ──────────────────────────────────────────
-- 주문 취소 시 재고 복원: 이미 무산으로 취소된 아이템은 그때 재고를 되돌렸다.
-- 여기서 또 더하면 재고가 부풀어 오른다.
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
      and status <> 'cancelled'
    group by product_id
  ) oi
  where p.id = oi.product_id;
  return new;
end;
$$;

-- 배송 단계 재계산에서 취소된 아이템 제외 (전부 취소면 주문도 취소 상태 유지)
create or replace function public.update_item_status(
  p_item_id uuid, p_status text, p_courier text default null,
  p_tracking_number text default null)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  v_item  public.order_items%rowtype;
  v_order public.orders%rowtype;
  v_stage integer;
begin
  if p_status not in ('preparing', 'shipped', 'delivered') then
    raise exception '허용되지 않는 배송 상태입니다: %', p_status;
  end if;

  select * into v_item from public.order_items where id = p_item_id;
  if not found or (v_item.seller_id <> auth.uid() and not public.is_admin()) then
    raise exception '본인 판매 상품만 변경할 수 있습니다.';
  end if;
  if v_item.status = 'cancelled' then
    raise exception '취소된 상품은 배송 상태를 변경할 수 없습니다.';
  end if;

  select * into v_order from public.orders where id = v_item.order_id for update;
  if v_order.status in ('pending_payment', 'cancelled') then
    raise exception '결제 완료된 주문만 배송 상태를 변경할 수 있습니다.';
  end if;

  update public.order_items
  set status = p_status,
      courier = coalesce(p_courier, courier),
      tracking_number = coalesce(p_tracking_number, tracking_number)
  where id = p_item_id;

  select min(case status when 'preparing' then 1 when 'shipped' then 2 else 3 end)
    into v_stage
  from public.order_items
  where order_id = v_item.order_id and status <> 'cancelled';

  if v_stage is not null then
    update public.orders
    set status = case v_stage when 1 then 'preparing'
                              when 2 then 'shipped'
                              else 'delivered' end,
        updated_at = now()
    where id = v_item.order_id;
  end if;
end;
$$;

-- ── 마감 판정 ─────────────────────────────────────────────────
-- 마감된 MOQ 상품을 성사/무산으로 확정한다. pg_cron이 5분마다 호출.
-- 미입금 주문 취소를 **세기 전에** 직접 하므로 다른 cron 잡과의 실행 순서에
-- 기대지 않는다.
create or replace function public.settle_group_buys()
returns integer
language plpgsql
security definer set search_path = public
as $fn$
declare
  v_p       record;
  v_item    record;
  v_order   record;
  v_reached integer;
  v_done    integer := 0;
begin
  for v_p in
    select id, title, min_quantity, seller_id
    from public.products
    where min_quantity > 0
      and ends_at <= now()
      and moq_settled_at is null
    for update
  loop
    -- 1) MOQ 상품의 무통장 입금 기한은 공구 마감이다. 미입금은 여기서 정리.
    --    (재고 복원은 restore_stock_on_cancel 트리거가 처리)
    update public.orders o
    set status = 'cancelled', updated_at = now()
    where o.status = 'pending_payment'
      and exists (select 1 from public.order_items oi
                  where oi.order_id = o.id and oi.product_id = v_p.id);

    -- 2) 입금 완료 이후 주문만 세어 목표 달성 여부 판정
    select coalesce(sum(oi.quantity), 0) into v_reached
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    where oi.product_id = v_p.id
      and oi.status <> 'cancelled'
      and o.status in ('paid', 'preparing', 'shipped', 'delivered');

    if v_reached >= v_p.min_quantity then
      -- 3a) 성사 — 구매자에게 알리고, 셀러에게 발주해도 된다고 알린다
      insert into public.notifications (user_id, title, body, link)
      select distinct o.user_id,
             '공동구매가 성사되었습니다',
             v_p.title || ' 목표 수량을 채웠습니다. 준비되는 대로 발송해 드립니다.',
             '/orders/' || o.id
      from public.order_items oi
      join public.orders o on o.id = oi.order_id
      where oi.product_id = v_p.id
        and oi.status <> 'cancelled'
        and o.status in ('paid', 'preparing', 'shipped', 'delivered');

      insert into public.notifications (user_id, title, body, link)
      values (v_p.seller_id, '공동구매 성사',
              v_p.title || ' — ' || v_reached || '개 확정. 발주하셔도 됩니다.',
              '/seller');
    else
      -- 3b) 무산 — 아이템만 취소하고 환불 대기에 올린다.
      --     한 주문에 다른 셀러 상품이 섞여 있을 수 있어 주문 전체를 취소하지
      --     않는다. 그 상품들은 정상 진행돼야 한다.
      for v_item in
        select oi.id, oi.order_id, oi.quantity, oi.unit_price, o.user_id
        from public.order_items oi
        join public.orders o on o.id = oi.order_id
        where oi.product_id = v_p.id
          and oi.status <> 'cancelled'
          and o.status in ('paid', 'preparing')
      loop
        update public.order_items set status = 'cancelled' where id = v_item.id;

        update public.products
        set stock = stock + v_item.quantity, updated_at = now()
        where id = v_p.id;

        insert into public.refund_requests (order_id, order_item_id, amount, reason)
        values (v_item.order_id, v_item.id,
                v_item.unit_price * v_item.quantity,
                v_p.title || ' 공동구매 목표 수량 미달');

        insert into public.notifications (user_id, title, body, link)
        values (v_item.user_id, '공동구매가 무산되었습니다',
                v_p.title || ' 이(가) 목표 수량을 채우지 못해 취소되었습니다. '
                || '결제하신 금액은 전액 환불해 드립니다.',
                '/orders/' || v_item.order_id);
      end loop;

      -- 살아있는 아이템이 하나도 없는 주문은 주문 자체를 취소한다.
      -- 카드 결제분은 환불이 먼저다 (가드 트리거가 미환불 취소를 막는다).
      for v_order in
        select distinct o.id
        from public.orders o
        join public.order_items oi on oi.order_id = o.id
        where oi.product_id = v_p.id
          and o.status in ('paid', 'preparing')
          and not exists (select 1 from public.order_items x
                          where x.order_id = o.id and x.status <> 'cancelled')
      loop
        perform public.refund_card_payment(v_order.id, '공동구매 목표 수량 미달');
        update public.orders
        set status = 'cancelled', updated_at = now()
        where id = v_order.id;
      end loop;

      insert into public.notifications (user_id, title, body, link)
      values (v_p.seller_id, '공동구매 무산',
              v_p.title || ' — 목표 ' || v_p.min_quantity || '개 중 '
              || v_reached || '개에 그쳐 취소되었습니다.',
              '/seller');
    end if;

    update public.products
    set moq_settled_at = now(), status = 'closed', updated_at = now()
    where id = v_p.id;

    v_done := v_done + 1;
  end loop;

  return v_done;
end;
$fn$;

revoke execute on function public.settle_group_buys() from public, anon, authenticated;

select cron.schedule(
  'settle-group-buys',
  '3-59/5 * * * *',
  $$ select public.settle_group_buys() $$
);

-- 관리자가 계좌 이체를 마친 뒤 환불 완료 처리
create or replace function public.complete_refund(p_id uuid, p_memo text default '')
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception '관리자만 처리할 수 있습니다.';
  end if;
  update public.refund_requests
  set status = 'done', done_at = now(), memo = p_memo
  where id = p_id and status = 'pending';
end;
$$;

grant execute on function public.complete_refund(uuid, text) to authenticated;
