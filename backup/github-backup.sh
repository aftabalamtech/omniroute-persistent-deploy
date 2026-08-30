#!/usr/bin/env bash
set -Eeuo pipefail

archive="${1:?backup archive path is required}"
repo="${GITHUB_BACKUP_REPO:?GITHUB_BACKUP_REPO must be set as OWNER/REPOSITORY}"
token="${GITHUB_TOKEN:?GITHUB_TOKEN must be set}"
file="${GITHUB_BACKUP_FILE:-latest.db.zst}"
branch="${GITHUB_BACKUP_BRANCH:-main}"
api="https://api.github.com"

[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo '[backup] invalid GitHub repository name' >&2; exit 2; }
[[ "$file" == 'latest.db.zst' ]] || { echo '[backup] only latest.db.zst is supported' >&2; exit 2; }
[[ -s "$archive" ]] || { echo '[backup] archive is empty' >&2; exit 2; }

work="$(mktemp -d /tmp/omniroute-publish.XXXXXX)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# A fresh orphan commit means the visible repository contains only the current
# artifact. The ref update is atomic: if push fails, the prior main ref remains.
git -C "$work" init -q
git -C "$work" config user.name 'OmniRoute backup'
git -C "$work" config user.email 'omniroute-backup@users.noreply.github.com'
cp -- "$archive" "$work/$file"
git -C "$work" add -- "$file"
git -C "$work" commit -q -m 'Update latest OmniRoute backup'
git -C "$work" branch -M "$branch"
git -C "$work" remote add origin "https://github.com/$repo.git"
git -C "$work" -c "http.extraHeader=Authorization: Bearer $token" push -q --force origin "HEAD:refs/heads/$branch"

local_sha="$(git -C "$work" hash-object "$file")"
remote_sha="$(curl -fsSL -H "Accept: application/vnd.github+json" -H "Authorization: Bearer $token" \
  "$api/repos/$repo/contents/$file?ref=$branch" | jq -r '.sha // empty')"
[[ -n "$remote_sha" && "$remote_sha" == "$local_sha" ]] || {
  echo '[backup] remote verification failed' >&2
  exit 1
}
