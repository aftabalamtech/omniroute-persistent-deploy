#!/usr/bin/env bash
set -Eeuo pipefail

DATA_DIR="${DATA_DIR:-/app/data}"
DB_FILE="${OMNIROUTE_DB_FILENAME:-storage.sqlite}"
DB_PATH="$DATA_DIR/$DB_FILE"
log() { printf '[restore] %s\n' "$1"; }
error_log() { printf '[restore] ERROR: %s\n' "$1" >&2; }

if [[ -e "$DB_PATH" ]]; then
  log 'existing data detected; skipping restore'
  exit 0
fi

repo="${GITHUB_BACKUP_REPO:?GITHUB_BACKUP_REPO must be set}"
token="${GITHUB_TOKEN:?GITHUB_TOKEN must be set}"
branch="${GITHUB_BACKUP_BRANCH:-main}"
file="${GITHUB_BACKUP_FILE:-latest.db.zst}"
api="https://api.github.com"
metadata_url="$api/repos/$repo/contents/$file?ref=$branch"
raw_url="$metadata_url"

tmpdir="$(mktemp -d /tmp/omniroute-restore.XXXXXX)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
metadata="$tmpdir/metadata.json"
archive="$tmpdir/latest.db.zst"
snapshot="$tmpdir/$DB_FILE"

log 'empty data directory detected'
log 'checking remote backup metadata'
http_code="$(curl -sS -L -o "$metadata" -w '%{http_code}' \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  -H "Authorization: Bearer $token" \
  "$metadata_url")"
if [[ "$http_code" == '404' ]]; then
  log 'no backup exists; starting with a fresh data directory'
  exit 10
fi
[[ "$http_code" == '200' ]] || { error_log "GitHub metadata lookup failed (HTTP $http_code)"; exit 1; }
expected_size="$(jq -er '.size' "$metadata")"
[[ "$expected_size" =~ ^[0-9]+$ && "$expected_size" -gt 0 ]] || { error_log 'remote backup metadata has invalid size'; exit 1; }

log 'downloading latest backup'
# Do not decode the Contents API JSON `.content` field: GitHub may truncate or
# omit it for large files. The raw media response preserves the binary bytes.
raw_code="$(curl -sS -L -o "$archive" -w '%{http_code}' \
  -H 'Accept: application/vnd.github.raw' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  -H "Authorization: Bearer $token" \
  "$raw_url")"
[[ "$raw_code" == '200' ]] || { error_log "GitHub backup download failed (HTTP $raw_code)"; exit 1; }
actual_size="$(stat -c '%s' "$archive")"
[[ "$actual_size" == "$expected_size" ]] || { error_log "remote backup size mismatch (expected $expected_size, got $actual_size)"; exit 1; }

log 'verifying backup archive'
zstd --quiet --test "$archive" || { error_log 'remote zstd validation failed'; exit 1; }
zstd --quiet --decompress --stdout "$archive" >"$snapshot" || { error_log 'remote decompression failed'; exit 1; }
sqlite3 "$snapshot" 'PRAGMA integrity_check;' | grep -qx 'ok' || { error_log 'restored SQLite integrity check failed'; exit 1; }

mkdir -p "$DATA_DIR"
install_tmp="$DATA_DIR/.${DB_FILE}.restore.tmp"
rm -f -- "$install_tmp"
cp -- "$snapshot" "$install_tmp"
sqlite3 "$install_tmp" 'PRAGMA integrity_check;' | grep -qx 'ok' || { error_log 'final SQLite validation failed'; rm -f -- "$install_tmp"; exit 1; }
chown node:node "$install_tmp" 2>/dev/null || true
if [[ -e "$DB_PATH" ]]; then
  rm -f -- "$install_tmp"
  error_log 'restore destination appeared during restore; refusing to overwrite'
  exit 1
fi
mv -- "$install_tmp" "$DB_PATH"
chown node:node "$DB_PATH" 2>/dev/null || true
log 'restore completed'
