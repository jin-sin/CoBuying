// Interactive design data only. Never use this store for real auth, money or stock.
export const fresh = () => {
  const clock = Date.now();
  const date = new Date(clock + 9 * 3600000).toISOString().slice(0, 10);
  const session = {
    id: "s1",
    date,
    title: "가을 신상",
    kind: "new",
    rate: 200,
    kr: 4000,
    cn: 3000,
    free: 5,
    days: 3,
    status: "open",
    closesAt: Date.parse(date + "T00:00:00+09:00") + 3 * 86400000,
  };
  return {
    tick: 0,
    next: 100,
    clock,
    session,
    sessions: [session],
    receivers: [
      {
        id: "bank",
        method: "bank",
        currency: "KRW",
        holder: "체험 판매자",
        instructions: "한국 계좌 안내 예시 · 실제 송금 불가",
        active: true,
        verified: true,
      },
      {
        id: "wechat",
        method: "wechat",
        currency: "CNY",
        holder: "체험 판매자",
        instructions: "위챗 수취 QR 안내 예시 · 실제 송금 불가",
        active: true,
        verified: true,
      },
      {
        id: "alipay",
        method: "alipay",
        currency: "CNY",
        holder: "체험 판매자",
        instructions: "알리페이 수취 QR 안내 예시 · 실제 송금 불가",
        active: true,
        verified: true,
      },
    ],
    depositLedger: [
      {
        id: "d0",
        customer: "c1",
        amount: 10000,
        kind: "received",
        ref: "DEMO-DEPOSIT",
        receiverId: "bank",
        at: clock,
      },
    ],
    devices: { c1: "active", c2: "active" },
    customers: [
      {
        id: "c1",
        name: "몽이맘",
        wechat: "몽이맘 · 기존 연락처",
        deposit: 10000,
        address: null,
      },
      {
        id: "c2",
        name: "몽베베",
        wechat: "몽베베 · 기존 연락처",
        deposit: 0,
        address: null,
      },
    ],
    products: [
      {
        id: "p1",
        session: "s1",
        publicOrder: 1,
        number: 27,
        title: "데님조끼",
        supplier: "마루",
        price: 12000,
        color: "검정",
        size: "M",
        visible: true,
        outfit: true,
        excluded: false,
      },
      {
        id: "p2",
        session: "s1",
        publicOrder: 2,
        number: 28,
        title: "코디 팬츠",
        supplier: "봄날",
        price: 16000,
        color: "핑크",
        size: "7호",
        visible: false,
        outfit: false,
        excluded: false,
      },
    ],
    lines: [],
    invoices: [],
    tasks: [],
    pos: [],
    shipments: [],
    audit: [],
  };
};
export const now = (s) => s.clock + s.tick * 86400000;
const id = (s, p) => `${p}${s.next++}`;
export const customer = (s, c) => s.customers.find((x) => x.id === c);
export const product = (s, p) => s.products.find((x) => x.id === p);
export const linesFor = (s, c) =>
  s.lines.filter((l) => l.customer === c && !l.cancelled);
export const currentInvoices = (s, c) =>
  s.invoices.filter((i) => i.customer === c && !i.void);
export const invFor = (s, l) =>
  s.invoices.find((i) => i.id === l.invoice && !i.void);
export const sumPaid = (i) =>
  i.receipts.filter((r) => r.confirmed).reduce((a, r) => a + r.amount, 0);
export const refunded = (i) =>
  (i.refunds ?? [])
    .filter((r) => r.confirmed)
    .reduce((a, r) => a + r.amount, 0);
export const netPaid = (i) => sumPaid(i) - refunded(i);
export const due = (i) => (i.currency === "KRW" ? i.totalK : i.totalC);
export const settled = (i) =>
  !!i &&
  netPaid(i) >= due(i) &&
  (due(i) > 0 || i.accepted) &&
  !i.receipts.some((r) => !r.confirmed);
export const blocked = (s, l) => {
  const i = invFor(s, l);
  return (
    !!i &&
    (sumPaid(i) > 0 || i.receipts.length > 0 || (due(i) === 0 && i.accepted))
  );
};
export function task(s, kind, c, ref, message) {
  s.tasks.push({
    id: id(s, "t"),
    kind,
    customer: c,
    ref,
    message,
    done: false,
  });
}
export function addLine(s, c, p, opts, source = "broadcast_assistant") {
  if (!customer(s, c) || !product(s, p))
    throw Error("고객과 상품을 선택해주세요.");
  if (!isOpen(s))
    throw Error("집중 주문 기간이 지났습니다. 판매자에게 문의해주세요.");
  const prod = product(s, p);
  if (prod.session !== s.session.id)
    throw Error("선택한 방송의 상품을 선택해주세요.");
  if (source === "customer_addition" && !prod.visible)
    throw Error("공개된 상품만 추가주문할 수 있습니다.");
  if (prod.deleted) throw Error("삭제된 상품은 주문할 수 없습니다.");
  const l = {
    id: id(s, "l"),
    seq: s.next,
    created: now(s),
    customer: c,
    session: s.session.id,
    product: p,
    title: prod.title,
    number: prod.number,
    supplier: prod.supplier,
    price: prod.price,
    color: opts.color ?? "",
    size: opts.size ?? "",
    qty: opts.qty ?? null,
    raw: opts.raw ?? "",
    review: opts.qty == null,
    note: opts.note ?? "",
    source,
    invoice: null,
    po: 0,
    arrived: 0,
    defect: 0,
    shipped: 0,
    cancelled: false,
  };
  if (l.qty !== null && (!Number.isInteger(l.qty) || l.qty < 1 || l.qty > 999))
    throw Error("수량은 1~999로 입력해주세요.");
  l.original = {
    title: l.title,
    price: l.price,
    color: l.color,
    size: l.size,
    qty: l.qty,
    raw: l.raw,
  };
  s.lines.push(l);
  if (source === "customer_addition") task(s, "추가 주문", c, l.id, l.raw);
  return l;
}
export function revise(s, l, opts, reason) {
  if (blocked(s, l))
    throw Error(
      "송금 진행 주문은 수정할 수 없습니다. 수취 내역을 먼저 확인해주세요.",
    );
  if (!reason.trim()) throw Error("수정 사유가 필요합니다.");
  if (!Number.isInteger(opts.qty) || opts.qty < 1 || opts.qty > 999)
    throw Error("수량을 확인해주세요.");
  if (
    opts.price !== undefined &&
    (!Number.isInteger(opts.price) || opts.price < 0)
  )
    throw Error("단가를 확인해주세요.");
  const i = invFor(s, l);
  if (i) {
    voidInvoice(s, i);
  }
  s.audit.push({ line: l.id, before: { ...l }, reason, at: now(s) });
  Object.assign(l, opts, { review: false });
  s.tasks
    .filter(
      (t) => t.ref === l.id && ["수정 요청", "추가 주문"].includes(t.kind),
    )
    .forEach((t) => (t.done = true));
}
export function issue(s, c, country) {
  const ls = linesFor(s, c).filter(
    (l) => !l.invoice && l.session === s.session.id,
  );
  if (!ls.length) throw Error("새로 정산할 주문이 없습니다.");
  if (ls.some((l) => l.review))
    throw Error("한 줄 주문의 색상·사이즈·수량을 먼저 확인해주세요.");
  const subtotal = ls.reduce((a, l) => a + l.qty * l.price, 0),
    eligible = ls
      .filter((l) => !product(s, l.product).excluded)
      .reduce((a, l) => a + l.qty, 0);
  const ship =
    eligible >= s.session.free
      ? 0
      : country === "KR"
        ? s.session.kr
        : Math.round((s.session.cn * s.session.rate) / 100);
  const cust = customer(s, c),
    deposit = Math.min(cust.deposit, subtotal + ship),
    totalK = subtotal + ship - deposit;
  const i = {
    id: id(s, "i"),
    customer: c,
    session: s.session.id,
    sessionTitle: s.session.title,
    created: now(s),
    country,
    shippingRule: { free: s.session.free, kr: s.session.kr, cn: s.session.cn },
    receivers: structuredClone(
      s.receivers.filter((r) => r.active && r.verified),
    ),
    receiverId: "wechat",
    refunds: [],
    rate: s.session.rate,
    subtotal,
    shipping: ship,
    deposit,
    totalK,
    totalC: Math.round((totalK / s.session.rate) * 100),
    currency: "CNY",
    accepted: false,
    items: ls.map((l) => ({
      id: l.id,
      title: l.title,
      color: l.color,
      size: l.size,
      qty: l.qty,
      price: l.price,
    })),
    receipts: [],
    void: false,
  };
  if (!i.receivers.some((r) => r.currency === "CNY")) {
    i.currency = "KRW";
    i.receiverId = i.receivers.find((r) => r.currency === "KRW")?.id;
  }
  i.receiverId = i.receivers.find((r) => r.currency === i.currency)?.id;
  if (!i.receivers.length) throw Error("확인된 수취 방법을 먼저 설정해주세요.");
  cust.deposit -= deposit;
  if (deposit)
    s.depositLedger.push({
      id: id(s, "d"),
      customer: c,
      amount: -deposit,
      kind: "allocated",
      invoice: i.id,
      at: now(s),
    });
  s.invoices.push(i);
  ls.forEach((l) => (l.invoice = i.id));
  return i;
}
export function submitReceipt(s, i, amount, payer) {
  if (
    i.void ||
    !i.receivers.some((r) => r.id === i.receiverId && r.currency === i.currency)
  )
    throw Error("현재 정산서의 수취 방법을 확인해주세요.");
  if (!i.accepted || !customer(s, i.customer).address)
    throw Error("주소와 주문 내용을 먼저 확인해주세요.");
  if (!Number.isInteger(amount) || amount <= 0)
    throw Error("송금액을 확인해주세요.");
  const r = {
    id: id(s, "r"),
    amount,
    payer,
    confirmed: false,
    receiverId: i.receiverId,
    needsInfo: false,
    clarification: "",
    evidence: "가상 캡처",
    ref: null,
  };
  i.receipts.push(r);
  task(s, "입금 확인", i.customer, r.id, "가상 증빙 제출");
  return r;
}
export function confirmReceipt(s, i, r, ref) {
  if (r.confirmed || r.needsInfo)
    throw Error("확인 가능한 증빙 상태가 아닙니다.");
  ref = ref.trim();
  if (!ref) throw Error("실제 수취 거래 식별자를 입력해주세요.");
  if (
    s.invoices.some((v) =>
      v.receipts.some(
        (x) => x.confirmed && x.ref === ref && x.receiverId === r.receiverId,
      ),
    )
  )
    throw Error("이미 확인한 수취 거래입니다.");
  if (
    s.depositLedger.some(
      (d) =>
        d.kind === "received" && d.ref === ref && d.receiverId === r.receiverId,
    )
  )
    throw Error("선입금으로 이미 기록한 거래입니다.");
  r.confirmed = true;
  r.ref = ref;
  s.tasks.filter((t) => t.ref === r.id).forEach((t) => (t.done = true));
}
export function orderSupplier(s) {
  const eligible = s.lines.filter(
    (l) =>
      !l.cancelled &&
      !l.review &&
      l.invoice &&
      settled(invFor(s, l)) &&
      l.po < l.qty,
  );
  if (!eligible.length) throw Error("입금완료된 새 발주 대상이 없습니다.");
  const groups = new Map();
  for (const l of eligible) {
    const key = JSON.stringify([l.supplier, l.product, l.color, l.size]);
    if (!groups.has(key))
      groups.set(key, {
        id: id(s, "po"),
        supplier: l.supplier,
        product: l.product,
        title: l.title,
        color: l.color,
        size: l.size,
        qty: 0,
        arrived: 0,
        events: [],
        created: now(s),
        allocations: [],
      });
    const p = groups.get(key),
      q = l.qty - l.po;
    p.qty += q;
    p.allocations.push({ line: l.id, qty: q, arrived: 0 });
    l.po += q;
  }
  s.pos.push(...groups.values());
}
export function arrive(s, p, qty) {
  if (!Number.isInteger(qty) || qty < 1 || qty > p.qty - p.arrived)
    throw Error("남은 미송 수량 안에서 입력해주세요.");
  let remaining = qty;
  p.arrived += qty;
  p.events.push({ qty, at: now(s) });
  for (const a of [...p.allocations].sort(
    (a, b) =>
      s.lines.find((l) => l.id === a.line).seq -
      s.lines.find((l) => l.id === b.line).seq,
  )) {
    const n = Math.min(remaining, a.qty - a.arrived);
    a.arrived += n;
    s.lines.find((l) => l.id === a.line).arrived += n;
    remaining -= n;
  }
}
export function defect(s, l, qty) {
  if (
    !Number.isInteger(qty) ||
    qty < 1 ||
    qty > l.arrived - l.defect - l.shipped
  )
    throw Error("미출고 정상 입고 수량을 확인해주세요.");
  l.defect += qty;
}
export function ship(s, c, tracking, selections) {
  const cust = customer(s, c);
  if (!cust.address) throw Error("배송주소가 필요합니다.");
  if (!tracking.trim()) throw Error("송장번호가 필요합니다.");
  const selected = Object.entries(selections).filter(([, q]) => q > 0);
  if (!selected.length) throw Error("출고 수량을 선택해주세요.");
  for (const [lid, q] of selected) {
    const l = s.lines.find((x) => x.id === lid);
    if (
      !l ||
      l.customer !== c ||
      !l.invoice ||
      !settled(invFor(s, l)) ||
      !Number.isInteger(q) ||
      q > l.arrived - l.defect - l.shipped
    )
      throw Error("출고 가능한 정상 입고 수량을 확인해주세요.");
  }
  const shipment = {
    id: id(s, "sh"),
    customer: c,
    tracking,
    at: now(s),
    address: structuredClone(cust.address),
    lines: selected.map(([line, qty]) => ({ line, qty })),
    extraShipping: 0,
  };
  for (const [lid, q] of selected)
    s.lines.find((l) => l.id === lid).shipped += q;
  s.shipments.push(shipment);
  return shipment;
}
export function tasks(s) {
  const all = s.tasks.filter((t) => !t.done);
  for (const i of s.invoices.filter(
    (i) =>
      !i.void &&
      !i.receipts.length &&
      due(i) > 0 &&
      now(s) - i.created >= 3 * 86400000,
  ))
    all.push({
      id: i.id,
      kind: "취소 확인 필요",
      customer: i.customer,
      message: "발행 후 3일 미입금 · 자동 취소하지 않음",
      invoice: i,
    });
  const late = new Map();
  for (const p of s.pos.filter((p) => now(s) - p.created > 14 * 86400000))
    for (const a of p.allocations.filter((a) => a.qty > a.arrived)) {
      const l = s.lines.find((l) => l.id === a.line);
      if (!late.has(l.customer)) late.set(l.customer, []);
      late
        .get(l.customer)
        .push(
          `${p.title} ${p.color}/${p.size} ${a.qty - a.arrived}개 · ${p.supplier} · ${Math.floor((now(s) - p.created) / 86400000)}일`,
        );
    }
  for (const [c, items] of late)
    all.push({
      id: `late-${c}`,
      kind: "장기 미송",
      customer: c,
      message: items.join(", "),
    });
  return all;
}

// Detailed design interactions. No persistence, external verification, or real authentication.
export const isOpen = (s) =>
  s.session.status === "open" && now(s) < s.session.closesAt;
export const sessionProducts = (s) =>
  s.products
    .filter((p) => p.session === s.session.id)
    .sort((a, b) => a.publicOrder - b.publicOrder);
export function voidInvoice(s, i) {
  if (i.void) return;
  if (i.receipts.length) throw Error("송금 진행 청구는 재발행할 수 없습니다.");
  i.void = true;
  customer(s, i.customer).deposit += i.deposit;
  if (i.deposit)
    s.depositLedger.push({
      id: id(s, "d"),
      customer: i.customer,
      amount: i.deposit,
      kind: "reversed",
      invoice: i.id,
      at: now(s),
    });
  s.lines.filter((l) => l.invoice === i.id).forEach((l) => (l.invoice = null));
}
export function recordDeposit(s, c, amount, ref, verified) {
  ref = ref.trim();
  if (!verified || !Number.isInteger(amount) || amount <= 0 || !ref)
    throw Error("실제 수취 금액과 거래 식별자를 확인해주세요.");
  if (
    s.depositLedger.some(
      (d) => d.kind === "received" && d.ref === ref && d.receiverId === "bank",
    ) ||
    s.invoices.some((i) =>
      i.receipts.some(
        (r) => r.confirmed && r.ref === ref && r.receiverId === "bank",
      ),
    )
  )
    throw Error("이미 사용한 수취 거래입니다.");
  customer(s, c).deposit += amount;
  s.depositLedger.push({
    id: id(s, "d"),
    customer: c,
    amount,
    kind: "received",
    ref,
    receiverId: "bank",
    at: now(s),
  });
}
export function requestInfo(s, i, r, reason) {
  if (r.confirmed || !reason.trim())
    throw Error("확인 전 증빙과 요청 사유를 확인해주세요.");
  r.needsInfo = true;
  r.clarification = reason;
}
export function replaceEvidence(s, i, r, stored) {
  if (!r.needsInfo || !stored)
    throw Error("보완 증빙을 저장한 뒤 제출해주세요.");
  r.needsInfo = false;
  r.evidence = "가상 보완 캡처";
}
export function requestRefund(s, i, amount, reason) {
  const reserved = i.refunds.reduce((a, r) => a + r.amount, 0);
  if (
    !reason.trim() ||
    !Number.isInteger(amount) ||
    amount <= 0 ||
    amount > sumPaid(i) - due(i) - reserved
  )
    throw Error("아직 환불하지 않은 초과 수취액 안에서 입력해주세요.");
  const r = { id: id(s, "rf"), amount, reason, confirmed: false, ref: null };
  i.refunds.push(r);
  task(s, "환불 확인", i.customer, i.id, "초과금 실제 환불 후 거래 기록 확인");
  return r;
}
export function confirmRefund(s, i, r, ref, verified) {
  if (!verified || !ref.trim() || r.confirmed)
    throw Error("실제 환불 거래를 확인해주세요.");
  if (
    s.invoices.some((v) =>
      v.refunds.some((x) => x.confirmed && x.ref === ref.trim()),
    )
  )
    throw Error("이미 기록한 환불 거래입니다.");
  r.confirmed = true;
  r.ref = ref.trim();
  r.at = now(s);
  if (i.refunds.every((x) => x.confirmed))
    s.tasks
      .filter((t) => t.ref === i.id && t.kind === "환불 확인")
      .forEach((t) => (t.done = true));
}
export function changeAddress(s, c, address, reason, isStaff = false) {
  const active = currentInvoices(s, c);
  if (!active.length) throw Error("정산서 발행 후 주소를 받습니다.");
  if (!reason.trim()) throw Error("변경 사유가 필요합니다.");
  const inProgress = active.some((i) => i.receipts.length || settled(i));
  if (!isStaff && inProgress)
    throw Error("입금 진행 이후에는 판매자에게 요청해주세요.");
  const changedCountry = active.filter((i) => i.country !== address.country);
  if (inProgress && changedCountry.length)
    throw Error(
      "입금 후 국가 변경은 배송비 예외 검토가 필요합니다. 이 화면에서는 같은 국가의 주소만 정정합니다.",
    );
  changedCountry.forEach((i) => voidInvoice(s, i));
  s.audit.push({
    customer: c,
    before: structuredClone(customer(s, c).address),
    after: structuredClone(address),
    reason,
    at: now(s),
  });
  customer(s, c).address = structuredClone(address);
  if (!inProgress) active.forEach((i) => (i.accepted = false));
  task(
    s,
    "주소 변경",
    c,
    c,
    reason +
      (changedCountry.length
        ? " · 국가 변경으로 재발행 필요"
        : " · 이후 출고에 적용"),
  );
}
export function requestDevice(s, c) {
  if (s.devices[c] === "pending") return;
  s.devices[c] = "pending";
  task(s, "기기 확인", c, c, "기존 위챗 연락처에서 본인 확인 필요");
}
export function approveDevice(s, c, verified) {
  if (!verified || s.devices[c] !== "pending")
    throw Error("기존 위챗 연락 경로에서 본인을 확인해주세요.");
  s.devices[c] = "approved";
  s.tasks
    .filter((t) => t.kind === "기기 확인" && t.customer === c)
    .forEach((t) => (t.done = true));
}
export function exportRows(s, kind, supplier = "") {
  if (kind === "supplier")
    return {
      headers: [
        "거래처",
        "제품명",
        "컬러",
        "사이즈",
        "발주수량",
        "이번 입고수량",
        "누적 입고수량",
        "남은 미송수량",
        "메모",
      ],
      rows: s.pos
        .filter((p) => !supplier || p.supplier === supplier)
        .map((p) => [
          p.supplier,
          p.title,
          p.color,
          p.size,
          p.qty,
          p.events.at(-1)?.qty ?? 0,
          p.arrived,
          p.qty - p.arrived,
          p.note ?? "",
        ]),
    };
  return {
    headers: [
      "주문순번",
      "거래처",
      "제품명",
      "컬러",
      "사이즈",
      "수량",
      "주문자명",
      "입금확인",
      "현재상태",
      "메모",
    ],
    rows: s.lines
      .filter((l) => !l.cancelled)
      .map((l) => [
        l.seq,
        l.supplier,
        l.title,
        l.color,
        l.size,
        l.qty ?? "확인 필요",
        customer(s, l.customer).name,
        settled(invFor(s, l)) ? "완료" : "미완료",
        l.shipped === l.qty
          ? "출고완료"
          : l.shipped
            ? "부분출고"
            : l.defect
              ? "불량교환"
              : l.po > l.arrived
                ? "미송"
                : l.arrived
                  ? "입고"
                  : "주문접수",
        l.note,
      ]),
  };
}
