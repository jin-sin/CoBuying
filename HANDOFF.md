# Claude Code 인계 · 오렌담마켓 / CoBuying

기준: 2026-10-21, `feature/moq-group-buy` / `099e7ce` (`origin/feature/moq-group-buy`와 동일). **이 문서는 작업공간의 미커밋 상태까지 포함한다.** 먼저 `git status --short`와 실제 파일을 대조할 것. 이 문서 작성 중 기능 코드·DB·운영 배포는 변경하지 않았고 커밋도 하지 않았다. 아래의 2026-09~10월 외부 환경 결과는 당시 기록이며 현재 상태를 새로 확인한 결과가 아니다. 비밀번호·토큰·키의 실제 값은 이 문서에 기록하지 않는다.

## 1. 목적과 기능 범위

Flutter 한 코드베이스로 Android·iOS·웹을 제공하는 셀러 입점형 공동구매 마켓이다. 구매자는 상품·옵션 조회, 장바구니, 주문, 찜, 알림, 리뷰를 사용하고, 셀러는 입점·자기 스토어·상품/판매/배송을, 관리자는 승인·주문·정산/환불을 관리한다. Supabase/PostgreSQL의 RLS·RPC·트리거가 거래 금액, 재고, 권한의 최종 기준이다. 타임세일과 MOQ 기능도 있다. 카드결제용 토스 코드가 있지만 `CARD_PAYMENT_ENABLED` 기본값은 `false`이며 실제 운영 결제 가능 범위로 간주하지 않는다. 무통장 환불과 셀러 지급은 수동 처리다. 네이버 로그인과 카드 부분 환불은 미구현이다.

정식 서비스명은 **오렌담마켓**, 축약명 **오렌담**, 영문 **ORENDAM**. 기존 사업자 상호는 별도로 보존한다. 서비스 도메인·패키지/앱 ID·인증/결제 연결 명칭은 브랜드와 함께 일괄 변경하지 않는다. [브랜드 기록](docs/brand.md)에 따르면 2026-09-13 기존 운영 웹과 점검 안내의 표시는 반영됐지만 Android/iOS 스토어 배포는 하지 않았다.

별도 개발 중인 **방송판매 MVP**는 자체 라이브 스트리밍이 아니다. 방송은 더우인, 고객 주문은 방송 중 더우인 채팅, 보조 담당자가 휴대폰에서 한 번 입력한다. 방송 뒤 고객 웹에서 자기 주문·추가/수정 요청·청구서·주소·송금 증빙·배송을 확인하고, 관리자는 수취 확인→거래처 합산발주→입고/미송/불량교환→부분출고/송장을 같은 주문 데이터로 처리한다. 고객에게 방송 중 웹 주문이나 사진 업로드를 강요하지 않는다. 요구 기준은 [판매자 요구사항 v1](docs/plans/broadcast-orders/requirements-v1.md), 구현 계약은 [계획 v2.2.0](docs/plans/broadcast-orders/README.md), [인터페이스](docs/plans/broadcast-orders/interfaces.md), [타입](docs/plans/broadcast-orders/contracts.d.ts), [시안](docs/prototypes/broadcast-orders/index.html)이다.

## 2. 브랜치 목표와 실제 진행

`feature/moq-group-buy`의 **커밋된 목표**는 상품별 최소 수량 공동구매다. `products.min_quantity`가 0이면 MOQ 없음, 양수면 결제 완료된 주문 수량만 공개 `product_progress`에 집계한다. 마감 뒤 `settle_group_buys()`가 목표 달성 여부를 확정한다. 미달 상품은 주문 전체가 아니라 해당 `order_items`를 취소하고 `refund_requests`에 수동 환불 업무를 만든다. 다른 상품은 계속 진행할 수 있다. 5분 주기 pg_cron, 상품/셀러 UI, 관리자 환불 대기 탭과 모니터의 오탐 감소 변경이 `main` 대비 커밋돼 있다 (`570db62`, `099e7ce`). **이 브랜치의 코드가 운영 DB에 모두 적용됐는지는 이번 인계에서 재확인하지 않았다.** 운영 반영은 별도 대조가 필요하다.

이후 방송판매·브랜드·운영 문서/모니터 변경은 **같은 브랜치의 미커밋 작업공간**에 쌓였다. 방송판매 단계 B00~B09 중 B00 문서·시안은 완료 이력이고 B01~B09는 모두 `v0.*` **진행 중**이다. 현재 체크포인트: B01 `v0.2.4`, B02 `v0.2.0`, B03 `v0.8.1`, B04 `v0.2.1`, B05 `v0.3.0`, B06 `v0.3.0`, B07 `v0.4.0`, B08 `v0.4.0`, B09 `v0.2.3`. [단계별 버전](docs/plans/broadcast-orders/stage-versions.md), [현재 인계](docs/plans/broadcast-orders/handoff-current.md), [작업표](docs/plans/broadcast-orders/worklog.md)를 읽고 변경한다. 버전은 Git 태그가 아니며 `v1.0.0` 완료 게이트 통과가 아니다.

방송 기능은 로컬 SQL/RPC·Flutter·고객 게이트웨이로 구현됐고, 별도 Supabase **테스트** 프로젝트에서 B02~B08 증분 SQL 25개와 비공개 Storage 버킷을 적용했다. 당시 두 Auth 사용자/20건 경합·고객 기기 승인·A/B 격리·가상 입금 2회·발주·부분입고·부분출고·송장까지 HTTP로 검증했다. 2026-09-29 임시 HTTPS에서 로그인/고객 첫 화면과 390px 배치만 확인했다. **실제 고객/직원 UI의 30단계 연속 조작, 카카오 복귀, 세 역할의 동시 기기 시험, 중국 본토 무VPN 접속은 미검증**이다. 테스트 프로젝트의 익명 로그인은 마지막 기록상 꺼져 있다. 당시 Quick Tunnel은 4시간짜리 호스트라 현재 재사용할 수 없다. 방송 기능은 운영 NAS DB·운영 웹에 반영하지 않았다.

## 3. 미커밋 변경: 무엇이며 왜 있는가

다음은 `099e7ce` 기준의 `git status`다. **파일이 완성됐다는 표시와 전체 MVP 검증 완료는 다르다.** 기존 변경을 덮어쓰거나 브랜치 전체를 일괄 배포하지 말 것.

| 경로 | 변경 이유 | 상태 |
|---|---|---|
| `README.md` | 오렌담마켓 소개·방송 계획/검토 문서로 안내 | 문서 작성됨, 미커밋. 방송 경로 표기는 실제 웹 해시 경로 `/#/...`와 대조 필요 |
| `android/app/src/main/AndroidManifest.xml` | Android 앱 표시명을 오렌담마켓으로 변경 | 소스 수정 완료, 설치 앱/스토어 배포 미검증 |
| `assets/icon/app_icon.svg` | 아이콘의 접근성 제목만 새 브랜드로 변경 | **픽셀 도형은 그대로**. 신규 도안이나 래스터 아이콘 생성 작업이 아님 |
| `ios/Runner/Info.plist` | iOS 표시명·내부 표시 이름 변경 | 소스 수정 완료, 기기/스토어 배포 미검증 |
| `lib/core/brand.dart`, 새 `lib/core/service_brand.dart` | 워드마크와 정식/축약/영문 브랜드 상수 일원화 | 구현됨, 기존 상호·앱 ID는 그대로 |
| `lib/features/info/legal.dart` | 서비스 브랜드와 기존 사업자 상호를 분리해 약관·개인정보/사업자 화면에 표시 | 문안 반영됨, 별도 법무/등록부 대조는 완료 아님 |
| `lib/main.dart`, `web/index.html`, `web/manifest.json` | Flutter 제목·웹 메타·PWA 이름/설명 변경 | 소스 반영됨. 기존 운영 웹 배포 기록은 [브랜드 기록](docs/brand.md)에 별도 보존 |
| `tools/gen_icons.py`, `tools/cloudflare/README.md`, `tools/cloudflare/maintenance-worker.js` | 아이콘 생성기 설명·점검 페이지 브랜드 문구 수정 | 설명/문구 반영됨. 아이콘 스크립트 동작 변경 없음; 점검 페이지 운영 반영은 과거 기록 참조 |
| `tools/cloudflare/monitor-worker/README.md`, `tools/cloudflare/monitor-worker/worker.js` | 모니터 알림 브랜드 변경 + 실행 Cloudflare colo·검사 결과 진단 로그 추가 | **소스만 변경, 모니터 Worker 미배포**. 기존 미커밋 변경이므로 방송/웹 배포와 묶지 말 것 |
| `supabase/README.md`, `supabase/schema.sql` | 2026-10-16 pg_cron 시작 지연 조사 결과 반영; 5분/10분 작업 시작 분을 분산 | 문서·SQL 동기화됨. 기록상 일정 필드만 운영에 적용됐으나 이번 작업에서 재확인 안 함. 전체 `schema.sql` 재적용 금지 |
| `lib/features/auth/login_page.dart` | debug/test 빌드에서만 익명 테스트 로그인 버튼 추가 | 구현됨; 테스트 환경용. 릴리스에 `BROADCAST_TEST_AUTH` 사용 금지, Cloud 익명 Auth 기본 비활성 |
| `lib/router/app_router.dart`, 새 `lib/router/auth_redirect.dart` | 방송 고객/직원 화면 경로와 로그인 후 초대 코드 복귀 | 구현됨; `BROADCAST_ORDERS_ENABLED` 기본 꺼짐, 실기기 로그인 복귀 미검증 |
| `pubspec.yaml`, `pubspec.lock` | 고객 HTTP, XLSX 내보내기/저장, 테스트용 의존성 추가 | 의존성 갱신됨; 파일 다운로드와 플랫폼 빌드는 실기기 재검증 필요 |
| 새 `lib/features/broadcast_orders/` | B01~B08 직원/고객/관리자 화면, 저장소, 명령 재시도, 입금·발주·입고·출고 | 로컬 구현 + 일부 Cloud HTTP 검증, 전체 현장 UX/기기 게이트 미완료 |
| 새 `services/broadcast-customer-gateway/` | 고정 링크 고객을 HttpOnly 쿠키와 판매자 승인으로 격리, 비공개 파일 프록시 | 로컬/Cloud HTTP 시험됨, 운영 호스팅·브라우저 연속 조작 미완료 |
| 새 `supabase/migrations/`, `supabase/storage/` | 기존 쇼핑몰과 분리된 `broadcast_*` 테이블/RPC/RLS 및 비공개 증빙·QR 버킷 | 테스트 Cloud 적용 기록 있음, **운영 DB 미적용**. 시간순 증분 적용·RLS 확인 필요 |
| 새 `test/broadcast_capture_test.dart`, `test/broadcast_purchase_export_test.dart`, `tools/broadcast-tests/` | 방송 SQL·HTTP·Flutter adapter·프로토타입·XLSX·Cloud 사전검증 | 자동화 작성/일부 통과. 로컬 네이티브 `flutter test`는 당시 Xcode 라이선스 문제로 중단됨 |
| 새 `docs/` | 브랜드/검토/요구/계획/계약/시안/버전/30단계 현장 검증표 | 문서와 시안 작성됨. 과거 버전은 이력이고 실제 구현·운영 완료 증거가 아님 |
| 새 `AGENTS.md`, 루트 `HANDOFF.md` | 지속 협업 규칙과 이번 인계 | 이 작업에서 최신 상태로 정리. 둘 다 Git 추적 전 |
| 로컬 `CLAUDE.md` | Claude Code의 시작 안내 | 이 작업에서 오래된 상태 설명을 정리. **전역 gitignore로 제외**되므로 다음 머신에는 자동 전달되지 않음 |

`tools/broadcast-tests/node_modules/`, 캐시, 빌드 산출물 및 임시 토큰 파일은 인계용 소스가 아니다. 추적/복사하지 말 것. Git 상태의 `??` 디렉터리 안에는 여러 파일이 있으므로 이후 커밋 범위는 파일별로 검토해야 한다.

## 4. 유지할 설계 결정

- **기존 쇼핑몰과 방송판매를 격리한다.** 방송 테이블/RPC/게이트웨이를 새 경로에 두며 기존 RLS·재고·로그인을 전역 완화하지 않는다. 방송 기능은 빌드 플래그 뒤에 있다.
- **방송 중 흐름을 느리게 만들지 않는다.** 신상 사전등록과 특가 현장 빠른등록을 모두 지원하고 사진은 필수가 아니다. 현재 코디는 여러 상품, 미소개 상품은 비공개, 상품번호는 재사용하지 않는다.
- **주문 원본을 보존한다.** 같은 고객·상품·옵션이라도 새 요청은 새 행이고, 같은 저장 동작의 재시도에만 멱등 키를 재사용한다. 서버 확정 전 성공을 표시하지 않는다. 원 순번/시각/원문은 불변이며 발주·입고 배정은 원 주문순이다.
- **고객 링크는 인증 수단이 아니다.** 새 기기에서 기존 위챗 연락으로 판매자가 본인 확인·단회 승인을 하고, 같은 기기 HttpOnly 세션으로 접근한다. 고객 A/B 분리는 서버에서 보장한다. 고객에게 가입/비밀번호를 강제하지 않는다.
- **돈과 이력을 스냅샷으로 관리한다.** 고객은 수정 요청, 관리자가 적용한다. 청구서는 판본이며 수취 진행 이후 임의 수정/취소를 잠근다. KRW/CNY는 선택 가능한 별도 통화이지 합산 대상이 아니다. 판매자 환율·배송/택포·수취 안내를 청구 시점에 고정한다. 선입금 원장/청구 배분은 분리하고, 증빙 업로드만으로 입금완료로 처리하지 않는다.
- **발주·입고·출고는 수량 사건이다.** 확인된 수취분만 거래처+상품+옵션별 합산 발주한다. 부분입고·미송·불량교환·부분출고·복수 송장을 추적하고 출고 주소를 스냅샷한다. 3일 미입금은 관리자 확인 후 취소, 14일 초과 미송은 고객별 처리함에 올린다.
- **브랜드와 사업자 상호를 분리한다.** `ServiceBrand`를 화면 표시 기준으로 하고 기존 `BusinessInfo.companyName`은 등록 변경 확인 전 유지한다.

## 5. 빌드·실행·검증·모니터링

환경 값은 `lib/core/env.dart`의 `--dart-define`으로 받는다. 실제 값은 승인된 로컬/비밀 저장소에서 주입하고 채팅·문서·Git·브라우저 번들에 서버 전용 키를 남기지 않는다. 방송 기기 시험은 **반드시 격리된 테스트 Supabase**를 사용한다.

```sh
flutter pub get
flutter analyze --no-pub
flutter run --dart-define=SUPABASE_URL=<테스트_URL> --dart-define=SUPABASE_ANON_KEY=<공개_키>
# 방송 debug 웹: 위 두 값과 함께 테스트 프로젝트에만 적용
flutter build web --debug --no-pub --dart-define=SUPABASE_URL=<테스트_URL> --dart-define=SUPABASE_ANON_KEY=<공개_키> --dart-define=BROADCAST_ORDERS_ENABLED=true --dart-define=BROADCAST_TEST_AUTH=true
npm install --prefix tools/broadcast-tests
npm run plan:check --prefix tools/broadcast-tests
npm test --prefix tools/broadcast-tests
npm run test:http --prefix tools/broadcast-tests
npm run test:adapter --prefix tools/broadcast-tests
npm run test:customer-access --prefix tools/broadcast-tests
npm run test:join-link --prefix tools/broadcast-tests
node tools/cloudflare/monitor-worker/worker.test.mjs
flutter test --no-pub
```

`test:http`/`test:adapter`는 일회용 로컬 PostgreSQL·PostgREST에 연결한다. Cloud 스크립트는 별도 테스트 프로젝트에만, 임시 인증 파일은 사용 후 삭제한다. 실제 기기용 웹은 `tools/broadcast-tests/test-web-host.mjs`가 Flutter 정적 파일과 고객 게이트웨이를 **같은 HTTPS 출처**에 묶는다. [테스트 안내](tools/broadcast-tests/README.md)와 [30단계 검증표](docs/plans/broadcast-orders/validation-b09.md)를 따른다. Flutter 웹 링크는 `/#/seller/broadcast`, `/#/seller/broadcast/join?...`, `/#/broadcast/<locator>` 형식이다. 과거 임시 URL은 만료됐다. 세 역할을 동시에 검증하려면 판매자 기기 1대·보조자 기기 1대·고객 기기 1대가 필요하다(PC는 판매자 기기로 가능). 두 대로 역할을 순차 전환하면 동시 운영 UX 시험을 대체하지 못한다. 중국 본토 접속 시험은 후속이다.

운영 웹은 NAS와 Cloudflare 점검 Worker를 사용한다. 배포 스크립트는 `tools/deploy_web.sh`지만 이번 인계 작업에서 실행하지 않았다. [Supabase 운영 문서](supabase/README.md)와 [Cloudflare 점검 안내](tools/cloudflare/README.md)를 먼저 읽는다. 외부 모니터는 `tools/cloudflare/monitor-worker/`의 Worker가 5분마다 웹·Supabase·백업 heartbeat·pg_cron·푸시 큐를 본다. NAS 예정 오프 02:00~08:00 KST 및 부팅 유예에는 건너뛰고, tick 내 재시도/연속 실패 기준으로 오탐을 줄인다. 로그 관측과 테스트는 [모니터 README](tools/cloudflare/monitor-worker/README.md)에 있다. `worker.js`의 colo 진단 로그와 새 알림 문구는 **미배포 소스**이므로 운영 상태로 단정하지 않는다. pg_cron 일정 분산의 운영 적용은 2026-10-16 문서 기록이며 새 배포 전에 현재 job 정의를 조회해야 한다.

## 6. 알려진 문제와 주의

1. **높음 — MOQ 부분 취소와 셀러 정산 집계.** `seller_settlements`는 주문 상태만 필터링하고 `order_items.status='cancelled'`를 제외하지 않는다. 같은 주문에 정상 상품이 남으면 MOQ 취소분이 `seller_balances`에 포함될 수 있다. [초기 검토 R1](docs/reviews/2026-09-12-project-review.md). 운영 DB 재현·영향 분석·회귀 테스트 후 수정해야 한다. 현재 코드에서도 조건 누락을 확인했다.
2. **MOQ 환불은 자동 완료가 아니다.** 무통장 환불은 관리자 이체/기록이 필요하고 카드 부분취소 API는 없다. `refund_requests` 생성과 실제 지급을 혼동하지 말 것.
3. **방송판매는 시험 운영 준비 단계다.** HTTP 통과와 시안 성공은 고객/직원 실제 UI, 재시작 후 명령 복구, 대량 목록/동시 관리자, 실기기 다운로드·캡처·기기 회수, 20건 입력 속도, 중국 무VPN 접속을 증명하지 않는다. [단계별 버전](docs/plans/broadcast-orders/stage-versions.md)의 미검증을 따른다. 고객 고정 링크나 서버 키를 공개 배포하지 말 것.
4. **문서의 시점 차이.** [초기 검토](docs/reviews/2026-09-12-project-review.md)와 단계별 오래된 `versions/` 파일에는 당시 미구현·Cloud 미적용 설명이 남는다. 이력으로 보존하고 최신 상태는 `version.json`/작업표/이 문서에서 확인한다. 특히 `services/broadcast-customer-gateway/README.md` 말미의 Cloud 파일 미검증 문구는 B09-v0.2.2의 HTTP 시험보다 오래됐지만 브라우저·기기 미검증은 여전히 유효하다.
5. **테스트 환경 제약.** 과거 `flutter test`는 이 Mac의 Xcode 라이선스 미동의로 네이티브 자산 빌드 전에 중단됐다. 이는 테스트 통과가 아니다. `shared_preferences` 명령 저널은 실제 프로세스 재시작·다중 탭 보안/경합을 검증해야 한다. 테스트 Cloud 익명 Auth는 마지막 기록상 꺼져 있다.
6. **운영/소스 혼재 금지.** 기존 브랜드 웹/점검 안내의 운영 반영 이력, pg_cron 일정의 운영 변경 기록, 미배포 모니터 코드, 미배포 방송 코드는 서로 다른 상태다. 운영 DB에 방송 SQL 묶음이나 전체 `schema.sql`을 무심코 적용하지 말 것. `CLAUDE.md`는 전역 ignore되어 다른 머신에 보이지 않을 수 있다.

## 7. 다음 작업 · 우선순위

1. **MOQ 정산 R1을 먼저 재현·수정한다.** 혼합 주문에서 취소 아이템을 셀러 집계에서 제외하고 환불/잔액까지 회귀 검증한다. 운영 정의·이미 계산된 값은 읽기 전용으로 확인한 뒤 적용 범위를 결정한다.
2. **방송 B09 실제 화면/기기 연속 시험을 준비한다.** 테스트 Cloud의 현재 설정을 확인하고 새 임시 HTTPS 출처를 만든다. 판매자·보조·고객 각 1기기에서 테스트 로그인/권한·초대·고객 링크 승인부터 시작해 [30단계 표](docs/plans/broadcast-orders/validation-b09.md)를 한 방송 데이터로 통과시킨다. 실거래·실고객 없이 한다.
3. **시험 실패를 단계별로 고친다.** 우선 20건 모바일 입력 속도/재시도/권한 회수, 보완 증빙과 입금 잠금, XLSX 실기기 저장, 부분입고·불량/출고·오류 정정, 대량 처리함·복수 관리자 경합을 검증한다. 변경 시 계획·시안·API/타입·단계 버전을 함께 갱신하고 새 `v0.*` 체크포인트를 만든다.
4. **기기·회선 외부 검증을 마무리한다.** 카카오 로그인 복귀와 iPhone/Android 브라우저, 이후 중국 연길 무VPN 일반 브라우저에서 첫 화면·청구·QR·증빙·송장 속도/실패율을 기록한다. 결과 전에는 중국 접속 가능/안정성을 보장하지 않는다.
5. **출시/운영 경계는 별도로 검토한다.** 모든 단계 `v1.0.0` 게이트, 개인정보/결제 주체, 운영 마이그레이션·백업/복구·배포 절차를 검증한 뒤 방송 기능 운영 적용 여부를 판단한다. 관련 없는 모니터 진단 변경은 독립 검토·배포한다.
