# OmniRoute Persistent Deployment Wrapper

This repository runs the **official OmniRoute v3.8.50 release** in a small Docker wrapper. It does not fork, copy, or rebuild OmniRoute. Live application state is stored on a Railway Volume mounted at `/app/data`, with one compressed disaster-recovery backup in a separate private GitHub repository.

## Fixed architecture

| Component | Use |
|---|---|
| Official OmniRoute release | `diegosouzapw/omniroute:3.8.50` |
| Railway Volume | Primary persistent storage at `/app/data` |
| SQLite Online Backup | Consistent live database snapshot |
| zstd | Fast compression |
| Private GitHub repository | Only `latest.db.zst` |
| Encryption | Not used |
| PostgreSQL / Redis | Not used |
| Panel / File Manager | Not used |

The deployment repository contains no OmniRoute source fork.

## Railway deployment

Deploy this repository as one Railway service. Add one Railway Volume and mount it **exactly at `/app/data`**. Do not mount it over `/app`. Use one replica.

Required variables:

| Variable | Value |
|---|---|
| `DATA_DIR` | `/app/data` |
| `PORT` | `20128` |
| `GITHUB_BACKUP_ENABLED` | `true` |
| `GITHUB_BACKUP_REPO` | `YOUR_GITHUB_USERNAME/omniroute-backup` |
| `GITHUB_BACKUP_BRANCH` | `main` |
| `GITHUB_BACKUP_FILE` | `latest.db.zst` |
| `GITHUB_TOKEN` | Fine-grained token with Contents read/write on the private backup repository |
| `BACKUP_INTERVAL_MINUTES` | `10` |
| `OMNIROUTE_DB_FILENAME` | `storage.sqlite` |

Keep the backup repository private. Never commit the GitHub token or other OmniRoute secrets.

## Backup behavior

The backup scheduler starts alongside OmniRoute. If `storage.sqlite` already exists, the first backup is attempted immediately. If the database has not been created yet, the scheduler polls every 15 seconds until it appears. After each backup attempt, the normal interval is 10 minutes.

Every backup:

1. Uses SQLite `.backup` / Online Backup API rather than copying a live database file.
2. Runs `PRAGMA quick_check` on the snapshot.
3. Compresses the snapshot with fast zstd.
4. Verifies the zstd archive locally.
5. Publishes only `latest.db.zst` to GitHub.
6. Downloads the remote artifact and compares its SHA-256 with the local archive.
7. Reports success only after remote verification succeeds.

The current implementation does **not** use metadata change detection; it prioritizes not missing a backup over avoiding an extra upload. Therefore a backup attempt can occur every 10 minutes even when the database did not change.

A failed backup does not terminate OmniRoute. The scheduler logs the error and retries on the next interval.

## GitHub publication and history

The backup publisher uses the GitHub Git Data API, not `git push`, so Railway never needs an interactive Git username/password.

Each successful publication creates a new orphan commit containing only `latest.db.zst` and force-updates the configured backup branch. The visible branch therefore contains only the current backup rather than a growing chain of large SQLite backup commits. GitHub may retain unreachable objects internally until its own garbage collection; the wrapper itself does not maintain backup history and does not use Git LFS.

## Restore behavior

At startup the wrapper checks:

```text
/app/data/storage.sqlite
```

If it exists, restore is skipped and the existing data is never overwritten.

If it is missing:

```text
GitHub latest.db.zst
        ↓
Download
        ↓
zstd verification
        ↓
Decompress to temporary file
        ↓
SQLite PRAGMA quick_check
        ↓
Install without clobbering a concurrently-created database
        ↓
Start OmniRoute
```

If no backup exists on a genuinely new installation, the wrapper starts with an empty data directory so OmniRoute can create its initial database. If a backup exists but is corrupt or cannot be validated, startup fails rather than starting against partial data.

## Railway Project A → Project B

Project A:

```text
Railway Volume
    ↓
/app/data/storage.sqlite
    ↓
Automatic backup
    ↓
omniroute-backup/latest.db.zst
```

Project B:

```text
New empty Volume
    ↓
/app/data
    ↓
Restore latest.db.zst
    ↓
Start OmniRoute
```

This restores the latest **successfully completed external backup**. It is not a zero-data-loss system: writes made after the last successful backup can be missing if the original Railway project disappears before another successful backup.

## Updating OmniRoute

The Dockerfile pins the official release instead of `latest` or a development branch. Before changing the pinned release:

1. Run a one-shot backup:

```sh
docker exec omniroute /app/backup/backup.sh --once
```

2. Confirm it completes successfully and the remote `latest.db.zst` is readable.
3. Change the official image tag.
4. Deploy while keeping the same Railway Volume mounted at `/app/data`.

Do not update the release if the mandatory pre-update backup failed.

## Health check

Railway uses:

```text
GET /api/monitoring/health
```

on port `20128`.

## Local testing

```sh
cp .env.example .env
docker compose up --build
curl --fail http://127.0.0.1:20128/api/monitoring/health
```

For a restore test, use a disposable local volume or copied test data. Never point a production Volume at an untrusted backup repository.

## Resource philosophy

The wrapper is intentionally lightweight. It uses shell scripts and the existing image plus only the required utilities. There is no web server, management UI, database server, Redis service, process manager, or additional application framework.

## Files

```text
omniroute-persistent-deploy/
├── Dockerfile
├── railway.json
├── docker-compose.yml
├── .dockerignore
├── .gitignore
├── .env.example
├── README.md
├── entrypoint.sh
└── backup/
    ├── backup.sh
    ├── restore.sh
    └── github-backup.sh
```

No OmniRoute source is included in this repository.
