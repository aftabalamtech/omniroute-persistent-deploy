#!/usr/bin/env bash
set -Eeuo pipefail

DATA_DIR="${DATA_DIR:-/app/data}"
DB_FILE="${OMNIROUTE_DB_FILENAME:-storage.sqlite}"
DB_PATH="$DATA_DIR/$DB_FILE"
RUNTIME_DIR="${RUNTIME_DIR:-/app/runtime}"
INTERVAL="${BACKUP_INTERVAL_MINUTES:-10}"
LOCK_FILE="$RUNTIME_DIR/backup.lock"
FINGERPRINT_FILE="$RUNTIME_DIR/last-successful-fingerprint"

log() { printf '[backup] %s\n' "$1"; }
error_log() { printf '[backup] ERROR: %s\n' "$1" >&2; }

# Content hashes avoid false-negative skips caused by coarse filesystem mtimes.
fingerprint() {
  local p
  for p in "$DB_PATH" "$DB_PATH-wal" "$DB_PATH-shm"; do
    if [[ -e "$p" ]]; then
      sha256sum -- "$p"
    else
      printf 'missing  %s\n' "$p"
    fi
  done
}

run_once() {
  [[ "${GITHUB_BACKUP_ENABLED:-true}" == "true" ]] || return 0
  if [[ ! -f "$DB_PATH" ]]; then
    log 'database not present; retrying soon'
    return 0
  fi
  log 'database detected'

  local current previous tmpdir snapshot archive
  current="$(fingerprint)"
  previous=""
  [[ -f "$FINGERPRINT_FILE" ]] && previous="$(cat "$FINGERPRINT_FILE")"
  if [[ "$current" == "$previous" ]]; then
    log 'no changes; skipping'
    return 0
  fi

  tmpdir="$(mktemp -d /tmp/omniroute-backup.XXXXXX)"
  snapshot="$tmpdir/$DB_FILE"
  archive="$tmpdir/latest.db.zst"
  trap 'rm -rf "$tmpdir"' RETURN

  log 'change detected'
  log 'creating SQLite snapshot'
  sqlite3 "$DB_PATH" ".timeout 5000" ".backup '$snapshot'"
  log 'SQLite snapshot created'
  sqlite3 "$snapshot" 'PRAGMA quick_check;' | grep -qx 'ok'

  log 'compressing with zstd'
  zstd --quiet --fast=3 --no-progress -o "$archive" -- "$snapshot"
  zstd --quiet --test "$archive"
  log 'compression verified'

  log 'uploading to GitHub'
  GITHUB_BACKUP_FILE="${GITHUB_BACKUP_FILE:-latest.db.zst}" \
    /app/backup/github-backup.sh "$archive"
  log 'GitHub upload successful'
  log 'remote backup verified'

  printf '%s' "$current" >"$FINGERPRINT_FILE"
  log 'backup completed successfully'
  rm -rf "$tmpdir"
  trap - RETURN
}

mkdir -p "$RUNTIME_DIR"
log "scheduler started (interval=${INTERVAL}m)"
if [[ "${1:-}" == "--once" ]]; then
  exec 9>"$LOCK_FILE"
  flock -n 9 || { error_log 'another backup is already running'; exit 0; }
  run_once
  exit $?
fi
while :; do
  if exec 9>"$LOCK_FILE" && flock -n 9; then
    if run_once; then
      :
    else
      status=$?
      error_log "backup attempt failed (exit $status); previous remote backup was not changed"
    fi
    flock -u 9
  fi
  # Poll quickly only until the first database exists; thereafter use the
  # requested ten-minute interval. This avoids delaying the first backup.
  if [[ -f "$DB_PATH" ]]; then
    sleep "${INTERVAL}m"
  else
    sleep 15
  fi
done
