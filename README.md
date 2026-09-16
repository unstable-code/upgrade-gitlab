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
- **Automatic backup** — Creates a GitLab backup and copies `gitlab-secrets.json` and `gitlab.rb` before upgrading. Old config copies are pruned with the same retention as `gitlab.rb`'s `backup_keep_time`, mirroring GitLab's own retention policy for the main `*.tar` files.
- **Maintenance mode during the upgrade** — When the instance supports GitLab maintenance mode (Premium/Ultimate), it is enabled before the backup so non-admin writes cannot land between the database and repository dumps, then disabled at the end — including on aborts, and on the next run if the process died. Opt out with `--no-maintenance-mode`.
- **Approximate upload progress** — During `Uploading backup archive to remote storage` (when GitLab's `backup_upload_*` is configured), shows an approximate `~%` derived from container egress bytes vs the assembled tar size. fog SDK's per-chunk open/close defeats exact tracking, so the percentage is explicitly marked with `~`.
- **Post-config-backup hook** — Optional executable invoked after the config snapshots are made and pruned. Use it to ship `gitlab.rb` / `gitlab-secrets.json` to wherever you want (S3, GCS, Azure Blob, OpenStack Swift, Google Drive — or anywhere `docker run ...` can reach). See [`upload-config.hook.example`](upload-config.hook.example).
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
- Root access or Docker group membership

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
| `--no-step-limit` | Disable the 3-step safety limit for `-y` mode. Requires `CI=true`. |
| `--reset-stuck-finalizing` | Reset batched_background_migrations rows stuck in `finalizing(5)` state for >7 days back to `active(1)` so GitLab can re-finalize them. Does NOT execute the finalize rake task itself. |
| `--max-tier=TIER` | Upper tier bound (`core`/`starter`/`premium`/`ultimate`) for the "What is new since" link in the completion webhook. Default: `core` for CE, `ultimate` for EE. |
| `--target-url=URL` | GitLab server URL for connection testing |
| `--discord-url=URL` | Discord webhook URL for notifications (required in `-y` mode unless `CI=true`) |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `TARGET_URL` | Same as `--target-url` |
| `DISCORD_URL` | Same as `--discord-url` |
| `UPGRADE_GITLAB_CONFIG_HOOK` | Path to an executable run after the `gitlab.rb` / `gitlab-secrets.json` snapshots are copied and pruned. If unset, an executable file named `upload-config.hook` next to the script is auto-detected. Receives `UPGRADE_GITLAB_BACKUP_DIR` (container-side path; use `docker cp` to extract), `UPGRADE_GITLAB_VERSION`, `UPGRADE_GITLAB_CONTAINER`, `UPGRADE_GITLAB_SCRIPT_DIR` env vars. Hook failure logs a warning but does not abort the upgrade. See [`upload-config.hook.example`](upload-config.hook.example) for a template covering S3 / GCS / Azure Blob / OpenStack Swift / Google Drive uploads. |

### Examples

```bash
# Auto-detect everything and upgrade to latest
./upgrade-gitlab --target-url=https://gitlab.example.com

# Upgrade to a specific version with Discord notifications
./upgrade-gitlab --version=17.0.0 --target-url=https://gitlab.example.com --discord-url=https://discord.com/api/webhooks/...

# Switch from CE to EE during upgrade
./upgrade-gitlab --edition=ee --target-url=https://gitlab.example.com

# Upgrade to the latest patch of the previous minor (N-1 strategy)
# e.g. if latest is 18.9.x, targets the latest 18.8.x patch
./upgrade-gitlab --skip-latest --target-url=https://gitlab.example.com

# N-1 within a specific major version
# e.g. if latest in major 18 is 18.9.x, targets the latest 18.8.x patch
./upgrade-gitlab --version=18 --skip-latest --target-url=https://gitlab.example.com

# Preview upgrade path without executing
./upgrade-gitlab --dry-run
```

## Upgrade Flow

```
Pre-checks:
  1. Disk space validation (data + backup volumes)
  2. Backup creation (gitlab-backup) + copy gitlab.rb / gitlab-secrets.json
  3. Prune old config copies via backup_keep_time
  4. Optional post-config-backup hook (UPGRADE_GITLAB_CONFIG_HOOK)
  5. Secrets integrity baseline check

Edition switch (if CE -> EE):
  6. Same-version edition migration

For each version in upgrade path:
  7. Pre-pull next version image (background)
  8. Health check current container
  9. Wait for background migrations to complete (with stuck detection)
  10. Container swap (stop -> rm -> pull -> run)
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

| Signal | Outside critical (backup, prompts, RestartPolicy) | Inside critical (CE→EE, upgrade loop, post-upgrade) | During docker pull |
|--------|---------------------------------------------------|-----------------------------------------------------|--------------------|
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
