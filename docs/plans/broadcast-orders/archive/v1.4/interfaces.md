# 화면·API 규약 v1.4

브랜드는 **오렌담마켓 / ORENDAM**(축약명: 오렌담)으로 표시한다. `sellerName`과 수취인 이름에는 실제 셀러/수취 주체를 사용하고 플랫폼 이름으로 대체하지 않는다. 시안의 ‘샘플옷장’은 가상 셀러다. 이번 명칭 변경으로 엔드포인트·주문 상태·ID를 바꾸지 않는다.

[계획](README.md) · [타입 계약](contracts.d.ts) · [시안](../../prototypes/broadcast-orders/index.html)

현재는 설계다. 아래 엔드포인트와 접근 제어는 아직 서버에 존재하지 않는다. 시안은 가상의 동일 회차에서 손님 A/B, 보조 담당자, 수금 확인자의 역할을 바꾸며 확인한다. 데모 전환 버튼은 실제 고객 화면에 넣지 않는다.

## 화면 계약

| ID / 화면 | 진입·입력 | 주요 동작 / 완료 표시 | 꼭 필요한 예외 |
|---|---|---|---|
| C1 방송 상품 | 고정 공개 링크, 현재 회차·번호·이름·가격 | 상품 선택 → 옵션·수량; 과거 담은 상품은 회차가 바뀌어도 유지 | 방송 전 빈 화면, 품절, 지연·재시도, 회차 종료 |
| C2 상품 선택 | 불변 상품 ID, 선택 목록 또는 고객 옵션 메모, 수량 1~99 | 내 구매 요청에 담기. 목록의 소개 상품이 바뀌어도 대상 유지 | 미선택·가격 변경 시 확인, 마감 시 저장 거부 |
| C3 내 구매 요청 | 첫 저장에 별명·연락 수단, 이후 수량 수정 | 변경된 초안은 이름·가격·옵션의 전후 표시 → 재확인 또는 제거 → 요청 저장 | 확인 전 저장 차단, 최종 서버 검사, 응답 유실 재시도·다른 손님 분리 |
| C4 배송지·청구서 | 중국 주소 입력 → 담당자 발행 후 확정 수량·배송비 확인 | 최종 청구서 동의 → 송금 안내 | 미발행 대기, 부분 공급 강조, 구 버전 재동의 |
| C5 송금 안내·증빙 | 사용 가능한 위챗/알리페이 수취 경로 선택, 거래 캡처 | ‘입금 확인 요청’은 저장 완료된 첨부 1장 이상일 때 활성 | 업로드 진행·실패, 안내 중 이탈·복귀, 청구서 변경 |
| C6 입금·배송 상태 | 내 청구서 | 확인 대기 / 추가 확인 / 완료 / 배송 | 보완 사유와 재첨부, 미입금 출고 금지 |
| C7 주문 복구 | 일반 링크는 자격 확인, 별도 개인 복구 링크는 일회용 | 명시적 연결 버튼 → 해당 주문 범위 세션 | 만료/이미 사용/다른 손님: 담당자 연결, 자동 병합 금지 |
| S1 현장 상품 관리 | 담당자 로그인, 허용 셀러·회차 | 이름·가격 등록, 접수 전 수정·삭제/복구, 판매 중지/재개, 접수 마감 | 접수 이력 후 수정·삭제 잠금과 이유 표시, 스냅샷 보존, 번호 재사용 금지 |
| S2 요청·청구 관리 | 회차별 고객 요청 목록, 공급 수량·단가·배송비 | 주소 준비된 요청만 청구서 발행, 변경 이유 기록 | 주소 미입력, 동시 수정 충돌, 수취 확인 중 수정 차단 |
| S3 입금 확인 | 수금 확인자 전용 목록, 증빙 + 실제 수취 대조 | 실제 거래 확인 체크·거래 식별자 기록 후 확정 | 금액/수취인 불일치, 중복 거래, 추가 확인 사유 필수 |
| S4 배송·마감 | 입금 확인된 청구서, 중국 주소, 송장 | 배송 기록, 회차별 집계·CSV | 부분/초과 송금, 취소·환불 기록 분리 |

UI는 기존 오렌담마켓의 주황색(#FF6B35), 밝은 바탕, 둥근 카드와 큰 터치 버튼을 따른다. 모바일 320px에서도 가로 넘침 없이 필수 버튼을 누를 수 있어야 한다. 업로드나 저장 중에는 이중 전송을 막되 실패 원인과 재시도를 제공한다. 16px 이상 입력 글자와 44px 이상 주요 터치 영역, 키보드 포커스·텍스트 오류 설명을 적용한다. 숫자 금액은 통화를 항상 붙인다.

공유 라우트는 `/s/{slug}/live`를 nginx에서 `/#/s/{slug}/live`로 넘긴다. 개인 주문 주소는 `/#/broadcast/me/{requestId}`이며 ID 자체는 접근 자격이 아니다. 일회용 복구 주소는 `/#/broadcast/recover?token=<opaque>`처럼 **토큰 전체를 fragment 안에** 둔다. Flutter 해시 라우팅과 별도의 두 번째 `#`를 섞지 않는다. 복구 화면에서 토큰을 메모리에 읽은 뒤 주소에서 제거하고, 사용자가 연결 버튼을 누르면 exchange API로 POST한다. 새로고침으로 토큰이 사라지면 원래 받은 링크로 재진입하게 한다. exchange의 동일 키 재시도는 같은 결과, 다른 키로 소비된 토큰 재사용은 거부한다. analytics·오류 수집에는 원래 복구 URL을 기록하지 않는다.

## API 공통 규칙

기준 경로는 `/api/broadcast/v1`. JSON은 camelCase, 시간은 UTC ISO8601, 금액은 `{currency, minor}`다. ID는 추측 불가능해도 권한 검사 대상이다. 응답에서 다른 손님의 정보를 제공하지 않는다. 목록은 페이지 크기 기본 50/최대 100, cursor 방식이다. 공개 응답에는 개인 주문·주소·입금 정보가 없다. 개인 응답은 `Cache-Control: no-store`다.

표의 `M`은 `MutationContext`, `C`는 `CreateContext`다. 수정은 `If-Match: <version>`, 모든 생성·결제·발행은 `Idempotency-Key`를 사용한다. 키는 동일 주체·경로·payload 해시 범위에서 24시간 보존하고 같은 키의 같은 요청에는 같은 결과를 반환한다. 다른 본문 재사용은 409. 만료 이후에도 guest+session 요청 유일 제약, active submission 유일 제약, 수취 거래 유일 제약을 유지한다. 응답 유실 시 같은 키로 재시도하고 성공을 추측하지 않는다.

`VERSION_CONFLICT/PRICE_CHANGED/INVOICE_CHANGED`는 최신 내용을 다시 보여 주고 고객 확인 후 새 키로 재요청한다. 가격은 서버 상품/청구서로 계산한다. 클라이언트의 총액을 신뢰하지 않는다. 존재하지 않는 ID와 다른 손님의 ID는 동일한 404로 취급한다. 제한 초과는 429+Retry-After, 점검은 503+재시도 안내다.

## 공개·고객 API

| Method / path | 인증 | 입력 → 출력 / 함수 이름 |
|---|---|---|
| GET `/shops/{slug}/catalog` | 공개 | → PublicCatalog / getCatalog |
| GET `/guest-session` | guest | → GuestAccess / getGuestAccess. 새로고침 후 CSRF 토큰 복원 |
| POST `/guest-sessions` | 동일 출처·제한 적용 | C → Set-Cookie + GuestAccess / startGuest |
| DELETE `/guest-session` | guest + CSRF | 204, 현재 자격 폐기 / endGuest |
| GET `/me/requests` | guest | → PurchaseRequest[] / getMyRequests. 복구 세션은 해당 요청만 |
| GET `/requests/{id}` | 소유 guest | → PurchaseRequest / getRequest |
| POST `/sessions/{id}/requests` | guest + CSRF | contact, lines, C → PurchaseRequest / createRequest |
| PUT `/requests/{id}` | 소유 guest + CSRF | lines, M → PurchaseRequest / replaceRequest. 전체 교체, 삭제는 목록에서 제외 |
| POST `/requests/{id}/cancel` | 소유 guest + CSRF | M → PurchaseRequest / cancelRequest. submitted만 |
| PUT `/requests/{id}/address` | 소유 guest + CSRF | ShippingAddressInput, M → PurchaseRequest / saveAddress |
| GET `/invoices/{id}` | 소유 guest | → Invoice / getInvoice |
| GET `/requests/{id}/invoices` | 소유 guest | cursor → Invoice[] 페이지 / listInvoiceHistory. 이전 청구 읽기 전용 |
| POST `/invoices/{id}/accept` | 소유 guest + CSRF | M → Invoice / acceptInvoice |
| POST `/invoices/{id}/change-request` | 소유 guest + CSRF | InvoiceChangeRequestInput, M → Invoice / requestInvoiceChange |
| POST `/invoices/{id}/evidence` | 소유 guest + CSRF | 버전·파일명·형식·크기, C → EvidenceReservation / reserveEvidence |
| PUT `예약된 uploadUrl` | 단기 업로드 자격 | 파일 bytes → 저장소 응답. 성공만으로 ready 아님 |
| POST `/evidence/{id}/complete` | 소유 guest + CSRF | C → Evidence / completeEvidence. 서버 내용 검사·청구서 연결 |
| POST `/invoices/{id}/submissions` | 소유 guest + CSRF | SubmissionInput, M → PaymentSubmission / submitPayment |
| POST `/recovery/exchange` | 일회용 토큰·Origin 검사 | token, C → Set-Cookie + GuestAccess / exchangeRecovery |

request POST는 첫 저장부터 submitted를 생성한다. UI에서 아직 저장하지 않은 장바구니 초안은 서버 접수와 구분한다. 이미 같은 guest+session 요청이 있으면 덮어쓰지 않고 409와 그 요청 ID를 반환해 PUT으로 편집하도록 한다. 수량·옵션 조합은 중복 라인 없이 정규화한다. 동시 마감은 DB 트랜잭션 안에서 회차를 잠그고 판단한다.

배송지 변경은 청구 발행 전까지 허용한다. 발행 후 배송비에 영향을 줄 수 있는 변경은 담당자에게 요청해 미결제 청구서를 새로 발행한다. 결제 확인 후는 운영 변경 기록과 본인 확인을 거친다. `requestVersion`과 `invoiceContentVersion`을 혼용하지 않는다. 모든 객체의 `version`은 동시 수정 방지용 상태 리비전이다. 청구서 `contentVersion`은 발행 내용 판본이며 동의·입금 상태 변경으로 바뀌지 않는다. 재발행은 새 invoice ID와 증가한 contentVersion을 만들고 이전 invoice를 superseded로 남긴다. 증빙·제출은 invoice ID와 contentVersion에 묶는다.

증빙 예약은 accepted/current invoice에서만, 제출은 ready 증빙이 해당 고객·청구서·버전에 속하는지 확인한 뒤 허용한다. 제출과 paymentState 변경은 한 트랜잭션이다. 한 invoice에 진행 중인 제출은 하나다. needs_info 재제출은 이전 이력을 보존하고 새 제출을 생성한다. 이미지 없는 manual_details는 송금자·금액·시각·사유가 필수이고 동일한 수동 확인 목록으로 간다.

## 운영 API

기존 Supabase JWT의 서명·만료를 서버에서 검증한 뒤 seller scope와 permission을 확인한다. 승인 셀러 여부만으로 다른 셀러의 주문이나 입금 확인 권한을 주지 않는다. 최고 운영자 접근도 감사 로그를 남긴다.

`/staff/`는 검증된 담당자 JWT만 사용하고 비회원 쿠키를 권한으로 해석하지 않는다. 고객 경로는 해당 비회원 접근 자격만 사용한다. 두 자격이 한 브라우저에 있어도 고객 요청을 관리자 권한으로 자동 승격하지 않는다.

| Method / path | 권한 | 입력 → 출력 / 함수 |
|---|---|---|
| GET `/staff/sessions/{id}` | 해당 셀러 담당 권한 | → StaffSessionView / getWorkspace. 본인 권한·초안 포함 |
| POST `/staff/sessions` | manage_catalog | sellerId, title, currency, C → BroadcastSession / createSession |
| PATCH `/staff/sessions/{id}` | manage_catalog | 상태/안내/기한, M → BroadcastSession / updateSession |
| POST `/staff/sessions/{id}/products` | manage_catalog | ProductDraftInput, C → ManagedProduct / saveProduct |
| PATCH `/staff/products/{id}` | manage_catalog | ProductUpdateInput(변경 사유 포함), M → ManagedProduct / updateProduct |
| POST `/staff/products/{id}/availability` | manage_catalog | ProductAvailabilityInput, M → ManagedProduct / setProductAvailability |
| POST `/staff/products/{id}/delete` | manage_catalog | ProductActionInput, M → ManagedProduct / deleteProduct. 논리 삭제 |
| POST `/staff/products/{id}/restore` | manage_catalog | ProductActionInput, M → ManagedProduct / restoreProduct. paused로 복구 |
| GET `/staff/sessions/{id}/requests` | manage_invoices | cursor → 요청 페이지 / listRequests |
| GET `/staff/requests/{id}/address` | manage_shipping | → ShippingAddressInput / getShippingAddress, 열람 기록 |
| POST `/staff/invoices` | manage_invoices | InvoiceDraftInput, C → Invoice / issueInvoice |
| POST `/staff/invoices/{id}/reissue` | manage_invoices | InvoiceDraftInput, M → Invoice / reissueInvoice |
| POST `/staff/invoices/{id}/cancel-request` | manage_invoices | CancelInvoiceRequestInput, M → request + invoice / cancelInvoicedRequest. 고객 전체 제외 요청 확인 후 미송금 주문 취소 |
| GET `/staff/requests/{id}/invoices` | manage_invoices | cursor → Invoice[] 페이지 / listInvoiceHistory |
| GET `/staff/sessions/{id}/submissions` | verify_receipts | cursor → 제출 페이지 / listSubmissions |
| GET `/staff/evidence/{id}/read-url` | verify_receipts | → 60초 URL / getEvidenceReadUrl, 열람 기록 |
| POST `/staff/submissions/{id}/review` | verify_receipts | ReviewInput, M → submission + Receipt/null / reviewSubmission |
| POST `/staff/recovery-links` | manage_invoices | RecoveryIssueInput, C → RecoveryLink / issueRecovery |
| PUT `/staff/invoices/{id}/shipment` | manage_shipping | Shipment, M → Invoice / updateShipment |
| POST `/staff/exceptions` | 취소=manage_invoices, 완료 환불=verify_receipts | 예외 정보, C → ExceptionRecord / recordException |

발행은 회차 closed, 요청 locked, 주소 준비, 실제 수취 설정 확인, 모든 라인 수량/통화 검증 후 원자적으로 처리한다. 공급 수량은 요청 수량 이하, 가격 변동은 표시하고 고객 동의를 받는다. 모두 공급 불가면 0원 청구서 대신 취소한다. 발행한 회차 통화나 수취 설정을 소급 변경하지 않는다.

상품 초안은 가격 null을 허용하는 `ManagedProduct`로 반환한다. 공개 `BroadcastProduct`는 이름·가격이 정해진 published/paused/sold_out 상품만 포함한다. 옵션 선택 목록은 없어도 게시할 수 있다. options=[] 및 allowCustomerNote=true가 기본이며 고객의 옵션 메모(customerNote, 최대 100자)는 확정 재고가 아닌 구매 희망으로 저장한다. 선택 목록이 있는 옵션에는 유효한 optionId/valueId가 필요하다. 옵션 메모는 표시할 때 이스케이프하고 명령/자동 상품 매칭에 사용하지 않는다. 미완성 초안은 담당자 getWorkspace에서만 조회한다. 상품 사진 업로드는 이번 현장 흐름에서 제외한다. 회차 CSV 내보내기는 P5 시작 시 권한 계약을 추가한다. 현재 계약은 핵심 주문·청구·수금 흐름을 우선 정의한다.

## 상품 수정·삭제 규약

### 접수 후 정정 청구 인터페이스 (v1.3)

| 화면 | 입력·표시 | 결과 |
|---|---|---|
| S2 정정 청구 작성 | 고객별 요청 원본, 현재 청구, 확보 수량·청구 단가·배송비, 필수 정정 사유, 정정 후 총액 | 새 판본 발행, 이전 청구 보존, 고객 확인 대기 |
| C4 정정 청구 확인 | 변경 전후 단가·수량·배송비·합계, 정정 사유, 요청 시 단가, 이전 청구 이력 | 명시적 동의 후 해당 청구서 송금 안내 열기 |
| C4a 동의하지 않음 | 다시 확인할 내용, 아직 송금하지 않았다는 확인 | change_requested, 송금 안내 닫기, 고객 요청을 담당자에게 표시 |
| S2 고객 수정 요청 | 고객의 사유와 미송금 확인 | 내용 검토 후 새 청구서 발행. 주문 자동 취소/상품 교체 없음 |

- 최초 발행도 요청과 수량·단가가 다르면 changeReason을 요구한다. 재발행은 항상 필수다. 서버가 원 요청/직전 청구로 changes를 산출하며 클라이언트의 비교값·합계를 신뢰하지 않는다. 요청 시 단가와 직전 청구 단가를 구분하여 표시한다. 0원 또는 모든 수량 0인 청구 대신 별도 취소 절차를 사용한다.
- 원 상품 이름·옵션·공개 단가와 원 구매 요청은 고정한다. 수정하는 것은 고객별 청구 제안이다. 다른 실제 상품이나 옵션으로 교체하는 UI는 제공하지 않으며 새 ID·번호와 고객의 별도 요청이 필요하다. 금액 정정 대상의 판매 중지와 사유 기록을 보존한다. 마감된 회차는 신규 요청 차단을 유지한다.
- 고객의 거절은 주문 취소가 아닌 확인 요청이다. 현재 invoice ID/contentVersion과 사유(1~300자), 미송금 확인을 검증하고 status=change_requested로 바꾼다. 과거 동의 이력은 보존하고 현재 동의는 유효하지 않게 한다. 고객이 응답하지 않으면 계속 확인 대기이며 동의로 간주하지 않는다.
- 재발행은 paymentState=unpaid이면서 status=issued 또는 change_requested에만 허용한다. accepted 상태는 고객에게 송금 안내가 이미 열렸으므로 담당자가 바로 수정할 수 없다. 고객이 미송금을 확인해 수정 요청을 남긴 뒤 처리한다. pending_review/needs_info/confirmed는 직접 정정과 고객 미송금 수정 요청 모두 PAYMENT_LOCKED이며 기존 수취 대조·예외 절차로 간다. unpaid라는 값만으로 미송금이 확실하다고 추정하지 않는다.
- 증빙 예약/업로드가 진행 중이거나 저장된 증빙이 연결된 경우 미송금 수정 요청과 재발행을 차단한다. 실제 송금 후 수정 요청을 잘못 남긴 사례는 별도 거래 확인이 필요하다. 시안은 첨부 없음 상태에서만 체험한다.
- 동의, 수정 요청, 청구 재발행, 증빙 예약/제출은 같은 요청·현재 청구 잠금 아래 원자적으로 검사한다. 먼저 처리된 결과에 따라 뒤 작업은 VERSION_CONFLICT/INVOICE_CHANGED/PAYMENT_LOCKED로 거부한다. 재발행은 새 ID/contentVersion을 만들고 이전 동의/증빙을 복사하지 않는다. change_requested와 superseded 청구는 동의·송금 안내·증빙 접수 대상이 아니다. 고객은 새 청구서를 받아야 다시 동의할 수 있다.
- 이전 청구와 수정 요청 사유는 고객 본인과 해당 셀러의 청구 권한자만 조회한다. 과거 판본은 ‘송금 대상 아님’으로 표시하며 그 화면에서 송금 동작을 제공하지 않는다. 목록/알림 문구에서 `고객 확인 대기`, `고객 수정 요청`, `판매자 확인 대기`를 구분한다.
- 시안 상단 ‘정정 상황 체험’은 가상 데이터로 초기화하여 1차 ¥188 → 2차 ¥208 사례를 연다. 담당자 정정 → 고객 수정 요청 → 재발행 → 재동의까지 메모리 상태로 체험한다. 실제 고객에게 메시지를 보내거나 송금하지 않는다.

### 상품별 제외 요청과 전체 취소 (v1.4)

| 화면 | 고객/담당자 행동 | 상태와 표시 |
|---|---|---|
| C4 상품별 제외 요청 | 해당 상품의 ‘이 상품 제외 요청’ → 옵션별 항목 선택 → 제외·미송금 확인 | remove_items 요청. 현재 청구 금액은 유지하며 송금 안내를 닫음 |
| C4 처리 대기 | 제외 요청한 상품·색상·사이즈·전체 수량 확인 | 담당자가 반영하기 전임을 표시. ‘처리 전 청구 금액’으로 구분 |
| S2 일부 제외 반영 | 요청한 각 항목의 ‘청구에서 제외’ → 남은 상품의 배송비 재확인 → 변경 사유 → 새 청구 발행 | 발행 전까지 편집 초안. 제외 취소 버튼은 이 초안에만 적용 |
| C4 새 청구 확인 | 남은 상품·배송비·최종 금액과 ‘청구에서 제외된 상품’ 확인 | 새 청구서 동의 후 송금 안내. 원 요청과 과거 청구는 이력으로 유지 |
| S2 전체 주문 취소 | 모든 현재 청구 항목의 제외 요청을 확인 → 취소 사유·확인 체크 → 취소 확정 | request=cancelled, invoice=void. 새 0원 청구서를 만들지 않음 |
| C4 취소 완료 | 취소 사유·담당자·시각·과거 청구 확인 | 송금할 금액 없음. 재동의·증빙·재발행 버튼 없음 |

- 제외 대상은 `requestLineId`로 특정한다. 같은 상품의 색상/사이즈가 다르면 별도 항목이다. 상품 번호·화면 인덱스·자유 입력 사유를 서버 식별자로 사용하지 않는다. removeRequestLineIds는 비어 있지 않고 중복이 없어야 하며 현재 고객의 현재 청구에서 포함 상태인 항목만 허용한다. 선택한 항목의 현재 청구 수량 전체를 제외하는 동작이고, 일부 수량 변경은 일반 수정 요청으로 구분한다.
- 고객은 대상 항목을 확인하고 confirmedRemoval 및 ‘현재 청구 상품을 전부 선택하면 취소 요청’에 명시적으로 동의한다. confirmedNotTransferred도 필수다. `remove_items` 요청의 참조 ID·대상 스냅샷·사유·확인 시각을 저장한다. 이미 접수된 요청이 있으면 추가 요청으로 조용히 덮어쓰지 않는다. 같은 멱등 요청은 같은 결과를 반환한다.
- 담당자는 이름·옵션을 바꾸지 않고 선택한 라인을 excluded=true/confirmedQuantity=0/lineTotal=0으로 새 청구에 남긴다. exclusionReason을 필수로 기록한다. 합계·지불 대상 목록에서는 제외하고 별도 제외 이력에 표시한다. included 행은 수량 >=1이다. 원 구매 요청이나 과거 청구 행을 삭제하지 않는다. 이미 발행된 제외 항목을 후속 청구에 다시 포함하는 것은 거부하고 별도 신규 요청을 받는다.
- 현재 제외 요청이 있으면 재발행에 resolvesChangeRequestId가 필수이며 최신 요청 ID와 일치해야 한다. 고객이 지정한 모든 항목을 제외하지 않은 재발행은 거부한다. 초안에서 수량 0으로 바꾸는 우회나 잘못된 ID를 제출하는 우회도 같은 검사를 받는다. 추가 품절 등으로 다른 항목을 제외하려면 해당 사유도 별도로 기록하고 새 청구 전체를 고객이 확인한다.
- 일부 제외 시 배송비를 자동으로 0원 또는 비례 금액으로 바꾸지 않는다. 담당자가 남은 상품 기준으로 배송비를 재확인하고 shippingRecheckedAfterExclusion=true를 제출해야 한다. 확인하지 않은 배송비를 포함해 새 청구를 발행하지 않는다. 새 판본의 전체 금액을 고객이 다시 동의해야 한다.
- 모든 **현재 포함 항목**에 대한 고객 제외 요청이 있고 취소 동의가 기록된 경우에만 cancelInvoicedRequest를 허용한다. 예전에 이미 제외된 항목은 다시 선택할 필요 없다. 일부 제외 요청을 담당자가 임의로 전체 취소로 확대할 수 없다. 자유 입력에 ‘취소’라는 글자가 있어도 구조화된 전체 제외/취소 동의 대신 사용하지 않는다.
- 취소는 현재 청구 ID/contentVersion·고객 변경 요청 ID·소유권·청구 권한·미송금 확인·증빙/지급 상태를 재검사한다. 회차 → 요청 → 현재 청구 및 관련 증빙 순으로 일관되게 잠그고 request=cancelled와 invoice=void, 취소 감사 기록을 같은 트랜잭션으로 처리한다. 상품 접수 이력은 유지하고 일반 상품 수정/삭제 잠금을 풀지 않는다. 과거 총액을 0으로 덮어쓰거나 새 청구서를 만들지 않는다.
- 동의·제외 요청·재발행·취소·증빙 생성/제출은 같은 요청/청구 경계에서 경합을 검사한다. accepted 상태의 직접 취소는 금지하며 미송금 확인을 포함한 고객 요청을 거친다. 증빙 연결/처리 중, pending_review/needs_info/confirmed는 이 미송금 경로의 제외/취소 대상이 아니다. 새 요청·청구 상태가 먼저 처리되면 뒤 작업은 VERSION_CONFLICT/INVOICE_CHANGED/PAYMENT_LOCKED로 거부한다.
- 취소 후 고객은 원 요청·취소된 청구·사유·시각을 읽을 수 있지만 accept/reissue/증빙/배송 상태 변경은 거부한다. 서버가 같은 키의 취소 재시도에 동일 결과를 반환한다. 실제 송금/환불 처리는 기존 예외 범위로 구분한다.
- 시안의 ‘상품 제외 체험’은 니트 2개와 셔츠 1개, 정정 청구 ¥316을 준비한다. 니트 제외 후 셔츠 ¥108 + 담당자가 확인한 배송비를 새로 청구하거나, 두 항목 전부 제외 요청 후 담당자 취소 확인을 체험한다. 실제 서버·실거래 취소는 구현하지 않는다.

### 일반 상품 수정 규칙

- 상품 번호는 서버에서 회차별 잠금 또는 원자적 시퀀스로 배정하고 `(sessionId, number)` 유일 제약을 둔다. 클라이언트는 희망 번호를 쓰지 않는다. 삭제/복구 후에도 ID·번호가 유지되고 번호를 재사용하지 않는다.
- updateProduct는 접수 이력이 없을 때만 허용 필드를 변경하고 version을 증가시킨다. 요청 이력이 있으면 이름·단가·옵션·옵션 메모 허용 여부를 포함한 일반 PATCH 전체를 409 `PRODUCT_LOCKED`로 거부한다. 취소된 요청도 이력이며 요청에서 해당 라인을 뺀 뒤에도 이력을 유지한다. state·number·참조 이력 필드를 일반 PATCH로 바꾸거나 요청/청구 스냅샷을 함께 UPDATE하지 않는다. 시안의 everOrdered는 모의 값이며 실제 서버는 영구 이력을 사용한다.
- ManagedProduct.canEdit/canDelete는 담당자 권한·회차/상품 상태·접수 이력에서 서버가 산출한다. S1은 수정 버튼 비활성 및 ‘요청 접수됨 · 정보 고정’ 이유를 표시한다. 이 응답이 오래되거나 이미 편집창을 열었더라도 서버가 저장 시 재검사한다. 버튼이나 클라이언트 전달 이력 값을 권한 근거로 삼지 않는다.
- updateProduct와 요청 저장은 회차 → 상품 ID 정렬 순서 → 요청 순으로 동일하게 잠그고 최신 상태·접수 이력·버전 검사와 변경을 하나의 트랜잭션에서 끝낸다. 수정이 먼저 커밋되면 구버전 요청에 `PRODUCT_CHANGED`; 첫 요청이 먼저 커밋되면 수정에 `PRODUCT_LOCKED`를 반환한다. 다중 상품 요청은 전체 검증 후 원자적으로 접수하며 일부만 성공시키지 않는다. 정확히 같은 멱등 요청의 성공 응답 재전달은 새 수정으로 처리하지 않는다.
- deleteProduct는 상품 잠금과 참조 검사 후 이력이 없을 때만 state=deleted로 바꾸고 사유/행위자/시각을 기록한다. 요청 생성과 동일 잠금 순서로 처리해 경합 중 요청이 먼저 저장되면 `PRODUCT_HAS_REQUESTS`, 삭제가 먼저면 고객 요청에 `PRODUCT_UNAVAILABLE`을 반환한다. 실제 행을 지우거나 다른 주문을 cascade 삭제하지 않는다.
- deleted는 고객 목록에서 제외한다. restore는 원래 ID·번호로 paused 상태 복구 후 담당자가 확인하여 재개한다. draft/published/paused/sold_out은 참조가 없으면 삭제 가능, deleted만 복구 가능. availability의 published 전환은 게시 필수값과 회차 open을 검사한다. 마감된 회차의 편집/삭제/재개는 거부하고 청구·예외 절차로 처리한다.
- paused/sold_out는 고객에게 ‘판매 중지/품절’로 표시하고 신규 요청·수량 증가를 막는다. 이미 저장한 요청 유지/감소/삭제는 가능하다. 상품 중지 자체는 기존 요청의 취소나 환불을 의미하지 않는다.
- 요청 PUT은 저장된 동일 라인(상품·선택 옵션·정규화된 customerNote)의 동일 버전 및 수량 감소/유지에는 기존 스냅샷을 보존한다. 신규·증가·옵션 변경은 published 상태와 최신 productVersion 검사가 필요하다. 클라이언트가 보낸 구버전 가격을 신뢰하지 않고 서버가 저장된 라인을 조회한다.
- 저장하지 않은 초안이 수정 전 버전이면 409 `PRODUCT_CHANGED`(가격만 다르면 `PRICE_CHANGED`도 가능), 삭제/중지된 상품이면 `PRODUCT_UNAVAILABLE`을 반환한다. C3은 기존 로컬 초안과 최신 공개 상품의 이름·개당 가격·옵션을 비교 표시한다. 고객은 현재 옵션을 재선택해 ‘변경 내용 확인하고 담기’를 누르거나 해당 상품을 뺀다. 확인 전 요청 저장은 비활성이고 서버도 거부한다. 기존 수량은 입력 초기값으로 보존하되 새 옵션을 자동 선택하거나 초안의 productVersion/가격을 몰래 최신 값으로 치환하지 않는다.
- 확인을 마친 뒤 저장 전에 다시 변경되면 새 충돌을 표시한다. 충돌로 실패한 요청을 다른 버전/가격으로 자동 재시도하지 않는다. 이미 접수된 라인의 유지/감소는 위 스냅샷 규칙을 적용한다. 상품 version은 판매 상태 변경에도 증가하므로, 가격/옵션이 같으면 가격 변경이라고 표시하지 않고 판매 상태가 갱신되었다고 안내한다.
- 앱/탭 복귀, C3 진입 시 공개 상품을 새로 조회하고 로컬 초안은 보존한다. 화면이 보일 때 주기적 조회 또는 변경 알림으로 보조하되 주기/연결 방식은 P0/P2에서 중국 회선 비용과 함께 결정한다. 최종 요청 저장의 서버 검사가 기준이며 모든 화면의 즉시 갱신을 보장하지 않는다. 오프라인/응답 유실에는 저장 성공을 추정하지 않는다.
- 접수 후 정정은 판매 중지 → 영향받는 고객에게 정정 내용 표시 → 명시적 확인의 별도 흐름이다. 금액 정정은 이전 단가/정정 단가/사유를 최종 청구에 표시하고, 발행된 미송금 청구서는 reissue로 새 판본을 만든다. 다른 실제 상품으로 교체하는 경우 새 ID·번호로 고객이 별도 요청하게 하고 기존 요청은 고객 확인 후 별도 취소한다. 응답 없는 고객에게 새 상품이나 가격을 자동 적용하지 않는다. pending_review/confirmed는 기존 잠금·예외 규칙을 따른다. 금액 정정/재동의 화면은 v1.3 시안에 포함한다. 고객의 전체 제외 요청에 따른 미송금 취소 화면은 v1.4에 포함한다. 실제 서버, 상품 교체 및 실거래 취소는 P3/P5 후속 범위다. 마감 후 상품 교체가 필요하면 마감 회차를 몰래 재개하지 않고 새 회차의 별도 요청으로 안내한다.

## 권한·동시성 검증 예시

1. A의 requestId를 B가 GET/PUT하거나 증빙 complete에 넣으면 404. staff의 seller scope 불일치도 거부.
2. 손님 두 명의 닉네임이 같아도 별도 요청. 같은 공용 링크는 개인 자료를 포함하지 않음.
3. 저장 응답이 끊겨 같은 키로 재요청하면 ID와 수량이 그대로. 중복 라인·중복 청구서 없음.
4. 담당자가 마감하는 순간 고객이 저장하면 하나의 트랜잭션 순서로 확정. 마감 후 접수 성공 없음.
5. 청구 v1 동의 후 v2가 발행되면 v1 업로드/제출 거부. pending_review이면 재발행 거부.
6. 업로드 성공처럼 보이더라도 객체 누락·형식 오류·다른 손님 소유라면 ready/접수 불가.
7. 보조 담당자가 review 호출하면 403. 확인자도 actualAmount 불일치나 수취 거래 재사용은 거부.
8. 입금 확정과 Receipt 생성은 원자적. 동일 요청 재시도는 중복 집계 없음. 직접 수금의 플랫폼 지급액은 0.

9. 사진·옵션 목록 없이 이름·가격으로 게시 가능. 요청의 자유 입력 옵션이 손님별로 분리되고 최종 청구에서 확인 가능.
10. 삭제/요청 동시 실행 순서에 따른 차단, 삭제 번호 재사용 금지, 복구 후 paused 확인. 주문 이력 상품 삭제 거부.
11. 접수 전 이름/가격/옵션 변경 시 고객 초안 원본 보존·전후 비교·확인 전 저장 거부. 확인 중 재변경, 변경 거절 후 제거, 새 옵션 재선택, 오프라인 복귀를 검증한다.
12. 첫 접수 이후 일반 PATCH의 모든 필드 변경을 거부한다. 편집창을 열어둔 상태에서 다른 손님 접수, 전부 취소/해당 라인 제거 후 재편집도 거부한다. 수정/첫 접수 경합을 양쪽 순서로 검증하며 공개 상품과 저장된 요청의 핵심 정보가 어긋나는 성공 경로가 없어야 한다.
13. 접수 후 판매 중지에도 기존 요청·청구를 보존한다. 정정 가격은 전후·사유가 표시된 새 청구 확인이 필요하고, 동의 전 송금 안내/증빙 접수를 거부한다. 다른 상품으로 고객 요청을 자동 이동하지 않는다.

14. 고객 수정 요청 후 동의/증빙 접수 거부, 담당자 재발행 후에만 새 동의 허용. accepted 청구 직접 재발행 거부, 미송금 고객 수정 요청 후에만 재발행. needs_info/pending_review/confirmed 및 증빙 연결된 건의 정정 차단, 동의/재발행/증빙 예약 경합을 양쪽 순서로 검증한다.

15. 같은 상품의 다른 옵션 항목 중 하나만 제외 요청했을 때 해당 requestLineId만 반영. 다른 고객/과거 청구/이미 제외된 항목/중복 ID를 거부. 제외 대상 누락 재발행 및 배송비 미확인 재발행 거부, 발행된 제외 항목 재포함 거부.
16. 모든 현재 항목 제외 요청에서만 담당자 취소 허용. 원 요청·청구 금액·상품 접수 이력 보존, 고객/담당자 취소 완료 화면 일치, 재동의/송금/재발행/중복 취소 차단. 일부 제외 요청을 전체 취소로 확대하거나 새로운 상태를 구버전 취소로 덮어쓰지 않음.

## 시안 범위

시안은 C1~C6 및 S1~S3의 핵심 경로와 A/B 분리, 업로드 실패, 보완 요청, 배송 표시를 체험한다. 정정 청구·고객 수정 요청·재발행 화면은 포함한다. C7 복구 보안, 실제 파일 업로드·영구 저장·권한·API·동시성, 상품 교체·실거래 취소·예외 환불, CSV는 문서 계약만 있고 시안에서 구현하지 않는다. 시안 데이터를 새로고침하면 초기화하며 실제 계좌·고객 개인정보는 넣지 않는다.
