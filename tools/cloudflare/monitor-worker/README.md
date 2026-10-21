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

## 오탐을 어떻게 거르는가

**한 번 실패했다고 바로 알리지 않는다.** Cloudflare에서 NAS까지는 가정 회선과
DSM 역방향 프록시를 지나기 때문에, 서버가 멀쩡해도 가끔 요청 하나가 그냥
사라진다. 그때마다 폰이 울리면 정작 진짜 장애 때 안 보게 된다. 두 단으로 거른다:

| 단계 | 설정 | 거르는 것 |
|---|---|---|
| tick 안 재시도 | `PROBE_TRIES` (2), `PROBE_GAP_MS` (2000) | 순간적인 패킷 유실 |
| 연속 실패 확정 | `FAIL_THRESHOLD` (2) | 몇 분짜리 끊김 |

대가는 **장애 인지가 최대 5분(1 tick) 늦어지는 것**이다. 복구 알림은 지연 없이
바로 나가고, 지속 시간은 확정 시각이 아니라 **첫 실패 시각**부터 센다.

2026-08-14 16:40~16:45에 웹·Supabase가 각각 한 tick씩 실패했다가 다음 tick에
복구된 적이 있다 (서버 로그에는 아무 흔적도 없었다 — 요청이 NAS까지 오지도
못했다). 이 두 단이 있었으면 알림이 한 건도 안 나갔다.

확정 전에 실패가 쌓이는 중인지는 `/check`의 `state`에서 본다 — `fails`가
0보다 크고 `ok`가 아직 true면 세는 중이다.

Worker 로그는 `[observability]`로 켜져 있다. 오탐을 다시 쫓게 되면
`npx wrangler tail orange-man-monitor` 또는 대시보드의 Logs에서 본다.

**08:00은 전원이 들어오는 시각이지 서비스가 뜨는 시각이 아니다.** NAS 부팅 +
컨테이너 기동에 4~5분 걸려서, 창이 끝나자마자 확인하면 멀쩡한 아침을 장애로 잡는다
(2026-08-04 08:01 "웹 503 / 헬스체크 523" → 08:05 자동 복구가 이 오탐이었다).
그래서 창이 끝난 뒤 `BOOT_GRACE_MIN`(15분) 동안은 감시를 건너뛴다. 체크 주기를
늘려도 이 문제는 안 없어진다 — 첫 확인 시점이 문제지 빈도가 문제가 아니다.

## 설정 (1회)

1. **텔레그램 봇 만들기 (TELEGRAM_TOKEN)**

   - 텔레그램에서 `@BotFather`를 검색한다 (파란 인증 배지가 붙은 쪽이 진짜).
   - `/newbot` 을 보낸다.
   - **표시 이름**을 묻는다 — 아무거나. 예: `오렌담마켓 모니터`
   - **사용자명**을 묻는다 — `bot`으로 끝나야 하고 전 세계에서 유일해야 한다.
     예: `orangeman_monitor_bot`
   - 성공하면 `Use this token to access the HTTP API:` 뒤에 토큰이 온다
     (`8012345678:AAHk9x_...`). 이게 `TELEGRAM_TOKEN`.

2. **chat_id 확인 (TELEGRAM_CHAT_ID)**

   먼저 **만든 봇과 대화를 열고 START를 누르거나 아무 메시지나 보낸다.**
   텔레그램은 사용자가 먼저 말을 걸지 않은 상대에게 봇이 메시지를 보내는 걸
   막기 때문에, 이 단계를 건너뛰면 chat_id도 안 나오고 알림도 안 온다.

   ```bash
   curl -s "https://api.telegram.org/bot<토큰>/getUpdates" | python3 -c "import sys,json; r=json.load(sys.stdin)['result']; print(*{u['message']['chat']['id'] for u in r if 'message' in u} or ['먼저 봇에게 메시지를 보내세요'], sep='\n')"
   ```

   나온 숫자가 `TELEGRAM_CHAT_ID` (개인 대화는 양수). `getUpdates`는 최근
   24시간 메시지만 보여주므로, 비어 있으면 봇에게 메시지를 다시 보내고 재실행.

3. **DB 토큰 확인** — 스키마 적용 시 임의 값으로 만들어진다. Worker 시크릿에 넣을
   값을 Studio SQL 편집기에서 읽어 온다:

   ```sql
   select value from private.app_secrets where key = 'health_token';
   ```

4. **KV 네임스페이스** — 이미 만들어져 `wrangler.toml`에 id가 들어 있다. 건너뛴다.

5. **먼저 배포** — 시크릿은 Worker가 이미 존재해야 넣을 수 있다
   (`Worker "orange-man-monitor" not found`). 그래서 배포가 먼저다.
   시크릿 없이 돌아도 알림을 보내지 않으니 안전하다.

   ```bash
   npx wrangler deploy
   ```

6. **시크릿 등록** (네 개를 차례로 물어본다):

   ```bash
   npx wrangler secret put HEALTH_TOKEN
   npx wrangler secret put SUPABASE_ANON_KEY
   npx wrangler secret put TELEGRAM_TOKEN
   npx wrangler secret put TELEGRAM_CHAT_ID
   ```

**반드시 이 디렉터리에서 실행할 것.** 한 단계 위(`tools/cloudflare/`)에는 점검
Worker의 `wrangler.toml`이 있어서, 거기서 실행하면 에러 없이 엉뚱한 Worker에
시크릿이 들어간다. 헷갈리면 어디서든 `--config` 경로를 붙이면 된다:

```bash
npx wrangler deploy --config tools/cloudflare/monitor-worker/wrangler.toml
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
이 값을 따로 갖고 있다. 부팅 지연은 `WINDOW_END`를 늦추지 말고 `BOOT_GRACE_MIN`
으로 흡수한다 — `WINDOW_END`를 건드리면 앱의 점검 안내 시간과 어긋난다.
