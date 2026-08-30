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
fingerprint() {
  local p
  for p in "$DB_PATH" "$DB_PATH-wal" "$DB_PATH-shm"; do
    if [[ -e "$p" ]]; then sha256sum -- "$p"; else printf 'missing  %s\n' "$p"; fi
  done
}
run_once() {
  [[ "${GITHUB_BACKUP_ENABLED:-true}" == "true" ]] || return 0
  if [[ ! -f "$DB_PATH" ]]; then log 'waiting for database'; return 0; fi
  log 'database detected'
  if ! /app/backup/validate-db.sh "$DB_PATH"; then
    error_log 'database schema validation failed; backup skipped'
    return 0
  fi
  log 'database schema validation passed'
  local current previous tmpdir snapshot archive
  current="$(fingerprint)"
  previous=''
  [[ -f "$FINGERPRINT_FILE" ]] && previous="$(cat "$FINGERPRINT_FILE")"
  if [[ -n "$previous" && "$current" == "$previous" ]]; then log 'no changes; skipping'; return 0; fi
  [[ -n "$previous" ]] || log 'first backup required'
  tmpdir="$(mktemp -d /tmp/omniroute-backup.XXXXXX)"
  snapshot="$tmpdir/$DB_FILE"
  archive="$tmpdir/latest.db.zst"
  trap 'rm -rf "$tmpdir"' RETURN
  log 'change detected'
  log 'creating SQLite snapshot'
  sqlite3 "$DB_PATH" ".timeout 5000" ".backup '$snapshot'"
  log 'SQLite snapshot created'
  log 'validating SQLite snapshot'
  sqlite3 "$snapshot" 'PRAGMA integrity_check;' | grep -qx 'ok' || { error_log 'SQLite integrity check failed'; return 1; }
  /app/backup/validate-db.sh "$snapshot" || { error_log 'snapshot schema validation failed'; return 1; }
  log 'compressing with zstd'
  zstd --quiet --fast=3 --no-progress -o "$archive" -- "$snapshot"
  zstd --quiet --test "$archive"
  log 'compression verified'
  log 'uploading backup to GitHub'
  if ! GITHUB_BACKUP_FILE="${GITHUB_BACKUP_FILE:-latest.db.zst}" /app/backup/github-backup.sh "$archive"; then
    error_log 'GitHub backup failed; previous remote backup remains unchanged'
    return 1
  fi
  log 'GitHub upload completed'
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
    if run_once; then :; else status=$?; error_log "backup attempt failed (exit $status); retrying next interval"; fi
    flock -u 9
  fi
  if [[ -f "$DB_PATH" ]]; then sleep "${INTERVAL}m"; else sleep 15; fi
done
