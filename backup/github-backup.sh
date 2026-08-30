#!/usr/bin/env bash
set -Eeuo pipefail

archive="${1:?backup archive path is required}"
repo="${GITHUB_BACKUP_REPO:?GITHUB_BACKUP_REPO must be set as OWNER/REPOSITORY}"
token="${GITHUB_TOKEN:?GITHUB_TOKEN must be set}"
file="${GITHUB_BACKUP_FILE:-latest.db.zst}"
branch="${GITHUB_BACKUP_BRANCH:-main}"
api="https://api.github.com"

log() { printf '[backup] %s\n' "$1"; }
error_log() { printf '[backup] ERROR: %s\n' "$1" >&2; }

[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { error_log 'invalid GitHub repository name'; exit 2; }
[[ "$file" == 'latest.db.zst' ]] || { error_log 'only latest.db.zst is supported'; exit 2; }
[[ -s "$archive" ]] || { error_log 'archive is empty'; exit 2; }

work="$(mktemp -d /tmp/omniroute-publish.XXXXXX)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# Use the GitHub Contents API directly. This avoids git credentials/username
# prompts inside Railway and keeps the backup repository limited to one file.
encoded_file="$file"
endpoint="$api/repos/$repo/contents/$encoded_file"
response="$work/response.json"

# GitHub Contents API accepts base64 content and an optional existing file SHA.
# First discover whether latest.db.zst already exists. A 404 is expected on the
# first backup and is treated as an initial upload.
existing_sha=""
http_code="$(curl -sS -o "$response" -w '%{http_code}' \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  -H "Authorization: Bearer $token" \
  "$endpoint?ref=$branch")"

case "$http_code" in
  200)
    existing_sha="$(jq -er '.sha' "$response")"
    ;;
  404)
    existing_sha=""
    ;;
  *)
    error_log "GitHub lookup failed (HTTP $http_code)"
    exit 1
    ;;
esac

content_b64="$work/content.b64"
base64 -w 0 "$archive" > "$content_b64"

payload="$work/payload.json"
if [[ -n "$existing_sha" ]]; then
  jq -n \
    --arg message 'Update latest OmniRoute backup' \
    --arg content "$(cat "$content_b64")" \
    --arg branch "$branch" \
    --arg sha "$existing_sha" \
    '{message:$message,content:$content,branch:$branch,sha:$sha}' > "$payload"
else
  jq -n \
    --arg message 'Create latest OmniRoute backup' \
    --arg content "$(cat "$content_b64")" \
    --arg branch "$branch" \
    '{message:$message,content:$content,branch:$branch}' > "$payload"
fi

log 'publishing backup to GitHub via Contents API'
put_response="$work/put-response.json"
put_code="$(curl -sS -o "$put_response" -w '%{http_code}' \
  -X PUT \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $token" \
  --data-binary @"$payload" \
  "$endpoint")"

case "$put_code" in
  200|201)
    ;;
  *)
    error_log "GitHub upload failed (HTTP $put_code)"
    exit 1
    ;;
esac

# Verify the exact bytes now stored remotely. This is intentionally independent
# of Git blob SHA calculations.
local_sha256="$(sha256sum "$archive" | awk '{print $1}')"
remote="$work/remote-latest.db.zst"
remote_code="$(curl -sS -L -o "$remote" -w '%{http_code}' \
  -H 'Accept: application/vnd.github.raw' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  -H "Authorization: Bearer $token" \
  "$endpoint?ref=$branch")"
[[ "$remote_code" == '200' ]] || { error_log "GitHub remote verification download failed (HTTP $remote_code)"; exit 1; }
[[ -s "$remote" ]] || { error_log 'remote artifact is empty'; exit 1; }
zstd --quiet --test "$remote" || { error_log 'remote zstd verification failed'; exit 1; }
remote_sha256="$(sha256sum "$remote" | awk '{print $1}')"
[[ "$remote_sha256" == "$local_sha256" ]] || { error_log 'remote SHA-256 does not match local archive'; exit 1; }

log 'remote backup verified'
exit 0
