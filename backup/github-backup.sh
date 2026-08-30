#!/usr/bin/env bash
set -Eeuo pipefail

archive="${1:?backup archive path is required}"
repo="${GITHUB_BACKUP_REPO:?GITHUB_BACKUP_REPO must be set as OWNER/REPOSITORY}"
token="${GITHUB_TOKEN:?GITHUB_TOKEN must be set}"
file="${GITHUB_BACKUP_FILE:-latest.db.zst}"
branch="${GITHUB_BACKUP_BRANCH:-main}"
api="https://api.github.com"

[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo '[backup] ERROR: invalid GitHub repository name' >&2; exit 2; }
[[ "$file" == 'latest.db.zst' ]] || { echo '[backup] ERROR: only latest.db.zst is supported' >&2; exit 2; }
[[ -s "$archive" ]] || { echo '[backup] ERROR: archive is empty' >&2; exit 2; }

work="$(mktemp -d /tmp/omniroute-publish.XXXXXX)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# Prepare an orphan commit so the visible branch contains only latest.db.zst.
# The forced ref update happens only after the complete new commit is ready.
git -C "$work" init -q
git -C "$work" config user.name 'OmniRoute backup'
git -C "$work" config user.email 'omniroute-backup@users.noreply.github.com'
cp -- "$archive" "$work/$file"
git -C "$work" add -- "$file"
git -C "$work" commit -q -m 'Update latest OmniRoute backup'
git -C "$work" branch -M "$branch"
git -C "$work" remote add origin "https://github.com/$repo.git"
git -C "$work" -c "http.extraHeader=Authorization: Bearer $token" push -q --force origin "HEAD:refs/heads/$branch"

local_sha256="$(sha256sum "$archive" | awk '{print $1}')"
remote="$work/remote-latest.db.zst"
curl -fsSL -H 'Accept: application/vnd.github.raw' -H "Authorization: Bearer $token" \
  "$api/repos/$repo/contents/$file?ref=$branch" -o "$remote"
[[ -s "$remote" ]] || { echo '[backup] ERROR: remote artifact is empty' >&2; exit 1; }
zstd --quiet --test "$remote" || { echo '[backup] ERROR: remote zstd verification failed' >&2; exit 1; }
remote_sha256="$(sha256sum "$remote" | awk '{print $1}')"
[[ "$remote_sha256" == "$local_sha256" ]] || {
  echo '[backup] ERROR: remote SHA-256 does not match local archive' >&2
  exit 1
}
echo '[backup] remote backup verified'
