#!/usr/bin/env bash
set -euo pipefail

backup_root="${WJ_BACKUP_DIR:-/home/ubuntu/william-james/backups/data}"
postgres_container="${WJ_POSTGRES_CONTAINER:-william-james-postgres-1}"
minio_container="${WJ_MINIO_CONTAINER:-william-james-minio-1}"
retention_days="${WJ_BACKUP_RETENTION_DAYS:-14}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
target="$backup_root/$timestamp"

case "$backup_root" in
  /home/ubuntu/william-james/backups/*) ;;
  *) echo "refusing unsafe backup root: $backup_root" >&2; exit 2 ;;
esac

install -d -m 700 "$target"
docker exec "$postgres_container" sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$target/postgres.dump"
docker run --rm --volumes-from "$minio_container" postgres:16-alpine \
  tar -C /data -czf - . > "$target/minio-data.tar.gz"
sha256sum "$target/postgres.dump" "$target/minio-data.tar.gz" > "$target/SHA256SUMS"

find "$backup_root" -mindepth 1 -maxdepth 1 -type d -mtime "+$retention_days" -print -exec rm -rf -- {} +
echo "backup completed: $target"
