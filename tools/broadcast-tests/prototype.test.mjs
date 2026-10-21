import { test } from "node:test";
import assert from "node:assert/strict";
import * as D from "../../docs/prototypes/broadcast-orders/domain.js";
function paidExample() {
  const s = D.fresh();
  s.session.free = 99;
  s.customers[0].deposit = 0;
  s.customers[0].address = { country: "KR", detail: "기존 테스트 주소" };
  s.products[0].price = 6000;
  const l = D.addLine(s, "c1", "p1", { color: "검정", size: "M", qty: 10 });
  const i = D.issue(s, "c1", "KR");
  i.accepted = true;
  return { s, l, i };
}
test("시안 300+20, 10중6, 불량1, 부분출고5+5, 주소 스냅샷", () => {
  const { s, l, i } = paidExample();
  assert.equal(i.totalC, 32000);
  const a = D.submitReceipt(s, i, 30000, "대리송금자");
  assert.equal(D.settled(i), false);
  D.confirmReceipt(s, i, a, "receipt-1");
  assert.equal(D.settled(i), false);
  assert.throws(() => D.orderSupplier(s));
  const b = D.submitReceipt(s, i, 2000, "대리송금자");
  D.confirmReceipt(s, i, b, "receipt-2");
  assert.equal(D.settled(i), true);
  assert.throws(() => D.revise(s, l, { qty: 1 }, "변경"));
  D.orderSupplier(s);
  assert.equal(s.pos[0].qty, 10);
  assert.throws(() => D.orderSupplier(s));
  D.arrive(s, s.pos[0], 6);
  D.defect(s, l, 1);
  assert.throws(() => D.ship(s, "c1", "too-many", { [l.id]: 6 }));
  D.ship(s, "c1", "first", { [l.id]: 5 });
  s.customers[0].address.detail = "새 테스트 주소";
  assert.equal(s.shipments[0].address.detail, "기존 테스트 주소");
  s.tick = 15;
  assert.equal(D.tasks(s).filter((t) => t.kind === "장기 미송").length, 1);
  D.arrive(s, s.pos[0], 4);
  l.defect -= 1;
  D.ship(s, "c1", "second", { [l.id]: 5 });
  assert.equal(l.shipped, 10);
  assert.equal(s.shipments.length, 2);
  assert.equal(D.tasks(s).filter((t) => t.kind === "장기 미송").length, 0);
  assert.equal(s.shipments[1].extraShipping, 0);
});
test("시안 선입금 단일 배분·정정 반환·원본 보존·확인전 청구 차단", () => {
  const s = D.fresh(),
    l = D.addLine(s, "c1", "p1", { qty: 1, size: "M" });
  const i = D.issue(s, "c1", "KR");
  assert.equal(i.deposit, 10000);
  assert.equal(s.customers[0].deposit, 0);
  D.revise(s, l, { qty: 1, size: "L" }, "요청");
  assert.equal(l.original.size, "M");
  assert.equal(s.customers[0].deposit, 10000);
  assert.equal(i.void, true);
  D.addLine(s, "c1", "p1", { raw: "핑크 7호 두개" }, "customer_addition");
  assert.throws(() => D.issue(s, "c1", "KR"), /확인/);
  s.tick = 15;
  assert.throws(
    () => D.addLine(s, "c1", "p1", { raw: "추가" }, "customer_addition"),
    /기간/,
  );
});
test("시안 회차 분리·수취 안내 스냅샷·마감 이후 추가 차단", () => {
  const s = D.fresh();
  D.addLine(s, "c1", "p1", { qty: 1 });
  const second = { ...s.session, id: "s2", title: "특가", status: "open" };
  s.sessions.push(second);
  s.session = second;
  assert.throws(() => D.issue(s, "c1", "CN"), /새로 정산/);
  assert.throws(() => D.addLine(s, "c1", "p1", { qty: 1 }), /방송/);
  s.session = s.sessions[0];
  const i = D.issue(s, "c1", "CN");
  s.receivers[1].holder = "변경된 예금주";
  s.session.rate = 999;
  assert.equal(i.rate, 200);
  assert.equal(i.receivers[1].holder, "체험 판매자");
  s.session.status = "closed";
  assert.throws(
    () => D.addLine(s, "c1", "p1", { raw: "1개" }, "customer_addition"),
    /기간/,
  );
});
test("시안 보완 증빙은 같은 수취 건·초과 환불은 차액 이내·중복 방지", () => {
  const { s, i, l } = paidExample();
  const r = D.submitReceipt(s, i, 35000, "대리송금자");
  D.requestInfo(s, i, r, "거래번호 확인");
  assert.throws(() => D.confirmReceipt(s, i, r, "x"), /상태/);
  assert.throws(() => D.revise(s, l, { qty: 1 }, "변경"), /송금/);
  assert.throws(() => D.replaceEvidence(s, i, r, false), /증빙/);
  D.replaceEvidence(s, i, r, true);
  assert.equal(i.receipts.length, 1);
  D.confirmReceipt(s, i, r, "x");
  assert.equal(D.sumPaid(i), 35000);
  assert.throws(() => D.requestRefund(s, i, 3001, "초과"), /초과/);
  const refund = D.requestRefund(s, i, 3000, "초과금");
  assert.throws(() => D.requestRefund(s, i, 1, "중복"), /초과/);
  assert.throws(() => D.confirmRefund(s, i, refund, "REFUND", false), /확인/);
  D.confirmRefund(s, i, refund, "REFUND", true);
  assert.equal(D.netPaid(i), 32000);
  assert.equal(D.sumPaid(i), 35000);
  assert.equal(D.settled(i), true);
  assert.equal(D.tasks(s).filter((t) => t.kind === "환불 확인").length, 0);
});
test("시안 선입금 수취 중복·0원 청구 확인·출고 주소 원본·표 개인정보", () => {
  const s = D.fresh();
  assert.throws(
    () => D.recordDeposit(s, "c1", 10000, "DEMO-DEPOSIT", true),
    /이미/,
  );
  D.recordDeposit(s, "c1", 10000, "DEMO-2", true);
  assert.equal(s.customers[0].deposit, 20000);
  const l = D.addLine(s, "c1", "p1", { qty: 1 }),
    i = D.issue(s, "c1", "KR");
  assert.equal(i.totalK, 0);
  assert.equal(D.settled(i), false);
  D.changeAddress(
    s,
    "c1",
    { country: "KR", detail: "테스트 주소" },
    "최초 등록",
  );
  i.accepted = true;
  assert.equal(D.settled(i), true);
  assert.equal(D.blocked(s, l), true);
  D.orderSupplier(s);
  D.arrive(s, s.pos[0], 1);
  D.ship(s, "c1", "TEST", { [l.id]: 1 });
  D.changeAddress(
    s,
    "c1",
    { country: "KR", detail: "정정 주소" },
    "고객 요청",
    true,
  );
  assert.equal(s.shipments[0].address.detail, "테스트 주소");
  assert.equal(D.settled(i), true);
  assert.equal(
    JSON.stringify(D.exportRows(s, "supplier")).includes("몽이맘"),
    false,
  );
  assert.equal(
    JSON.stringify(D.exportRows(s, "customer")).includes("몽이맘"),
    true,
  );
});
test("시안 국가 변경 청구 무효·선입금 반환·새 기기 확인 필요", () => {
  const s = D.fresh();
  D.addLine(s, "c1", "p1", { qty: 1 });
  const i = D.issue(s, "c1", "CN");
  D.changeAddress(
    s,
    "c1",
    { country: "KR", detail: "한국 테스트" },
    "국가 변경",
  );
  assert.equal(i.void, true);
  assert.equal(s.customers[0].deposit, 10000);
  s.devices.c1 = "new";
  D.requestDevice(s, "c1");
  D.requestDevice(s, "c1");
  assert.equal(D.tasks(s).filter((t) => t.kind === "기기 확인").length, 1);
  assert.throws(() => D.approveDevice(s, "c1", false), /확인/);
  D.approveDevice(s, "c1", true);
  assert.equal(s.devices.c1, "approved");
  assert.equal(D.tasks(s).filter((t) => t.kind === "기기 확인").length, 0);
});
