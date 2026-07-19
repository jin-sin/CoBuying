# 시놀로지 NAS에 Supabase 셀프호스팅 배포

## 1. 사전 준비
- 시놀로지 패키지센터에서 **Container Manager**(구 Docker) 설치
- SSH 접속 활성화 (제어판 > 터미널 및 SNMP)
- (권장) DDNS + 역방향 프록시로 HTTPS 도메인 준비
  - 예: `https://supabase.example.synology.me` → NAS의 Kong 포트(기본 8000)
  - 제어판 > 로그인 포털 > 고급 > 역방향 프록시에서 설정
  - 소셜 로그인 콜백에 HTTPS가 필요하므로 꼭 설정하세요.

## 2. Supabase 설치 (SSH)
```bash
ssh admin@NAS주소
sudo -i
mkdir -p /volume1/docker && cd /volume1/docker
git clone --depth 1 https://github.com/supabase/supabase
cd supabase/docker
cp .env.example .env
```

### .env 필수 수정 항목
| 키 | 설명 |
|---|---|
| `POSTGRES_PASSWORD` | 강력한 비밀번호로 변경 |
| `JWT_SECRET` | 40자 이상 랜덤 문자열 |
| `ANON_KEY`, `SERVICE_ROLE_KEY` | JWT_SECRET 기반으로 재생성 ([공식 가이드](https://supabase.com/docs/guides/self-hosting/docker#securing-your-services)의 키 생성기 사용) |
| `SITE_URL` | 앱 웹 주소 (예: `https://shop.example.synology.me`) |
| `API_EXTERNAL_URL` | 외부에서 접근하는 Supabase 주소 |
| `DASHBOARD_USERNAME/PASSWORD` | Studio 접속 계정 |

### 실행
```bash
docker compose pull
docker compose up -d
```
Studio 접속: `http://NAS주소:8000` (역방향 프록시 설정 후엔 HTTPS 도메인)

## 3. DB 스키마 적용
Studio > **SQL Editor** 에서 이 폴더의 `schema.sql` 전체를 붙여넣고 실행.

- 상품/장바구니/주문 테이블 + RLS 정책
- `create_order` RPC (재고·기한 검증 트랜잭션)
- `product-images` 스토리지 버킷
- **pg_cron**: 5분마다 기한 지난 상품을 `closed` 처리

마지막으로 본인 계정으로 앱에서 1회 로그인한 뒤, `schema.sql` 맨 아래 주석의
관리자 지정 쿼리를 실행하세요.

## 4. 소셜 로그인 설정 (Studio > Authentication > Providers)

### 카카오 (Supabase 기본 지원)
1. [Kakao Developers](https://developers.kakao.com)에서 앱 생성
2. 카카오 로그인 활성화, 동의항목(닉네임/이메일) 설정
3. Redirect URI: `https://<supabase주소>/auth/v1/callback`
4. Studio에서 Kakao provider 활성화, REST API 키/Secret 입력

### 페이스북 (Supabase 기본 지원)
1. [Meta for Developers](https://developers.facebook.com)에서 앱 생성
2. Facebook Login 제품 추가
3. Valid OAuth Redirect URI: `https://<supabase주소>/auth/v1/callback`
4. Studio에서 Facebook provider 활성화, App ID/Secret 입력

### 네이버 (기본 미지원 → Edge Function으로 연동)
Supabase는 네이버를 기본 제공하지 않습니다. 두 가지 방법:
1. **권장**: Edge Function을 만들어 네이버 OAuth 토큰을 검증한 뒤
   `service_role` 키로 `auth.admin.createUser` + 세션 발급 (커스텀 토큰 교환)
2. 임시로 카카오/페이스북만 오픈하고 네이버는 추후 추가

앱 코드(`lib/features/auth/auth_repository.dart`)의 `signInWithNaver()`에
TODO로 표시해 두었습니다.

## 5. 모바일 딥링크 (OAuth 콜백)
- 앱 스킴: `io.cobuying://login-callback`
- Studio > Authentication > URL Configuration > Redirect URLs 에 추가:
  - `io.cobuying://login-callback` (앱)
  - `https://<웹주소>/` (웹)
- Android: `android/app/src/main/AndroidManifest.xml`에 intent-filter 추가됨 여부 확인
- iOS: `ios/Runner/Info.plist`에 URL Scheme 추가 필요

## 6. Flutter 앱 연결
빌드/실행 시 `--dart-define`으로 주소와 키를 주입합니다:
```bash
flutter run --dart-define=SUPABASE_URL=https://<supabase주소> \
            --dart-define=SUPABASE_ANON_KEY=<ANON_KEY>
```

## 7. 백업
매일 pg_dump 백업 스크립트가 NAS에 설치돼 있다 (`/volume1/docker/supabase/backup.sh`,
레포 사본은 `supabase/backup.sh`). 최근 14개를 `backups/`에 보관.

**DSM 작업 스케줄러 등록** (제어판 > 작업 스케줄러 > 생성 > 예약된 작업 > 사용자 정의 스크립트):
- 사용자: shinnas_admin, 스케줄: 매일 01:30 (NAS 전원 오프 전),
- 실행 명령: `/volume1/docker/supabase/backup.sh`

복원:
```bash
docker exec -i supabase-db pg_restore -U supabase_admin -d postgres \
  --clean --if-exists < backups/cobuying-<날짜>.dump
```

추가로 상품 이미지(`volumes/storage`)와 `.env`는 Hyper Backup 대상에
포함시키는 것을 권장 (오프사이트 백업).
