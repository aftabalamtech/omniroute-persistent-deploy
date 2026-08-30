#!/usr/bin/env bash
set -Eeuo pipefail

DATA_DIR="${DATA_DIR:-/app/data}"
DB_FILE="${OMNIROUTE_DB_FILENAME:-storage.sqlite}"
DB_PATH="$DATA_DIR/$DB_FILE"
RUNTIME_DIR="${RUNTIME_DIR:-/app/runtime}"
INTERVAL="${BACKUP_INTERVAL_MINUTES:-10}"
LOCK_FILE="$RUNTIME_DIR/backup.lock"

log() { printf '[backup] %s\n' "$1"; }
error_log() { printf '[backup] ERROR: %s\n' "$1" >&2; }

run_once() {
  [[ "${GITHUB_BACKUP_ENABLED:-true}" == "true" ]] || return 0
  if [[ ! -f "$DB_PATH" ]]; then
    log 'database not present; retrying soon'
    return 0
  fi

  log 'database detected; creating backup'
  local tmpdir snapshot archive
  tmpdir="$(mktemp -d /tmp/omniroute-backup.XXXXXX)"
  snapshot="$tmpdir/$DB_FILE"
  archive="$tmpdir/latest.db.zst"
  trap 'rm -rf "$tmpdir"' RETURN

  log 'creating SQLite Online Backup snapshot'
  sqlite3 "$DB_PATH" ".timeout 5000" ".backup '$snapshot'"
  log 'SQLite snapshot created'

  sqlite3 "$snapshot" 'PRAGMA quick_check;' | grep -qx 'ok' || {
    error_log 'SQLite integrity check failed'
    return 1
  }

  log 'compressing with zstd'
  zstd --quiet --fast=3 --no-progress -o "$archive" -- "$snapshot"
  zstd --quiet --test "$archive"
  log 'compression verified'

  log 'uploading to GitHub'
  GITHUB_BACKUP_FILE="${GITHUB_BACKUP_FILE:-latest.db.zst}" \
    /app/backup/github-backup.sh "$archive"
  log 'GitHub upload successful'
  log 'remote backup verified'

  rm -rf "$tmpdir"
  trap - RETURN
  log 'backup completed successfully'
}

mkdir -p "$RUNTIME_DIR"
log "scheduler started (interval=${INTERVAL}m)"

if [[ "${1:-}" == "--once" ]]; then
  exec 9>"$LOCK_FILE"
  flock -n 9 || { error_log 'another backup is already running'; exit 0; }
  run_once
  exit $?
fi

# Always create a backup when the database exists. This intentionally avoids
# metadata/content change detection: in SQLite WAL mode the main DB file can
# remain unchanged while committed data is written to the WAL. False-positive
# backups are acceptable; a false-negative backup is not.
while :; do
  if exec 9>"$LOCK_FILE" && flock -n 9; then
    if run_once; then
      :
    else
      status=$?
      error_log "backup attempt failed (exit $status); retrying next interval"
    fi
    flock -u 9
  fi

  if [[ -f "$DB_PATH" ]]; then
    sleep "${INTERVAL}m"
  else
    sleep 15
  fi
done
