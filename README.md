# upgrade-gitlab

An automated upgrade script for Docker-based GitLab instances. Supports both CE and EE editions with safe, step-by-step version upgrades following the [official upgrade path](https://gitlab-com.gitlab.io/support/toolbox/upgrade-path/).

## Features

- **CE/EE auto-detection** — Automatically detects the running edition from the container image. Supports CE-to-EE migration at the same version before proceeding with upgrades.
- **Safe upgrade path** — Fetches recommended upgrade stops from GitLab's official upgrade-path API and applies them sequentially.
- **Background migration tracking** — Waits for batched background migrations to complete between each version hop, with per-migration progress display.
- **Migration status verification** — Checks for `down` state migrations after each upgrade step.
- **Disk space pre-check** — Validates that data and backup volumes have at least 1.5x free space before starting.
- **Secrets integrity check** — Runs `gitlab:doctor:secrets` before and after the upgrade process.
- **Signal safety** — Critical sections (container swap) defer SIGINT/SIGTERM/SIGTSTP/SIGHUP; `docker pull` is interruptible and auto-retries.
- **Background pre-pull** — Downloads the next version image in the background while the current version stabilizes.
- **Discord notifications** — Optional webhook alerts for upgrade progress, warnings, and errors.
- **Automatic backup** — Creates a GitLab backup and copies `gitlab-secrets.json` and `gitlab.rb` before upgrading.

## Requirements

- **GitLab 12.2+** (recommended minimum version)
  - <=12.1: auto-fallback from `gitlab-backup create` to `gitlab-rake gitlab:backup:create`
  - <=13.0: `doctor:secrets` check auto-skipped (unavailable)
  - <=13.9: background migration tracking auto-skipped (`batched_background_migrations` table unavailable)
  - 13.1+: secrets integrity check enabled
  - 13.10+: full background migration tracking enabled
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
| `-y`, `--yes` | Skip confirmation prompts (non-interactive mode) |
| `--help` | Show help message |
| `--edition=ce\|ee` | Force GitLab edition (auto-detected if omitted) |
| `--version=X.Y.Z` | Upgrade to a specific version instead of latest |
| `--target-url=URL` | GitLab server URL for connection testing |
| `--discord-url=URL` | Discord webhook URL for notifications |
| `--all-tags` | Parse all tags from Docker Hub instead of the upgrade-path API |
| `--page-size=N` | Tags per page when using `--all-tags` (default: 25) |
| `--extract` | Export sorted release tags to `/tmp/gitlab-released-tags.txt` (mutually exclusive with `--version`) |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `TARGET_URL` | Same as `--target-url` |
| `DISCORD_URL` | Same as `--discord-url` |
| `PAGE_SIZE` | Same as `--page-size` |

### Examples

```bash
# Auto-detect everything and upgrade to latest
./upgrade-gitlab --target-url=https://gitlab.example.com

# Upgrade to a specific version with Discord notifications
./upgrade-gitlab --version=17.0.0 --target-url=https://gitlab.example.com --discord-url=https://discord.com/api/webhooks/...

# Switch from CE to EE during upgrade
./upgrade-gitlab --edition=ee --target-url=https://gitlab.example.com

# Export available release tags
./upgrade-gitlab --extract
```

## Upgrade Flow

```
Pre-checks:
  1. Disk space validation (data + backup volumes)
  2. Backup creation (gitlab-backup + secrets + config)
  3. Secrets integrity baseline check

Edition switch (if CE -> EE):
  4. Same-version edition migration

For each version in upgrade path:
  5. Pre-pull next version image (background)
  6. Health check + reconfigure current container
  7. Container swap (stop -> rm -> pull -> run)
  8. Wait for HTTP 200 + healthy status
  9. Wait for background migrations to complete
  10. Verify migration status (no 'down' states)

Post-upgrade:
  11. Final health check (skip reconfigure)
  12. Secrets integrity verification
```

## Signal Handling

| Signal | Normal | Critical Section | During Pull |
|--------|--------|-----------------|-------------|
| SIGINT (Ctrl+C) | Exit | Deferred | Restart pull |
| SIGTERM | Exit | Deferred | Restart pull |
| SIGTSTP (Ctrl+Z) | Exit | Deferred | Restart pull |
| SIGHUP | Exit | Deferred | Restart pull |
| SIGQUIT (Ctrl+\\) | Exit | Exit | Exit |

## License

[MIT](LICENSE)
