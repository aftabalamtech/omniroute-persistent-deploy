# OmniRoute Persistent Deployment Wrapper

This repository runs the **official OmniRoute v3.8.50 release** in a small Docker wrapper. It does not fork, copy, or rebuild OmniRoute. The wrapper keeps the live application state on a Railway Volume mounted at `/app/data` and maintains one compressed disaster-recovery copy in a separate private GitHub repository.

The upstream release documents `${DATA_DIR}/storage.sqlite` as the primary runtime database and exposes the service on port `20128`. Its official Docker image is `diegosouzapw/omniroute:3.8.50`; the upstream health endpoint is `/api/monitoring/health`.

## Architecture

| Layer | Responsibility |
|---|---|
| Official OmniRoute image | Runs the gateway and dashboard without source changes |
| Railway Volume | Primary live storage, mounted at `/app/data` |
| SQLite Online Backup API | Creates a consistent snapshot while OmniRoute is running |
| zstd | Fast, low-resource compression of the snapshot |
| Private GitHub repository | Stores only `latest.db.zst` as the disaster-recovery copy |
| Startup wrapper | Restores only when `storage.sqlite` is genuinely missing, then starts the official command |

The Railway Volume and GitHub repository are intentionally independent. Normal operation uses the Volume. GitHub is used for scheduled backups, pre-update backups, and restoration of an empty new Volume.

## Create the repositories

The deployment repository is `YOUR_GITHUB_USERNAME/omniroute-persistent-deploy`. Create a second repository named `omniroute-backup` and keep it **private**. The backup repository should contain only the current `latest.db.zst`; it is not an archive-history system.

Create a fine-grained GitHub token scoped only to `omniroute-backup`, with **Contents: Read and write** permission. Store it only as the Railway variable `GITHUB_TOKEN`. Never commit it, print it, or pass it to OmniRoute provider configuration.

The wrapper publishes an orphan commit and force-updates the backup branch. This keeps the visible branch to one current artifact and avoids continuously adding large SQLite binaries to the branch history. GitHub may retain unreachable objects temporarily under its own retention and garbage-collection policies; the wrapper does not maintain backup history or use Git LFS.

## Railway deployment

Deploy this repository as one Railway service. Add a Railway Volume and mount it at exactly `/app/data`. Do not mount the Volume over `/app`, because that would hide the official application files. Use one replica.

Set the variables below in Railway. Copy the official OmniRoute variables required by your provider configuration from the upstream release documentation; they are intentionally not duplicated here because they change with the official release.

| Variable | Required value |
|---|---|
| `DATA_DIR` | `/app/data` |
| `PORT` | `20128`, unless you deliberately configure another supported port |
| `GITHUB_BACKUP_ENABLED` | `true` |
| `GITHUB_BACKUP_REPO` | `YOUR_GITHUB_USERNAME/omniroute-backup` |
| `GITHUB_BACKUP_BRANCH` | `main` |
| `GITHUB_BACKUP_FILE` | `latest.db.zst` |
| `GITHUB_TOKEN` | Fine-grained token for the private backup repository |
| `BACKUP_INTERVAL_MINUTES` | `10` |
| `OMNIROUTE_DB_FILENAME` | `storage.sqlite` |

Railway should use the health check from `railway.json`: `GET /api/monitoring/health`. The wrapper does not add a panel, REST API, database server, Redis service, or management UI.

## Startup and restore behavior

At startup, the wrapper checks `/app/data/storage.sqlite`, which is the verified upstream state marker. If it exists, the wrapper logs that existing data was detected and never downloads or overwrites the GitHub backup. This is the normal Railway redeploy path.

If the database is missing, the wrapper downloads `latest.db.zst`, verifies the zstd frame, decompresses into a temporary file, runs SQLite `PRAGMA quick_check`, and only then installs the database into `/app/data`. If no backup exists or any validation fails, the container exits before starting OmniRoute against partial or corrupt state. On a genuinely empty first deployment with no credentials or no backup, it starts normally with a fresh database and the first backup will occur after OmniRoute creates state.

The restore operation uses a temporary file and a no-clobber rename. Existing `storage.sqlite` is never automatically replaced. The wrapper backs up the database only; upstream documentation identifies `log.txt` and `call_logs/` as diagnostics/request artifacts rather than required application state, so they are deliberately excluded to minimize storage and bandwidth.

## Automatic backups

A lightweight background shell loop checks every ten minutes. It compares the database, WAL, and shared-memory file metadata with the last successful backup fingerprint. If nothing changed, it logs `[backup] no changes; skipping`. If state changed, it invokes SQLite's `.backup` command, which uses SQLite's Online Backup API rather than copying a live database file, runs `PRAGMA quick_check`, compresses with fast zstd, verifies the compressed frame, and publishes the single latest artifact.

Publication is failure-safe. A new orphan commit is prepared and pushed with a forced branch ref update. If snapshotting, compression, verification, or publication fails, the prior `main` ref and its `latest.db.zst` remain available. Credentials are supplied in process memory and are never written into the archive or logs.

There is no zero-data-loss guarantee. With a ten-minute interval, data created after the most recent successful backup may be absent if the Railway project disappears before the next successful run.

## Railway Project A to Project B migration

First deploy this same repository to Project B, attach a new empty Volume at `/app/data`, and set the same backup repository and token variables. On startup, the missing `storage.sqlite` marker causes the wrapper to restore the latest verified backup automatically before starting OmniRoute. Existing state in a new Volume is never overwritten.

The restored state is the last successful external backup, not necessarily every write made after that backup. Keep the backup repository private and verify that the token can read its contents before migration.

## Updating the official OmniRoute release

The Dockerfile pins `diegosouzapw/omniroute:3.8.50`, not `latest`, `main`, or a development branch. To update, first create and verify a fresh backup using the running deployment, confirm that `latest.db.zst` is readable in the private backup repository, then change the pinned tag and deploy. Keep `/app/data` mounted to the existing Railway Volume. Never deploy a new pin when the mandatory pre-update backup failed.

Because the wrapper is intentionally lightweight, the pre-update step is operational rather than an in-container release orchestrator. Before changing the pinned tag, run a one-shot backup inside the running container and confirm it exits successfully:

```sh
docker exec omniroute /app/backup/backup.sh --once
```

On Railway, the same command can be run through the service shell. Only after this succeeds and `latest.db.zst` is readable in the private repository should the pinned tag be changed. A future release may change its database path; update `OMNIROUTE_DB_FILENAME` only after verifying the upstream release files.

## Local testing

Copy `.env.example` to `.env`, set a private test repository and token, then run:

```sh
cp .env.example .env
docker compose up --build
curl --fail http://127.0.0.1:20128/api/monitoring/health
```

For a safe restore test, stop the service, copy the current Volume data aside, remove only the local `storage.sqlite`, start the service, and verify that the database is restored. Restore the original data after the test. Never test by pointing a production Volume at an untrusted backup repository.

The important acceptance scenarios are: a first empty deployment starts without inventing data; an existing Volume skips restore; a changed database produces a new verified artifact; an unchanged database does not upload; an upload failure leaves the old artifact; an empty Project B restores; an existing Project B database is not overwritten; a corrupt zstd or SQLite file is rejected; and an interrupted publication leaves the previous branch ref usable.

## Troubleshooting

If restore is skipped unexpectedly, inspect whether `/app/data/storage.sqlite` already exists and confirm that the Volume is mounted at the exact path. If restore fails with an authentication error, check that `GITHUB_BACKUP_REPO` is `OWNER/REPOSITORY`, the repository is private but accessible to the token, and the token has repository **Contents: Read and write** permission. If backup publication fails, the previous artifact is intentionally preserved; correct the token or repository settings and retry.

To verify persistence, write a harmless test marker through the OmniRoute UI or configuration, redeploy the service without deleting the Volume, and confirm that the state remains. Do not use the presence of unrelated temporary files as the persistence test; the wrapper uses the upstream `storage.sqlite` marker.

## Files

The implementation is deliberately small: `Dockerfile`, `railway.json`, `docker-compose.yml`, `.env.example`, `backup/backup.sh`, `backup/restore.sh`, `backup/github-backup.sh`, and the startup `entrypoint.sh`. No OmniRoute source is included.

## References

[1]: https://github.com/diegosouzapw/OmniRoute/tree/v3.8.50 "Official OmniRoute v3.8.50 release source"
[2]: https://github.com/diegosouzapw/OmniRoute/blob/v3.8.50/Dockerfile "Official OmniRoute Dockerfile"
[3]: https://github.com/diegosouzapw/OmniRoute/blob/v3.8.50/docs/architecture/ARCHITECTURE.md "Official OmniRoute architecture documentation"
