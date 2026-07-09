# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**upgrade-gitlab** is an automated, Docker-based GitLab upgrade tool that performs safe, step-by-step version upgrades following the official GitLab upgrade path. Single bash script (`upgrade-gitlab`, ~2150 lines) supporting CE/EE editions with background migration tracking, stuck-migration detection, signal safety, and Discord notifications.

Repository: `gitlab.com/gitlab-useful-scripts/upgrade-gitlab` (GitLab, not GitHub — use `glab` instead of `gh`)

## Common Commands

### Linting
```bash
shellcheck upgrade-gitlab
```

### Running Tests
```bash
# All tests (requires bash, curl, jq, coreutils, bats)
bats tests/

# Single test file
bats tests/upgrade_path.bats
bats tests/full_flow.bats

# With coverage (CI style)
kcov --include-pattern=/upgrade-gitlab/upgrade-gitlab coverage_output bats tests/
```

### Dry Run (no Docker required)
```bash
./upgrade-gitlab --dry-run
```

## Architecture

### Single-Script Design
The entire tool is one bash script (`upgrade-gitlab`) with no external library dependencies beyond standard CLI tools (docker, curl, jq, sort, bash 4.0+).

### Upgrade Path Resolution
Single unified source: **path.json** provides required waypoints (major.minor stops), **Docker Hub** resolves each waypoint to its latest patch version and determines the overall latest tag. No `--source` flag, no freshness check, no interactive prompt.

### Signal Safety
The whole post-confirmation flow (after pre-upgrade secrets check, through runner-resume) runs as a single `enter_critical`/`exit_critical` zone. Inside that zone, SIGINT/SIGTERM/SIGTSTP/SIGHUP set the `_interrupted` flag and return without exiting. Each upgrade-loop iteration begins with a flag check that breaks the loop early when set; post-upgrade verification (health, secrets, runner resume) then still runs, after which the script exits 130. The recovery branch (line 1782) opens its own short-lived critical zone with the same semantics. Ctrl+\\ (SIGQUIT) forces immediate exit at any time. `check_gitlab_server_healthy` no longer manages its own critical zone — it relies on the caller's outer zone.

### Stuck Migration Detection
`_check_stuck_migrations` runs at the top of every `wait_for_background_migrations` call and scans `batched_background_migrations` for rows with `updated_at` older than 7 days. Routing by status:
- `failed(4)` → FATAL banner + recovery guide + `exit 1` (always; auto recovery is unsafe).
- `finalizing(5)` → FATAL in `-y` mode; interactive mode polls every 30s until resolved externally; `--reset-stuck-finalizing` auto-resets to `active(1)` so GitLab re-finalizes on the next post-deploy migration (does NOT run the finalize rake itself).
- `paused(0)`/`active(1)`/`aborted(2)` stale → warning only (may be a slow active migration).

### Main Upgrade Flow
1. Pre-flight checks (disk space, secrets integrity)
2. Backup (gitlab-backup or gitlab-rake for <12.2)
3. Optional edition switch (CE→EE)
4. Version upgrade loop: for each stop → pre-pull next image → wait for background migrations → swap container → health check → verify migrations
5. Post-upgrade: final health check, resume paused runners

### Recovery Path
When `UPGRADE_POINTS_ARRAY` is empty (already at target) AND `_prev_exit != 0` (previous container exit was abnormal), the script skips backup and re-runs health/migration/secrets checks only. This is also the entry point exercised by integration-test's stuck-injection scenarios via `docker kill` (which sets ExitCode=137 so the next invocation enters the recovery path without a fresh backup).

### Backup Progress Tracking
A background `_size_poller` runs `docker exec` in a loop and writes per-tick lines to a tempfile: sizes of `*.tar.gz` staging files, size of the assembled `*_gitlab_backup.tar`, and total non-loopback `tx_bytes` from `/sys/class/net/*/statistics`. `run_with_progress_bar` consumes these to compute per-stage percentages:
- `Dumping repositories` → `_total_project_count` vs `"completed create"` log lines
- `Dumping uploads/builds/artifacts/lfs` → tar.gz size vs precomputed total from `project_statistics`
- `Creating backup archive` → assembled tar size vs the staging total. GitLab's `pack` only deletes staging content in its `ensure` block (after the tar is written and uploaded), so the denominator stays valid for the whole stage. The total comes from a one-shot `du -sb --exclude=*_gitlab_backup.tar` fired asynchronously on stage entry (`_start_pack_total_probe`) — `du` can take seconds on a large staging dir, so the bar stays indeterminate until the value lands, and stays indeterminate for good if the probe fails.
- `Uploading backup archive to remote storage` → egress bytes since stage start vs final tar size, rendered with `~` prefix to indicate approximation (fog SDK's per-chunk open/close defeats FD-position tracking, so network bytes are the only viable signal)

### Config Backup Lifecycle
After GitLab's `.tar` backup (which GitLab handles + uploads itself if `backup_upload_*` is configured), the script:
1. Copies `gitlab.rb` and `gitlab-secrets.json` into `BACKUP_DIR` with the `*-${VERSION}-backup` naming.
2. Prunes old copies using `gitlab.rb`'s `backup_keep_time` (parsed with the same simple grep+awk+sed pattern as `backup_path`; missing/0 = keep forever, mirroring GitLab's own retention semantics for `.tar`).
3. Optionally invokes a user hook (see `UPGRADE_GITLAB_CONFIG_HOOK` below). The hook receives the container-side `BACKUP_DIR` (host-path translation is intentionally left to the hook via `docker cp`, so the feature works regardless of mount topology). Hook failures warn but never abort the upgrade.

### TTY-Aware Output
Terminal detected → animated spinners, progress bars with ETA. No terminal (CI) → plain text status.

## Testing

Tests use [BATS](https://github.com/bats-core/bats-core) (Bash Automated Testing System).

### Test Structure
- `tests/upgrade_path.bats` — Logic tests using `--dry-run` (path resolution, `--skip-latest`, `--version`, `--max-tier` validation)
- `tests/full_flow.bats` — Integration tests simulating full upgrade loops via mocks (includes stuck-migration scenarios)
- `tests/test_helper.bash` — Shared setup; prepends `tests/mocks/` to PATH, sets default version `16.11.0-ce.0`, and defaults `CI=true` so local bats bypasses `-y` mode's `DISCORD_URL` requirement. Tests that need to exercise non-CI paths explicitly `unset CI`.

### Mock System
Stateful mock binaries in `tests/mocks/` (curl, docker, df, du, id) shadow real binaries via PATH priority. Docker mock tracks version state through `MOCK_STATE_DIR/current_version` file, enabling multi-step upgrade simulation. Curl mock routes URLs to fixture files. `MOCK_STUCK_MIGRATIONS` / `MOCK_STUCK_RESOLVE_AFTER` env vars simulate stuck batched_background_migrations for detection tests.

### Fixtures
- `tests/fixtures/path.json` — Pre-computed upgrade path waypoints (major.minor stops)
- `tests/fixtures/dockerhub_*.json` — Docker Hub API response fixtures per major version

## CI Pipeline (.gitlab-ci.yml)

Stages: `lint` → `test` → `promote`

- **shellcheck**: Lints on develop, master, MRs
- **logic-test**: Runs `bats tests/` with kcov coverage on develop, master, MRs
- **integration-test**: Spins up real GitLab container, runs full upgrade, then impersonates stuck batched_background_migrations (status=4 / status=5) to validate real-PG detection against the recovery path triggered via `docker kill`. Schedule/manual only, self-hosted runner, 6h timeout.
- **promote-to-master**: Auto-pushes develop → master (official project only, uses `PUSH_TOKEN`)

## Key Flags

`-y` auto-confirm (requires `DISCORD_URL` unless `CI=true`) | `--dry-run` compute path only | `--version=X[.Y[.Z]]` target version | `--skip-latest`/`--n-1` previous minor | `--no-step-limit` (CI only) | `--skip-lfs` skip LFS in backup | `--edition=ce|ee` | `--reset-stuck-finalizing` auto-reset status=5 zombies | `--max-tier=core|starter|premium|ultimate` what's-new URL tier | `--target-url` health check URL | `--discord-url` webhook

Env-only: `UPGRADE_GITLAB_CONFIG_HOOK=PATH` runs an executable after gitlab.rb/secrets.json copies are made and pruned. If unset, an executable `upload-config.hook` next to the script is auto-detected. Hook receives `UPGRADE_GITLAB_SCRIPT_DIR` so it can locate sibling files (rclone.conf, etc.). Template at `upload-config.hook.example`.
