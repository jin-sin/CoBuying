# 방송판매 MVP 현재 인계 메모 · 2026-09-29

공통 요구/인터페이스 기준은 `v2.2.0`이다. 이 문서는 지금까지의 **로컬 구현 현황**이며 시험 운영 완료나 운영 반영을 뜻하지 않는다. 단계별 최신 버전은 [version.json](version.json), 상세 결과는 [작업표](worklog.md)를 따른다.

| 단계 | 최신 | 현재 가능한 로컬 경로 | 다음 필수 작업 |
| --- | --- | --- | --- |
| B01 | v0.2.4 | 직원 방송/상품/주문, 코드 참여, Cloud 테스트 JWT/20건 경합 | 실제 카카오·두 휴대폰/복귀·현장 속도 |
| B02 | v0.2.0 | 고객 링크의 기기 승인·회수, 고객 추가/수정요청, 관리자 검토 | 실제 브라우저 연속 조작·기기 복귀 |
| B03 | v0.8.1 | 관리자 배송국가·선입금·청구, 고객 청구/주소/최종확인, 수취 안내·상품 제외/고객 요청/판매자·미입금 국가 정정 재발행, 전량 취소 무효화, 실제 반환·오기입 무효화·주소 정정·비공개 QR | 입금 후 국가변경 수동 예외·실제 Storage/기기 검증 |
| B04 | v0.2.1 | 고객 캡처/송금 신고, 관리자 실수취 대조, 같은 수취 건 증빙 보완, 복수 입금/환불 SQL | 실제 비공개 Storage·QR 안내·실기기 |
| B05 | v0.3.0 | 입금완료 발주, 관리자 발주 내역, 거래처/고객표 XLSX, 입고·미송·불량교환 대기 수량 | 거래처 ID·실기기 저장 |
| B06 | v0.3.0 | 부분입고, 원 주문순 배정, 불량교환 입고 화면 | 실기기 재시도/경합·대량 발주 페이지 |
| B07 | v0.4.0 | 정상 배정품 부분출고, 여러 송장, 고객 목록/주소 스냅샷, 관리자 과거 출고 페이지 | 출고 오류 정정·실기기 연속 흐름 |
| B08 | v0.4.0 | 처리함 집계, 재시작 뒤 동일 키 수동 미입금 취소, 고객별 14일 미송 상세 | 대량 목록·복수 관리자·실제 업무 처리 |
| B09 | v0.2.3 | 30개 현장 검증표, 테스트 Cloud 연속 HTTP, 임시 HTTPS 웹·게이트웨이 및 390px 첫 화면 확인 | 직원 테스트 로그인·고객 링크 발급/실제 화면 연속 조작, 카카오/두 휴대폰, 한 방송 30단계 현장 시험, 중국 본토 무VPN iPhone/Android |

새 증분 SQL은 `202609280004`~`016`, `202609290001`~`012`이며 순서대로 적용한다. 테스트 Cloud `orendam-broadcast-test`에는 B02~B08 증분 25개와 private 증빙/QR 버킷·정책을 적용했다. `broadcast_customer_devices`·`broadcast_invoices` 존재, 방송 테이블 RLS 미활성 0개, 두 버킷 `public=false`·정확한 제한·정책 존재를 읽기 전용으로 확인했다. 실제 Auth JWT, QR/증빙 파일 업로드·권한 경계, 고객 게이트웨이의 승인→분할 테스트 수취→발주→부분출고 HTTP 흐름을 통과했다. 고객/직원 실제 브라우저 UI와 실기기 시험은 아직 하지 않았다. 운영 DB와 운영 웹에는 적용하지 않았다. `tools/cloudflare/monitor-worker/worker.js`를 포함한 기존 미커밋 변경은 보존한다.

로컬 확인 명령:

```sh
npm run test:customer-access --prefix tools/broadcast-tests
npm run test:http --prefix tools/broadcast-tests
dart --enable-asserts --packages=.dart_tool/package_config.json tools/broadcast-tests/purchase_export_check.dart
flutter analyze lib/features/broadcast_orders lib/router/app_router.dart --no-pub
flutter build web --dart-define=BROADCAST_ORDERS_ENABLED=true --no-wasm-dry-run --no-pub
npm run plan:check --prefix tools/broadcast-tests
git diff --check
```

`flutter test`는 이 컴퓨터의 Xcode 라이선스 미동의로 objective_c native-assets 빌드 전에 중단됐다. 해당 XLSX 로직은 순수 Dart 생성·재읽기 시험으로 별도 확인했다. 테스트 Cloud의 익명 로그인은 다시 꺼 둔 상태다. 실제 고객/실거래·고객 메시지·운영 배포는 수행하지 않았다.
