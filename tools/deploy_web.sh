#!/usr/bin/env bash
# CoBuying 웹 배포 스크립트
# 사용법: ANON_KEY=<키> ./tools/deploy_web.sh
# (NAS SSH 키 인증이 되어 있어야 함)
set -euo pipefail

NAS="shinnas_admin@orange-man.xyz"
NAS_PORT=2022
SUPABASE_URL="https://supabase.orange-man.xyz"
WEB_DIR="/volume1/docker/cobuying-web/html"

if [[ -z "${ANON_KEY:-}" ]]; then
  echo "ANON_KEY 환경변수가 필요합니다. NAS의 /volume1/docker/supabase/.env 참고." >&2
  exit 1
fi

cd "$(dirname "$0")/.."

echo "▶ Flutter 웹 릴리즈 빌드..."
# --pwa-strategy=none: 서비스 워커 캐시가 배포 직후에도 이전 버전을
# 내보내는 문제 방지 (새로고침하면 항상 최신 버전)
flutter build web --release \
  --pwa-strategy=none \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_ANON_KEY="$ANON_KEY"

# 캐시 버스팅: Cloudflare 프록시가 js에 max-age를 붙여 브라우저가 최대 4시간
# 이전 번들을 쓰는 문제 방지. 배포마다 URL을 바꿔 즉시 새 번들을 받게 한다.
STAMP=$(date +%s)
sed -i '' "s|flutter_bootstrap\.js|flutter_bootstrap.js?v=$STAMP|g" build/web/index.html
sed -i '' "s|\"main\.dart\.js\"|\"main.dart.js?v=$STAMP\"|g" build/web/flutter_bootstrap.js

echo "▶ NAS 업로드..."
tar -C build/web -czf - . | \
  ssh -p "$NAS_PORT" "$NAS" "rm -rf $WEB_DIR/* && tar -xzf - -C $WEB_DIR" 2>&1 | \
  grep -v "LIBARCHIVE.xattr" || true

echo "▶ 확인..."
ssh -p "$NAS_PORT" "$NAS" "curl -s -o /dev/null -w '%{http_code}' http://localhost:8091/" 2>/dev/null | \
  grep -q 200 && echo "✅ 배포 완료: https://shop.orange-man.xyz" || {
    echo "❌ 서버 응답 이상 — NAS에서 docker logs cobuying-web 확인" >&2
    exit 1
  }
