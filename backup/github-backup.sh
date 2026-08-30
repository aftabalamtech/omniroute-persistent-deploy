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
[[ "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] || { error_log 'invalid GitHub branch name'; exit 2; }
[[ -s "$archive" ]] || { error_log 'archive is empty'; exit 2; }
archive_bytes="$(stat -c '%s' -- "$archive")"
max_backup_bytes="${MAX_BACKUP_BYTES:-94371840}"
[[ "$max_backup_bytes" =~ ^[0-9]+$ ]] || { error_log 'MAX_BACKUP_BYTES must be an integer'; exit 2; }
if (( archive_bytes > max_backup_bytes )); then
  error_log "backup archive is too large (${archive_bytes} bytes; limit ${max_backup_bytes})"
  exit 2
fi

work="$(mktemp -d /tmp/omniroute-publish.XXXXXX)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

auth_headers=(
  -H 'Accept: application/vnd.github+json'
  -H 'X-GitHub-Api-Version: 2022-11-28'
  -H "Authorization: Bearer $token"
)
json_headers=(
  -H 'Accept: application/vnd.github+json'
  -H 'X-GitHub-Api-Version: 2022-11-28'
  -H "Authorization: Bearer $token"
  -H 'Content-Type: application/json'
)

# An empty GitHub repository cannot accept Git Database API blob/tree/commit
# operations yet. GitHub documents that this returns HTTP 409; initialize it
# exactly once through the Contents API, then use the Git Database API for all
# subsequent replacements so backup history does not accumulate on the branch.
ref_endpoint="$api/repos/$repo/git/refs/heads/$branch"
ref_response="$work/ref-initial.json"
ref_code="$(curl -sS -o "$ref_response" -w '%{http_code}' \
  "${auth_headers[@]}" "$ref_endpoint")"

content_b64="$work/content.b64"
base64 -w 0 "$archive" > "$content_b64"

if [[ "$ref_code" == '404' ]]; then
  log 'GitHub backup repository is empty; initializing it with latest.db.zst'
  init_payload="$work/init.json"
  jq -n --rawfile content "$content_b64" --arg path "$file" \
    '{message:"Initialize OmniRoute backup",content:($content|rtrimstr("\n")),branch:"main"}' > "$init_payload"

  init_response="$work/init-response.json"
  init_code="$(curl -sS -o "$init_response" -w '%{http_code}' \
    -X PUT "${json_headers[@]}" \
    --data-binary @"$init_payload" \
    "$api/repos/$repo/contents/$file")"
  [[ "$init_code" == '201' ]] || { error_log "GitHub initial backup creation failed (HTTP $init_code)"; exit 1; }
else
  [[ "$ref_code" == '200' ]] || { error_log "GitHub branch lookup failed (HTTP $ref_code)"; exit 1; }

  blob_payload="$work/blob.json"
  jq -n --rawfile content "$content_b64" \
    '{content:($content|rtrimstr("\n")),encoding:"base64"}' > "$blob_payload"

  log 'creating GitHub backup blob'
  blob_response="$work/blob-response.json"
  blob_code="$(curl -sS -o "$blob_response" -w '%{http_code}' \
    -X POST "${json_headers[@]}" \
    --data-binary @"$blob_payload" \
    "$api/repos/$repo/git/blobs")"
  [[ "$blob_code" == '201' ]] || { error_log "GitHub blob creation failed (HTTP $blob_code)"; exit 1; }
  blob_sha="$(jq -er '.sha' "$blob_response")"

  tree_payload="$work/tree.json"
  jq -n --arg path "$file" --arg sha "$blob_sha" \
    '{tree:[{path:$path,mode:"100644",type:"blob",sha:$sha}]}' > "$tree_payload"

  tree_response="$work/tree-response.json"
  tree_code="$(curl -sS -o "$tree_response" -w '%{http_code}' \
    -X POST "${json_headers[@]}" \
    --data-binary @"$tree_payload" \
    "$api/repos/$repo/git/trees")"
  [[ "$tree_code" == '201' ]] || { error_log "GitHub tree creation failed (HTTP $tree_code)"; exit 1; }
  tree_sha="$(jq -er '.sha' "$tree_response")"

  commit_payload="$work/commit.json"
  jq -n --arg message 'Update latest OmniRoute backup' --arg tree "$tree_sha" \
    '{message:$message,tree:$tree}' > "$commit_payload"

  commit_response="$work/commit-response.json"
  commit_code="$(curl -sS -o "$commit_response" -w '%{http_code}' \
    -X POST "${json_headers[@]}" \
    --data-binary @"$commit_payload" \
    "$api/repos/$repo/git/commits")"
  [[ "$commit_code" == '201' ]] || { error_log "GitHub commit creation failed (HTTP $commit_code)"; exit 1; }
  commit_sha="$(jq -er '.sha' "$commit_response")"

  update_payload="$work/ref-update.json"
  jq -n --arg sha "$commit_sha" '{sha:$sha,force:true}' > "$update_payload"
  update_response="$work/ref-update-response.json"
  update_code="$(curl -sS -o "$update_response" -w '%{http_code}' \
    -X PATCH "${json_headers[@]}" \
    --data-binary @"$update_payload" \
    "$ref_endpoint")"
  [[ "$update_code" == '200' ]] || { error_log "GitHub branch update failed (HTTP $update_code)"; exit 1; }
fi

# Verify exact remote bytes independently of Git blob SHA calculations.
local_sha256="$(sha256sum "$archive" | awk '{print $1}')"
remote="$work/remote-latest.db.zst"
remote_code="$(curl -sS -L -o "$remote" -w '%{http_code}' \
  "${auth_headers[@]}" \
  -H 'Accept: application/vnd.github.raw' \
  "$api/repos/$repo/contents/$file?ref=$branch")"
[[ "$remote_code" == '200' ]] || { error_log "GitHub remote verification download failed (HTTP $remote_code)"; exit 1; }
[[ -s "$remote" ]] || { error_log 'remote artifact is empty'; exit 1; }
zstd --quiet --test "$remote" || { error_log 'remote zstd verification failed'; exit 1; }
remote_sha256="$(sha256sum "$remote" | awk '{print $1}')"
[[ "$remote_sha256" == "$local_sha256" ]] || { error_log 'remote SHA-256 does not match local archive'; exit 1; }

log 'remote backup verified'
exit 0
