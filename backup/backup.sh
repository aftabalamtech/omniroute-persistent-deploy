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

# Content hashes are deliberately used instead of timestamps. A timestamp-only
# check can miss a write on filesystems with coarse or unusual mtime behavior.
# Hashing the database, WAL, and SHM files can produce false positives during a
# concurrent write, but cannot safely justify skipping a changed byte sequence.
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
  [[ -f "$DB_PATH" ]] || { log 'database not present; skipping'; return 0; }

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
  sqlite3 "$snapshot" 'PRAGMA quick_check;' | grep -qx 'ok'

  log 'compressing snapshot'
  zstd --quiet --fast=3 --no-progress -- "$snapshot" -o "$archive"
  zstd --quiet --test "$archive"

  log 'uploading backup'
  GITHUB_BACKUP_FILE="${GITHUB_BACKUP_FILE:-latest.db.zst}" \
    /app/backup/github-backup.sh "$archive"

  printf '%s' "$current" >"$FINGERPRINT_FILE"
  log 'backup verified'
  rm -rf "$tmpdir"
  trap - RETURN
}

mkdir -p "$RUNTIME_DIR"
if [[ "${1:-}" == "--once" ]]; then
  exec 9>"$LOCK_FILE"
  flock -n 9 || { log 'another backup is already running'; exit 0; }
  run_once
  exit $?
fi
while :; do
  if exec 9>"$LOCK_FILE" && flock -n 9; then
    run_once || printf '[backup] operation failed; previous remote backup was not changed\n' >&2
    flock -u 9
  fi
  sleep "${INTERVAL}m"
done
