#!/bin/sh
# CoBuying DB 백업 — DSM 작업 스케줄러가 매일 실행 (레포 사본: supabase/backup.sh)
# pg_dump 커스텀 포맷으로 덤프하고 최근 14개만 보관한다.
# 복원: docker exec -i supabase-db pg_restore -U supabase_admin -d postgres --clean --if-exists < 덤프파일
set -eu
export PATH=/usr/local/bin:$PATH DOCKER_CONFIG=/tmp/.docker-shinnas

BACKUP_DIR=/volume1/docker/supabase/backups
mkdir -p "$BACKUP_DIR"

STAMP=$(date +%Y%m%d-%H%M)
OUT="$BACKUP_DIR/cobuying-$STAMP.dump"

docker exec supabase-db pg_dump -U supabase_admin -d postgres -Fc > "$OUT"

# 빈 덤프 방지 검사 (100KB 미만이면 실패로 간주)
SIZE=$(wc -c < "$OUT")
if [ "$SIZE" -lt 100000 ]; then
  echo "backup too small: $SIZE bytes" >&2
  exit 1
fi

# 최근 14개만 보관
ls -1t "$BACKUP_DIR"/cobuying-*.dump | tail -n +15 | xargs -r rm --

# 성공했을 때만 하트비트 — 이 값이 늙으면 모니터가 백업 실패로 본다 (schema.sql 27절).
# 실패해도 백업 자체는 성공이므로 종료코드를 망치지 않는다.
docker exec supabase-db psql -U supabase_admin -d postgres -qtAX -c \
  "select public.record_heartbeat('db_backup', jsonb_build_object('bytes', $SIZE));" \
  > /dev/null || echo "heartbeat 기록 실패 (백업은 정상)" >&2

echo "ok: $OUT ($SIZE bytes)"
