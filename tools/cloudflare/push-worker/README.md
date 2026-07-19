# FCM 푸시 알림 설정 가이드

인앱 알림(`notifications` 테이블 insert)이 자동으로 기기 푸시로도 나가게 하는
구성. 흐름은 다음과 같다.

```
notifications insert (주문 이벤트·타임세일 트리거)
  → push_queue 적재 (트리거, 토큰 있는 사용자만)
  → pg_cron 1분마다 send_push_notifications()
  → 이 Worker(cobuying-push)로 배치 POST
  → Worker가 Firebase 서비스 계정으로 FCM v1 발송
  → 무효 토큰 목록 반환 → DB가 push_tokens에서 삭제
```

앱은 로그인 시 FCM 토큰을 `register_push_token` RPC로 등록하고, 로그아웃 시
해제한다. **아래 설정을 하나도 안 하면 푸시만 조용히 꺼진 채 앱은 정상 동작한다**
(schema.sql 25절 — 시크릿 미등록 시 큐를 비우고 건너뜀).

## 1. Firebase 프로젝트 + 앱 설정

```bash
# Firebase 콘솔(console.firebase.google.com)에서 프로젝트 생성 후:
dart pub global activate flutterfire_cli
flutterfire configure   # Android(필수), Web(웹 푸시 쓸 때) 선택
```

`lib/firebase_options.dart`(자리표시 파일)가 실제 값으로 덮어써진다.
apiKey가 REPLACE로 시작하면 앱이 푸시 초기화를 건너뛰므로, 이 파일이
채워지는 순간부터 켜진다.

## 2. Worker 배포

```bash
cd tools/cloudflare/push-worker
npx wrangler deploy

# Firebase 콘솔 > 프로젝트 설정 > 서비스 계정 > 새 비공개 키 생성 → JSON 다운로드
npx wrangler secret put FIREBASE_SERVICE_ACCOUNT   # JSON 내용 통째로 붙여넣기

openssl rand -hex 32                                # 공유 시크릿 생성
npx wrangler secret put PUSH_SHARED_SECRET
```

배포 후 나오는 `https://cobuying-push.<계정>.workers.dev` 주소를 기록해 둔다.

## 3. DB 설정 (NAS)

```bash
ssh -p 2022 shinnas_admin@orange-man.xyz
sudo docker exec -it supabase-db psql -U postgres
```

```sql
-- 스키마 반영 (schema.sql 25절 포함 전체 재실행해도 안전 — 멱등)
-- 그리고 Worker 연결 정보 등록:
insert into private.app_secrets (key, value) values
  ('push_worker_url',    'https://cobuying-push.<계정>.workers.dev'),
  ('push_shared_secret', '<openssl로 만든 값>')
on conflict (key) do update set value = excluded.value;
```

## 4. 웹 푸시 (선택)

1. Firebase 콘솔 > 프로젝트 설정 > 클라우드 메시징 > 웹 푸시 인증서 생성 → VAPID 키 복사
2. `web/firebase-messaging-sw.js`의 firebaseConfig를 웹 앱 값으로 채우기
   (`lib/firebase_options.dart`의 web과 동일 값)
3. 빌드에 `--dart-define=FCM_VAPID_KEY=<VAPID 키>` 추가 (deploy_web.sh 사용 시
   스크립트의 flutter build 명령에 포함)

VAPID 키가 없으면 웹에서는 푸시를 켜지 않는다 (앱은 무관).

## 5. iOS (나중에)

APNs 인증 키(유료 Apple Developer 계정 필요)를 Firebase 콘솔에 업로드하고
Xcode에서 Push Notifications capability를 켜야 한다. 미설정 상태에서는
iOS만 푸시가 비활성일 뿐 다른 플랫폼에 영향 없다.

## 동작 확인

```sql
-- 앱에서 카카오 로그인 후 토큰이 등록됐는지:
select platform, left(token, 20), updated_at from public.push_tokens;

-- 테스트 알림 발송 (본인 uuid로):
insert into public.notifications (user_id, title, body, link)
values ('<내 user uuid>', '푸시 테스트', '이 알림이 기기에 떠야 한다', '/orders');

-- 1분 내 큐가 비워지면 발송 성공:
select * from public.push_queue;
```

Worker 로그는 `npx wrangler tail cobuying-push`로 실시간 확인.

## 제한·설계 메모

- 발송 배치는 실행당 큐 25건 (Workers 무료 플랜의 요청당 서브요청 50개 제한
  고려, 사용자당 기기 1~2개 가정). 초과분은 다음 분에 이어 발송.
- 1시간 넘게 큐에 머문 알림은 폐기 (푸시는 즉시성이 생명 — NAS 재기동 직후
  묵은 알림 폭탄 방지).
- NAS 전원 오프(02~08시) 동안은 알림 생성 자체가 없으므로 밀릴 것도 없다.
- 앱이 포그라운드일 때는 시스템 알림을 띄우지 않는다 (인앱 알림 벨이 이미
  60초 폴링으로 갱신됨 — 이중 알림 방지).
