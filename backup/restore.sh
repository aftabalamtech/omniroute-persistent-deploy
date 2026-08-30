#!/usr/bin/env bash
set -Eeuo pipefail

DATA_DIR="${DATA_DIR:-/app/data}"
DB_FILE="${OMNIROUTE_DB_FILENAME:-storage.sqlite}"
DB_PATH="$DATA_DIR/$DB_FILE"
RUNTIME_DIR="${RUNTIME_DIR:-/app/runtime}"
log() { printf '[restore] %s\n' "$1"; }
error_log() { printf '[restore] ERROR: %s\n' "$1" >&2; }

invalid_existing=0
if [[ -e "$DB_PATH" ]]; then
  log 'database file exists; validating SQLite integrity'
  if /app/backup/validate-db.sh "$DB_PATH"; then
    log 'database is valid; skipping restore'
    exit 0
  fi
  log 'database file exists but schema is invalid'
  log 'preserving invalid database for recovery'
  invalid_existing=1
fi

repo="${GITHUB_BACKUP_REPO:?GITHUB_BACKUP_REPO must be set}"
token="${GITHUB_TOKEN:?GITHUB_TOKEN must be set}"
branch="${GITHUB_BACKUP_BRANCH:-main}"
file="${GITHUB_BACKUP_FILE:-latest.db.zst}"
api="https://api.github.com"
metadata_url="$api/repos/$repo/contents/$file?ref=$branch"

tmpdir="$(mktemp -d /tmp/omniroute-restore.XXXXXX)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
metadata="$tmpdir/metadata.json"
archive="$tmpdir/latest.db.zst"
snapshot="$tmpdir/$DB_FILE"

log 'validating remote backup'
http_code="$(curl -sS -L -o "$metadata" -w '%{http_code}' \
  -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
  -H "Authorization: Bearer $token" "$metadata_url")"
if [[ "$http_code" == '404' ]]; then
  log 'no backup exists; leaving data unchanged'
  exit 10
fi
[[ "$http_code" == '200' ]] || { error_log "GitHub metadata lookup failed (HTTP $http_code)"; exit 1; }
expected_size="$(jq -er '.size' "$metadata")"
[[ "$expected_size" =~ ^[0-9]+$ && "$expected_size" -gt 0 ]] || { error_log 'remote backup metadata has invalid size'; exit 1; }

curl -sS -L -o "$archive" \
  -H 'Accept: application/vnd.github.raw' -H 'X-GitHub-Api-Version: 2022-11-28' \
  -H "Authorization: Bearer $token" "$metadata_url"
actual_size="$(stat -c '%s' "$archive")"
[[ "$actual_size" == "$expected_size" ]] || { error_log "remote backup size mismatch (expected $expected_size, got $actual_size)"; exit 1; }
sha256sum "$archive" | awk '{printf "[restore] remote SHA-256: %s\n", $1}'

zstd --quiet --test "$archive" || { error_log 'remote zstd validation failed'; exit 1; }
log 'remote zstd validation passed'
zstd --quiet -d "$archive" -o "$snapshot" || { error_log 'remote decompression failed'; exit 1; }
/app/backup/validate-db.sh "$snapshot" || { error_log 'remote OmniRoute schema validation failed'; exit 1; }

mkdir -p "$DATA_DIR"
install_tmp="$DATA_DIR/.${DB_FILE}.restore.tmp"
rm -f -- "$install_tmp"
if (( invalid_existing == 1 )); then
  quarantine_dir="$RUNTIME_DIR/quarantine"
  mkdir -p "$quarantine_dir"
  quarantine="$quarantine_dir/${DB_FILE}.$(date -u +%Y%m%dT%H%M%SZ).invalid"
  cp -p -- "$DB_PATH" "$quarantine"
  log "invalid database quarantined at $quarantine"
fi
cp -- "$snapshot" "$install_tmp"
/app/backup/validate-db.sh "$install_tmp" || { rm -f -- "$install_tmp"; error_log 'final restore validation failed'; exit 1; }
chown node:node "$install_tmp" 2>/dev/null || true
mv -f -- "$install_tmp" "$DB_PATH"
chown node:node "$DB_PATH" 2>/dev/null || true
log 'restoring valid backup'
log 'restore completed'
