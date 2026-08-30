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

# Hash only the live DB. SQLite Online Backup creates a consistent snapshot,
# including committed WAL state, so WAL/SHM mtimes must not control backup decisions.
fingerprint() {
  sha256sum -- "$DB_PATH"
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

# First successful database detection triggers an immediate backup attempt.
# Subsequent attempts occur every configured interval. A failed attempt does
# not terminate the scheduler or OmniRoute; it retries on the next cycle.
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

  if [[ -f "$DB_PATH" ]]; then
    sleep "${INTERVAL}m"
  else
    sleep 15
  fi
done
