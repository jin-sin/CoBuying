# 방송판매 로컬·Cloud 검증

`npm install --prefix tools/broadcast-tests` 후 저장소 루트에서 실행한다.

```sh
npm test --prefix tools/broadcast-tests
npm run test:http --prefix tools/broadcast-tests
npm run test:adapter --prefix tools/broadcast-tests
sh tools/broadcast-tests/test_flutter_isolated.sh
npm run test:join-link --prefix tools/broadcast-tests
npm run test:customer-access --prefix tools/broadcast-tests
```

첫 명령은 PGlite 단일 연결 SQL 시험이다. 둘째는 별도 PostgreSQL 15/PostgREST 16을 `127.0.0.1`에 띄워 로컬 서명 JWT→HTTP RPC, 권한·경합·멱등·페이지를 검증하고 종료한다. macOS Apple Silicon에서는 공식 PostgREST 릴리스 v16.4를 SHA-256 확인 후 `.cache/`에 보관한다. 다른 환경에서는 공식 실행 파일 경로를 `POSTGREST_BIN`으로 지정한다. 운영 Supabase URL·키는 읽지 않는다. 통합 시험의 `auth.uid()`는 로컬 JWT claim을 사용하는 테스트 대체 함수이며 Supabase Auth 자체의 테스트가 아니다.

`test:adapter`는 같은 일회용 DB·HTTP 서버에 실제 `SupabaseBroadcastRepository`의 Flutter 테스트를 연결한다. 고객/주문 페이지, 명령 저장과 동일 키 재시도, 타 사용자 거부를 시험한다. 앱의 다른 네이티브 빌드 훅과 분리된 임시 Flutter 프로젝트를 사용한다. 이 시험의 JWT도 로컬 서명이며 실제 Supabase Auth 발급 시험과 구분한다.

독립된 Supabase Cloud 테스트 프로젝트에는 먼저 `cloud_test_baseline.sql`을 적용하고 기존 네 방송 마이그레이션을 순서대로 적용한다. 이 baseline은 운영 앱에 이미 있는 `seller_profiles`의 최소 테스트 대체이며 **운영 DB에는 적용하지 않는다**. 테스트 프로젝트의 URL·publishable key는 저장소에 보관하지 않는다.

Cloud Auth 두 사용자 검증은 **고정된 별도 테스트 프로젝트 `kshysvfxcjtixfveimai`에서만** 익명 로그인을 잠시 켠 후 `BROADCAST_CLOUD_URL`·`BROADCAST_CLOUD_KEY`를 환경으로 지정하고 `node tools/broadcast-tests/cloud-auth-create.mjs /tmp/broadcast-test-sessions.json`을 실행한다. 출력된 seller UUID를 테스트 프로젝트의 `seller_profiles(user_id,status='approved')`에 등록한 뒤 같은 임시 파일로 `cloud-auth-check.mjs`와 `cloud-adapter-check.mjs`를 실행한다. 첫 스크립트는 실제 Auth 토큰으로 초대·참여·20건 주문·회수 후 차단을, 둘째는 실제 Flutter 저장소의 Cloud RPC 경로를 검사한다. 이어 `node tools/broadcast-tests/cloud-preflight-check.mjs /tmp/broadcast-test-sessions.json`으로 주문 별도 행·청구 스냅샷·비공개 QR 실제 업로드·무입금 발주 차단을 확인한다. 서버 전용 테스트 `BROADCAST_SERVICE_KEY`도 시험 프로세스의 메모리에만 제공할 경우 같은 스크립트가 고객 게이트웨이의 기기 승인·실제 Storage 증빙·분할 테스트 입금·발주·부분입고·출고까지 이어서 검사한다. QR/증빙은 테스트용 1픽셀 PNG이며 실제 송금 계정이나 고객 자료를 사용하지 않는다. **즉시 익명 로그인을 다시 끈다.** 시간이 지나 JWT가 만료되면 익명 로그인을 재활성화하지 않고 `cloud-auth-refresh.mjs`로 임시 파일의 토큰을 갱신할 수 있다. 검증을 모두 마치면 임시 토큰 파일을 삭제한다. 이메일·비밀번호를 만들거나 운영 키를 사용하지 않는다. 기존 카카오 로그인 화면의 리다이렉트는 이 시험 범위가 아니다.

`cloud-public-barrier-check.mjs`는 publishable key만으로 고객 테이블·직원 RPC의 익명 거절과 private 버킷 목록 비노출을 확인한다. 목록의 `200 []` 자체는 권한 증거가 아니며, QR 실제 업로드 뒤 `cloud-preflight-check.mjs`가 익명 다운로드 차단을 확인한다.

실제 PC·휴대폰 브라우저 시험에는 `test-web-host.mjs`가 Flutter `build/web`와 고객 게이트웨이를 하나의 HTTPS 출처로 제공한다. 이 호스트는 `BROADCAST_BACKEND_URL`을 고정 테스트 프로젝트 ref로 검사하고 `BROADCAST_SERVICE_KEY`를 서버 프로세스에서만 읽는다. `BROADCAST_GATEWAY_ORIGIN`은 터널이 발급한 정확한 `https://...` 주소로 지정한다. `PORT` 기본값은 8789이며 localhost에만 바인딩한다. 브라우저 번들에 서버 키를 넣지 않는다.

테스트 빌드는 `BROADCAST_ORDERS_ENABLED=true`, `BROADCAST_TEST_AUTH=true`, 테스트 Supabase URL·**publishable** key를 `--dart-define`으로 주어 `flutter build web --debug --no-pub`로 만든다. 테스트 인증 버튼은 debug 빌드에서만 보인다. 외부 기기에는 공식 Cloudflare [Quick Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/) 등으로 로컬 8789 포트를 임시 연결한다. 터널의 임의 URL을 먼저 알아야 고객 게이트웨이의 정확한 Origin을 설정할 수 있다. 터널·컴퓨터·호스트가 종료되거나 URL이 바뀌면 링크와 고객 쿠키 세션은 다시 준비한다. 테스트 호스트도 시작 후 4시간이 지나면 스스로 종료한다. Quick Tunnel은 개발/시험용이며 지속 접속을 보장하지 않는다.

직원 브라우저 링크는 `https://<임시호스트>/#/seller/broadcast`, 보조 참여는 `https://<임시호스트>/#/seller/broadcast/join?code=<판매자발급코드>`, 고객은 판매자가 생성한 고정 locator의 `https://<임시호스트>/#/broadcast/<locator>`다. 고객 링크 열람만으로 주문이 보이지 않으며 그 고객의 요청 기기에서 접근 요청·판매자 승인을 완료해야 한다. 시험 계정·코드는 실제 운영 고객에게 보내지 않는다.

`test:join-link`는 기존 Flutter 로그인·참여 화면을 격리 프로젝트에서 열어 링크의 코드가 로그인 전후 유지되고 참여 RPC 후 판매자 화면으로 이동하는지 확인한다. 테스트 빌드에서만 `BROADCAST_TEST_AUTH=true`로 익명 로그인 버튼이 나오며, Auth/참여 RPC 응답은 로컬 모의 HTTP다. 별도 Cloud 테스트 프로젝트의 앱 화면 검증이나 카카오 OAuth 자체 검증으로 해석하지 않는다. 릴리스 빌드에는 테스트 버튼이 나오지 않는다.

`test:customer-access`는 B02 증분 SQL의 고정 locator·요청/승인/활성화/회수·고객 A/B 경계(PGlite)와 같은 출처 쿠키 게이트웨이(모의 백엔드)를 검사한다. `test:http`도 B02 증분 마이그레이션과 service_role JWT→PostgREST RPC 경로를 함께 검증한다. 실제 고객 웹·운영 프록시 배포는 아직 없다. [게이트웨이 설정](../../services/broadcast-customer-gateway/README.md)을 따른다.

브라우저 새로고침 복구 경로를 수동 재현하려면 `sh tools/broadcast-tests/build-restart-harness.sh`로 별도 웹 빌드를 만들고 출력된 `build/web`을 로컬 HTTP 서버로 연다. 고객 검색→상품 선택→주문 저장에서 모의 서버가 저장 후 응답을 잃은 것처럼 동작한다. 새로고침하면 미확인 요청이 복구되고 같은 요청을 재확인할 수 있다. 모의 서버의 상태는 브라우저 저장소에만 있으며 실제 HTTP 주문 시험과 별개다.
