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
flutter build web --release \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_ANON_KEY="$ANON_KEY"

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
