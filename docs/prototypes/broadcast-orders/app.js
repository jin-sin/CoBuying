import * as D from "./domain.js";
import { createDetails } from "./details.js";
let s = D.fresh();
const ui = {
  role: "staff",
  tab: "home",
  customer: "c1",
  search: "",
  selected: null,
  product: "p1",
  color: "검정",
  size: "M",
  staffDemo: "none",
};
const app = document.querySelector("#app"),
  dialog = document.querySelector("#dialog");
const e = (v) =>
  String(v ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
const money = (n, c = "KRW") =>
  c === "KRW"
    ? `₩${Math.round(n).toLocaleString("ko-KR")}`
    : `¥${(n / 100).toFixed(2)}`;
const btn = (label, act, id = "", cls = "") =>
  `<button class="${cls}" data-act="${act}" data-id="${e(id)}">${label}</button>`;
const input = (label, name, value = "", type = "text", extra = "") =>
  `<label>${label}<input name="${name}" type="${type}" value="${e(value)}" ${extra}></label>`;
const select = (label, name, opts, value) =>
  `<label>${label}<select name="${name}">${opts.map(([id, name]) => `<option value="${e(id)}" ${id === value ? "selected" : ""}>${e(name)}</option>`).join("")}</select></label>`;
const check = (label, name, checked = false) =>
  `<label><input name="${name}" type="checkbox" ${checked ? "checked" : ""}>${label}</label>`;
const empty = (text) => `<p class="empty">${text}</p>`;
const cust = () => D.customer(s, ui.customer);
const detail = createDetails({
  state: () => s,
  ui,
  e,
  money,
  btn,
  input,
  select,
  check,
  modal,
  toast,
  render,
});
function toast(text) {
  if (dialog.open) {
    let error = dialog.querySelector(".dialog-error");
    if (!error) {
      error = document.createElement("p");
      error.className = "notice dialog-error";
      error.setAttribute("role", "alert");
      dialog.prepend(error);
    }
    error.textContent = text;
  }
  const t = document.querySelector("#toast");
  t.textContent = text;
  t.classList.add("show");
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => t.classList.remove("show"), 4500);
}
function modal(title, form, content, id = "") {
  dialog.innerHTML = `<div class="row between"><h2>${title}</h2>${btn("닫기", "close")}</div><form data-form="${form}" data-id="${e(id)}">${content}<button class="primary full" type="submit">저장</button></form>`;
  dialog.showModal();
}
function staffDemo() {
  const status = {
    none: "아직 참여 코드를 만들지 않았습니다.",
    invited: "30분 일회용 코드가 생성됐습니다. 담당자에게 직접 전달하세요.",
    joined: "보조 담당자가 기존 계정으로 참여했습니다. 방송 주문 접근이 활성화됐습니다.",
    removed: "관리자가 접근을 회수했습니다. 이전 코드는 다시 사용할 수 없습니다.",
  }[ui.staffDemo];
  dialog.innerHTML = `<div class="row between"><h2>보조 담당자 참여 체험</h2>${btn("닫기", "close")}</div><p>${status}</p>${ui.staffDemo === "invited" ? "<p>예시 코드: 11111111-1111-4111-8111-111111111111</p>" : ""}<div class="row">${ui.staffDemo === "none" || ui.staffDemo === "removed" ? btn("참여 코드 만들기", "staff-demo-create") : ""}${ui.staffDemo === "invited" ? btn("보조 참여", "staff-demo-join") : ""}${ui.staffDemo === "joined" ? btn("접근 회수", "staff-demo-remove") : ""}</div><p class="muted">시안의 가상 전환입니다. 실제 JWT·참여 링크·만료 검증은 B01 서버 시험 대상입니다.</p>`;
  if (!dialog.open) dialog.showModal();
}
function header() {
  return `<header><span class="brand">ORENDAM</span><div class="row between"><h1>${ui.role === "staff" ? "방송부터 출고까지" : "내 방송 주문"}</h1><span class="tag">${e(s.session.title)}</span></div><p class="muted">${ui.role === "staff" ? "더우인 채팅을 한 번 입력하고, 같은 주문으로 끝까지 관리하세요." : s.devices[ui.customer] === "active" ? `${e(cust().name)}님 · 방송 후 천천히 확인해주세요.` : "고객 전용 페이지 · 기기 확인 필요"}</p></header>`;
}
function render() {
  const pages = {
    home: ["처리할 일", home],
    capture: ["빠른 주문 입력", capture],
    sessions: ["방송 회차", detail.sessions],
    catalog: ["방송·상품", catalog],
    customers: ["고객·정산", customers],
    payments: ["입금 확인", payments],
    purchase: ["거래처 발주", purchase],
    fulfill: ["입고·출고", fulfill],
    exports: ["관리표 내보내기", detail.exportsPage],
    receivers: ["수취 설정", detail.receivers],
  };
  app.innerHTML =
    header() +
    (ui.role === "staff" || s.devices[ui.customer] === "active"
      ? `<div class="session-picker">${select(
          "선택한 방송",
          "active-session",
          s.sessions.map((v) => [v.id, v.title]),
          s.session.id,
        )}</div>`
      : "") +
    (ui.role === "staff"
      ? `<div class="layout"><nav class="nav" aria-label="운영 메뉴">${Object.entries(
          pages,
        )
          .map(([id, [label]]) =>
            btn(label, "tab", id, ui.tab === id ? "active" : ""),
          )
          .join("")}</nav><main>${pages[ui.tab][1]()}</main></div>`
      : `<main class="customer">${customerScreen()}</main>`);
  document.querySelector("#demo-customer").innerHTML = s.customers
    .map((c) => `<option value="${c.id}">${e(c.name)}</option>`)
    .join("");
  document.querySelector("#demo-customer").value = ui.customer;
}
function home() {
  const tasks = D.tasks(s);
  return `<div class="stats"><div class="stat">처리할 일<b>${tasks.length}</b></div><div class="stat">선택 방송 접수<b>${s.lines.filter((l) => l.session === s.session.id).length}</b></div><div class="stat">미송 수량<b>${s.pos.reduce((a, p) => a + p.qty - p.arrived, 0)}</b></div></div><div class="card"><h2>다음 고객 주문을 바로 입력하세요</h2><p>상품과 옵션을 유지하고 고객만 바꿔 저장합니다. 이전 상품 입력 중에도 다음 소개를 이어갈 수 있습니다.</p>${btn("빠른 입력 열기", "tab", "capture", "primary")}</div><div class="card"><h2>보조 담당자</h2><p>판매자가 30분 일회용 코드를 만들고 보조의 기존 로그인 계정에 권한을 연결합니다.</p>${btn("담당자 참여 체험", "staff-demo")}</div><h2>처리할 일</h2>${tasks.length ? tasks.map((t) => `<article class="card task"><div class="row between"><strong>${e(D.customer(s, t.customer).name)} · ${e(t.kind)}</strong><span class="tag">처리 대기</span></div><p>${e(t.message)}</p>${t.kind === "취소 확인 필요" ? btn("미입금 취소 검토", "cancel-invoice", t.invoice.id) : t.kind === "장기 미송" ? btn("입고 확인", "tab", "fulfill") : btn("업무 열기", "open-task", t.id)}</article>`).join("") : empty("현재 처리할 일이 없습니다. 읽음으로 지우지 않고 업무 완료 후 정리합니다.")}`;
}
function capture() {
  return `<section class="card"><h2>방송 주문 빠른 입력</h2>${!D.isOpen(s) ? '<p class="notice">주문 접수가 마감되었거나 아직 시작 전입니다. 방송 회차에서 설정해주세요.</p>' : ""}<form data-form="capture">${input("고객 닉네임 검색", "search", ui.search, "search", 'id="customer-search" autocomplete="off" placeholder="몽"')}<div id="candidates">${candidates()}</div><p>${btn("새 고객 등록", "new-customer")}</p>${select(
    "상품",
    "product",
    D.sessionProducts(s)
      .filter((p) => !p.deleted)
      .map((p) => [p.id, `${p.number}번 ${p.title} · ${money(p.price)}`]),
    ui.product,
  )}<div class="two">${input("컬러", "color", ui.color)}${input("사이즈", "size", ui.size)}</div>${input("수량", "qty", 1, "number", 'min="1" max="999" required')}${input("특이사항 (선택)", "note")}<button type="submit" class="primary full">주문 1건 저장</button></form><p class="muted">동일 고객·상품·옵션의 재주문도 별도 행입니다.</p></section><section class="card"><h3>최근 접수</h3>${
    s.lines
      .filter((l) => l.session === s.session.id)
      .slice(-5)
      .reverse()
      .map((l) => line(l))
      .join("") || empty("아직 접수된 주문이 없습니다.")
  }</section>`;
}
function candidates() {
  return ui.search.trim()
    ? s.customers
        .filter((c) => c.name.includes(ui.search.trim()))
        .map(
          (c) =>
            `<button type="button" class="candidate ${ui.selected === c.id ? "selected" : ""}" data-act="select-customer" data-id="${c.id}">${e(c.name)} · ${e(c.wechat)} ${ui.selected === c.id ? "✓" : ""}</button>`,
        )
        .join("") || "<p>고객을 찾지 못했습니다. 새 고객을 등록해주세요.</p>"
    : "<small>닉네임 일부로 검색해주세요. 동일 닉네임은 위챗 관리 정보로 구분합니다.</small>";
}
function line(l, customer = false) {
  const remain = (l.qty ?? 0) - l.shipped,
    status = l.cancelled
      ? "취소"
      : l.shipped > 0
        ? remain > 0
          ? "부분 출고"
          : "출고 완료"
        : l.invoice && D.settled(D.invFor(s, l))
          ? "상품 준비 중"
          : l.invoice
            ? "입금 확인"
            : "주문 확인";
  return `<article class="line"><div class="row between"><strong>${customer ? "" : e(D.customer(s, l.customer).name) + " · "}${l.number}번 ${e(l.title)}</strong><span class="tag">${status}</span></div><p>${l.review ? `${e(l.raw)} · 옵션 확인 필요` : `${e(l.color)} / ${e(l.size)} / ${l.qty}개 · ${money(l.price * (l.qty ?? 0))}`}</p>${customer && s.audit.some((a) => a.line === l.id) ? '<p class="notice">담당자가 변경한 최종 내용입니다. 정산서를 다시 확인해주세요.</p>' : ""}${!customer ? `<small>#${l.seq} · ${l.source === "broadcast_assistant" ? "방송 보조 입력" : l.source === "customer_addition" ? "고객 직접 추가" : "판매자 입력"} · ${new Date(l.created).toLocaleTimeString("ko-KR")}</small>` : ""}<div class="row">${!l.cancelled && !D.blocked(s, l) ? btn(customer ? "수정 요청" : "주문 정정", customer ? "request-change" : "edit-line", l.id) : ""}</div></article>`;
}
function catalog() {
  return `<div class="card"><div class="row between"><h2>방송 설정</h2>${btn("설정 변경", "settings")}</div><p>${s.session.kind === "new" ? "신상 · 사전등록" : "특가 · 현장등록"} · 1위안 = ${s.session.rate}원</p><p>한국 ${money(s.session.kr)} / 중국 ${money(s.session.cn, "CNY")} · ${s.session.free}장 택포 · 이후 ${s.session.days}일 접수</p></div><div class="row between"><h2>상품 준비와 공개</h2>${btn("상품 빠른 등록", "new-product", "", "primary")}</div><p class="muted">사진 없이 번호·이름으로 구분합니다. 현재 코디는 여러 상품을 선택할 수 있습니다.</p><div class="grid">${D.sessionProducts(
    s,
  )
    .map(
      (p) =>
        `<article class="card"><span class="number">${p.number}번</span><h3>${e(p.title)}</h3><p>${money(p.price)} · ${e(p.supplier)}</p><p>${p.excluded ? "택포 수량 제외" : "택포 수량 포함"}</p><div class="row">${p.deleted ? btn("삭제 상품 복구", "restore-product", p.id) : btn(p.visible ? "공개 중 · 숨기기" : "고객에게 공개", "publish", p.id, p.visible ? "" : "primary")}${p.visible ? btn(p.outfit ? "현재 코디에서 빼기" : "현재 코디에 추가", "outfit", p.id) : ""}${!p.deleted && D.sessionProducts(s).filter((x) => !x.deleted)[0]?.id !== p.id ? btn("공개 순서 위로", "move-product", p.id) : ""}${!s.lines.some((l) => l.product === p.id) ? (p.deleted ? "<small>삭제됨 · 번호 보존</small>" : btn("상품 수정", "edit-product", p.id) + btn("삭제", "delete-product", p.id)) : "<small>접수 이력 있음 · 주문은 고객별 정정</small>"}</div></article>`,
    )
    .join("")}</div>`;
}
function customerPicker() {
  return select(
    "관리할 고객",
    "staff-customer",
    s.customers.map((c) => [c.id, c.name]),
    ui.customer,
  );
}
function customers() {
  const c = cust(),
    ls = s.lines.filter((l) => l.customer === c.id);
  return `<div class="card">${customerPicker()}<div class="row between"><h2>${e(c.name)}</h2>${btn("고정 링크 안내", "link")}</div><p>${e(c.wechat)} · 남은 확인 선입금 ${money(c.deposit)}</p><p class="muted">주소는 정산서 발행 후 받습니다.</p>${btn("고객 추가", "new-customer")}${detail.customerTools()}</div><section class="card"><h2>고객 주문 원장 · 전체 방송</h2><p class="muted">청구 버튼은 선택한 방송의 미정산 주문만 포함합니다.</p>${ls.map((l) => line(l)).join("") || empty("주문이 없습니다.")}<p>${btn("미정산 주문 청구하기", "issue", "", "primary")}</p></section>${D.currentInvoices(
    s,
    c.id,
  )
    .map((i) => invoiceCard(i, false))
    .join("")}`;
}
function invoiceCard(i, isCustomer) {
  const paid = D.netPaid(i),
    target = D.due(i);
  return `<section class="card"><div class="row between"><h2>정산서 ${i.id}</h2><small>${e(i.sessionTitle)}</small><span class="tag">${D.settled(i) ? (paid > target ? "초과 입금 · 환불 확인" : "입금 완료") : i.receipts.some((r) => !r.confirmed) ? "입금 확인 대기" : paid ? "추가 입금 필요" : "입금 대기"}</span></div>${i.items.map((l) => `<div class="line">${e(l.title)} · ${e(l.color)}/${e(l.size)} · ${l.qty}개 <strong>${money(l.qty * l.price)}</strong></div>`).join("")}<p>상품 ${money(i.subtotal)} + 배송 ${money(i.shipping)}</p><p>선입금 차감 −${money(i.deposit)}</p><div class="total">${money(i.totalK)} <small>또는</small> ${money(i.totalC, "CNY")}</div><small>1위안 = ${i.rate}원 · 두 통화 중 하나로 송금</small><p>확인된 수취 ${money(D.sumPaid(i), i.currency)} / 남은 금액 ${money(Math.max(0, target - paid), i.currency)}</p>${paid > target ? `<div class="notice">초과 ${money(paid - target, i.currency)} · 판매자가 실제 환불 후 별도로 기록해야 합니다.</div>` : ""}${detail.paymentDetails(i, isCustomer)}${isCustomer ? paymentActions(i) : `<p>선입금 ${money(i.deposit)}를 이 청구에 배분했습니다. 기존 청구를 변경할 때는 재발행합니다.</p>`}</section>`;
}
function paymentActions(i) {
  const c = cust();
  if (D.settled(i))
    return `<p>입금을 확인했습니다.</p><p>배송지: ${e(c.address?.detail)}</p><small>주소 변경은 기존 위챗으로 판매자에게 요청해주세요.</small>`;
  return `${!c.address ? `<div class="notice">정산서가 발행되었습니다. 배송주소를 입력해주세요.</div>${btn("배송주소 입력", "address", i.id, "primary")}` : `<p>배송지: ${e(c.address.detail)}</p>${i.receipts.length ? "" : btn("배송주소 수정", "address", i.id)}`}<div class="notice">제품명·컬러·사이즈·수량을 확인해주세요. 입금 후에는 상품 변경 및 취소가 불가능합니다.</div>${
    !i.accepted
      ? `<form data-form="accept" data-id="${i.id}">${check("주문 내용과 입금 후 변경·취소 불가 안내를 확인했습니다.", "agree")}<p><button class="primary" type="submit">확인하고 송금 안내 열기</button></p></form>`
      : `<div class="notice">시안 송금 안내 · 실제 수취 계정은 연결되지 않았습니다.</div>${
          i.receipts.length
            ? ""
            : select(
                "송금할 통화",
                `currency-${i.id}`,
                [
                  ["CNY", "CNY · 위안"],
                  ["KRW", "KRW · 원"],
                ],
                i.currency,
              )
        }${detail.receiverGuide(i)}${btn("가상 캡처로 입금 확인 요청", "evidence", i.id, "primary")}`
  }`;
}
function payments() {
  return `<h2>수취 내역을 직접 확인해주세요</h2><p class="muted">캡처 제출만으로 입금 완료가 되지 않습니다. 대리 송금도 가능합니다.</p>${
    s.invoices
      .filter((i) => !i.void)
      .map(
        (i) =>
          `<section class="card"><h3>${e(D.customer(s, i.customer).name)} · ${i.id}</h3><p>청구 ${money(D.due(i), i.currency)} · 확인 ${money(D.sumPaid(i), i.currency)}</p>${i.receipts.map((r) => `<article class="line"><strong>${money(r.amount, i.currency)}</strong> · 송금자 ${e(r.payer)}<p>가상 증빙 · ${r.confirmed ? "수취 확인 완료" : "실제 수취 대조 필요"}</p>${r.confirmed ? "" : r.needsInfo ? "보완 제출 대기" : btn("수취 확인", "confirm-receipt", `${i.id}/${r.id}`, "primary") + btn("추가 확인 요청", "request-info", `${i.id}/${r.id}`)}</article>`).join("") || empty("제출된 증빙이 없습니다.")}${detail.paymentDetails(i)}</section>`,
      )
      .join("") || empty("발행된 정산서가 없습니다.")
  }`;
}
function purchase() {
  return `<div class="card"><h2>거래처별 합산 발주</h2><p>입금완료된 미발주 수량만 모읍니다. 같은 옵션의 주문 원본은 그대로 남습니다.</p>${btn("입금완료 주문 합산 발주", "purchase", "", "primary")}</div>${s.pos.map((p) => `<article class="card"><h3>${e(p.supplier)} · ${e(p.title)}</h3><p>${e(p.color)} / ${e(p.size)}</p><div class="row"><span>발주 ${p.qty}</span><span>최근 입고 ${p.events.at(-1)?.qty ?? 0}</span><span>누적 ${p.arrived}</span><strong>미송 ${p.qty - p.arrived}</strong></div></article>`).join("") || empty("발주 내역이 없습니다.")}<div class="card"><h3>고객관리표 · 내부 전용</h3><div class="scroll"><table><thead><tr><th>주문자</th><th>거래처·상품</th><th>옵션</th><th>주문</th><th>입고/불량/출고</th></tr></thead><tbody>${s.lines
    .filter((l) => !l.cancelled)
    .map(
      (l) =>
        `<tr><td>${e(D.customer(s, l.customer).name)}</td><td>${e(l.supplier)} / ${e(l.title)}</td><td>${e(l.color)}/${e(l.size)}</td><td>${l.qty ?? "확인"}</td><td>${l.arrived}/${l.defect}/${l.shipped}</td></tr>`,
    )
    .join(
      "",
    )}</tbody></table></div><small>거래처 발주표에는 위 고객 이름을 포함하지 않습니다. 실제 XLSX는 B05 구현 대상입니다.</small><p>${btn("관리표 내보내기", "tab", "exports")}</p></div>`;
}
function fulfill() {
  return `<h2>입고·미송</h2>${s.pos.map((p) => `<article class="card"><h3>${e(p.supplier)} · ${e(p.title)} ${e(p.color)}/${e(p.size)}</h3><p>발주 ${p.qty} · 누적 입고 ${p.arrived} · 미송 ${p.qty - p.arrived}</p>${p.qty > p.arrived ? btn("부분 입고 등록", "arrival", p.id, "primary") : ""}<small>원 주문 순서로 배정합니다.</small></article>`).join("") || empty("먼저 입금완료 주문을 발주해주세요.")}<div class="card">${customerPicker()}<h2>고객 출고 준비</h2>${D.linesFor(
    s,
    ui.customer,
  )
    .map(
      (l) =>
        `<article class="line"><strong>${l.number}번 ${e(l.title)} ${e(l.color)}/${e(l.size)}</strong><p>주문 ${l.qty ?? "?"} · 미송 ${l.po - l.arrived} · 불량교환 ${l.defect} · 출고 ${l.shipped}</p><div class="row">${l.arrived - l.defect - l.shipped > 0 ? btn("불량교환 분리", "defect", l.id) : ""}${l.defect > 0 ? btn("교환 입고 확인", "exchange", l.id) : ""}</div></article>`,
    )
    .join(
      "",
    )}${btn("출고 상품·수량 선택", "shipment", "", "primary")}<p class="muted">추가 분리배송비는 판매자가 부담합니다. 출고 영상은 기존 위챗으로 보냅니다.</p></div>${shipments(false)}`;
}
function shipments(customer) {
  return s.shipments
    .filter((sh) => sh.customer === ui.customer)
    .map(
      (sh) =>
        `<article class="card"><h3>${new Date(sh.at).toLocaleDateString("ko-KR")} · 출고 ${sh.id}</h3>${sh.lines
          .map((a) => {
            const l = s.lines.find((l) => l.id === a.line);
            return `<p>${e(l.title)} ${e(l.color)}/${e(l.size)} · ${a.qty}개</p>`;
          })
          .join(
            "",
          )}<p>송장 <strong>${e(sh.tracking)}</strong></p><small>출고 당시 주소: ${e(sh.address.detail)} · 추가 고객 배송비 0원</small></article>`,
    )
    .join("");
}
function customerScreen() {
  const gate = detail.gate();
  if (gate) return gate;
  const ps = D.sessionProducts(s).filter((p) => p.visible && !p.deleted),
    ls = D.linesFor(s, ui.customer);
  return `<div class="notice">이 화면은 인증을 대신하는 시안 체험입니다. 실제 고정 링크는 등록된 기기에서만 개인 주문을 엽니다.</div>${s.tasks
    .filter((t) => t.customer === ui.customer && t.resolution)
    .map((t) => `<p class="notice">수정 요청 안내: ${e(t.resolution)}</p>`)
    .join("")}<h2>현재 코디</h2><div class="grid">${
    ps
      .filter((p) => p.outfit)
      .map((p) => productCard(p))
      .join("") || empty("현재 코디를 준비하고 있습니다.")
  }</div><h2>이 방송에서 소개한 상품</h2><p class="muted">추가주문 마감: ${new Date(s.session.closesAt).toLocaleString("ko-KR")}</p>${ps.map((p) => productCard(p)).join("")}<section class="card"><h2>내 주문</h2>${ls.map((l) => line(l, true)).join("") || empty("접수된 주문이 없습니다.")}<p class="muted">미송·교환을 포함한 준비 과정은 ‘상품 준비 중’으로 안내합니다.</p></section>${D.currentInvoices(
    s,
    ui.customer,
  )
    .map((i) => invoiceCard(i, true))
    .join(
      "",
    )}<h2>이번에 출고된 상품</h2>${shipments(true) || empty("아직 출고 내역이 없습니다.")}<div class="card"><h3>아직 남은 상품</h3>${
    ls
      .filter((l) => (l.qty ?? 0) > l.shipped)
      .map(
        (l) =>
          `<p>${e(l.title)} ${e(l.color)}/${e(l.size)} · ${(l.qty ?? 0) - l.shipped}개</p>`,
      )
      .join("") || "<p>남은 상품이 없습니다.</p>"
  }</div>`;
}
function productCard(p) {
  return `<article class="card"><span class="number">${p.number}번</span><h3>${e(p.title)}</h3><p>${money(p.price)} / ${money(Math.round((p.price / s.session.rate) * 100), "CNY")}</p>${D.isOpen(s) ? btn("한 줄로 추가 주문", "add", p.id) : "<p>집중 주문 기간 종료 · 판매자 문의</p>"}</article>`;
}
function productForm(p) {
  return (
    input("거래처", "supplier", p?.supplier ?? "", "text", "required") +
    input("짧은 제품명", "title", p?.title ?? "", "text", "required") +
    input("가격 (원)", "price", p?.price ?? "", "number", 'min="0" required') +
    input("기본 컬러", "color", p?.color ?? "") +
    input("기본 사이즈", "size", p?.size ?? "FREE") +
    check("택포 계산에서 제외", "excluded", p?.excluded) +
    check("수량 제한 있음 (자동 품절은 후속)", "limited", p?.limited) +
    input(
      "판매 가능 수량",
      "available",
      p?.available ?? "",
      "number",
      'min="0"',
    )
  );
}
function resolveTask(t) {
  if (t.kind === "기기 확인") {
    detail.click("approve-device", t.customer);
    return;
  }
  if (["입금 확인", "환불 확인"].includes(t.kind)) {
    ui.customer = t.customer;
    ui.tab = "payments";
    render();
  } else if (["수정 요청", "추가 주문"].includes(t.kind)) {
    ui.customer = t.customer;
    ui.tab = "customers";
    render();
    document
      .querySelector(`[data-act="edit-line"][data-id="${t.ref}"]`)
      ?.click();
  } else if (t.kind === "주소 변경") {
    modal(
      "주소 변경 확인",
      "resolve-address",
      `<p>${e(t.message)}</p>${check("새 주소를 확인했습니다.", "checked")}`,
      t.id,
    );
  }
}
document.addEventListener("click", (ev) => {
  const b = ev.target.closest("[data-act]");
  if (!b) return;
  if (b.closest("form")) ev.preventDefault();
  const a = b.dataset.act,
    id = b.dataset.id;
  try {
    if (detail.click(a, id, b)) return;
    if (a === "role") {
      ui.role = b.dataset.value;
      render();
      return;
    }
    if (a === "staff-demo") {
      staffDemo();
      return;
    }
    if (["staff-demo-create", "staff-demo-join", "staff-demo-remove"].includes(a)) {
      ui.staffDemo = {"staff-demo-create": "invited", "staff-demo-join": "joined", "staff-demo-remove": "removed"}[a];
      staffDemo();
      return;
    }
    if (a === "tab") {
      ui.tab = id;
      render();
      return;
    }
    if (a === "close") {
      dialog.close();
      return;
    }
    if (a === "select-customer") {
      ui.selected = id;
      document.querySelector("#candidates").innerHTML = candidates();
      return;
    }
    if (a === "reset") {
      s = D.fresh();
      ui.staffDemo = "none";
      ui.product = "p1";
      ui.customer = "c1";
      ui.selected = null;
      ui.search = "";
      render();
      return;
    }
    if (a === "seed") {
      s = D.fresh();
      s.depositLedger = [];
      s.session.free = 99;
      s.customers[0].deposit = 0;
      s.products[0].price = 6000;
      D.addLine(s, "c1", "p1", { color: "검정", size: "M", qty: 10 });
      D.issue(s, "c1", "KR");
      D.addLine(s, "c2", "p1", { color: "검정", size: "M", qty: 1 });
      D.issue(s, "c2", "KR");
      ui.product = "p1";
      ui.selected = null;
      ui.search = "";
      ui.customer = "c1";
      ui.tab = "customers";
      render();
      toast("몽이맘 320위안 청구 · 300+20 입금과 10중6 입고를 체험하세요.");
      return;
    }
    if (a === "advance") {
      s.tick += 15;
      ui.tab = "home";
      ui.role = "staff";
      render();
      return;
    }
    if (a === "new-customer") {
      modal(
        "고객 등록",
        "customer",
        input("더우인 닉네임", "name", "", "text", "required") +
          input("위챗 관리 정보", "wechat") +
          "<p>주소는 정산서 발행 후, 선입금은 실제 수취 확인 후 따로 기록합니다.</p>",
      );
      return;
    }
    if (a === "new-product" || a === "edit-product") {
      const p = s.products.find((p) => p.id === id);
      modal(
        p ? "상품 수정" : "상품 빠른 등록",
        "product",
        productForm(p) +
          (p
            ? "<p>수정 후 비공개로 돌아갑니다. 변경 내용을 확인한 뒤 다시 공개해주세요.</p>"
            : ""),
        id,
      );
      return;
    }
    if (a === "delete-product") {
      const p = D.product(s, id);
      if (s.lines.some((l) => l.product === id))
        throw Error("접수 이력이 있어 삭제할 수 없습니다.");
      p.deleted = true;
      p.visible = false;
      p.outfit = false;
    }
    if (a === "restore-product") {
      const p = D.product(s, id);
      p.deleted = false;
      p.visible = false;
      p.outfit = false;
    }
    if (a === "publish") {
      const p = D.product(s, id);
      if (p.deleted) throw Error("복구 후 공개해주세요.");
      p.visible = !p.visible;
      if (!p.visible) p.outfit = false;
    }
    if (a === "outfit") {
      const p = D.product(s, id);
      if (!p.visible) throw Error("먼저 공개해주세요.");
      p.outfit = !p.outfit;
    }
    if (a === "link") {
      modal(
        "고객 고정 링크",
        "close-form",
        '<p>예시: /broadcast/c/무작위고객식별자</p><p>같은 등록 기기에서는 계속 사용합니다. 새 기기는 기존 위챗 연락 경로로 확인 후 일회용 활성화 링크를 받습니다.</p><div class="notice">현재 시안은 실제 고객 링크를 발급하지 않습니다. 고정 주소만 아는 사람에게 주문·주소를 공개하지 않습니다.</div>',
      );
      return;
    }
    if (a === "add") {
      const p = D.product(s, id);
      modal(
        `${p.number}번 ${e(p.title)} 추가`,
        "addition",
        input(
          "컬러·사이즈·수량을 한 줄로",
          "raw",
          "",
          "text",
          'placeholder="검정 M 하나" required',
        ) +
          '<p class="muted">그대로 접수하고 담당자가 정산 전에 확인합니다.</p>',
        id,
      );
      return;
    }
    if (a === "edit-line") {
      const l = s.lines.find((l) => l.id === id);
      if (D.blocked(s, l)) throw Error("송금 진행 중에는 수정할 수 없습니다.");
      modal(
        "주문 정정",
        "edit-line",
        `<p>원 접수: ${e(l.original.raw || `${l.original.color}/${l.original.size} ${l.original.qty}개`)}</p>` +
          input(
            "단가 정정 (원)",
            "price",
            l.price,
            "number",
            'min="0" required',
          ) +
          input("컬러", "color", l.color) +
          input("사이즈", "size", l.size) +
          input(
            "수량",
            "qty",
            l.qty ?? 1,
            "number",
            'min="1" max="999" required',
          ) +
          input(
            "수정 사유",
            "reason",
            l.review ? "한 줄 추가주문 확인" : "",
            "text",
            "required",
          ) +
          check("이 상품 취소", "cancelled", l.cancelled) +
          "<p>이미 발행된 미입금 청구서는 무효화하며 새 정산서를 발행해야 합니다.</p>",
        id,
      );
      return;
    }
    if (a === "request-change") {
      const l = s.lines.find((l) => l.id === id);
      if (D.blocked(s, l)) throw Error("입금 이후 변경할 수 없습니다.");
      modal(
        "주문 수정 요청",
        "change",
        input(
          "원하는 변경 또는 취소 내용",
          "reason",
          "",
          "text",
          'placeholder="M을 L로 바꿔주세요" required',
        ) + check("아직 송금하지 않았습니다.", "unpaid"),
        id,
      );
      return;
    }
    if (a === "issue") {
      modal(
        "미정산 주문 청구",
        "issue",
        select(
          "배송 국가",
          "country",
          [
            ["CN", "중국"],
            ["KR", "한국"],
          ],
          "CN",
        ) +
          "<p>전체 주소는 발행 후 고객이 입력합니다. 국가에 따라 기본 배송비를 적용합니다.</p>",
      );
      return;
    }
    if (a === "evidence") {
      const i = s.invoices.find((i) => i.id === id);
      modal(
        "가상 송금 캡처 제출",
        "receipt",
        `<div class="notice">시안용 가상 증빙입니다. 실제 사진·계좌정보를 입력하지 마세요.</div>` +
          input(
            `송금액 (${i.currency})`,
            "amount",
            "",
            "number",
            `min="${i.currency === "CNY" ? "0.01" : "1"}" step="${i.currency === "CNY" ? "0.01" : "1"}" required`,
          ) +
          input(
            "송금자 (대리 송금 가능)",
            "payer",
            "체험 송금자",
            "text",
            "required",
          ) +
          check("가상 캡처가 저장되었습니다.", "evidence"),
        id,
      );
      return;
    }
    if (a === "confirm-receipt") {
      modal(
        "실제 수취 내역 대조",
        "confirm",
        input(
          "수취 거래 식별자",
          "ref",
          `DEMO-${s.next++}`,
          "text",
          "required",
        ) + check("수취 계정의 실제 거래·금액을 확인했습니다.", "verified"),
        id,
      );
      return;
    }
    if (a === "purchase") {
      D.orderSupplier(s);
      toast("입금완료된 미발주 수량을 합산했습니다.");
    }
    if (a === "arrival") {
      const p = s.pos.find((x) => x.id === id);
      modal(
        "부분 입고 · 주문순 배정",
        "arrival",
        input(
          "이번 입고수량",
          "qty",
          p.qty - p.arrived,
          "number",
          `min="1" max="${p.qty - p.arrived}" required`,
        ) +
          `<p>원 주문 순서: ${p.allocations
            .map((a) => {
              const l = s.lines.find((l) => l.id === a.line);
              return `${e(D.customer(s, l.customer).name)} #${l.seq}`;
            })
            .join(" → ")}</p>` +
          check("주문순 배정안을 확인했습니다.", "verified"),
        id,
      );
      return;
    }
    if (a === "defect" || a === "exchange") {
      const l = s.lines.find((l) => l.id === id);
      modal(
        a === "defect" ? "불량교환 대기" : "교환 입고 확인",
        a,
        input(
          "수량",
          "qty",
          1,
          "number",
          `min="1" max="${a === "defect" ? l.arrived - l.shipped - l.defect : l.defect}" required`,
        ),
        id,
      );
      return;
    }
    if (a === "shipment") {
      const ls = D.linesFor(s, ui.customer).filter(
        (l) => l.arrived - l.defect - l.shipped > 0,
      );
      if (!ls.length) throw Error("출고 가능한 정상 입고 상품이 없습니다.");
      modal(
        "부분/전량 출고",
        "shipment",
        ls
          .map((l) =>
            input(
              `${e(l.title)} ${e(l.color)}/${e(l.size)} · 가능 ${l.arrived - l.defect - l.shipped}`,
              `qty-${l.id}`,
              l.arrived - l.defect - l.shipped,
              "number",
              `min="0" max="${l.arrived - l.defect - l.shipped}"`,
            ),
          )
          .join("") +
          input("송장번호", "tracking", "", "text", "required") +
          "<p>현재 주소를 출고 기록에 보존합니다. 추가 고객 배송비 0원.</p>",
      );
      return;
    }
    if (a === "open-task") {
      resolveTask(s.tasks.find((t) => t.id === id));
      return;
    }
    if (a === "cancel-invoice") {
      modal(
        "3일 미입금 취소 검토",
        "cancel-invoice",
        "<p>실제 수취 내역에 입금이 없는지 확인한 후 처리해주세요.</p>" +
          input("취소 사유", "reason", "3일 미입금", "text", "required") +
          check("입금·증빙이 없고 취소 대상임을 확인했습니다.", "verified"),
        id,
      );
      return;
    }
    render();
  } catch (err) {
    toast(err.message);
  }
});
document.addEventListener("input", (ev) => {
  if (ev.target.id === "customer-search") {
    ui.search = ev.target.value;
    ui.selected = null;
    document.querySelector("#candidates").innerHTML = candidates();
  }
});
document.addEventListener("change", (ev) => {
  const el = ev.target;
  if (detail.change(el)) return;
  if (el.id === "demo-customer" || el.name === "staff-customer") {
    ui.customer = el.value;
    render();
  }
  if (el.name === "product") {
    ui.product = el.value;
    const p = D.product(s, el.value);
    ui.color = p.color;
    ui.size = p.size;
    el.form.elements.color.value = p.color;
    el.form.elements.size.value = p.size;
  }
  if (el.name?.startsWith("currency-")) {
    const i = s.invoices.find((i) => i.id === el.name.slice(9));
    if (i.receipts.length) {
      toast("입금 진행 후 통화를 바꿀 수 없습니다.");
      return;
    }
    i.currency = el.value;
    i.receiverId = i.receivers.find((r) => r.currency === i.currency)?.id;
    render();
  }
});
document.addEventListener("submit", (ev) => {
  const form = ev.target;
  if (!form.dataset.form) return;
  ev.preventDefault();
  const f = new FormData(form),
    v = (n) => f.get(n)?.toString() ?? "",
    n = (k) => Number(v(k)),
    id = form.dataset.id;
  try {
    if (detail.submit(form, f)) {
      dialog.close();
      render();
      return;
    }
    switch (form.dataset.form) {
      case "capture":
        D.addLine(s, ui.selected, v("product"), {
          color: v("color"),
          size: v("size"),
          qty: n("qty"),
          note: v("note"),
        });
        ui.product = v("product");
        ui.color = v("color");
        ui.size = v("size");
        ui.search = "";
        ui.selected = null;
        toast("주문 1건 저장 · 다음 고객을 검색해주세요.");
        break;
      case "customer": {
        if (!v("name").trim()) throw Error("닉네임을 입력해주세요.");
        s.customers.push({
          id: `c${s.next++}`,
          name: v("name"),
          wechat: v("wechat"),
          deposit: 0,
          address: null,
        });
        break;
      }
      case "product": {
        let p = s.products.find((p) => p.id === id);
        if (p && s.lines.some((l) => l.product === p.id))
          throw Error("접수 이력이 있어 상품 원본을 바꾸지 않습니다.");
        if (f.has("limited") && !v("available"))
          throw Error("판매 가능 수량을 입력해주세요.");
        if (!p) {
          p = {
            id: `p${s.next++}`,
            session: s.session.id,
            publicOrder:
              Math.max(0, ...D.sessionProducts(s).map((p) => p.publicOrder)) +
              1,
            number: Math.max(0, ...s.products.map((p) => p.number)) + 1,
            visible: false,
            outfit: false,
          };
          s.products.push(p);
        } else {
          p.visible = false;
          p.outfit = false;
        }
        Object.assign(p, {
          title: v("title"),
          supplier: v("supplier"),
          price: n("price"),
          color: v("color"),
          size: v("size"),
          excluded: f.has("excluded"),
          limited: f.has("limited"),
          available: v("available") ? n("available") : null,
        });
        break;
      }
      case "addition":
        D.addLine(s, ui.customer, id, { raw: v("raw") }, "customer_addition");
        toast("추가주문을 접수했습니다. 담당자가 옵션을 확인합니다.");
        break;
      case "edit-line":
        D.revise(
          s,
          s.lines.find((l) => l.id === id),
          {
            color: v("color"),
            size: v("size"),
            qty: n("qty"),
            price: n("price"),
            cancelled: f.has("cancelled"),
          },
          v("reason"),
        );
        break;
      case "change": {
        const l = s.lines.find((l) => l.id === id);
        if (D.blocked(s, l) || !f.has("unpaid"))
          throw Error("미송금 여부를 확인해주세요.");
        D.task(s, "수정 요청", ui.customer, id, v("reason"));
        const i = D.invFor(s, l);
        if (i) i.accepted = false;
        break;
      }
      case "issue":
        D.issue(s, ui.customer, v("country"));
        break;
      case "accept": {
        const i = s.invoices.find((i) => i.id === id);
        if (!f.has("agree") || !cust().address)
          throw Error("배송주소와 확인 항목을 모두 완료해주세요.");
        if (
          s.tasks.some(
            (t) =>
              !t.done &&
              t.kind === "수정 요청" &&
              i.items.some((l) => l.id === t.ref),
          )
        )
          throw Error("담당자가 수정 요청을 처리한 뒤 정산서를 확인해주세요.");
        i.accepted = true;
        break;
      }
      case "receipt": {
        if (!f.has("evidence"))
          throw Error("증빙 저장 후 확인 요청을 제출해주세요.");
        const i = s.invoices.find((i) => i.id === id);
        D.submitReceipt(
          s,
          i,
          Math.round(n("amount") * (i.currency === "CNY" ? 100 : 1)),
          v("payer"),
        );
        break;
      }
      case "confirm": {
        if (!f.has("verified")) throw Error("실제 수취 내역을 대조해주세요.");
        const [iid, rid] = id.split("/"),
          i = s.invoices.find((i) => i.id === iid);
        D.confirmReceipt(
          s,
          i,
          i.receipts.find((r) => r.id === rid),
          v("ref"),
        );
        break;
      }
      case "arrival":
        if (!f.has("verified")) throw Error("배정안을 확인해주세요.");
        D.arrive(
          s,
          s.pos.find((p) => p.id === id),
          n("qty"),
        );
        break;
      case "defect":
        D.defect(
          s,
          s.lines.find((l) => l.id === id),
          n("qty"),
        );
        break;
      case "exchange": {
        const l = s.lines.find((l) => l.id === id);
        if (!Number.isInteger(n("qty")) || n("qty") < 1 || n("qty") > l.defect)
          throw Error("교환 대기 수량을 확인해주세요.");
        l.defect -= n("qty");
        break;
      }
      case "shipment":
        D.ship(
          s,
          ui.customer,
          v("tracking"),
          Object.fromEntries(
            [...f.entries()]
              .filter(([k]) => k.startsWith("qty-"))
              .map(([k, v]) => [k.slice(4), Number(v)]),
          ),
        );
        break;
      case "resolve-address":
        if (!f.has("checked")) throw Error("확인 항목을 체크해주세요.");
        s.tasks.find((t) => t.id === id).done = true;
        break;
      case "cancel-invoice": {
        const i = s.invoices.find((i) => i.id === id);
        if (!f.has("verified") || i.receipts.length)
          throw Error("입금·증빙이 없는 주문만 취소할 수 있습니다.");
        const cancelledLines = s.lines.filter((l) => l.invoice === i.id);
        D.voidInvoice(s, i);
        cancelledLines.forEach((l) => {
          l.cancelled = true;
          l.invoice = null;
        });
        s.audit.push({ invoice: id, reason: v("reason"), at: D.now(s) });
        break;
      }
    }
    dialog.close();
    render();
    if (form.dataset.form === "capture")
      document.querySelector("#customer-search")?.focus();
  } catch (err) {
    toast(err.message);
  }
});
render();
