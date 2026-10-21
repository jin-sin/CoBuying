# 방송 고객 접근 게이트웨이 · 테스트 구현

고객 브라우저는 Supabase `service_role` 키를 받지 않는다. 이 Node 서버만 비공개 환경변수로 키를 보유하고 고객 링크·요청 기기의 HttpOnly 쿠키를 검사한 뒤, 고객 전용 RPC를 호출한다. 고객 웹과 **같은 출처**에서 `/api/broadcast/v2/*`로 프록시해야 한다. 운영 배포 전용 구성이 아니며 현재 운영 웹에는 연결되지 않았다.

필수 환경변수:

- `BROADCAST_BACKEND_URL`: Supabase 프로젝트 URL. 서버가 `/rest/v1/rpc/*`를 호출한다.
- `BROADCAST_SERVICE_KEY`: 서버 전용 Supabase `sb_secret_` 키 또는 기존 service-role JWT. 브라우저 번들·로그·저장소에 넣지 않는다. 새 `sb_secret_` 키는 [Supabase API 키 안내](https://supabase.com/docs/guides/getting-started/api-keys)에 따라 `apikey` 헤더에만 넣고 JWT처럼 Bearer로 보내지 않는다.
- `BROADCAST_GATEWAY_SESSION_SECRET`: 임의 생성 32자 이상의 HMAC 비밀.
- `BROADCAST_GATEWAY_ORIGIN`: 고객 웹의 정확한 HTTPS origin.
- `PORT`, `HOST`: 선택. 기본값 8788, 127.0.0.1.

로컬 HTTP 시험 때만 `BROADCAST_GATEWAY_INSECURE_LOCAL=1`을 사용한다. 이 플래그도 origin이 localhost/127.0.0.1일 때만 허용된다. HTTPS 운영에서는 Secure·HttpOnly·SameSite=Lax 쿠키를 발급한다. 모든 POST는 같은 출처 `Origin`을 요구한다. 요청은 48시간, 승인 토큰은 30분, 활성 기기 세션은 30일 유효하다. 승인 링크는 판매자가 기존 위챗 연락처로 수동 전달하며, **접근 요청을 만든 동일 브라우저**에서 열어야 한다. 단순 링크 열람과 고객 고정 URL 자체는 개인정보 접근 권한이 아니다.

고객 API는 접근 요청/활성화, 주문·수정 요청, 청구·주소·최종확인, 선입금 반환, 캡처 업로드/보완, 수취 확인 상태, 출고·송장, 청구 시점 위챗/알리 수취 QR 조회를 포함한다. 관리자 link/overview/approve/revoke와 주문·정산·출고 명령은 기존 로그인 JWT의 SQL RPC로 분리한다. 수취 QR 이미지는 비공개 `broadcast-receiver-qr` 버킷에서 이 서버가 해당 고객 기기/청구를 확인한 뒤 프록시하며 공개 URL은 발급하지 않는다.

SQL/RPC·모의 Storage/게이트웨이 로컬 테스트를 통과했고, 별도 Supabase Cloud 테스트 프로젝트에 버킷·정책을 적용했다. 실제 Cloud 파일 업로드/다운로드, HTTPS 같은 출처 프록시, iPhone/Android·중국 접속은 검증 전이다. 테스트 적용 현황과 재구성 절차는 [B09 안내](../../docs/plans/broadcast-orders/validation-b09.md)를 따른다. 테스트 환경의 service-role 키는 서버 환경변수에만 넣고 채팅·Git·Flutter 빌드 값에 넣지 않는다.
