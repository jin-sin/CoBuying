# 프로젝트 파악 및 검토 기록 — 2026-09-12

- 검토자: Codex
- 기준 커밋: `099e7ce` (모니터 오탐 정리 — 한 번 실패로는 알리지 않는다)
- 범위: Claude의 인계 문서, 실행 설정, 최근 변경 이력, Flutter 주요 흐름, DB 스키마, 로컬 검사
- 상태: 초기 구조 파악 완료. 아래 문제는 미수정이며, 운영 DB 재현은 아직 수행하지 않았다.

## 프로젝트 이해

오렌담마켓은 셀러 입점형 공동구매 플랫폼이다. Flutter 단일 코드베이스가 Android·iOS·웹 화면을 담당하고, 구매자·셀러·관리자 기능을 함께 제공한다.

| 영역 | 역할 | 주요 진입점 |
| --- | --- | --- |
| 앱 시작·환경 | Supabase 초기화, 한국어 설정, 푸시 초기화, 점검 안내 | [main.dart](../../lib/main.dart), [env.dart](../../lib/core/env.dart) |
| 화면 이동·인증 | go_router 경로, 로그인 필요 경로, 소셜 로그인 | [app_router.dart](../../lib/router/app_router.dart), [auth_repository.dart](../../lib/features/auth/auth_repository.dart) |
| 상품·주문 | 상품 조회, 옵션, 장바구니, 주문 생성·취소·배송 | [products_repository.dart](../../lib/features/products/products_repository.dart), [orders_repository.dart](../../lib/features/orders/orders_repository.dart) |
| 판매·운영 | 입점, 전용 스토어, 배송 관리, 정산·환불 | [seller_repository.dart](../../lib/features/seller/seller_repository.dart), [admin_home_page.dart](../../lib/features/admin/admin_home_page.dart) |
| 거래 규칙 | 가격·옵션 검증, 재고 차감, 권한, 공동구매 마감, 환불 | [schema.sql](../../supabase/schema.sql) |
| 배포·운영 | NAS 웹 배포, 백업, 점검 안내, 푸시, 외부 장애 감시 | [deploy_web.sh](../../tools/deploy_web.sh), [Supabase 운영 문서](../../supabase/README.md), [모니터 문서](../../tools/cloudflare/monitor-worker/README.md) |

앱의 일반적인 흐름은 화면 → Riverpod Provider → Repository → Supabase 조회/RPC다. 핵심 거래 규칙은 PostgreSQL 함수와 트리거에 있으므로, 기능 변경 시 Flutter와 SQL을 함께 확인해야 한다. 데이터 변경 후에는 관련 Provider를 무효화해 다시 조회하는 방식이다.

운영 문서에 따르면 웹과 Supabase는 시놀로지 NAS에서 실행하고, Cloudflare는 점검 안내·푸시 전송·외부 감시를 담당한다. NAS의 정기 전원 종료 시간은 02:00~08:00 KST다. 이는 문서에 기록된 구성으로, 이번 검토에서 운영 서버 상태를 직접 확인하지 않았다.

## 최근 작업 맥락

Claude가 남긴 로컬 인계 문서 `CLAUDE.md`, `.claude/launch.json`, 최근 커밋을 참고했다.
`CLAUDE.md`는 현재 전역 Git 제외 설정으로 추적되지 않으므로, 이 검토 기록은 저장소의 [README.md](../../README.md)에서도 연결한다.

- 셀러 입점 신청 시 정산 계좌 입력을 승인 이후로 미룸.
- 셀러 전용 공개 판매 링크 `/s/{slug}` 추가.
- 신규 셀러의 기본 수수료율을 0%로 변경. 주문 시점 요율은 주문 아이템에 저장.
- 최소 수량 공동구매(MOQ) 추가. 입금 완료 수량으로 마감 후 성사 여부를 판정하며, 무산한 상품은 아이템 단위로 취소.
- 외부 장애 감시에서 부팅 유예, 재시도, 연속 실패 기준으로 오탐을 줄임.

## 현재 기능의 제한

- **카드결제:** 토스 연동 코드는 있지만 `Env.cardPaymentEnabled` 기본값이 false이고, 클라이언트 키 기본값은 테스트 키다. 웹 배포 스크립트에서도 카드결제 활성화 값을 전달하지 않는다. 운영 DB의 키는 조회하지 않았다.
- **네이버 로그인:** `signInWithNaver()`는 `UnimplementedError`를 발생시키는 미구현 상태다.
- **iOS 푸시:** 운영 문서상 APNs 설정이 남아 있다. 실제 설정 여부는 확인하지 않았다.
- **환불·정산 지급:** 무통장 환불과 셀러 정산 지급은 관리자가 이체 후 기록하는 방식이다. 카드 부분 환불도 문서상 미구현이다.

## 발견 사항

### R1. 부분 취소된 공동구매 상품이 정산 집계에 포함될 수 있음

- 우선순위: 높음 — 셀러 지급액에 영향을 줄 수 있음.
- 상태: 로컬 SQL에서 조건 누락 확인. DB 실행 재현 및 수정 미완료.
- 근거: [schema.sql](../../supabase/schema.sql)의 `seller_settlements` 정의(검토 시점 328행)는 주문 전체 상태가 `paid`, `preparing`, `shipped`, `delivered`인지로만 집계 대상을 정한다. `order_items.status = 'cancelled'`를 제외하는 조건이 없다.
- 연결된 동작: `settle_group_buys()`(2253행)는 MOQ 무산 상품의 아이템을 취소하지만, 다른 유효한 아이템이 남은 주문은 전체 취소하지 않는다. `seller_balances`(477행)는 `seller_settlements`를 사용한다.
- 예상 영향: 주문 일부만 취소되면 취소 아이템의 판매액·수수료·셀러 지급액이 집계에 남아 미지급 잔액이 과다 표시될 수 있다.

후속 검증 시나리오:

1. MOQ 상품 A와 정상 진행 상품 B를 한 주문에 담고 입금 완료 처리한다.
2. A가 목표 미달로 마감되도록 하고 `settle_group_buys()`를 실행한다.
3. A 아이템만 취소되고 B와 주문은 유효하게 남는지 확인한다.
4. 정산 집계에서 A의 금액·수수료가 제외되고 B만 남는지 확인한다.
5. 전체 취소 주문과 같은 셀러의 여러 상품이 섞인 주문도 함께 검증한다.

수정 검토 방향은 정산 집계에서 취소 아이템을 제외하는 것이다. 운영 반영 전 실제 DB 정의와 영향받는 주문·정산 기록도 확인해야 한다.

### R2. 거래 흐름을 검증하는 자동 테스트가 부족함

- 상태: 테스트 파일 조사 기준 확인.
- Flutter 테스트는 [widget_test.dart](../../test/widget_test.dart)의 남은 시간 표시 2건이다.
- 장애 모니터에는 시간대·부팅 유예·하트비트·연속 실패 판정 테스트가 있다.
- 저장소에서 주문 생성·재고·권한·MOQ·환불·정산을 검증하는 테스트는 찾지 못했다.
- 후속 우선순위: R1 재현과 함께 부분 취소·정산 집계 회귀 테스트를 마련한다.

### R3. 인계 문서와 주석 일부가 현재 구현보다 오래됨

- `CLAUDE.md`의 권한 절은 관리자만 상품 등록·수정할 수 있다고 설명하지만, 실제 상품 RLS는 승인 셀러의 본인 상품 등록도 허용한다.
- `CLAUDE.md`의 구조 설명에는 입점 신청 때 정산 계좌를 등록한다고 적혀 있으나, 현재 신청 코드에서는 계좌를 받지 않고 승인 후 등록한다.
- `OrdersRepository.cancelMyOrder()` 주석은 입금 대기 상태만 취소할 수 있다고 설명하지만, 최종 DB 함수에는 입금 완료된 카드 주문의 취소·환불 처리도 있다.
- 후속 작업에서 해당 기능을 수정할 때 문서와 주석도 함께 갱신할 필요가 있다.

## 실행한 검사

검사 환경은 Flutter 3.38.5 / Dart 3.10.4다.

| 검사 | 결과 | 해석 |
| --- | --- | --- |
| `flutter analyze --no-pub` | 통과 — No issues found | 정적 분석 결과이며 거래 로직의 정확성을 보장하지 않음 |
| `node --test tools/cloudflare/monitor-worker/worker.test.mjs` | 통과 | 파일 내 35개 검사 통과, Node 테스트 파일 1개 성공 |
| `flutter test --no-pub` | 테스트 시작 전 중단 | `objective_c`의 네이티브 빌드 과정에서 macOS SDK 조회 실패 |
| `xcrun --sdk macosx --show-sdk-path` | 종료 코드 69 | Xcode 라이선스 미동의가 직접 원인으로 확인됨 |

Flutter 테스트가 통과한 것으로 간주하면 안 된다. Xcode 라이선스 문제가 해결된 환경에서 다시 실행해야 한다.

## 검토 범위와 인계 상태

- 운영 서버 접속, 실제 로그인·구매·결제, DB 재현, 웹·모바일 빌드 및 화면 검증은 수행하지 않았다.
- 검토 시작 시 `tools/cloudflare/monitor-worker/worker.js`에 기존 미커밋 변경 1건이 있었다. 실행 위치(colo)와 검사 결과를 로그에 남기는 19행 추가이며, 이번 검토에서 수정하지 않았다.
- 이번 후속 작업에서는 이 검토 문서를 만들고 `README.md`와 로컬 `CLAUDE.md`에 연결을 추가했다. R1을 포함한 기능 수정·배포·커밋은 수행하지 않았다.
- 다음 검토자는 이 문서의 기준 커밋과 현재 코드 차이를 먼저 확인하고, R1을 재현한 뒤 해결 여부와 검증 결과를 기록하면 된다.
