# OmniRoute Persistent Deployment

Lightweight Docker deployment for the official OmniRoute release on Railway with persistent `/app/data` storage, a private GitHub disaster-recovery backup, and automatic restore on a genuinely empty data volume.

## Goals

- Run the official OmniRoute release; do not fork or vendor OmniRoute source.
- Keep persistent application data on a Railway Volume mounted at `/app/data`.
- Keep the deployment lightweight: no PostgreSQL, Redis is optional, no panel, no file manager, and no heavy backup service.
- Maintain one latest compressed backup in a private GitHub repository.
- Automatically restore the latest backup when a new deployment has no existing persistent data.
- Never overwrite a valid existing data directory automatically.
- Preserve OmniRoute's existing encryption key when reusing an encrypted database.

## Current OmniRoute Configuration

The deployment currently pins the OmniRoute Docker image explicitly in `Dockerfile` to the stable `3.8.50` release rather than using a floating `latest` tag. Verify the official release status and migration notes before upgrading.

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

## Railway Volume

Create a Railway Volume and mount it at:

```text
/app/data
```

Do **not** mount the volume at `/app` and do not use `/app/app/data`.

The Volume is the primary live source of persistent data. GitHub is an external disaster-recovery copy, not a replacement for the live Volume.

## Required OmniRoute Environment Variables

Set these in Railway. Keep the existing values stable when reusing an existing installation.

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

Never generate a new `STORAGE_ENCRYPTION_KEY` for an existing encrypted `storage.sqlite`. OmniRoute deliberately refuses to auto-generate a new key when an existing encrypted database is present, because the new key cannot decrypt the old credentials. Preserve the old key in Railway Variables or in the persisted data directory as supported by the selected OmniRoute release. citehttps://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.50/bin/omniroute.mjs

Never commit real secrets to Git.

## Optional Redis

Redis is **not required** for persistence or backup.

If a Railway Redis service is provisioned and you want OmniRoute's rate limiter to use it, set:

```env
REDIS_URL=${{Redis.REDIS_URL}}
```

Redis does not replace the Railway Volume or GitHub backup. The official environment example treats Redis rate limiting as opt-in; without it, the built-in in-memory rate limiter can be used. citehttps://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.50/.env.example

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

The scheduler starts **only after OmniRoute passes the local HTTP health check**. It then performs the first backup immediately and subsequent checks at the configured interval.

## Backup Flow

```text
/app/data/storage.sqlite
        ↓
SQLite Online Backup snapshot
        ↓
SQLite integrity + schema check
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
/app/data contains a valid SQLite database
        ↓
preserve it and let OmniRoute migrate it

OR

/app/data is empty or the existing SQLite file fails integrity validation
        ↓
download latest.db.zst from GitHub
        ↓
verify archive size + zstd integrity
        ↓
decompress to temporary location
        ↓
SQLite integrity check
        ↓
install atomically
        ↓
prepare required base schema
        ↓
start OmniRoute migrations/bootstrap
```

A valid existing database is never overwritten automatically.

If no GitHub backup exists, a genuinely first-time installation may start with a fresh data directory.

A corrupt or unverifiable backup must never be installed as the live database.

## Data Safety and Encryption

The GitHub backup repository contains a compressed copy of persistent application data and may contain sensitive configuration or encrypted credentials. Keep the repository private and protect the GitHub token.

The backup system does not add a second encryption layer. OmniRoute's own database encryption remains responsible for encrypted-at-rest database protection. The `STORAGE_ENCRYPTION_KEY` is therefore part of the recovery material and must be preserved separately from the backup artifact.

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
Research official release/tag + migration notes
      ↓
Change pinned OmniRoute version
      ↓
Deploy and test
```

If the backup cannot be verified, do not treat the release update as safe.

## What This Project Does NOT Use

```text
OmniRoute source fork     NO
Panel                     NO
File Manager              NO
PostgreSQL                NO
Redis                     OPTIONAL
Railway Volume            YES
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

The Railway Volume remains the primary live data store.

## Testing Checklist

Before production use, verify:

- [ ] Official pinned OmniRoute image starts successfully.
- [ ] Railway Volume is mounted at `/app/data`.
- [ ] `storage.sqlite` is created at `/app/data/storage.sqlite`.
- [ ] Existing encrypted database starts with the exact previous `STORAGE_ENCRYPTION_KEY`.
- [ ] Application health endpoint becomes ready before backup scheduler starts.
- [ ] First backup succeeds.
- [ ] `latest.db.zst` exists in the private backup repository.
- [ ] Remote SHA-256 verification succeeds.
- [ ] A failed upload does not report success.
- [ ] A failed upload does not destroy the previous backup.
- [ ] Empty new Volume restores automatically when a valid backup exists.
- [ ] Existing valid data skips restore and is not overwritten.
- [ ] Corrupt backup is rejected.
- [ ] OmniRoute continues running when a scheduled backup fails.
- [ ] A restart preserves the Railway Volume data.

## Files

```text
Dockerfile
railway.json
docker-compose.yml
entrypoint.sh
backup/001_initial_schema.sql
backup/backup.sh
backup/github-backup.sh
backup/restore.sh
.env.example
.gitignore
.dockerignore
README.md
```
