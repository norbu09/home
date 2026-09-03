#!/bin/sh
# Postgres backup loop for the home stack. Runs inside the pgvector image
# (which ships pg_dump), writes timestamped custom-format dumps to /backups,
# and prunes anything older than $BACKUP_KEEP_DAYS.
set -eu

: "${PGHOST:=db}"
: "${PGUSER:=postgres}"
: "${PGDATABASE:=home_prod}"
: "${PGPASSWORD:?PGPASSWORD is required}"
: "${BACKUP_INTERVAL_SECONDS:=86400}"
: "${BACKUP_KEEP_DAYS:=14}"

export PGPASSWORD

backup_dir=/backups
mkdir -p "$backup_dir"

echo "[backup] starting: every ${BACKUP_INTERVAL_SECONDS}s, keep ${BACKUP_KEEP_DAYS} days, target ${PGHOST}/${PGDATABASE}"

while true; do
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  target="$backup_dir/home-$stamp.dump"

  if pg_dump --format=custom --no-owner --no-privileges \
      --host="$PGHOST" --username="$PGUSER" "$PGDATABASE" > "$target"; then
    size=$(du -h "$target" | cut -f1)
    echo "[backup] wrote $target ($size)"
  else
    echo "[backup] FAILED at $stamp" >&2
    rm -f "$target"
  fi

  # Prune dumps older than the retention window.
  find "$backup_dir" -name 'home-*.dump' -mtime "+$BACKUP_KEEP_DAYS" -delete

  sleep "$BACKUP_INTERVAL_SECONDS"
done
