# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**upgrade-gitlab** is an automated, Docker-based GitLab upgrade tool that performs safe, step-by-step version upgrades following the official GitLab upgrade path. Single bash script (`upgrade-gitlab`, ~2150 lines) supporting CE/EE editions with background migration tracking, stuck-migration detection, signal safety, and Discord notifications.

Repository: `gitlab.gggames.synology.me/peter/gitlab/upgrade-gitlab` (GitLab, not GitHub — use `glab` instead of `gh`). The former `gitlab.com/gitlab-useful-scripts/upgrade-gitlab` is being retired; its CI can no longer create jobs (GitLab.com requires account identity verification).

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

All `docker stop` calls pass `-t $STOP_TIMEOUT` (300s). The 10s default SIGKILLs GitLab — a real shutdown measures 32-55s — leaving PostgreSQL/Gitaly to crash-recover on the next boot. `-t` is a ceiling, not a fixed wait, so a generous value costs nothing when shutdown is clean.
5. Post-upgrade: final health check, resume paused runners

### Recovery Path
When `UPGRADE_POINTS_ARRAY` is empty (already at target) AND `_prev_exit != 0` (previous container exit was abnormal), the script skips backup and re-runs health/migration/secrets checks only. `docker kill` sets ExitCode=137, so an invocation following a killed container enters this path without taking a fresh backup — the handle used to reach it manually when reproducing stuck-migration scenarios against a real PostgreSQL.

### Backup Progress Tracking
A background `_size_poller` runs `docker exec` in a loop and writes per-tick lines to a tempfile: sizes of `*.tar.gz` staging files, size of the assembled `*_gitlab_backup.tar`, and total non-loopback `tx_bytes` from `/sys/class/net/*/statistics`. `run_with_progress_bar` consumes these to compute per-stage percentages:
Stages pass an `approx` flag to `_draw_backup_progress`; when set, the percentage renders as `~N%` and `_backup_progress_extra` renders the ETA as `ETA ~HH:MM:SS`. Every `*.tar.gz` stage is approximate by construction: the numerator is the gzipped file (`Backup::Helper#compress_cmd` is `gzip -c -1`, overridable via `COMPRESS_CMD`) while the denominator is the uncompressed byte count from the DB, so the bar reads low by the compression ratio. Count-based and raw-byte-based stages (`Dumping repositories`, `Creating backup archive`) are exact and must not gain a `~`.

- `Dumping repositories` → `_total_project_count` vs `"completed create"` log lines (exact)
- `Dumping uploads/artifacts` → `~` tar.gz size vs precomputed total from `project_statistics`. These carry the same object-storage overcount as lfs did, but deliberately keep the `project_statistics` denominator: the precise source (`ci_job_artifacts`) is renamed to the partitioned `p_ci_job_artifacts` in newer schemas, and `_query_backup_stats` runs against the *pre-upgrade* version, so the table name is not stable across the range this tool traverses. Both stages are a ~1% sliver of backup wall-clock; a silently-failing fallback is not worth it.
- `Dumping builds` → indeterminate. `builds.tar.gz` holds CI job logs (`Settings.gitlab_ci.builds_path`), a different tree from `artifacts.tar.gz` (`JobArtifactUploader.root`), and no size column tracks it. Do not fold it back into the artifacts branch — doing so measures a file that does not exist yet at that point in the backup.
- `Dumping lfs objects` → `~` `lfs.tar.gz` size vs `SUM(size) FROM lfs_objects WHERE COALESCE(file_store,1)=1` (`_query_lfs_disk_size`). `lfs.tar.gz` archives the oid-addressed *deduplicated* store, so `SUM(project_statistics.lfs_objects_size)` is the wrong denominator twice over: it double-counts objects shared across forks, and it counts objects that live in object storage and never reach the tar. The query falls back to the `project_statistics` value on failure (old GitLab, permissions); a legitimate `0` is a success and correctly yields an indeterminate bar.
- `Creating backup archive` → assembled tar size vs the staging total. GitLab's `pack` only deletes staging content in its `ensure` block (after the tar is written and uploaded), so the denominator stays valid for the whole stage. The total comes from a one-shot `du -sb --exclude=*_gitlab_backup.tar` fired asynchronously on stage entry (`_start_pack_total_probe`) — `du` can take seconds on a large staging dir, so the bar stays indeterminate until the value lands, and stays indeterminate for good if the probe fails.
- `Uploading backup archive to remote storage` → egress bytes since stage start vs final tar size, rendered with `~` prefix to indicate approximation (fog SDK's per-chunk open/close defeats FD-position tracking, so network bytes are the only viable signal)

### Config Backup Lifecycle
After GitLab's `.tar` backup (which GitLab handles + uploads itself if `backup_upload_*` is configured), the script:
1. Copies `gitlab.rb` and `gitlab-secrets.json` into `BACKUP_DIR` with the `*-${VERSION}-backup` naming.
2. Prunes old copies using `gitlab.rb`'s `backup_keep_time` (parsed with the same simple grep+awk+sed pattern as `backup_path`; missing/0 = keep forever, mirroring GitLab's own retention semantics for `.tar`).
3. Optionally invokes a user hook (see `UPGRADE_GITLAB_CONFIG_HOOK` below). The hook receives the container-side `BACKUP_DIR` (host-path translation is intentionally left to the hook via `docker cp`, so the feature works regardless of mount topology). Hook failures warn but never abort the upgrade.

### Object Storage Detection

`_detect_object_storage_skips` backs `--skip-object-storage`. It reads the **runtime** `Gitlab.config`, not gitlab.rb and not the rendered gitlab.yml. This is not a stylistic choice: consolidated object storage (`gitlab_rails['object_store']['enabled']` + `['objects'][type]['bucket']`) is merged into each type's section by `config/object_store_settings.rb` at Rails boot, *after* omnibus has written gitlab.yml. The rendered yml still shows `<type>.object_store.enabled: false`; only the booted config reflects the truth. Reading runtime config is therefore the one approach that handles the legacy per-type flags (`gitlab_rails['artifacts_object_store_enabled']`) and the consolidated form identically, with no branching.

Detection requires `enabled` **and** a non-empty `remote_directory`. `enabled` alone is not sufficient: `object_store_settings.rb` only raises on a missing bucket when the *type* section's own `enabled` is truthy (`missing_bucket_for`), so a type whose section leaves `enabled:` blank — `agent_plan_content`, `ci_secure_files` — ends up with `object_store.enabled = true` and no bucket. That state means the data is still on disk, and skipping it would drop it from the backup without it existing anywhere else. Observed on a real 19.2.5 instance: every configured type reported `remote_directory="<bucket>"`, `agent_plan_content` reported `nil`. The merge moves `bucket` into `remote_directory` and deletes the original key (`split_bucket_prefix`), so `remote_directory` is the only name visible at runtime. In the legacy path omnibus always renders a `remote_directory` default, so the extra condition filters nothing there.

`_OBJECT_STORAGE_TYPES` holds the type list in one place — the Ruby snippet and the output whitelist both derive from it, since a list duplicated across the two drifts silently. Membership is decided by *backup targets*, not by object storage support: a name only belongs there if `lib/backup/tasks/` has a matching `self.id`, because the result becomes `SKIP=`. `dependency_proxy` supports consolidated object storage but has no backup task, so it is deliberately excluded; `agent_plan_content` has both, so it is included. Backup target ids as of 19.2.5: `agent_plan_content artifacts builds ci_secure_files db external_diffs lfs packages pages registry repositories terraform_state uploads`.

### Container Log Driver
The container is recreated on every hop, so log settings must be passed explicitly or they silently revert to the daemon default. `LOG_ARGS` (derived next to `VOLUMES`/`PORTS`) preserves the current container's `LogConfig.Type` and its `--log-opt`s, with one deliberate exception: Synology ContainerManager's proprietary `db` driver is replaced with `json-file` (`max-size=50m`, `max-file=3`).

`db` deadlocks dockerd whenever a container is stopped while `docker logs --follow` is attached — which is exactly what the non-CI stop path does. Confirmed by goroutine dump (`kill -USR1 <dockerd>`): `dblog.readLogs` → `logdb.tail` blocks on the logdb mutex; the stalled reader still holds the broadcaster mutex that `handleContainerExit` → `CloseStreams` → `broadcaster.Clean` needs; `handleContainerExit` holds the container State lock, so `ContainerStop` → `Daemon.Kill` → `State.GetPID`, `docker kill`, and `docker inspect` all block forever. containerd delivers the exit event correctly — the deadlock is entirely inside dockerd, which is why killing the shim does nothing and only a daemon restart recovers. `json-file` never enters `pkg/logdb`, making the deadlock structurally impossible.

Reproduces only under log-DB contention (a busy multi-container host with accumulated log history); a quiet 2-container host runs the identical code without wedging. `UPGRADE_GITLAB_LOG_DRIVER` overrides the choice in both directions. Trade-off: json-file logs do not appear in the DSM Container Manager UI (`docker logs` is unaffected).

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
- **promote-to-master**: Auto-pushes develop → master (canonical project only, uses `PUSH_TOKEN`)

There is no integration job. One existed — a real GitLab container upgraded end to end, then `batched_background_migrations` rows rewritten to status=4/5 to check stuck detection against a real PostgreSQL — but it had been failing continuously and was removed. Reviving it needs a privileged runner (it drove `docker:dind`) and a runner `maximum_timeout` above the default hour; a multi-hop upgrade of a real instance exceeds that.

It also could not cross GitLab 19.0, which is worth knowing independently of CI: 19.0 dropped bundled Mattermost and its reconfigure hard-aborts with `Removed configurations found in gitlab.rb. Aborting reconfigure` when a `mattermost` key is present. On a stock install it *is* present — 18.x auto-generates a mattermost section in `gitlab-secrets.json` (salts, `sql_at_rest_encrypt_key`) even when Mattermost is unused, and regenerates it on every reconfigure, so each intermediate 18.x hop re-adds it. Crossing 19.0 cleanly would require editing secrets automatically, which is unsafe for real Mattermost users. This is an upstream GitLab issue, not a tool bug; users hit it as actionable output from `print_stacktrace_errors`' "Removed configurations found" branch (covered by a bats test).

## Key Flags

`-y` auto-confirm (requires `DISCORD_URL` unless `CI=true`) | `--dry-run` compute path only | `--version=X[.Y[.Z]]` target version | `--skip-latest`/`--n-1` previous minor | `--no-step-limit` (CI only) | `--skip-lfs` skip LFS in backup | `--skip-object-storage` skip every resource offloaded to object storage (detected via `gitlab-rails runner` reading `Gitlab.config.<type>.object_store` — both `enabled` *and* a non-empty `remote_directory`; merges into the same `SKIP=` list as `--skip-lfs`. See Object Storage Detection below) | `--edition=ce|ee` | `--reset-stuck-finalizing` auto-reset status=5 zombies | `--max-tier=core|starter|premium|ultimate` what's-new URL tier | `--target-url` health check URL | `--discord-url` webhook

Env-only: `UPGRADE_GITLAB_CONFIG_HOOK=PATH` runs an executable after gitlab.rb/secrets.json copies are made and pruned. If unset, an executable `upload-config.hook` next to the script is auto-detected. Hook receives `UPGRADE_GITLAB_SCRIPT_DIR` so it can locate sibling files (rclone.conf, etc.). Template at `upload-config.hook.example`.

`UPGRADE_GITLAB_LOG_DRIVER=NAME` forces the log driver of the recreated container (see Container Log Driver below).
