# OmniRoute on Render with external disaster recovery

Lightweight Docker deployment for the official OmniRoute release on Render with a Persistent Disk mounted at `/app/data`, a private GitHub disaster-recovery backup, and automatic restore on a genuinely empty data volume. This branch is Render-only; the Railway implementation remains on `main` and is not modified here.

## Goals

- Run the official OmniRoute Docker release; do not fork or vendor OmniRoute source.
- Keep persistent application data on a Render Persistent Disk mounted at `/app/data`.
- Keep the deployment lightweight: no PostgreSQL, Redis is optional, no panel, no file manager, and no heavy backup service.
- Maintain one latest compressed backup in a private GitHub repository.
- Automatically restore the latest backup when a new deployment has no existing persistent data.
- Never overwrite an existing data directory automatically.
- Preserve OmniRoute's existing encryption key when reusing an encrypted database.

## Current OmniRoute Configuration

The deployment currently pins the OmniRoute Docker image explicitly in `Dockerfile` rather than using the floating `latest` tag. Verify the pinned tag against the official OmniRoute release before upgrading.

Persistent path:

```text
/app/data
```

Expected SQLite database:

```text
/app/data/storage.sqlite
```

Port:

```text
20128
```

The official OmniRoute environment reference defines `DATA_DIR` as the root for the SQLite database, backups, and data files. `STORAGE_ENCRYPTION_KEY` is the key used for encrypted SQLite storage and must be preserved when an existing encrypted database is reused. citehttps://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.50/docs/reference/ENVIRONMENT.md

## Render Persistent Disk

Create a Render Persistent Disk and mount it at:

```text
/app/data
```

Do **not** mount the disk over the application directory; mount it only at `/app/data`.

The Persistent Disk is the primary live source of persistent data. Render's filesystem is otherwise ephemeral, so GitHub is an external disaster-recovery copy, not a replacement for the live disk. Render disks are available to a single instance and prevent zero-downtime instance swapping.

## Required OmniRoute Environment Variables

Set these in the Render Dashboard or through the Blueprint secret prompts. Keep the existing values stable when reusing an existing installation.

```env
DATA_DIR=/app/data
PORT=20128
HOSTNAME=0.0.0.0
NODE_ENV=production

JWT_SECRET=<existing-stable-secret>
API_KEY_SECRET=<existing-stable-secret>
INITIAL_PASSWORD=<admin-password>

# CRITICAL when reusing an existing encrypted database:
STORAGE_ENCRYPTION_KEY=<EXACT-EXISTING-KEY>
STORAGE_ENCRYPTION_KEY_VERSION=v1
```

### Encryption key warning

Never generate a new `STORAGE_ENCRYPTION_KEY` for an existing encrypted `storage.sqlite`. OmniRoute deliberately refuses to auto-generate a new key when an existing encrypted database is present, because the new key cannot decrypt the old credentials. Preserve the old key in Render environment variables or in the persisted data directory as supported by the selected OmniRoute release. citehttps://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.50/bin/omniroute.mjs

Never commit real secrets to Git.

## Optional Redis

Redis is **not required** for persistence or backup.

If a Render Redis service is provisioned and you want OmniRoute's rate limiter to use it, set:

```env
REDIS_URL=${{Redis.REDIS_URL}}
```

Redis does not replace the Render Persistent Disk or GitHub backup. The official environment example treats Redis rate limiting as opt-in; without it, the built-in in-memory rate limiter can be used. citehttps://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.50/.env.example

Only configure Redis if you actually have a Redis service available.

## GitHub Disaster-Recovery Backup

Backup repository:

```text
 aftabalamtech/omniroute-backup
```

Keep this repository **private**.

Required deployment variables:

```env
GITHUB_BACKUP_ENABLED=true
GITHUB_BACKUP_REPO=aftabalamtech/omniroute-backup
GITHUB_BACKUP_BRANCH=main
GITHUB_BACKUP_FILE=latest.db.zst
GITHUB_TOKEN=<GitHub-token-with-required-private-repo-access>

BACKUP_INTERVAL_MINUTES=10
OMNIROUTE_DB_FILENAME=storage.sqlite
```

For testing, you can temporarily use:

```env
BACKUP_INTERVAL_MINUTES=2
```

The first backup is attempted as soon as the database exists; the configured interval controls subsequent attempts.

## Backup Flow

```text
/app/data/storage.sqlite
        ↓
SQLite Online Backup snapshot
        ↓
SQLite integrity check
        ↓
zstd compression + integrity test
        ↓
GitHub private repository
        ↓
latest.db.zst
        ↓
remote download + zstd test + SHA-256 comparison
```

A backup is considered successful **only after the remote artifact has been downloaded and its SHA-256 matches the local archive**.

If a backup fails, OmniRoute must continue running and the previous remote backup must remain usable.

## Restore Flow

On startup:

```text
/app/data contains valid existing data
        ↓
restore skipped

OR

/app/data is genuinely empty
        ↓
download latest.db.zst from GitHub
        ↓
verify archive
        ↓
decompress to temporary location
        ↓
SQLite integrity check
        ↓
install atomically
        ↓
start OmniRoute
```

Existing data must never be overwritten automatically.

If no GitHub backup exists, a genuinely first-time installation may start with a fresh data directory.

A corrupt or unverifiable backup must never be installed as the live database.

## Data Safety and Encryption

The GitHub backup repository contains a compressed copy of persistent application data and may contain sensitive configuration or encrypted credentials. Keep the repository private and protect the GitHub token.

The backup system does not add a second encryption layer. OmniRoute's own database encryption remains responsible for encrypted-at-rest database protection. The `STORAGE_ENCRYPTION_KEY` is therefore part of the recovery material and must be preserved separately from the backup artifact. Never generate a replacement key when restoring an existing encrypted database; supply the exact prior key through Render environment variables.

Do not log:

- GitHub tokens
- encryption keys
- API keys
- passwords
- database contents

## Release Updates

Do not blindly track a floating OmniRoute `latest` image.

Before upgrading the pinned OmniRoute release:

```text
Current deployment
      ↓
Successful external backup
      ↓
Remote backup verification
      ↓
Change pinned OmniRoute version
      ↓
Deploy and test
```

If the backup cannot be verified, do not treat the release update as safe.

Always research the official OmniRoute release, Docker image/tag, data layout, startup command, and migration notes before changing the pinned version.

## What This Project Does NOT Use

```text
OmniRoute source fork     NO
Panel                     NO
File Manager              NO
PostgreSQL                NO
Redis                     OPTIONAL
Render Persistent Disk    YES
Private GitHub backup     YES
SQLite Online Backup      YES
zstd compression          YES
Extra backup encryption   NO
Automatic backup          YES
Automatic restore         YES
Backup history            NO
Heavy backup service      NO
```

## Important Limitation

No external backup design can honestly guarantee zero data loss. The recovery point depends on successful backup completion and the configured interval. With a 10-minute interval, a recent change may not yet exist in the external GitHub backup if the service fails before that backup succeeds.

The Render Persistent Disk remains the primary live data store. Without it, Render's local filesystem is ephemeral and recovery depends on the last verified GitHub backup.

## Testing Checklist

Before production use, verify:

- [ ] Official pinned OmniRoute image starts successfully.
- [ ] Render Persistent Disk is mounted at `/app/data` and not over `/app`.
- [ ] `storage.sqlite` is created at `/app/data/storage.sqlite`.
- [ ] Existing encrypted database starts with the exact previous `STORAGE_ENCRYPTION_KEY`.
- [ ] First backup succeeds.
- [ ] `latest.db.zst` exists in the private backup repository.
- [ ] Remote SHA-256 verification succeeds.
- [ ] A failed upload does not report success.
- [ ] A failed upload does not destroy the previous backup.
- [ ] Empty new Render Persistent Disk restores automatically.
- [ ] Existing data skips restore and is not overwritten.
- [ ] Corrupt backup is rejected.
- [ ] OmniRoute continues running when a scheduled backup fails.
- [ ] A restart/redeploy preserves the Render Persistent Disk data.

## Files

```text
Dockerfile
render.yaml
docker-compose.yml
entrypoint.sh
backup/
  backup.sh
  github-backup.sh
  restore.sh
.env.example
.gitignore
.dockerignore
README.md
```

## Official References

- OmniRoute environment reference: https://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.50/docs/reference/ENVIRONMENT.md
- OmniRoute encryption/bootstrap behavior: https://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.50/bin/omniroute.mjs
- OmniRoute environment example: https://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.50/.env.example
- Render Blueprint specification: https://render.com/docs/blueprint-spec
- Render Persistent Disks: https://render.com/docs/disks
- Render Docker services: https://render.com/docs/docker
- GitHub Contents API: https://docs.github.com/en/rest/repos/contents
