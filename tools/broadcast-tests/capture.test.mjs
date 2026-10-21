import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { PGlite } from "@electric-sql/pglite";
const db = new PGlite();
const owner = randomUUID(),
  other = randomUUID(),
  assistant = randomUUID(),
  stranger = randomUUID(),
  joiner = randomUUID();
let session, customer, product, otherCustomer;
async function as(user, fn, role = "authenticated") {
  await db.exec(`set role ${role}`);
  await db.query("select set_config('request.jwt.claim.sub',$1,false)", [
    user ?? "",
  ]);
  try {
    return await fn();
  } finally {
    await db.exec("reset role");
  }
}
async function command(
  user,
  command,
  data,
  key = randomUUID(),
  seller = owner,
) {
  return as(
    user,
    async () =>
      (
        await db.query(
          "select public.broadcast_command($1,$2,$3::jsonb,$4) as value",
          [seller, command, JSON.stringify(data), key],
        )
      ).rows[0].value,
  );
}
const orderData = () => ({
  session_id: session.id,
  customer_id: customer.id,
  product_id: product.id,
  color: "검정",
  size: "M",
  quantity: 1,
});
before(async () => {
  await db.exec(`create role anon; create role authenticated; create schema auth;
 create table auth.users(id uuid primary key);
 create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
 grant usage on schema public,auth to anon,authenticated;
 grant execute on function auth.uid() to anon,authenticated;
 create table public.seller_profiles(user_id uuid primary key references auth.users(id),status text not null);`);
  for (const id of [owner, other, assistant, stranger, joiner])
    await db.query("insert into auth.users values($1)", [id]);
  for (const id of [owner, other])
    await db.query("insert into public.seller_profiles values($1,'approved')", [
      id,
    ]);
  await db.exec(
    await readFile(
      new URL(
        "../../supabase/migrations/202609230001_broadcast_capture.sql",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  const existing = await db.query(
    "insert into broadcast_sessions(seller_id,title,kind,exchange_rate,closes_at) values($1,'기존 테스트 방송','new',190,now()+interval '3 day') returning id",
    [owner],
  );
  await db.exec(
    await readFile(
      new URL(
        "../../supabase/migrations/202609280001_broadcast_capture_management.sql",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  await db.exec(
    await readFile(
      new URL(
        "../../supabase/migrations/202609280002_broadcast_staff_invites.sql",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  await db.exec(
    await readFile(new URL("../../supabase/migrations/202609280003_broadcast_paging.sql", import.meta.url), "utf8"),
  );
  const upgraded = await db.query(
    "select title,version,status from broadcast_sessions where id=$1",
    [existing.rows[0].id],
  );
  assert.deepEqual(upgraded.rows[0], {
    title: "기존 테스트 방송",
    version: 1,
    status: "open",
  });
  await db.query(
    "insert into public.broadcast_memberships values($1,$2,'assistant')",
    [owner, assistant],
  );
  customer = await command(owner, "customer.create", {
    nickname: "몽이맘",
    wechat_note: "위챗 확인",
  });
  otherCustomer = await command(
    other,
    "customer.create",
    { nickname: "다른 셀러 손님" },
    randomUUID(),
    other,
  );
  session = await command(owner, "session.create", {
    title: "신상 방송",
    kind: "new",
    exchange_rate: 190,
  });
  product = await command(assistant, "product.create", {
    session_id: session.id,
    supplier: "서울상사",
    title: "데님조끼",
    price_krw: 19000,
    colors: ["검정"],
    sizes: ["M", "L"],
  });
});
after(() => db.close());
test("보조 참여 코드는 일회용·만료되며 관리자가 회수할 수 있다", async () => {
  const key = randomUUID();
  const invite = await as(owner, async () => (await db.query(
    "select broadcast_staff_manage($1,'invite',null,$2) value", [owner,key],
  )).rows[0].value);
  const replay = await as(owner, async () => (await db.query(
    "select broadcast_staff_manage($1,'invite',null,$2) value", [owner,key],
  )).rows[0].value);
  assert.deepEqual(invite,replay);
  assert.ok(new Date(invite.expires_at)>new Date());
  await assert.rejects(as(stranger, async () => db.query(
    "select broadcast_staff_overview($1)",[owner],
  )), /판매자 관리 권한/);
  await assert.rejects(as(stranger, async () => db.query(
    "select broadcast_staff_manage($1,'invite',null,$2)",[owner,randomUUID()],
  )), /판매자 관리 권한/);
  const joined = await as(joiner, async () => (await db.query(
    "select broadcast_staff_join($1) value",[invite.code],
  )).rows[0].value);
  assert.deepEqual(joined,{seller_id:owner,role:"assistant"});
  const joinedAgain = await as(joiner, async () => (await db.query(
    "select broadcast_staff_join($1) value",[invite.code],
  )).rows[0].value);
  assert.deepEqual(joinedAgain,joined);
  await assert.rejects(as(stranger, async () => db.query(
    "select broadcast_staff_join($1)",[invite.code],
  )), /사용된 참여 코드/);
  const workspace = await as(joiner, async () => (await db.query(
    "select broadcast_workspace($1) value",[owner],
  )).rows[0].value);
  assert.equal(workspace.role,"assistant");
  const overview = await as(owner, async () => (await db.query(
    "select broadcast_staff_overview($1) value",[owner],
  )).rows[0].value);
  assert.ok(overview.members.some(m=>m.user_id===joiner));
  const removeKey = randomUUID();
  const removed = await as(owner, async () => (await db.query(
    "select broadcast_staff_manage($1,'remove',$2,$3) value",[owner,joiner,removeKey],
  )).rows[0].value);
  assert.equal(removed.removed,true);
  assert.deepEqual(await as(owner, async () => (await db.query(
    "select broadcast_staff_manage($1,'remove',$2,$3) value",[owner,joiner,removeKey],
  )).rows[0].value),removed);
  await assert.rejects(as(joiner, async () => db.query(
    "select broadcast_workspace($1)",[owner],
  )), /방송 관리 권한/);
  await assert.rejects(command(joiner,"customer.create",{nickname:"차단 확인"}), /방송 관리 권한/);
  await assert.rejects(as(joiner, async () => db.query(
    "select broadcast_staff_join($1)",[invite.code],
  )), /만료되었거나 사용된 참여 코드/);
  const expired = await as(owner, async () => (await db.query(
    "select broadcast_staff_manage($1,'invite',null,$2) value",[owner,randomUUID()],
  )).rows[0].value);
  await db.query("update broadcast_staff_invites set expires_at=now()-interval '1 second' where code=$1",[expired.code]);
  await assert.rejects(as(joiner, async () => db.query(
    "select broadcast_staff_join($1)",[expired.code],
  )), /만료되었거나 사용된 참여 코드/);
});
test("신상 기본 설정과 비공개 상품, 다중 코디 공개", async () => {
  assert.equal(session.shipping_krw, 4000);
  assert.equal(session.shipping_cny_fen, 3000);
  assert.equal(session.management_days, 3);
  assert.equal(product.visible, false);
  assert.equal(product.number, 1);
  const p2 = await command(assistant, "product.create", {
    session_id: session.id,
    supplier: "서울상사",
    title: "하의",
    price_krw: 10000,
  });
  assert.equal(p2.number, 2);
  for (const p of [product, p2])
    await command(assistant, "product.publish", {
      id: p.id,
      version: p.version,
      visible: true,
      in_outfit: true,
    });
  const w = await as(
    owner,
    async () =>
      (await db.query("select broadcast_workspace($1) w", [owner])).rows[0].w,
  );
  assert.equal(w.products.filter((p) => p.in_outfit).length, 2);
  await assert.rejects(
    command(assistant, "product.publish", {
      id: product.id,
      version: 1,
      visible: true,
      in_outfit: true,
    }),
    /변경되었습니다/,
  );
});
test("같은 고객/옵션 재주문은 별도 행, 같은 저장 재시도만 한 행", async () => {
  const key = randomUUID(),
    data = orderData();
  const a = await command(assistant, "order.create", data, key),
    replay = await command(assistant, "order.create", data, key);
  const b = await command(assistant, "order.create", data);
  assert.equal(a.id, replay.id);
  assert.notEqual(a.id, b.id);
  assert.ok(Number(b.sequence) > Number(a.sequence));
  assert.equal(a.source, "broadcast_assistant");
  assert.equal(a.unit_price_krw, 19000);
  await assert.rejects(
    command(assistant, "order.create", { ...data, quantity: 2 }, key),
    /같은 저장 키/,
  );
});
test("20건 독립 저장과 재시도, 합계 보존", async () => {
  const ids = [];
  for (let i = 0; i < 20; i++) {
    const key = randomUUID(),
      row = await command(assistant, "order.create", orderData(), key);
    ids.push(row.id);
    assert.equal(
      (await command(assistant, "order.create", orderData(), key)).id,
      row.id,
    );
  }
  const result = await db.query(
    "select count(*)::integer n,sum(quantity)::integer q from broadcast_order_lines where id=any($1::uuid[])",
    [ids],
  );
  assert.deepEqual(result.rows[0], { n: 20, q: 20 });
});
test("수정은 원본/순번/시각 보존, 낡은 수정과 보조 수정 차단", async () => {
  const a = await command(owner, "order.create", orderData());
  const edit = {
    id: a.id,
    version: 1,
    color: "검정",
    size: "L",
    quantity: 2,
    reason: "고객 M→L",
    note: "확인",
  };
  await assert.rejects(
    command(assistant, "order.revise", edit),
    /판매자 관리 권한/,
  );
  const b = await command(owner, "order.revise", edit);
  assert.equal(b.original.size, "M");
  assert.equal(b.size, "L");
  assert.equal(b.sequence, a.sequence);
  assert.equal(b.created_at, a.created_at);
  await assert.rejects(command(owner, "order.revise", edit), /변경되었습니다/);
  const audit = await db.query(
    "select command,reason from broadcast_audit where entity_id=$1 order by id desc limit 1",
    [a.id],
  );
  assert.equal(audit.rows[0].command, "seller_edit");
  assert.equal(audit.rows[0].reason, "고객 M→L");
  await db.query(
    "update broadcast_order_lines set payment_locked=true where id=$1",
    [a.id],
  );
  await assert.rejects(
    command(owner, "order.revise", { ...edit, version: 2 }),
    /송금 진행/,
  );
});
test("판매자/고객 바꿔치기·무인증·직접 쓰기 차단", async () => {
  await assert.rejects(command(stranger, "order.create", orderData()), /권한/);
  await assert.rejects(command(other, "order.create", orderData()), /권한/);
  await assert.rejects(
    command(owner, "order.create", {
      ...orderData(),
      customer_id: otherCustomer.id,
    }),
    /고객/,
  );
  await assert.rejects(
    as(null, () => db.query("select broadcast_workspace($1)", [owner]), "anon"),
    /permission denied/,
  );
  await assert.rejects(
    as(assistant, () =>
      db.query("update broadcast_order_lines set quantity=99"),
    ),
    /permission denied/,
  );
  await assert.rejects(
    as(assistant, () =>
      db.query("insert into broadcast_memberships values($1,$2,'manager')", [
        other,
        assistant,
      ]),
    ),
    /permission denied/,
  );
  const hidden = await as(other, () =>
    db.query("select * from broadcast_order_lines where seller_id=$1", [owner]),
  );
  assert.equal(hidden.rows.length, 0);
  const hiddenCustomers = await as(other, () =>
    db.query("select * from broadcast_customers where seller_id=$1", [owner]),
  );
  assert.equal(hiddenCustomers.rows.length, 0);
  await assert.rejects(
    command(assistant, "session.create", {
      title: "불가",
      kind: "special",
      exchange_rate: 190,
    }),
    /판매자 관리 권한/,
  );
});
test("클라이언트 가격/순번/출처 위조 무시, 수량 오류 거절", async () => {
  const a = await command(assistant, "order.create", {
    ...orderData(),
    unit_price_krw: 1,
    source: "customer_addition",
    sequence: -1,
  });
  assert.equal(a.unit_price_krw, 19000);
  assert.equal(a.source, "broadcast_assistant");
  assert.ok(Number(a.sequence) > 0);
  await assert.rejects(
    command(owner, "order.create", { ...orderData(), quantity: 0 }),
  );
  await assert.rejects(
    command(owner, "order.create", { ...orderData(), quantity: 1.5 }),
  );
});
test("방송 날짜·상태 변경과 사전 상품등록, 마감된 방송 접수 차단", async () => {
  const day = new Date(Date.now() + 86400000).toISOString().slice(0, 10);
  const draft = await command(owner, "session.create", {
    title: "내일 특가",
    kind: "special",
    status: "draft",
    broadcast_date: day,
    exchange_rate: 200,
    management_days: 2,
  });
  assert.equal(draft.status, "draft");
  assert.equal(draft.broadcast_date, day);
  assert.equal(
    new Date(draft.closes_at).toISOString().slice(0, 10),
    new Date(Date.parse(day + "T00:00:00+09:00") + 2 * 86400000)
      .toISOString()
      .slice(0, 10),
  );
  const p = await command(assistant, "product.create", {
    session_id: draft.id,
    supplier: "체험상사",
    title: "가디건",
    price_krw: 20000,
  });
  assert.equal(p.visible, false);
  await assert.rejects(
    command(assistant, "order.create", {
      ...orderData(),
      session_id: draft.id,
      product_id: p.id,
    }),
    /접수 가능한/,
  );
  await assert.rejects(
    command(assistant, "session.update", {
      id: draft.id,
      version: 1,
      status: "open",
    }),
    /관리 권한/,
  );
  const ready = await command(owner, "session.update", {
    id: draft.id,
    version: 1,
    status: "open",
  });
  assert.equal(ready.status, "open");
  await assert.rejects(
    command(assistant, "order.create", {
      ...orderData(),
      session_id: draft.id,
      product_id: p.id,
    }),
    /접수 가능한/,
  );
  await assert.rejects(
    command(owner, "session.update", {
      id: draft.id,
      version: 1,
      status: "closed",
    }),
    /변경/,
  );
  const today = new Date(Date.now() + 9 * 3600000).toISOString().slice(0, 10);
  const live = await command(owner, "session.update", {
    id: draft.id,
    version: 2,
    broadcast_date: today,
    management_days: 3,
    shipping_krw: 5000,
  });
  assert.equal(live.shipping_krw, 5000);
  const order = await command(assistant, "order.create", {
    ...orderData(),
    session_id: draft.id,
    product_id: p.id,
  });
  assert.equal(order.product_title, "가디건");
  const closed = await command(owner, "session.update", {
    id: draft.id,
    version: 3,
    status: "closed",
  });
  assert.equal(closed.status, "closed");
  await assert.rejects(
    command(assistant, "order.create", {
      ...orderData(),
      session_id: draft.id,
      product_id: p.id,
    }),
    /접수 가능한/,
  );
});
test("상품 접수 전 정정·삭제/복구·번호 보존·공개순서와 접수 후 잠금", async () => {
  const s = await command(owner, "session.create", {
    title: "상품 검증",
    kind: "special",
    exchange_rate: 200,
  });
  const first = await command(assistant, "product.create", {
    session_id: s.id,
    supplier: "가게",
    title: "자켓",
    price_krw: 20000,
    colors: ["검정"],
    sizes: ["M"],
  });
  const second = await command(assistant, "product.create", {
    session_id: s.id,
    supplier: "가게",
    title: "조끼",
    price_krw: 10000,
  });
  const shown = await command(assistant, "product.publish", {
    id: first.id,
    version: 1,
    visible: true,
    in_outfit: true,
  });
  assert.equal(shown.visible, true);
  const changed = await command(assistant, "product.update", {
    id: first.id,
    version: 2,
    supplier: "새 가게",
    title: "새 자켓",
    price_krw: 21000,
    colors: ["파랑"],
    sizes: ["L"],
    shipping_excluded: true,
  });
  assert.equal(changed.title, "새 자켓");
  assert.equal(changed.number, first.number);
  assert.equal(changed.shipping_excluded, true);
  assert.equal(changed.visible, false);
  assert.equal(changed.in_outfit, false);
  await assert.rejects(
    command(assistant, "product.update", {
      id: first.id,
      version: 2,
      supplier: "가게",
      title: "옛 자켓",
      price_krw: 1,
    }),
    /변경/,
  );
  const archived = await command(assistant, "product.archive", {
    id: second.id,
    version: 1,
  });
  assert.ok(archived.deleted_at);
  assert.equal(archived.visible, false);
  await assert.rejects(
    command(assistant, "order.create", {
      ...orderData(),
      session_id: s.id,
      product_id: second.id,
    }),
    /판매 가능/,
  );
  const third = await command(assistant, "product.create", {
    session_id: s.id,
    supplier: "가게",
    title: "치마",
    price_krw: 12000,
  });
  assert.equal(third.number, 3);
  const restored = await command(assistant, "product.restore", {
    id: second.id,
    version: 2,
  });
  assert.equal(restored.number, 2);
  assert.equal(restored.deleted_at, null);
  const reordered = await command(assistant, "product.reorder", {
    id: third.id,
    version: 1,
    direction: "up",
  });
  assert.equal(reordered.moved.public_order, 2);
  assert.equal(reordered.neighbor.public_order, 3);
  const order = await command(assistant, "order.create", {
    ...orderData(),
    session_id: s.id,
    product_id: first.id,
  });
  assert.equal(order.product_title, "새 자켓");
  assert.equal(order.unit_price_krw, 21000);
  await assert.rejects(
    command(assistant, "product.update", {
      id: first.id,
      version: 3,
      supplier: "가게",
      title: "수정",
      price_krw: 1,
    }),
    /접수 이력/,
  );
  await assert.rejects(
    command(assistant, "product.archive", { id: first.id, version: 3 }),
    /접수 이력/,
  );
  const w = await as(
    owner,
    async () =>
      (await db.query("select broadcast_workspace($1) w", [owner])).rows[0].w,
  );
  assert.ok(
    w.products.some((p) => p.id === second.id && p.deleted_at === null),
  );
  assert.ok(
    (await as(owner, async () => (await db.query(
      "select broadcast_order_page($1,$2,null,50) value", [owner,s.id],
    )).rows[0].value)).items.some(
      (o) => o.id === order.id && o.original.product.title === "새 자켓",
    ),
  );
});
test("고객 검색과 주문 기록은 서버 페이지로 조회하고 판매자 경계를 지킨다", async () => {
  const duplicate = await command(owner,"customer.create",{nickname:"몽이맘",wechat_note:"두 번째"});
  const first = await as(owner, async () => (await db.query(
    "select broadcast_customer_page($1,$2,null,null,1) value",[owner,"몽",],
  )).rows[0].value);
  assert.equal(first.items.length,1);
  assert.ok(first.next_id);
  const second = await as(owner, async () => (await db.query(
    "select broadcast_customer_page($1,$2,$3,$4,1) value",[owner,"몽",first.next_nickname,first.next_id],
  )).rows[0].value);
  assert.equal(second.items.length,1);
  assert.notEqual(first.items[0].id,second.items[0].id);
  assert.deepEqual(new Set([first.items[0].id,second.items[0].id]),new Set([customer.id,duplicate.id]));
  assert.equal(second.next_id,null);
  const page = await as(owner, async () => (await db.query(
    "select broadcast_order_page($1,$2,null,5) value",[owner,session.id],
  )).rows[0].value);
  assert.equal(page.items.length,5);
  assert.ok(page.next_before_sequence);
  const older = await as(owner, async () => (await db.query(
    "select broadcast_order_page($1,$2,$3,5) value",[owner,session.id,page.next_before_sequence],
  )).rows[0].value);
  assert.ok(older.items.every(o=>o.sequence<page.next_before_sequence));
  const workspace = await as(owner, async () => (await db.query(
    "select broadcast_workspace($1) value",[owner],
  )).rows[0].value);
  assert.deepEqual(workspace.customers,[]);
  assert.deepEqual(workspace.orders,[]);
  assert.ok(workspace.products.some(p=>p.id===product.id && p.has_orders===true));
  await assert.rejects(as(other,async()=>db.query("select broadcast_customer_page($1)",[owner])),/권한/);
  await assert.rejects(as(other,async()=>db.query("select broadcast_order_page($1,$2)",[owner,session.id])),/권한/);
  await assert.rejects(as(owner,async()=>db.query("select broadcast_order_page($1,$2)",[owner,randomUUID()])),/방송을 찾을 수/);
});
test("회차 경계, 접수 마감, 판매자 정지", async () => {
  const otherSession = await command(owner, "session.create", {
    title: "특가",
    kind: "special",
    exchange_rate: 190,
  });
  await assert.rejects(
    command(owner, "order.create", {
      ...orderData(),
      session_id: otherSession.id,
    }),
    /같은 방송/,
  );
  await db.query(
    "update broadcast_sessions set closes_at=now()-interval '1 second' where id=$1",
    [session.id],
  );
  await assert.rejects(
    command(owner, "order.create", orderData()),
    /접수 가능한/,
  );
  await db.query(
    "update seller_profiles set status='suspended' where user_id=$1",
    [owner],
  );
  await assert.rejects(
    command(owner, "customer.create", { nickname: "불가" }),
    /권한/,
  );
  await assert.rejects(
    command(assistant, "customer.create", { nickname: "불가" }),
    /권한/,
  );
});
