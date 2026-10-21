# 화면·상태·API 규약 v2.2.0

기준: [판매자 요구 v1](requirements-v1.md) · [단계별 버전](stage-versions.md). v1.4와 호환되지 않는 새 계약. **실제 구현 여부는 작업표로 확인**하며 이 문서의 모든 API가 이미 존재한다는 뜻이 아니다.

## 화면

| 화면 | 행동 / 예외 |
|---|---|
| 직원 빠른입력 | 방송 선택, 닉네임 부분검색/위챗 관리정보, 상품·색·사이즈 유지, 수량, 독립행 저장, 성공 후 고객 검색, 실패 재시도/작성 보존 |
| 방송/상품 | 신상/특가, 수동 환율·배송·택포·3일, 비공개 사전등록, 현장등록, 공개/숨김, 여러 코디 선택 |
| 처리함 | 수정·추가·주소·증빙·3일·14일, 읽어도 해결 전 유지, 업무 완료 시 처리 |
| 고객관리 | 고객ID+더우인/위챗, 선입금 원장, 고정 링크 재전달, 원본/최종 행, 내부 감사기록 |
| 고객 링크 | 미인증 기기는 판매자 확인 안내만. 인증 후 현재 코디/소개목록/자신의 행/한 줄 추가/수정 요청 |
| 정산 | 미정산 행 선택, 택포 제외 수량, KRW/CNY, 선입금, 국가별 배송, 판본 발행 |
| 고객 청구 | 최종 옵션/금액·선입금·주소·입금 후 변경불가 경고, 통화 선택, 송금 안내, 증빙 제출, 부족금 |
| 입금 | 비공개 캡처, 대리송금 정보, 실수취 대조 후 1:N 확인, 부족/초과/환불대기, 확인중 잠금 |
| 발주/고객표 | 동일 데이터 두 보기, 입금완료만 합산, 고객표 내부전용, 거래처표 개인정보 제외, 기본 XLSX |
| 입고 | 복수 입고 사건, 원 주문순 배정안 확인, 미송 잔량, 불량 수량 격리/교환 |
| 출고 | 정상입고 미출고 수량 선택, 부분출고, 주소 스냅샷, 송장 여러 개, 잔여와 고객 추가배송비0 |

## 데이터 모델

Seller(기존) 1:N StaffMembership(role=assistant/manager, 실제 한 사람이 여러 권한 가능)
Seller 1:N Customer(internal UUID, nickname 비고유, wechatNote, public locator)
Session 1:N Product(번호 불변, supplier, 공개순서, 코디)
Customer+Session 1:N OrderLine(같은 옵션 반복 가능, originalSnapshot, currentSnapshot, sequence, createdAt)
OrderLine 1:N Revision / ChangeRequest
InvoiceVersion 1:N InvoiceLine(원 OrderLine ID), 1:N Receipt, 1:N Evidence
Customer 1:N DepositEntry, Invoice 1:N DepositAllocation
PurchaseOrder 1:N PurchaseOrderItem(supplier+product+color+size), Item 1:N OrderAllocation
Item 1:N Arrival, Arrival 1:N CustomerAllocation, 1:N DefectExchange
Customer 1:N Shipment, Shipment 1:N ShipmentLine(orderLineId,quantity), immutable addressSnapshot
Task(sourceType,sourceId,conditionVersion,dueAt,resolvedAt), Audit(actor,old,new,reason)

복수 입고/불량/출고를 한 status로 덮어쓰지 않는다. 주문 당시 정보와 확정 정보 분리. 모든 join에 seller 경계 포함, 고객 API는 서버 세션의 customer ID만 사용한다.

## 상태와 경합

- 주문행: received / needs_review / cancelled. 청구/입금/공급/출고 상태는 별도 연관 데이터에서 산출.
- 청구: draft → issued → superseded 또는 void. accepted는 검토 동의 기록, 정산 완료는 확인수취 합계로 계산.
- 수취: pending_review / needs_info / confirmed / rejected. 청구 요약 unpaid / reviewing / partial / settled / overpaid / refund_pending.
- 공급 수량: ordered, arrived_good, unarrived, defect_waiting, allocated, shipped. 미송 주문 재생성 금지.
- 고객 상태: 주문 확인 → 입금 확인 → 상품 준비 중 → 부분 출고 → 출고 완료.
- 부분입금·증빙대기 동안 청구·주문 수정 보류. 선입금 잔고만으로 전체 주문 잠그지 않는다.
- 모든 변경은 version 검사, 서버 권한, 멱등키. 입금/정정/발주/출고는 관련 청구/행을 같은 순서로 잠근다. 화면 버튼만으로 보호하지 않는다.

## B01 실제 RPC 계약

`broadcast_workspace(p_seller_id uuid)` — 기존 JWT 필요. 승인된 셀러 본인 또는 명시적 구성원만 해당 셀러 방송/상품 목록 조회. 고객·주문 배열은 항상 빈 배열로 두어 전체 개인정보/주문을 초기 화면에 전송하지 않는다. 상품마다 서버 계산 `has_orders`를 포함해 접수 뒤 정정/삭제 버튼을 잠근다. 다른 셀러/무인증 거절.

`broadcast_customer_page(p_seller_id uuid,p_query text='',p_after_nickname text=null,p_after_id uuid=null,p_limit integer=20)` — 같은 판매자 고객만 닉네임 부분 일치 검색. `(nickname,id)` 순서의 키셋 페이지이며 `items,next_nickname,next_id` 반환. 중복 닉네임도 ID로 구분한다. 최대 50건. 검색어 변경 시 커서 폐기. 직원 화면은 검색 후 첫 페이지와 더 보기로 선택한다.

`broadcast_order_page(p_seller_id uuid,p_session_id uuid,p_before_sequence bigint=null,p_limit integer=30)` — 해당 회차의 원 주문순번 역순 키셋 페이지. `items,next_before_sequence` 반환, 최대 50건. 각 행에 내부 표시용 닉네임을 붙인다. 없는/타 판매자 회차 거절. 화면의 현재 로드 건수는 전체 접수 건수가 아니다.

`broadcast_command(p_seller_id uuid, p_command text, p_data jsonb, p_key uuid)` — 원자적 저장. 같은 actor/seller/key/내용 재시도는 동일 결과, 같은 key 다른 내용은 오류. 출처/시각/순번/소유권은 서버 결정.

보조 담당자는 기존 오렌담 로그인 뒤 판매자가 전달한 **일회용 30분 참여 코드**로 연결한다. `broadcast_staff_manage(seller, action=invite|remove, userId?, key)`는 관리자만 실행하며 초대 생성/접근 회수 모두 명령 키로 중복을 막는다. 초대는 assistant 권한만 부여한다. `broadcast_staff_overview(seller)`는 관리자에게 담당자 ID·역할과 미사용 코드/만료시각을 제공한다. `broadcast_staff_join(code)`는 로그인 사용자만 실행하고 코드 원자적 선점 후 해당 seller의 assistant 구성원으로 등록한다. 같은 사람이 같은 코드로 재시도하면 기존 결과를 주고, 타인 재사용·만료·판매자 미승인은 거절한다. 접근 회수 후 모든 직원 RPC는 다음 권한 검사에서 거절되며 사용된 코드를 다시 쓸 수 없다. 코드는 판매자가 직접 전달하며 시스템은 고객/직원 메시지를 자동 발송하지 않는다.

직원 Flutter 화면은 명령 전송 전에 `{version,name,key,payload}` 한 건을 기기 저장소에 기록한다. 로그인 actor와 seller별로 분리하며 재시작 때 미확인 명령이 있으면 신규 저장을 잠그고 `저장 결과 다시 확인`으로 같은 key/payload만 재전송한다. 서버 확정/명시적 거절 뒤 기기 기록을 지운다. 기록 쓰기·읽기·삭제가 실패하면 새 명령 전송을 막고 저장소 재확인을 안내한다. 이 기록은 기기 로컬 일반 preferences 저장이므로 결제 캡처·주소 보관에는 사용하지 않으며, 여러 탭/기기 동시 입력과 브라우저 저장소 삭제 시 복구 보장은 B09 실환경 검증·후속 큐 설계 대상이다.

| command | data | 권한 |
|---|---|---|
| customer.create | nickname, wechat_note | assistant/manager |
| session.create | title, kind, broadcast_date, status, exchange_rate, shipping_krw, shipping_cny_fen, free_shipping_count, management_days | manager |
| session.update | id, version, title, kind, broadcast_date, status, exchange_rate, 배송/택포/관리일수 | manager; 접수 중 설정 변경 시 기록 |
| product.create | session_id, supplier, title, price_krw, colors[], sizes[], shipping_excluded, quantity_limited, available_quantity | assistant/manager |
| product.update | id, version, 거래처·제품명·단가·옵션·수량/택포 설정 | assistant/manager; 접수 이력 없을 때만, 수정 후 비공개 |
| product.archive / product.restore | id, version | assistant/manager; 주문 이력 있으면 삭제 거절, 복구 시 번호 유지·비공개 |
| product.reorder | id, version, direction(up/down) | assistant/manager; 같은 방송의 옆 상품과 공개 순서 교환 |
| product.publish | id, version, visible, in_outfit | assistant/manager |
| order.create | session_id, customer_id, product_id, color, size, quantity, note | assistant/manager |
| order.revise | id, version, color, size, quantity, note, reason, cancelled | manager, 미송금/미청구 B01 범위 |

B01은 `payment_locked`와 `invoice_id`를 향후 청구 연결용 서버 전용 가드로 예약한다. 클라이언트가 해제할 수 없다. 청구 후 정정은 B03 원자적 재발행으로만 구현해야 하므로 B01에서 거절한다. 기존 원문/순번/출처는 수정되지 않고 별도 audit에 seller_edit 기록.

## B02~B08 API (B02 일부 로컬 구현, 나머지 예정)

- POST /api/broadcast/v2/access/request, /activate, /revoke: 고정 locator만으로 정보 반환 금지, 활성화 토큰 해시/단회/짧은 만료/속도제한, 서버 HttpOnly Secure 세션. GET 링크 방문만으로 활성화 금지. Referrer-Policy no-referrer, no-store, 제3자 스크립트 없음.

- B02-v0.2.0 로컬 구현: 고객 게이트웨이는 `POST /access/request`, `POST /access/activate`, `GET /customer/:locator`, `GET|POST /customer/:locator/requests`를 제공한다. 관리자 링크 생성·접근 요청 목록·승인·회수는 `broadcast_customer_link`, `broadcast_access_overview`, `broadcast_access_approve`, `broadcast_access_revoke` RPC이며 기존 로그인 JWT와 manager 권한을 요구한다. 게이트웨이만 호출하는 `broadcast_access_request`, `broadcast_access_activate`, `broadcast_guest_view`, `broadcast_guest_request`, `broadcast_guest_requests`는 `service_role` 전용이다. 미인증 GET은 고객 데이터 없이 401, POST는 같은 출처 Origin 필수. 관리자 요청 목록·승인/반려는 JWT manager 전용 `broadcast_customer_request_page`, `broadcast_customer_request_review` RPC다. `POST /customer/:locator/requests`는 `{kind:addition|change,target_id,raw_text,request_key}`로 원문과 재시도 키를 받는다. 실제 고객/관리자 Flutter 경로는 `/broadcast/:locator`, `/seller/broadcast/requests`이며 기능 플래그를 요구한다. `/access/revoke` 고객 API와 실브라우저 연속 검증·처리함 통합은 아직 없다.
- GET /me, /catalog; POST /me/orders(rawText+productId+idempotencyKey), /me/change-requests(lineId,reason), /me/address(expectedVersion). 타 고객 ID 파라미터 무시가 아니라 거절/세션 범위 검사.
- B03-v0.2.0 로컬 구현: 관리자 JWT 전용 `broadcast_billing_command(seller,command,data,key)`의 `destination.country`, `deposit.verify`, `invoice.issue`와 `broadcast_billing_preview` 후보 조회. `/seller/broadcast/billing`에서 고객·회차 검색/선택, 배송국가·실수취 선입금 기록, 미청구 행 확인·청구 발행을 연결한다. 청구는 미청구 행·설정 스냅샷과 KRW 확인 선입금 잔액을 같은 거래에서 고정/배분한다. 고객 게이트웨이 `GET /customer/:locator/billing`, `POST /customer/:locator/address {address,expected_version}`, `POST /customer/:locator/invoices/:id/accept {}`는 활성 기기 세션만 허용한다. 고객 조회는 직원/거래처 원본 정보를 반환하지 않는다. 청구 재발행·반환·수취 안내·고객 통화 선택은 후속이다.
- B03-v0.2.1 `202609290002`: 관리자 `broadcast_receiver_command(seller,{method,holder,instructions,active,verified},key)`와 `broadcast_receiver_page(seller)`로 한국 계좌(KRW)·위챗페이/알리페이(CNY)의 텍스트 수취 안내를 설정한다. 활성화 시 관리자가 실제 계정을 확인했다고 표시해야 한다. `invoice.issue` 삽입 트리거가 그 시점의 활성·확인된 안내를 `snapshot.receiver_snapshots`에 고정한다. 고객 청구 조회의 기존 `snapshot`에 포함되며 고객 화면은 해당 청구에서 가능한 통화만 선택한다. QR 업로드/안내는 미구현이며 안내가 없는 기존 청구에는 새 송금 신고 버튼을 잠근다. 재발행·선입금 반환은 후속이다.
- B03-v0.3.0 `202609290003`: 관리자 `broadcast_invoice_revision_preview(seller,customer,session)`은 현재 청구 행/잠금 상태를 반환한다. `broadcast_invoice_revise(seller,invoice,excluded_line_ids,reason,key)`는 미입금·미증빙·미발주 상태에서만 제외 주문을 취소 표시하고, 기존 판본을 `superseded`로 보존한 채 같은 시리즈 다음 판본을 발행한다. 옛 청구 스냅샷과 주문 원문·순번은 불변, 선입금 배분은 이전 할당을 역전하고 새 청구에 다시 할당한다. 고객은 `issued` 판본만 기본 화면에 보고 새 판본에 다시 동의한다. 고객 수정 요청 처리함과 재발행 결과 연결은 후속이다.
- B03-v0.4.0 `202609290004`~`006`: `broadcast_customer_request_page`는 현재 청구 ID·행 판본·단가를 반환한다. 청구된 변경 요청은 `broadcast_invoice_revise_request(seller,invoice,request,change,reason,key)`가 행 정정/취소·선입금 재배분·새 청구 발행·요청 해결을 원자적으로 처리한다. 증빙 예약/입금/발주 시작 후에는 거절한다. `broadcast_deposit_return(seller,{deposit_id,amount_krw,receiver,transaction_ref,reason,returned_at},key)`는 실제 반환만 미배분 잔액 안에서 기록하며 `GET /customer/:locator/deposit-returns`는 활성 기기에 반환 금액·일자·사유만 제공한다. `broadcast_manager_destination(seller,customer)`와 `broadcast_manager_address(seller,customer,address,expected_version,reason,key)`는 판매자 주소 정정과 감사 기록을 제공한다. 배송국가 변경은 거절하고 이전 출고 주소는 보존한다. 모든 관리자 명령은 판매자 JWT·멱등 키를 요구한다.
- B03-v0.5.0 `202609290008`: 관리자 `broadcast_invoice_revise_line(seller,invoice,{order_line_id,expected_version,color,size,quantity,unit_price_krw,cancelled},reason,key)`는 고객 요청이 없는 판매자 입력 정정을 같은 판본 규칙으로 처리한다. `broadcast_invoice_revision_preview`의 각 행은 현재 `current_version`을 포함한다. 마지막 청구 상품을 취소하면 다음 빈 청구 대신 기존 청구 상태를 `void`로 기록한다. 고객 요청 정정에도 같은 전량 취소 규칙이 적용된다.
- B03-v0.6.0 `202609290005`: 관리자 `broadcast_deposit_void(seller,deposit_id,reason,key)`는 실제 미수취 오기입만 무효화한다. 원래 선입금 행과 사유는 보존하며 청구 후보/발행의 사용 가능 잔액에서 제외한다. 활성 청구 배분이나 실제 반환이 있으면 거절한다. 고객의 이미 발행된 청구에 배분된 금액을 직접 소거하지 않는다.
- B03-v0.7.0 `202609290010`: 관리자 `broadcast_receiver_qr_attach(seller,method,object_id,content_type,key)`는 `broadcast-receiver-qr` 비공개 버킷의 판매자 경로에 실제 파일이 있어야 위챗/알리 QR을 연결한다. `broadcast_receiver_page`는 QR 등록 여부만 반환한다. 수취 명의/안내/활성 상태 변경은 새 청구용 QR 연결을 해제한다. 청구 스냅샷에는 당시 QR ID/형식이 고정된다. 고객 `GET /customer/:locator/invoices/:id/receiver-qr/:method`는 활성 기기·해당 고객의 `issued` 청구를 서버에서 확인한 뒤 비공개 이미지를 프록시하고 캐시를 금지한다. Storage 정책은 [별도 버킷 SQL](../../../supabase/storage/broadcast_receiver_qr_bucket.sql) 적용이 필요하며 실제 Cloud 업로드는 미검증이다.
- B03-v0.8.0 `202609290011`: 관리자 `broadcast_invoice_country_revise(seller,invoice,country,reason,key)`는 미입금·미증빙·미발주 청구만 국가를 정정한다. 이전 청구/선입금 배분을 보존하고 배송비·환율을 새 판본에 다시 계산하며 주소를 비우고 새 고객 최종 확인을 요구한다. 입금 진행 후에는 자동 변경을 거절하고 운영 예외로 처리한다.
- B03-v0.8.1 `202609290012`: 관리자 `broadcast_invoice_revise`가 현재 청구의 모든 상품을 제외하면 새 빈 청구를 만들지 않고 기존 청구를 `void`로 처리한다. 선입금 배분은 되돌리고 원 주문·청구 이력과 멱등 결과를 보존한다. 관리 화면은 전량 선택 시 ‘정산서 무효화’를 표시한다.
- POST /staff/invoices/draft, /issue, /revise; /deposits/verify, /allocate: 최종 목표 API. 금액 서버 재계산, 환율/수취계정 스냅샷, 중복차감 금지.
- POST /me/evidence/reserve, /complete, /payments/submit: 실제 파일 검증/비공개 저장 완료 후 제출. POST /staff/receipts/confirm, /reject, /refund-record. 거래 ID 중복 검사, 예금주 일치 강제 없음.
- POST /staff/purchase-orders/preview, /commit; GET /exports/supplier.xlsx, /exports/customers.xlsx: 확정 수취/미발주 수량 잠금 검사, 개인정보 필터.
- POST /staff/arrivals, /allocations/confirm, /defects, /exchanges/receive: 주문순 배정, 초과수량 거부, 중복 수신 재시도 안전.
- POST /staff/shipments: 정상 배정 미출고 잔량 검사, 주소와 송장 원자적 저장. 고객 부과 배송비는 추가0.
- GET /staff/tasks; POST /staff/tasks/{id}/resolve: 서버 조건 미해결이면 해결 거절. 72시간 무입금/14일 초과 미송 파생 조건을 조회+스케줄러로 보완.

### B04~B08 로컬 첫 구현의 실제 경로

- B04 `202609280007`: 고객 게이트웨이 `POST /customer/:locator/evidence?invoice=<uuid>&key=<uuid>`는 이미지 원본 최대 5MB의 MIME/파일 서명을 검사하고 비공개 `broadcast-evidence` Storage 버킷에 서버 키로 업로드한다. 고객 `POST /customer/:locator/receipts`, `GET /customer/:locator/payments`; SQL `broadcast_guest_evidence_reserve`, `broadcast_evidence_stored`, `broadcast_guest_receipt_submit`, 관리자 `broadcast_receipt_page`, `broadcast_payment_command`의 `receipt.confirm|reject`, `refund.plan|confirm`. B04-v0.2.0에서 고객 파일 제출과 판매자 증빙 대조 Flutter 화면을 연결했다. 실제 버킷/정책 적용과 실브라우저 조작은 후속이다.
- B04-v0.2.1 `202609290001`: 관리자 `broadcast_receipt_request_info(seller,receipt,reason,key)`와 고객 `GET /customer/:locator/receipts/needs-info`, `POST /customer/:locator/receipts/:id/supplement {evidence_id}`를 연결했다. 보완은 기존 receipt ID·신고 금액을 유지하고 비공개 캡처 이력을 남긴다. 보완 중 확정과 과거 캡처의 새 수취 재사용을 서버에서 거절한다. 실제 Storage/실브라우저 검증은 후속이다.
- B05 `202609280008`·`012`, `202609290009`: manager JWT `broadcast_purchase_preview`, `broadcast_purchase_commit`, `broadcast_purchase_tables`, `broadcast_purchase_page`. 거래처표는 고객 필드를 반환하지 않고 최신 원발주 입고 회차·누적 입고·미송·불량교환 대기 수량을 포함한다. 내부 고객표는 출고/입고 배정 수량으로 현재상태를 계산한다. 거래처 메모 칸은 내부 고객 메모를 재사용하지 않고 비워 둔다. Flutter는 두 표를 별도 XLSX로 생성·저장하며 앱의 실제 다운로드 동작은 실기기 검증이 남았다.
- B06 `202609280009`·`015`: manager JWT `broadcast_inventory_command`의 `arrival.record|allocation.commit|exchange.receive`, `broadcast_inventory_status`, `broadcast_defect_page`. 정상 입고만 원 주문순 배정한다. `/seller/broadcast/inventory` 관리자 화면은 부분입고·정상/불량 수량·주문순 배정·불량교환 입고 및 재시도 키를 연결한다.
- B07 `202609280010`·`014`, `202609290007`: manager JWT `broadcast_shipment_ready`, `broadcast_shipment_create`, `broadcast_shipment_history(seller,customer?,before_at?,before_id?,limit?)`; 고객 게이트웨이 전용 SQL `broadcast_guest_shipments`. 고객 출고 목록과 관리자 정상 배정품 부분출고·송장·과거 출고 키셋 페이지를 연결했다. 과거 목록은 출고 당시 주소 스냅샷과 송장·상품별 수량을 반환한다. 실기기·오류 정정 절차는 후속이다.
- B08 `202609280011`·`013`: manager JWT `broadcast_tasks`, `broadcast_task_resolve_address`, `broadcast_invoice_cancel`, `broadcast_missing_detail`. 72시간 미입금은 자동취소하지 않으며 관리자 취소 후 사라진다. 14일 초과 미송은 원 주문 수량의 미배정분을 고객별로 묶고 상품·옵션·거래처·경과일을 상세 조회한다. `/seller/broadcast/tasks` Flutter 관리자 처리함은 업무별 건수를 표시하고 미입금 취소 원문·멱등 키를 기기에 보존해 재시작 후 재확인한다. 실제 JWT 화면·실기기·대량 목록 검증은 후속이다.

## 수용 기준 연결

v1 §48 1~7=B01/B00, 8~11=B02, 12~14=B03, 15~18=B04, 19~20=B05, 21~24=B06, 25~27=B07, 28~29=B08, 30=B09. 동작하는 시안은 해당 API의 완료 증거가 아니다.


## B01 범위 주의

B01 로컬 실행 코드는 고객/방송/상품 생성, 방송 날짜·상태/기한 변경, 상품 정정·소프트삭제/복구·공개 순서·공개/코디, 직원 주문 추가/정정, 미확인 요청 재확인, 보조 담당자 코드 참여/회수, 고객 검색·고객/주문 목록 페이지네이션까지다. 방송 기한은 한국시간 방송 날짜 00시 + 관리일수이며 준비 중 상품 사전등록은 허용하되 접수는 금지한다. supplier는 우선 trim된 문자열이며 B05 전에 거래처 ID를 도입해 별칭/중복명을 정리한다. 별도 테스트 Supabase의 Auth JWT→RPC·동시접속과 카카오 없는 모의 HTTP 참여 링크 화면을 검증했다. 실제 앱의 Cloud 연속 링크·프로세스 재시작·실기기 참여/회수 검증은 B01 잔여다. 시안에 있는 기능을 모두 실제 RPC 완료로 해석하지 않는다.

## v2.1 상세 화면과 예정 API

아래는 **B00 시안/계약**이다. 방송 날짜·상태 및 상품 변경은 위 B01 RPC로 로컬 구현했지만 아래 REST 경로는 아직 실제 서버가 아니다. UI 위치와 검증 상태는 [커버리지](ui-coverage.md)를 참조한다. 변경 API 공통: 직원 JWT/고객 세션, seller 범위, version, idempotencyKey, 서버 권한·수량·금액 검사. 고객 세션에서 직원 API 접근 금지.

| 행동 | 예정 요청 | 결과 / 실패 시 화면 |
|---|---|---|
| 방송 생성/날짜/마감 변경 | POST/PATCH /staff/sessions {date,title,kind,closesAt,status,...} | 회차 전환; 마감 후 신규 주문 거절, 기존 물류 유지 |
| 상품 수정/소프트삭제/복구/공개순서 | PATCH /staff/products/{id} {version,fields}; POST /archive,/restore,/reorder | 접수 이력 상품의 경제 조건 자동 변경 금지; 번호 보존 |
| 수취 안내 변경 | PUT /staff/receivers/{id} {holder,currency,instructions,privateQrObjectId,verified,active} | manager만, 새 청구에 적용; 미확인 활성화 차단 |
| 선입금 확인 | POST /staff/deposits/verify {customerId,receiverId,amount,transactionRef} | 실제 수취 원장 추가, 거래 중복 차단 |
| 증빙 보완 요청/제출 | POST /staff/receipts/{id}/request-info {reason}; POST /me/receipts/{id}/replace-evidence {storedEvidenceId} | needs_info→pending_review; 같은 receipt ID, 수취 합계 불변 |
| 초과 환불 예정/완료 | POST /staff/refunds {invoiceId,sourceReceiptIds,amount,reason}; POST /staff/refunds/{id}/confirm {actualTransactionRef,receivedAt} | 초과금 한도·중복 검사; 실제 송금은 외부 수금 수단에서 수동 수행 |
| 관리자 주소 정정 | POST /staff/customers/{id}/address-revisions {address,reason,expectedVersion} | 사유/전후 기록, 과거 shipment 불변, 입금 후 국가변경은 예외 처리 |
| 새 기기 승인/회수 | POST /staff/access/{requestId}/approve, /staff/devices/{deviceId}/revoke | 기존 위챗 확인 후 요청 기기에 묶인 단회 활성화; 단순 조회로 소비 금지 |
| 변경 요청 반려 | POST /staff/change-requests/{id}/decline {reason} | 고객에게 사유 표시, 주문 원본 유지, 처리함 해결 |
| 표 생성/다운로드 | POST /staff/exports {kind,supplierId,sessionIds}; GET /staff/exports/{id} | queued→ready/failed, 재시도, 다운로드 만료·재생성. 실제 동기 GET .xlsx도 같은 권한 검사 |

### 돈과 상태의 화면 규칙

`확인수취=sum(confirmed receipts)`, `순수취=확인수취−완료환불`, `남은 금액=max(0,청구액−순수취)`, `추가 환불 가능=max(0,확인수취−청구액−예정/완료환불)`을 구분한다. 시안의 초과환불은 청구액을 변경하지 않으며 PG 환불 API를 호출하지 않는다. 보완 중 수취는 확인 합계에 넣지 않는다. 실제 수취 금액이 캡처 신고 금액과 다르면 운영자가 금액/통화 대조 예외로 처리하며 임의 자동 완료 금지.

선입금으로 잔여 청구0이면 `주소 있음 + 최종 청구 동의` 후 완료로 표시한다. 일반 청구의 충분한 확인수취는 별도로 계산한다. 계좌+거래ID 중복은 선입금 수취와 청구 직접입금 원장을 통틀어 검사한다.

주소/옵션/단가 정정으로 청구가 무효화되면 이전 청구 송금 안내를 즉시 닫고 새 정산서 확인을 요구한다. 고객은 복잡한 변경 이력 대신 최종 내용과 변경 안내를 본다. 직원은 원본/사유를 조회한다. 일부 품절은 해당 라인만 취소하며 나머지 주문을 새 정산서에 포함한다.

### 시안 경계

현재 새 기기/역할/수취/증빙/파일 생성은 메모리 상태 전환이다. 증빙 업로드 성공·실패·재시도/영구저장, 데이터 로딩·네트워크 오류, 접근토큰 단회/만료, XLSX 다운로드·실패 재시도는 실제 B02~B05 통합 구현에서 재검증한다. 시안의 ‘파일 생성 완료 체험’은 실제 XLSX 생성 성공을 뜻하지 않는다. 개발 시 이 상태를 빠뜨리지 않도록 [커버리지](ui-coverage.md)의 구현 검증 항목을 따른다.
