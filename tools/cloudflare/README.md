# Cloudflare 점검 시간(break time) 웹 커버

NAS 전원 스케줄(매일 02:00~08:00 KST) 동안 서버가 꺼지면 웹 신규 접속자는
아무 안내도 못 보고 접속 실패를 겪는다. Cloudflare 프록시를 앞단에 두고,
원본 응답 실패를 감지하면 Worker가 점검 안내 페이지를 대신 보여준다.

- `shop.orange-man.xyz` → 오렌담마켓 break time 안내 (한국어)
- `photo.orange-man.xyz` → 乐梦童装 유지보수 안내 (중국어)
- 시간 하드코딩 없이 "원본 다운"을 감지하므로 예정에 없는 장애에도 동작.

## 1회 설정 (사용자 직접, 약 15분)

1. **Cloudflare 가입 + 사이트 추가**: <https://dash.cloudflare.com> 가입 →
   "Add a site" → `orange-man.xyz` → **Free 플랜**. 기존 DNS 레코드를
   자동으로 불러온다 (shop / photo / supabase 레코드가 다 보이는지 확인).
2. **네임서버 변경 (가비아)**: Cloudflare가 알려주는 네임서버 2개를
   가비아 → My가비아 → 도메인 관리 → 네임서버 설정에 입력.
   전파까지 보통 수십 분, 최대 24시간.
3. **프록시 설정** (Cloudflare DNS 탭):
   - `shop`, `photo` → 프록시 켬 (주황색 구름)
   - `supabase` → **DNS only (회색 구름)** — 앱이 Realtime WebSocket·대용량
     업로드로 직접 붙는 도메인이라 일단 프록시 제외 (원하면 나중에 검토).
4. **SSL/TLS 모드**: SSL/TLS 탭 → **Full (strict)**.
   원본에 DSM Let's Encrypt 인증서가 있으므로 그대로 동작한다.
5. **Worker 배포**: 이 디렉토리에서

   ```bash
   cd tools/cloudflare
   npx wrangler login          # 또는 CLOUDFLARE_API_TOKEN 환경변수
   npx wrangler deploy
   ```

   API 토큰 방식이면 dash.cloudflare.com → My Profile → API Tokens →
   "Edit Cloudflare Workers" 템플릿으로 생성.

## 확인

- 평상시: `curl -I https://shop.orange-man.xyz` → 200 (사이트 정상 서빙)
- 점검 시간(원본 다운): 같은 요청 → **503** + 점검 안내 HTML.
  기다리지 않고 시험하려면 DSM 역방향 프록시를 잠깐 끄거나 02시 이후 접속.

## 참고

- DSM의 Let's Encrypt 자동 갱신(HTTP-01)은 프록시를 통과해도 대체로 동작하지만,
  갱신 실패가 보이면 Cloudflare SSL/TLS → Origin Server에서 **Origin CA 인증서**
  (15년 유효)를 발급해 DSM에 넣는 방법이 있다.
- 부수 효과: 집 IP가 외부에 노출되지 않게 된다 (프록시 뒤로 숨음).
