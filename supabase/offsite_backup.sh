#!/bin/sh
# CoBuying 오프사이트 백업 — DB 덤프·상품 이미지·.env를 Cloudflare R2로 올린다.
# (레포 사본: supabase/offsite_backup.sh, 설정 절차는 supabase/README.md 7절)
#
# backup.sh가 만든 덤프를 NAS 밖으로 내보내는 게 목적이다. NAS는 볼륨이 하나뿐이라
# 디스크가 죽으면 DB와 백업이 같이 사라진다.
#
# sync가 아니라 copy를 쓴다 — NAS 쪽 파일이 지워져도 R2 사본은 남는다.
# 그래서 R2에는 backup.sh의 14개 로테이션보다 오래된 덤프도 계속 쌓인다 (의도된 동작).
# rclone은 NAS에 설치하지 않고 컨테이너로 실행한다.
set -eu
export PATH=/usr/local/bin:$PATH DOCKER_CONFIG=/tmp/.docker-shinnas

BASE=/volume1/docker/supabase
CONF=$BASE/rclone.conf
BUCKET=r2:cobuying-backup
IMAGE=rclone/rclone:1.74

[ -f "$CONF" ] || { echo "rclone 설정 없음: $CONF (README 7절 참고)" >&2; exit 1; }

rc() {
  docker run --rm \
    -v "$CONF:/rclone.conf:ro" \
    -v "$BASE:/data:ro" \
    "$IMAGE" --config /rclone.conf "$@"
}

rc copy /data/backups         "$BUCKET/backups" --no-traverse
rc copy /data/volumes/storage "$BUCKET/storage"
rc copy /data/.env            "$BUCKET/config"

# 최신 덤프가 실제로 올라갔는지 확인 (조용한 실패 방지)
NAME=$(basename "$(ls -1t "$BASE"/backups/cobuying-*.dump | head -1)")
rc lsf "$BUCKET/backups" | grep -qx "$NAME" || {
  echo "업로드 확인 실패: $NAME" >&2
  exit 1
}

echo "ok: $NAME 포함 오프사이트 복사 완료"
