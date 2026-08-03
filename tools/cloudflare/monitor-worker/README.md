# 운영 장애 모니터 (orange-man-monitor)

5분마다 서비스 상태를 확인하고, **상태가 바뀔 때만** 텔레그램으로 알린다.

NAS가 죽으면 DB도 같이 죽어서 DB로는 그 사실을 알릴 수 없다. 그래서 감시는
바깥(Cloudflare)에서 하고, DB는 바깥에서 확인할 수 없는 신호만
`health_check()`로 넘겨준다 (`supabase/schema.sql` 27절).

## 무엇을 보는가

| 항목 | 판정 | 왜 필요한가 |
|---|---|---|
| Supabase | `/rest/v1/`가 200 또는 401 | 죽으면 앱 전체가 멈춘다 |
| 서비스 웹 | `shop.orange-man.xyz`가 200 | nginx 컨테이너만 죽는 경우가 있다 |
| DB 백업 | 하트비트가 26시간 이내 | DSM 스케줄러는 실패해도 조용하다 |
| 오프사이트 백업 | 하트비트가 26시간 이내 | R2 복사가 막혀도 조용하다 |
| pg_cron | 잡별 마지막 성공이 30분 이내 | 멈추면 주문 자동취소·푸시가 안 나간다 |
| 푸시 큐 | 가장 오래된 항목이 15분 이내 | 발송 Worker가 막히면 쌓인다 |

백업 판정은 **데드맨 스위치**다. `backup.sh`·`offsite_backup.sh`가 성공했을 때만
`record_heartbeat()`를 찍고, 그 값이 늙으면 실패로 본다 — 스크립트가 실패한
경우와 아예 실행되지 않은 경우가 함께 잡힌다.

매일 02:00~08:00은 NAS 전원 스케줄이라 다운이 정상이다. 이 시간대에는 아무것도
보지 않는다. 23:00~08:00에 발생한 알림은 무음으로 보낸다 (기록은 남고 폰은 안 울린다).

## 설정 (1회)

1. **텔레그램 봇 만들기** — 텔레그램에서 `@BotFather`에게 `/newbot`.
   봇 이름을 정하면 토큰(`123456:ABC-...`)을 준다.
   그다음 만든 봇과 대화를 시작(`/start`)하고 chat_id를 확인한다:

   ```bash
   curl -s "https://api.telegram.org/bot<토큰>/getUpdates" | grep -o '"id":[0-9-]*' | head -1
   ```

2. **DB 토큰 확인** — 스키마 적용 시 임의 값으로 만들어진다. Worker 시크릿에 넣을
   값을 Studio SQL 편집기에서 읽어 온다:

   ```sql
   select value from private.app_secrets where key = 'health_token';
   ```

3. **KV 네임스페이스** — 이미 만들어져 `wrangler.toml`에 id가 들어 있다. 건너뛴다.

4. **시크릿 등록** (네 개를 차례로 물어본다):

   ```bash
   npx wrangler secret put HEALTH_TOKEN
   npx wrangler secret put SUPABASE_ANON_KEY
   npx wrangler secret put TELEGRAM_TOKEN
   npx wrangler secret put TELEGRAM_CHAT_ID
   ```

5. **배포**:

   ```bash
   npx wrangler deploy
   ```

## 확인

크론을 기다리지 않고 지금 상태를 볼 수 있다:

```bash
curl -s -H "Authorization: Bearer <HEALTH_TOKEN>" https://orange-man-monitor.<계정>.workers.dev/check
```

`checks` 배열의 모든 항목이 `ok: true`면 정상이다.

단, **백업 두 항목은 첫 배포 직후 이상으로 뜬다** — 하트비트가 아직 한 번도 안
찍혔기 때문이다. NAS에 스크립트를 다시 올린 뒤(`supabase/README.md` 8절) 한 번씩
직접 돌리면 바로 정상이 되고, 하트비트 기록이 실제로 되는지도 같이 확인된다:

```bash
ssh -p 2022 shinnas_admin@orange-man.xyz \
  "/volume1/docker/supabase/backup.sh && /volume1/docker/supabase/offsite_backup.sh"
```
 알림이 실제로 오는지 보려면
NAS의 웹 컨테이너를 잠깐 내렸다가(`docker stop cobuying-web`) 5분 뒤 텔레그램을
확인하고 다시 올리면 된다(`docker start cobuying-web`).

시간대 판정(점검창·무음창)은 자정을 넘느냐에 따라 조용히 틀리기 쉬워 테스트가 있다:

```bash
node tools/cloudflare/monitor-worker/worker.test.mjs
```

## 임계값 조정

전부 `wrangler.toml`의 `[vars]`에 있다. 알림이 너무 잦으면 해당 값을 늘리고
`npx wrangler deploy`로 다시 올리면 된다. 코드는 건드릴 필요 없다.

점검 시간(`WINDOW_START`/`WINDOW_END`)은 DB의 `app_settings.maintenance`와
같은 값으로 맞춰 둬야 한다. 서버가 꺼진 동안에는 DB를 읽을 수 없어서 Worker가
이 값을 따로 갖고 있다.
