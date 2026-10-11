# upgrade-gitlab

[![pipeline status](https://gitlab.gggames.synology.me/peter/gitlab/upgrade-gitlab/badges/master/pipeline.svg)](https://gitlab.gggames.synology.me/peter/gitlab/upgrade-gitlab/-/commits/master)
[![coverage report](https://gitlab.gggames.synology.me/peter/gitlab/upgrade-gitlab/badges/master/coverage.svg?job=logic-test)](https://gitlab.gggames.synology.me/peter/gitlab/upgrade-gitlab/-/commits/master)

An automated upgrade script for Docker-based GitLab instances. Supports both CE and EE editions with safe, step-by-step version upgrades following the [official upgrade path](https://gitlab-com.gitlab.io/support/toolbox/upgrade-path/).

## Features

- **CE/EE auto-detection** — Automatically detects the running edition from the container image. Supports CE-to-EE migration at the same version before proceeding with upgrades.
- **Safe upgrade path** — Uses `path.json` from the [upgrade-path](https://gitlab.com/gitlab-com/support/toolbox/upgrade-path) project for required waypoints, with Docker Hub API for patch version resolution.
- **Background migration tracking** — Waits for batched background migrations to complete between each version hop, with per-migration progress display.
- **Stuck migration detection** — Flags batched migrations stuck >7 days in `failed(4)` or `finalizing(5)` state with actionable recovery guidance. Interactive mode polls until resolved; `-y` mode exits with a FATAL banner. Use `--reset-stuck-finalizing` to auto-reset `finalizing` zombies to `active`.
- **Migration status verification** — Checks for `down` state migrations after each upgrade step.
- **Disk space pre-check** — Validates that data and backup volumes have at least 1.5x free space before starting.
- **Secrets integrity check** — Runs `gitlab:doctor:secrets` before and after the upgrade process.
- **Signal safety** — Critical sections (container swap) defer SIGINT/SIGTERM/SIGTSTP/SIGHUP; `docker pull` is interruptible and auto-retries.
- **Background pre-pull** — Downloads the next version image in the background while the current version stabilizes.
- **Discord notifications** — Webhook alerts for upgrade progress, warnings, and errors. The completion message links to GitLab's "What is new since" page pre-filtered to the upgrade's previous version. Required in `-y` mode (unless `CI=true`) so fatal events are never silent.
- **Automatic backup** — Creates a GitLab backup and archives the whole `/etc/gitlab` volume with `gitlab-ctl backup-etc` before upgrading. GitLab's own backup leaves that volume out on purpose, and it holds more than `gitlab.rb` and `gitlab-secrets.json`: the SSH host keys, TLS keys and certificates, the Gitaly commit signing key and the license. The archive (mode 600) goes to `/etc/gitlab/config_backup`, apart from the application backup; a failed archive aborts the run like a failed backup. The separate `gitlab.rb` / `gitlab-secrets.json` copies next to the backup are no longer made; a config hook that `docker cp`s them must switch to the archive (see the hook row below). Old config copies and archives are pruned with the same retention as `gitlab.rb`'s `backup_keep_time`, mirroring GitLab's own retention policy for the main `*.tar` files. The upgrade does not start without a complete backup: a failed backup always aborts the run (there is no override), and cancelling during the backup stops the `gitlab-backup` process inside the container too, instead of leaving it running.
- **Maintenance mode during the upgrade** — When the instance supports GitLab maintenance mode (Premium/Ultimate), it is enabled before the backup so non-admin writes cannot land between the database and repository dumps, then disabled at the end — including on aborts, and on the next run if the process died. Costs one `gitlab-rails` boot before the backup (shared with `--skip-object-storage` when that is also set) and one to release at the end — around 5 minutes each (2m22s CE / 3m52s EE measured on 19.2.6; slower on a larger instance). Opt out with `--no-maintenance-mode`.
- **Approximate upload progress** — During `Uploading backup archive to remote storage` (when GitLab's `backup_upload_*` is configured), shows an approximate `~%` derived from container egress bytes vs the assembled tar size. fog SDK's per-chunk open/close defeats exact tracking, so the percentage is explicitly marked with `~`.
- **Post-config-backup hook** — Optional executable invoked after the config snapshots are made and pruned. Use it to ship the `/etc/gitlab` archive to wherever you want (S3, GCS, Azure Blob, OpenStack Swift, Google Drive — or anywhere `docker run ...` can reach). See [`upload-config.hook.example`](upload-config.hook.example).
- **Patched images** — For instances that run the official image plus local source patches, an optional image hook builds the image to run for each hop (e.g. `FROM gitlab/gitlab-ee:<ver>` + `git apply`). It runs before the old container is stopped, and its result must carry an `org.upgrade-gitlab.base` label naming the official base; a failure stops the upgrade with the current version still running. A container on such a derived image is detected through that label. Without a hook, each hop would start the official image and drop the patches, so an interactive run asks first (y/N) and `-y` refuses. See [`build-image.hook.example`](build-image.hook.example), which applies every `*.patch` in a `patches/` directory next to the script.
- **Recovery on abnormal exit** — If the previous run left the container with a non-zero exit code, re-running the script at the already-installed version skips the backup and re-runs health, migration, and secrets checks instead of silently exiting "already satisfied".

## Requirements

>>> [!WARNING] Data loss risk
Versions below 13.10 cannot track batched background migrations, which may cause data corruption during upgrades.

EOS (end-of-support) versions are checked via GitLab releases API but not exhaustively tested.
>>>

- **GitLab 13.10+** (recommended minimum version)
  - 13.10+: full background migration tracking enabled
  - 13.1+: secrets integrity check enabled
  - <=13.0: `doctor:secrets` check auto-skipped (unavailable)
  - <=12.1: auto-fallback from `gitlab-backup create` to `gitlab-rake gitlab:backup:create`
- Docker (Engine or Desktop)
- `bash`, `curl`, `jq`, `sort` (with `-V` flag)
- Access to the Docker daemon (root, Docker group membership, or rootless Docker via `DOCKER_HOST`)

## Usage

```bash
./upgrade-gitlab [OPTIONS]
```

### Options

| Flag | Description |
|------|-------------|
| `-y`, `--yes` | Skip confirmation prompts (non-interactive mode). Requires `DISCORD_URL` unless `CI=true`. |
| `--help` | Show help message |
| `--edition=ce\|ee` | Force GitLab edition (auto-detected if omitted) |
| `--version=X.Y.Z` | Upgrade to a specific version instead of latest. Partial versions (e.g. `18`) are resolved automatically. End-of-support versions are rejected via GitLab releases API. |
| `--skip-latest`, `--n-1` | Target the latest patch of the previous minor version (N-1 strategy). Can combine with major-only `--version` (e.g. `--version=18 --skip-latest` targets N-1 within major 18). |
| `--dry-run` | Compute and display upgrade path without executing. Implies `-y`. |
| `--skip-lfs` | Skip LFS objects during backup |
| `--no-maintenance-mode` | Do not enable [maintenance mode](https://docs.gitlab.com/administration/maintenance_mode/). By default it is enabled right before the backup when the instance supports it (checked at runtime, so CE/unlicensed instances are skipped silently) and disabled when the run ends. A mode that was already on is left on. |
| `--running-jobs=wait\|abort` | What to do with CI jobs still running once the runners are paused: `wait` (default) until they finish, or `abort` the upgrade without touching them. Interactive runs ask, with this as the default. CI jobs are never cancelled by the script. |
| `--running-jobs-timeout=SECONDS` | Upper bound for `wait`. `0` (default) waits indefinitely so a deployment job is never cut off; when exceeded, the upgrade is aborted before the backup. |
| `--no-step-limit` | Disable the 3-step safety limit for `-y` mode. Requires `CI=true`. |
| `--reset-stuck-finalizing` | Reset batched_background_migrations rows stuck in `finalizing(5)` state for >7 days back to `active(1)` so GitLab can re-finalize them. Does NOT execute the finalize rake task itself. |
| `--max-tier=TIER` | Upper tier bound (`core`/`starter`/`premium`/`ultimate`) for the "What is new since" link in the completion webhook. Default: `core` for CE, `ultimate` for EE. |
| `--ready-timeout=SECONDS` | Upper bound for waiting until a started container is ready (the sign-in page and the Docker health check, both checked inside the container). Default `3600`; `0` waits indefinitely. When exceeded, interactive runs ask whether to keep waiting; `-y` stops with exit 1 and, like a fatal error, leaves the runners paused and maintenance mode on until a later run releases them. |
| `--discord-url=URL` | Discord webhook URL for notifications (required in `-y` mode unless `CI=true`) |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `DISCORD_URL` | Same as `--discord-url` |
| `UPGRADE_GITLAB_CONFIG_HOOK` | Path to an executable run after the `/etc/gitlab` archive is made and old config backups are pruned. If unset, an executable file named `upload-config.hook` next to the script is auto-detected. Receives `UPGRADE_GITLAB_CONFIG_ARCHIVE` (the archive) and `UPGRADE_GITLAB_BACKUP_DIR` (container-side paths; use `docker cp` to extract), `UPGRADE_GITLAB_VERSION`, `UPGRADE_GITLAB_CONTAINER`, `UPGRADE_GITLAB_SCRIPT_DIR` env vars. Hook failure logs a warning but does not abort the upgrade. A hook copied from the earlier template, which `docker cp`s `gitlab.rb.<version>-backup` and `gitlab-secrets.json.<version>-backup` from the backup directory, now fails because those copies are no longer made: replace that part with a `docker cp` of `$UPGRADE_GITLAB_CONFIG_ARCHIVE`, as in the current template. See [`upload-config.hook.example`](upload-config.hook.example) for a template covering S3 / GCS / Azure Blob / OpenStack Swift / Google Drive uploads. |
| `UPGRADE_GITLAB_IMAGE_HOOK` | Path to an executable that builds the image to run for each hop. If unset, an executable file named `build-image.hook` next to the script is auto-detected. Receives `UPGRADE_GITLAB_BASE_IMAGE` (e.g. `gitlab/gitlab-ee:19.4.1-ee.0`), `UPGRADE_GITLAB_VERSION`, `UPGRADE_GITLAB_EDITION`, `UPGRADE_GITLAB_CONTAINER`, `UPGRADE_GITLAB_SCRIPT_DIR`. Must print the image to run as the last line of stdout (build logs go to stderr), and that image must carry the label `org.upgrade-gitlab.base=<base image>`. Unlike the config hook, a failure or a configured-but-not-executable hook stops the upgrade. See [`build-image.hook.example`](build-image.hook.example) for a template. |

### Examples

```bash
# Auto-detect everything and upgrade to latest
./upgrade-gitlab

# Upgrade to a specific version with Discord notifications
./upgrade-gitlab --version=17.0.0 --discord-url=https://discord.com/api/webhooks/...

# Switch from CE to EE during upgrade
./upgrade-gitlab --edition=ee

# Upgrade to the latest patch of the previous minor (N-1 strategy)
# e.g. if latest is 18.9.x, targets the latest 18.8.x patch
./upgrade-gitlab --skip-latest

# N-1 within a specific major version
# e.g. if latest in major 18 is 18.9.x, targets the latest 18.8.x patch
./upgrade-gitlab --version=18 --skip-latest

# Preview upgrade path without executing
./upgrade-gitlab --dry-run
```

## Upgrade Flow

```
Pre-checks:
  1. Disk space validation (data + backup volumes)
  2. Backup creation (gitlab-backup) + /etc/gitlab archive (gitlab-ctl backup-etc)
  3. Prune old config copies and archives via backup_keep_time
  4. Optional post-config-backup hook (UPGRADE_GITLAB_CONFIG_HOOK)
  5. Secrets integrity baseline check

For each step in upgrade path (a CE -> EE switch is the first step, at the same version):
  6. Prepare the image to run: pull it, then build it via UPGRADE_GITLAB_IMAGE_HOOK if configured (a failure stops here, before the swap)
  7. Pre-pull next version image (background)
  8. Health check current container
  9. Wait for background migrations to complete (with stuck detection)
  10. Container swap (stop -> rm -> start the prepared replacement)
  11. Wait for HTTP 200 + healthy status
  12. Wait for background migrations to complete (with stuck detection)
  13. Verify migration status (no 'down' states)

Post-upgrade:
  14. Final health check
  15. Secrets integrity verification
  16. Resume any runners that were paused before the upgrade
```

## Signal Handling

The whole upgrade flow from the post-secrets-check point through runner-resume is a single critical zone. SIGINT/SIGTERM/SIGTSTP/SIGHUP inside that zone are deferred — set a flag and return; the script reaches the next safe checkpoint (start of next loop iteration) and breaks early, then still runs post-upgrade verification (final health check, secrets check, runner resume) before exiting 130. This means an aborted upgrade still leaves GitLab in a consistent, verified state at whichever version step had completed.

| Signal | Outside critical (backup, prompts, RestartPolicy) | Inside critical (upgrade loop incl. CE→EE, post-upgrade) | During docker pull |
|--------|---------------------------------------------------|----------------------------------------------------------|--------------------|
| SIGINT (Ctrl+C) | Exit immediately | Deferred → finish current iteration → break loop → post-upgrade → exit 130 | Restart pull |
| SIGTERM | Exit immediately | Deferred (same as SIGINT) | Restart pull |
| SIGTSTP (Ctrl+Z) | Exit immediately | Deferred (same as SIGINT) | Restart pull |
| SIGHUP | Exit immediately | Deferred (same as SIGINT) | Restart pull |
| SIGQUIT (Ctrl+\\) | Exit immediately | Exit immediately (escape hatch) | Exit immediately |

## Testing

### Lint

```bash
shellcheck upgrade-gitlab
```

### BATS suites (mock-driven, no Docker required)

```bash
# All suites
bats tests/

# Single suite
bats tests/upgrade_path.bats   # arg parsing + path resolution via --dry-run
bats tests/full_flow.bats      # full upgrade flow against stateful mocks (incl. stuck-migration scenarios)
```

## Wiki

For detailed guides, see the [project wiki](https://gitlab.gggames.synology.me/peter/gitlab/upgrade-gitlab/-/wikis/home):

- [Pre-upgrade Checklist](https://gitlab.gggames.synology.me/peter/gitlab/upgrade-gitlab/-/wikis/Pre-upgrade-Checklist) — Manual steps to complete before running the script
- [Troubleshooting](https://gitlab.gggames.synology.me/peter/gitlab/upgrade-gitlab/-/wikis/Troubleshooting) — Solutions for DB migration failures and debugging tips

## License

[MIT](LICENSE)
