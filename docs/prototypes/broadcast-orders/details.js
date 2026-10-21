import * as D from "./domain.js";

// Supplemental UI-only flows. These actions never call a server or move funds.
export function createDetails({
  state,
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
}) {
  const s = state,
    c = () => D.customer(s(), ui.customer);
  const methodName = {
    bank: "한국 계좌",
    wechat: "위챗페이",
    alipay: "알리페이",
  };
  const countries = [
    ["CN", "중국"],
    ["KR", "한국"],
  ];
  const invoice = (id) => s().invoices.find((i) => i.id === id);
  const receipt = (id) => {
    const [iid, rid] = id.split("/");
    const i = invoice(iid);
    return [i, i.receipts.find((r) => r.id === rid)];
  };
  const kinds = {
    received: "실제 수취 확인",
    allocated: "정산서 차감",
    reversed: "차감 취소 반환",
  };
  const sessionFields = (v) =>
    input("방송명", "title", v.title, "text", "required") +
    input("방송 날짜", "date", v.date, "date", "required") +
    select(
      "방송 종류",
      "kind",
      [
        ["new", "신상 · 사전등록"],
        ["special", "특가 · 현장등록"],
      ],
      v.kind,
    ) +
    select(
      "방송 상태",
      "status",
      [
        ["draft", "준비 중"],
        ["open", "주문 접수 중"],
        ["closed", "접수 마감"],
      ],
      v.status,
    ) +
    input(
      "1위안당 원화",
      "rate",
      v.rate,
      "number",
      'min="0.0001" step="0.0001" required',
    ) +
    input("한국 배송비 (원)", "kr", v.kr, "number", 'min="0" required') +
    input(
      "중국 배송비 (위안)",
      "cn",
      v.cn / 100,
      "number",
      'min="0" step="0.01" required',
    ) +
    input("택포 기준 장수", "free", v.free, "number", 'min="1" required') +
    input(
      "집중 관리 일수",
      "days",
      v.days,
      "number",
      'min="1" max="30" required',
    ) +
    '<p class="muted">접수 기한은 방송 날짜의 한국시간 00시 + 설정 일수입니다. 마감 후에도 기존 주문의 정산·입출고는 계속할 수 있습니다. 발행한 정산서의 환율·배송비는 유지됩니다.</p>';
  function switchSession(id) {
    s().session = s().sessions.find((x) => x.id === id);
    const p = D.sessionProducts(s()).find((p) => !p.deleted);
    ui.product = p?.id ?? "";
    ui.color = p?.color ?? "";
    ui.size = p?.size ?? "";
    ui.selected = null;
    ui.search = "";
  }
  function sessions() {
    return `<div class="row between"><h2>방송 회차 관리</h2>${btn("방송 만들기", "new-session", "", "primary")}</div>${s()
      .sessions.map(
        (v) =>
          `<article class="card"><h3>${e(v.title)}</h3><p>${e(v.date)} · ${v.kind === "new" ? "신상" : "특가"} · ${v.status === "draft" ? "준비 중" : v.status === "open" ? "접수 중" : "마감"}</p><p>접수 기한 ${new Date(v.closesAt).toLocaleString("ko-KR")}</p><div class="row">${btn(v.id === s().session.id ? "선택된 방송" : "이 방송 선택", "select-session", v.id)}${btn("설정 변경", "edit-session", v.id)}</div></article>`,
      )
      .join("")}`;
  }
  function receivers() {
    return `<h2>송금 수취 설정</h2><p class="notice">모든 값은 체험용입니다. 실제 계좌나 QR은 입력하지 마세요. 변경한 안내는 새 정산서부터 적용됩니다.</p>${s()
      .receivers.map(
        (r) =>
          `<article class="card"><h3>${methodName[r.method]} · ${r.currency}</h3><p>${e(r.holder)}</p><p>${e(r.instructions)}</p><span class="tag">${r.active && r.verified ? "새 정산서에 사용" : "사용 안 함"}</span> ${btn("수취 안내 수정", "receiver", r.id)}</article>`,
      )
      .join("")}`;
  }
  function customerTools() {
    const ledger = s().depositLedger.filter((d) => d.customer === ui.customer);
    return `<div class="row">${btn("선입금 수취 기록", "deposit")}${btn("관리자 주소 정정", "staff-address")}${btn("기기 접근 회수", "revoke-device")}</div><details><summary>선입금 원장 (${ledger.length})</summary>${ledger.map((d) => `<p>${kinds[d.kind]} · ${money(d.amount)} · ${e(d.invoice ?? d.ref)}</p>`).join("") || "<p>기록 없음</p>"}</details>${s()
      .tasks.filter(
        (t) => t.customer === ui.customer && t.kind === "수정 요청" && !t.done,
      )
      .map(
        (t) =>
          `<div class="notice">요청: ${e(t.message)} ${btn("요청 반려", "decline-change", t.id)}</div>`,
      )
      .join("")}`;
  }
  function gate() {
    const status = s().devices[ui.customer];
    if (status === "active") return null;
    return `<section class="card"><span class="tag">고객 전용 링크</span><h2>${status === "pending" ? "판매자 확인을 기다리고 있어요" : status === "approved" ? "이 기기에서 주문을 열어주세요" : "새 기기 확인이 필요해요"}</h2><p>기존에 연락하던 위챗으로 판매자에게 본인 확인을 요청해주세요. 가입이나 비밀번호는 필요하지 않습니다.</p>${status === "approved" ? btn("일회용 활성화 링크 열기 체험", "activate-device", "", "primary") : status === "pending" ? "<p>확인 중 · 주문과 주소는 아직 표시하지 않습니다.</p>" : btn("기기 확인 요청", "request-device", "", "primary")}<p class="muted">시안의 기기 상태 체험입니다. 실제 링크·인증·메시지는 생성하지 않습니다.</p></section>`;
  }
  function receiverGuide(i) {
    const rs = i.receivers.filter((r) => r.currency === i.currency),
      selected = rs.find((r) => r.id === i.receiverId) ?? rs[0];
    return `<section class="transfer-guide">${select(
      "송금 방법",
      `receiver-${i.id}`,
      rs.map((r) => [r.id, methodName[r.method]]),
      selected?.id,
    )}<p>받는 분: ${e(selected?.holder)}</p><p>${e(selected?.instructions)}</p><small>정산서 발행 당시 수취 안내 · 실제 송금 불가</small></section>`;
  }
  function paymentDetails(i, customer = false) {
    const refunds = i.refunds ?? [],
      available =
        D.sumPaid(i) - D.due(i) - refunds.reduce((a, r) => a + r.amount, 0);
    const info = i.receipts
      .filter((r) => r.needsInfo)
      .map(
        (r) =>
          `<div class="notice">추가 확인 요청: ${e(r.clarification)} ${customer ? btn("보완 캡처 제출", "replace-evidence", `${i.id}/${r.id}`) : "<small>고객의 보완 제출을 기다리고 있습니다.</small>"}</div>`,
      )
      .join("");
    return (
      info +
      (!customer && available > 0
        ? btn("초과금 환불 기록 시작", "refund", i.id)
        : "") +
      refunds
        .map(
          (r) =>
            `<article class="line"><strong>초과금 환불 ${money(r.amount, i.currency)}</strong><p>${r.confirmed ? "실제 환불 확인 완료" : "환불 예정 · 아직 송금하지 않음"} · ${e(r.reason)}</p>${!customer && !r.confirmed ? btn("실제 환불 완료 기록", "confirm-refund", `${i.id}/${r.id}`) : ""}</article>`,
        )
        .join("") +
      (D.refunded(i)
        ? `<p>환불 완료 ${money(D.refunded(i), i.currency)} · 순수취 ${money(D.netPaid(i), i.currency)}</p>`
        : "")
    );
  }
  function exportsPage() {
    const kind = ui.exportKind ?? "supplier",
      supplier = ui.exportSupplier ?? "";
    const data = D.exportRows(s(), kind, supplier);
    return `<h2>관리표 내보내기</h2><div class="card">${select(
      "표 종류",
      "export-kind",
      [
        ["supplier", "거래처 발주표 · 개인정보 없음"],
        ["customer", "고객관리표 · 내부 전용"],
      ],
      kind,
    )}${kind === "supplier" ? select("거래처 선택", "export-supplier", [["", "전체 거래처"], ...[...new Set(s().pos.map((p) => p.supplier))].map((x) => [x, x])], supplier) : ""}<p>${kind === "supplier" ? "고객 이름·주소·연락처·입금캡처를 포함하지 않습니다." : "내부용 고객 이름과 입금상태를 포함합니다. 거래처에 전달하지 마세요."}</p><div class="scroll"><table><thead><tr>${data.headers.map((h) => `<th>${e(h)}</th>`).join("")}</tr></thead><tbody>${data.rows.map((row) => `<tr>${row.map((x) => `<td>${e(x)}</td>`).join("")}</tr>`).join("")}</tbody></table></div><p>${data.rows.length}행 · 현재 주문 데이터 기준</p>${btn("XLSX 내보내기 체험", "export-preview", "", "primary")}<p class="muted">시안은 생성 확인 화면까지 제공합니다. 실제 파일 생성은 B05 서버 구현 범위입니다.</p></div>`;
  }
  function click(a, id) {
    if (a === "select-session") {
      switchSession(id);
      render();
      return true;
    }
    if (["new-session", "edit-session", "settings"].includes(a)) {
      const v =
        a === "new-session"
          ? {
              ...s().session,
              title: "",
              date: new Date(D.now(s()) + 9 * 3600000)
                .toISOString()
                .slice(0, 10),
              status: "draft",
            }
          : a === "settings"
            ? s().session
            : s().sessions.find((x) => x.id === id);
      modal(
        a === "new-session" ? "방송 만들기" : "방송 설정",
        "session-detail",
        sessionFields(v),
        a === "new-session" ? "new" : v.id,
      );
      return true;
    }
    if (a === "receiver") {
      const r = s().receivers.find((x) => x.id === id);
      modal(
        "수취 안내 수정",
        "receiver",
        input("수취인 (체험용)", "holder", r.holder, "text", "required") +
          input(
            "계좌 또는 QR 안내 문구 (체험용)",
            "instructions",
            r.instructions,
            "text",
            "required",
          ) +
          check(
            "수취 주체와 이용 가능한 수금 경로를 확인했습니다.",
            "verified",
            r.verified,
          ) +
          check("새 정산서에서 사용", "active", r.active) +
          "<p>발행된 정산서의 안내를 덮어쓰지 않습니다.</p>",
        id,
      );
      return true;
    }
    if (a === "deposit") {
      modal(
        "선입금 실제 수취 기록",
        "deposit",
        input(
          "확인한 금액 (원)",
          "amount",
          10000,
          "number",
          'min="1" required',
        ) +
          input("한국 계좌 수취 거래 식별자", "ref", "", "text", "required") +
          check("실제 계좌의 수취를 확인했습니다.", "verified") +
          "<p>신규 고객 기본 선입금 10,000원. 고객별 잔액에서 정산 시 한 번만 차감됩니다.</p>",
      );
      return true;
    }
    if (a === "staff-address" || a === "address") {
      const i = id ? invoice(id) : null;
      if (!D.currentInvoices(s(), ui.customer).length)
        throw Error("정산서 발행 후 주소를 받습니다.");
      if (
        a === "address" &&
        D.currentInvoices(s(), ui.customer).some((x) => x.receipts.length)
      )
        throw Error("입금 진행 후에는 판매자에게 요청해주세요.");
      const address = c().address ?? {
        country: i?.country ?? "CN",
        recipient: c().name,
        phone: "",
        detail: "",
      };
      modal(
        a === "staff-address" ? "관리자 주소 정정" : "배송주소",
        a,
        select("배송 국가", "country", countries, address.country) +
          input("받는 분", "recipient", address.recipient, "text", "required") +
          input("전화번호", "phone", address.phone, "tel", "required") +
          input("전체 주소", "detail", address.detail, "text", "required") +
          (a === "staff-address"
            ? input("고객 요청·정정 사유", "reason", "", "text", "required")
            : "") +
          "<p>국가 변경은 미입금 청구 재발행이 필요합니다. 이미 출고한 주소는 바뀌지 않습니다.</p>",
        id,
      );
      return true;
    }
    if (a === "request-info") {
      modal(
        "증빙 추가 확인 요청",
        "request-info",
        input(
          "고객에게 보여줄 요청",
          "reason",
          "",
          "text",
          'placeholder="금액과 거래번호가 보이는 캡처를 보내주세요" required',
        ),
        id,
      );
      return true;
    }
    if (a === "replace-evidence") {
      modal(
        "보완 캡처 제출",
        "replace-evidence",
        `<p>${e(receipt(id)[1].clarification)}</p>` +
          check("가상 보완 캡처가 저장되었습니다.", "stored") +
          "<p>같은 송금 건에 증빙만 추가합니다. 입금액이 중복되지 않습니다.</p>",
        id,
      );
      return true;
    }
    if (a === "refund") {
      const i = invoice(id);
      modal(
        "초과금 환불 예정 기록",
        "refund",
        input(
          `환불액 (${i.currency})`,
          "amount",
          (D.sumPaid(i) -
            D.due(i) -
            i.refunds.reduce((a, r) => a + r.amount, 0)) /
            (i.currency === "CNY" ? 100 : 1),
          "number",
          `min="${i.currency === "CNY" ? ".01" : "1"}" step="${i.currency === "CNY" ? ".01" : "1"}" required`,
        ) +
          input("환불 사유", "reason", "초과 입금 반환", "text", "required") +
          "<p>이 버튼으로 송금되지 않습니다. 실제 환불 후 완료 기록이 필요합니다.</p>",
        id,
      );
      return true;
    }
    if (a === "confirm-refund") {
      modal(
        "실제 환불 완료 기록",
        "confirm-refund",
        input("환불 거래 식별자", "ref", "", "text", "required") +
          check("실제 환불 송금 내역과 금액을 확인했습니다.", "verified"),
        id,
      );
      return true;
    }
    if (a === "new-device" || a === "revoke-device") {
      s().devices[ui.customer] = "new";
      s()
        .tasks.filter(
          (t) => t.kind === "기기 확인" && t.customer === ui.customer,
        )
        .forEach((t) => (t.done = true));
      if (a === "new-device") ui.role = "customer";
      render();
      toast(
        a === "new-device"
          ? "새 기기에서는 개인정보를 표시하지 않습니다."
          : "기기 접근을 회수했습니다.",
      );
      return true;
    }
    if (a === "request-device") {
      D.requestDevice(s(), ui.customer);
      render();
      return true;
    }
    if (a === "activate-device") {
      if (s().devices[ui.customer] !== "approved")
        throw Error("판매자 확인이 필요합니다.");
      s().devices[ui.customer] = "active";
      render();
      return true;
    }
    if (a === "approve-device") {
      modal(
        "새 기기 본인 확인",
        "approve-device",
        `<p>${e(D.customer(s(), id).wechat)}</p>` +
          check(
            "기존 위챗 연락처에서 본인과 새 기기 요청을 확인했습니다.",
            "verified",
          ) +
          "<p>실제 서비스는 해당 요청 기기에만 쓸 수 있는 일회용 링크를 전달합니다. 시안은 확인 화면만 바뀝니다.</p>",
        id,
      );
      return true;
    }
    if (a === "decline-change") {
      modal(
        "수정 요청 반려",
        "decline-change",
        input("고객에게 안내할 사유", "reason", "", "text", "required") +
          "<p>주문 원본을 변경하지 않고 요청을 종료합니다.</p>",
        id,
      );
      return true;
    }
    if (a === "export-preview") {
      const kind = ui.exportKind ?? "supplier",
        d = D.exportRows(s(), kind, ui.exportSupplier ?? "");
      if (!d.rows.length)
        throw Error(
          "내보낼 행이 없습니다. 먼저 주문 또는 발주를 등록해주세요.",
        );
      modal(
        "내보내기 확인",
        "export-finish",
        `<p>${kind === "supplier" ? "거래처 발주표" : "고객관리표"} · ${d.rows.length}행</p><p>예정 파일: ${kind === "supplier" ? "supplier" : "customers"}.xlsx</p>${check(kind === "supplier" ? "고객 개인정보가 없는 발주표임을 확인했습니다." : "고객관리표는 내부에서만 사용합니다.", "verified")}<p class="muted">저장하면 생성 완료 화면을 체험합니다. 실제 다운로드 파일은 만들지 않습니다.</p>`,
      );
      return true;
    }
    if (a === "move-product") {
      const p = D.product(s(), id),
        ps = D.sessionProducts(s()),
        index = ps.indexOf(p);
      if (index > 0) {
        const prev = ps[index - 1];
        [p.publicOrder, prev.publicOrder] = [prev.publicOrder, p.publicOrder];
      }
      render();
      return true;
    }
    return false;
  }
  function submit(form, f) {
    const v = (n) => f.get(n)?.toString() ?? "",
      num = (n) => Number(v(n)),
      id = form.dataset.id;
    switch (form.dataset.form) {
      case "session-detail": {
        const vals = {
          title: v("title").trim(),
          date: v("date"),
          kind: v("kind"),
          status: v("status"),
          rate: num("rate"),
          kr: num("kr"),
          cn: Math.round(num("cn") * 100),
          free: num("free"),
          days: num("days"),
        };
        if (!vals.title || vals.rate <= 0 || vals.days < 1 || vals.free < 1)
          throw Error("방송 설정 값을 확인해주세요.");
        vals.closesAt =
          Date.parse(vals.date + "T00:00:00+09:00") + vals.days * 86400000;
        if (id === "new") {
          vals.id = "s" + s().next++;
          s().sessions.push(vals);
        } else
          Object.assign(
            s().sessions.find((x) => x.id === id),
            vals,
          );
        switchSession(id === "new" ? vals.id : id);
        break;
      }
      case "receiver": {
        if (f.has("active") && !f.has("verified"))
          throw Error("수취 경로 확인 후 사용해주세요.");
        Object.assign(
          s().receivers.find((r) => r.id === id),
          {
            holder: v("holder"),
            instructions: v("instructions"),
            verified: f.has("verified"),
            active: f.has("active"),
          },
        );
        break;
      }
      case "deposit":
        D.recordDeposit(
          s(),
          ui.customer,
          num("amount"),
          v("ref"),
          f.has("verified"),
        );
        break;
      case "address":
      case "staff-address":
        D.changeAddress(
          s(),
          ui.customer,
          {
            country: v("country"),
            recipient: v("recipient"),
            phone: v("phone"),
            detail: v("detail"),
          },
          v("reason") || "고객 직접 주소 변경",
          form.dataset.form === "staff-address",
        );
        break;
      case "request-info": {
        const [i, r] = receipt(id);
        D.requestInfo(s(), i, r, v("reason"));
        break;
      }
      case "replace-evidence": {
        const [i, r] = receipt(id);
        D.replaceEvidence(s(), i, r, f.has("stored"));
        break;
      }
      case "refund": {
        const i = invoice(id);
        D.requestRefund(
          s(),
          i,
          Math.round(num("amount") * (i.currency === "CNY" ? 100 : 1)),
          v("reason"),
        );
        break;
      }
      case "confirm-refund": {
        const [iid, rid] = id.split("/"),
          i = invoice(iid);
        D.confirmRefund(
          s(),
          i,
          i.refunds.find((r) => r.id === rid),
          v("ref"),
          f.has("verified"),
        );
        break;
      }
      case "approve-device":
        D.approveDevice(s(), id, f.has("verified"));
        break;
      case "decline-change": {
        const t = s().tasks.find((t) => t.id === id);
        t.done = true;
        t.resolution = v("reason");
        break;
      }
      case "export-finish":
        if (!f.has("verified")) throw Error("내보내기 대상을 확인해주세요.");
        toast("생성 완료 체험 · 실제 XLSX 파일 생성은 B05에서 구현합니다.");
        break;
      default:
        return false;
    }
    return true;
  }
  function change(el) {
    if (el.name === "active-session") {
      switchSession(el.value);
      render();
      return true;
    }
    if (el.name === "export-kind") {
      ui.exportKind = el.value;
      ui.exportSupplier = "";
      render();
      return true;
    }
    if (el.name === "export-supplier") {
      ui.exportSupplier = el.value;
      render();
      return true;
    }
    if (el.name?.startsWith("receiver-")) {
      const i = invoice(el.name.slice(9));
      i.receiverId = el.value;
      render();
      return true;
    }
    return false;
  }
  return {
    sessions,
    receivers,
    customerTools,
    gate,
    receiverGuide,
    paymentDetails,
    exportsPage,
    click,
    submit,
    change,
  };
}
