#!/usr/bin/env bash
set -Eeuo pipefail

DATA_DIR="${DATA_DIR:-/app/data}"
DB_FILE="${OMNIROUTE_DB_FILENAME:-storage.sqlite}"
DB_PATH="$DATA_DIR/$DB_FILE"
repo="${GITHUB_BACKUP_REPO:?GITHUB_BACKUP_REPO must be set}"
token="${GITHUB_TOKEN:?GITHUB_TOKEN must be set}"
branch="${GITHUB_BACKUP_BRANCH:-main}"
file="${GITHUB_BACKUP_FILE:-latest.db.zst}"
url="https://api.github.com/repos/$repo/contents/$file?ref=$branch"

log() { printf '[restore] %s\n' "$1"; }

# The database is the verified application-state marker. Never overwrite it.
if [[ -f "$DB_PATH" ]]; then
  log 'existing data detected; skipping restore'
  exit 0
fi

log 'empty data directory detected'
tmpdir="$(mktemp -d /tmp/omniroute-restore.XXXXXX)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
archive="$tmpdir/latest.db.zst"
snapshot="$tmpdir/$DB_FILE"

log 'downloading latest backup'
response="$tmpdir/github-response.json"
http_code="$(curl -sS -o "$response" -w '%{http_code}' -H 'Accept: application/vnd.github+json' -H "Authorization: Bearer $token" "$url")"
if [[ "$http_code" == '404' ]]; then
  log 'no backup exists; starting with a fresh data directory'
  exit 10
fi
[[ "$http_code" == '200' ]] || { echo '[restore] GitHub download failed' >&2; exit 1; }
jq -er '.content' "$response" | tr -d '\n' | base64 -d >"$archive"

log 'backup verified'
zstd --quiet --test "$archive"
zstd --quiet --decompress --stdout "$archive" >"$snapshot"
sqlite3 "$snapshot" 'PRAGMA quick_check;' | grep -qx 'ok'

# Install only after all validation succeeds. A missing DB cannot be replaced by
# this operation because the caller checked it and the destination is renamed
# into place in the same filesystem.
install_tmp="$DATA_DIR/.${DB_FILE}.restore.tmp"
rm -f -- "$install_tmp"
cp -- "$snapshot" "$install_tmp"
sqlite3 "$install_tmp" 'PRAGMA quick_check;' | grep -qx 'ok'
chown node:node "$install_tmp" 2>/dev/null || true
mv -n -- "$install_tmp" "$DB_PATH"
[[ -f "$DB_PATH" ]] || { echo '[restore] destination appeared during restore; refusing to overwrite' >&2; exit 1; }
chown node:node "$DB_PATH" 2>/dev/null || true
log 'restore completed'
