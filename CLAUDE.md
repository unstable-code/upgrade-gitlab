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

### Maintenance Mode

Enabled by default right before the backup, disabled at the end; `--no-maintenance-mode` opts out. The purpose is backup consistency: no non-admin writes between the DB dump and the repository dumps.

Availability is decided inside `gitlab-rails runner` (`_MAINTENANCE_ENABLE_RUBY`), never from the DB. On a real 19.2 EE instance `License.current&.plan` was `nil` while `License.feature_available?(:maintenance_mode)` was `true` and the Admin UI section was present, so a DB-side license check would give the wrong answer. CE (`License` undefined) and pre-13.9 schemas (no column) both surface as `NameError` → `unavailable`; any other exception → `error`. Neither blocks the upgrade.

Writes go through `ApplicationSetting.current_without_cache.update!`, not psql: an SQL `UPDATE` leaves the settings cache (process memory + Redis) stale.

When `--skip-object-storage` is also set, both snippets run in one rails boot; `_detect_object_storage_skips` filters runner output from stdin with the type whitelist, which is what keeps the `maintenance_mode=` line out of `SKIP=`.

Release goes through `_release_upgrade_holds`, which resumes paused runners and disables maintenance mode together — every exit path (normal end, recovery, already-satisfied, EXIT trap) calls that one function, so a third pre-upgrade hold does not have to be threaded through four call sites again. Both halves are idempotent: `_resume_paused_runners` clears `PAUSED_RUNNER_IDS` after a successful resume so a second call cannot re-resume from the memory fallback.

A persistent `.maintenance-mode` state file next to the runner state file is the source of truth, it is removed only after a successful disable, and a leftover file is released by the next run. `already` (the admin turned it on) writes no state file, so it is never turned off by the script. A failed disable is not retried inside the same process (`_maintenance_release_attempted`): the state file already carries the retry to the next run, and a rails boot costs around 5 minutes per attempt (measured on 19.2.6: 2m22s CE, 3m52s EE; a larger or busier instance takes longer), unlike the sub-second psql UPDATE behind runner resume. That cost is also why the enable snippet shares the pre-backup boot with `--skip-object-storage` rather than taking its own, and why the feature adds roughly ten minutes per run in total (one boot before the backup, one to release at the end) — accepted because a real upgrade spends far longer in backup and hops. The EXIT trap skips the whole release under `--dry-run` — that flag promises to compute the path and change nothing, including holds left by another run.

Every `gitlab-rails runner` call goes through `_rails_runner` (a thin wrapper over `_exec_isolated`, which serves any side-effecting `docker exec` whose result the script needs; output lands in `_exec_out`), because a terminal Ctrl+C signals the whole foreground process group: it kills the `docker exec` client, but the runner inside the container carries on regardless (reproduced on docker 29.8 — the in-container side effect happened while the client returned empty output). Pressed during the enable boot, that meant the script exited without the `enabled` result and so without a state file, and minutes later the orphaned runner turned maintenance mode on with nothing left to turn it off. `_rails_runner` starts the client under `set -m` so it gets its own process group and the terminal's signal never reaches it (pure bash — `setsid` is not guaranteed on DSM), and defers signals like a critical zone while it waits via `_wait_reap`. The caller acts on the deferred `_interrupted` only after the result is recorded; before the backup that is an `exit 130`, which the EXIT trap turns into a proper release. Results come back through the `_exec_out` global rather than command substitution, since traps revert to their defaults inside a `$(...)` subshell and the deferral would silently stop working. The cost is that Ctrl+C now waits out the in-flight boot — the container was going to run it to completion either way. Ctrl+\\ (SIGQUIT) still forces an immediate exit, and with it the old orphan risk.

### Backup Failure and Cancellation

Two failure modes combined into "an irreversible upgrade with no backup of the current version" (#16), and both are now closed.

**A failed backup aborts.** The backup's exit code used to be ignored, so a failure went straight on to config copies, the critical zone and the container swap. Upstream (checked at `v19.2.6-ee`): `Backup::Manager#create` returns `create_task_result.all?` and the task does `exit 1 unless success`; DB/file-target errors (`DatabaseBackupError`/`FileBackupError`) are logged and the remaining targets still run, while a repository failure raises plain `Backup::Error` and aborts at once. Either way the code is non-zero, and nothing exits non-zero on a mere warning, so non-zero means incomplete. It always aborts, interactive or not. Unlike the pre-upgrade secrets check there is deliberately no "continue anyway" prompt: this tool cannot roll back, and an incomplete backup is not a backup. The way forward is to fix the cause, or to exclude a target explicitly with `--skip-*`.

**Cancelling a backup stops the one inside the container.** The client dies on Ctrl+C but `gitlab-backup` does not, and it would carry on through `pack` → `upload` → `remove_old` after the holds were released. Worse, 16.0+ serializes backups through `Rails.root/tmp/backup_restore.pid` (`lock_backup`, MR !119004), so re-running right away failed the new backup on the lock, and that failure used to be ignored. `_backup_in_progress` brackets the backup call, and the EXIT trap calls `_stop_container_backup` *before* `_release_upgrade_holds` — releasing maintenance mode while the dump is still running would defeat it. The stop sends SIGTERM, not SIGKILL: the backup code has no signal handling, so Ruby raises `SignalException` and the `ensure` blocks clean staging and delete the PID file. The target is `pgrep -f "$_BACKUP_PROC_PATTERN"` (`gitlab[:]backup[:]create`), which matches the rake ruby process and not the `gitlab-backup create` bash wrapper, and covers the <12.2 `gitlab-rake` path too. The pattern is defined once because it is used in three places: the first liveness check, the in-container wait, and the size poller. The bracket form matches the real process but not an `sh` loop that carries the pattern as an argument; the plain string would make such a loop match itself forever. The rake process's direct children (`tar`/`gzip`, `pg_dump`, `gitaly-backup`) get SIGTERM as well, rake first. With rake alone, the exception only fires once the in-flight pipeline returns, so the current target is dumped to the end anyway. The wait is for exit, not completion, capped by `STOP_TIMEOUT`. The SIGTERM and the wait run as a single in-container `sh -c`, which exits 124 on timeout so that a timeout stays distinguishable from a failed `docker exec`; polling with one `docker exec` per check would cost up to 150 round-trips. Past the timeout it prints the PID and a `pgrep` command to watch, and still releases the holds. Signals are deferred during the wait, because a second Ctrl+C exiting inside the EXIT trap would skip the release entirely.

Measured on a disposable 19.2.6 EE container with a 3GB file in uploads, interrupting during `Dumping uploads`:

| SIGTERM sent to | exit after | next target started? | cleanup |
|---|---|---|---|
| rake only | 43s (after the uploads `tar \| gzip` finished) | no | staging, `backups/tmp`, PID file all removed; no processes left |
| rake, then its children | 1s | no — the pending `SignalException` wins over the target's failure path | same |

The risk the second row rules out: that a killed `tar` would surface as a `FileBackupError`, which `run_create_task` rescues, and let the run continue to the next target.

The progress bar's `_size_poller` had the same orphan problem in its own right. Its in-container `while true` loop outlives the local `docker exec` client that `_stop_size_poller` and `_handle_signal` kill. On a run that goes on to upgrade, the container swap removed it; after a cancel or an aborted backup it kept polling every 0.5s until the container restarted (found by the 19.2.6 E2E). The loop now ends itself: once the backup process has been seen and is gone, or after ~10 minutes if it never appears. It takes `_BACKUP_PROC_PATTERN` as a positional argument, which is exactly the self-match case the bracket form exists for.

### Container Log Driver
The container is recreated on every hop, so log settings must be passed explicitly or they silently revert to the daemon default. `LOG_ARGS` (derived next to `VOLUMES`/`PORTS`) preserves the current container's `LogConfig.Type` and its `--log-opt`s, with one deliberate exception: Synology ContainerManager's proprietary `db` driver is replaced with `json-file` (`max-size=50m`, `max-file=3`).

`db` deadlocks dockerd whenever a container is stopped while `docker logs --follow` is attached — which is exactly what the non-CI stop path does. Confirmed by goroutine dump (`kill -USR1 <dockerd>`): `dblog.readLogs` → `logdb.tail` blocks on the logdb mutex; the stalled reader still holds the broadcaster mutex that `handleContainerExit` → `CloseStreams` → `broadcaster.Clean` needs; `handleContainerExit` holds the container State lock, so `ContainerStop` → `Daemon.Kill` → `State.GetPID`, `docker kill`, and `docker inspect` all block forever. containerd delivers the exit event correctly — the deadlock is entirely inside dockerd, which is why killing the shim does nothing and only a daemon restart recovers. `json-file` never enters `pkg/logdb`, making the deadlock structurally impossible.

Reproduces only under log-DB contention (a busy multi-container host with accumulated log history); a quiet 2-container host runs the identical code without wedging. `UPGRADE_GITLAB_LOG_DRIVER` overrides the choice in both directions. Trade-off: json-file logs do not appear in the DSM Container Manager UI (`docker logs` is unaffected).

### Reconfigure Deprecation Summary

Chef's trailing `Deprecations:` block from `gitlab-ctl reconfigure` was always streamed to stdout — `run_with_bouncing_bar` prints every new line of the command's output as it appears. It was simply unreadable: one reconfigure emits hundreds to thousands of lines, and reconfigure runs once per hop, so the block scrolls out of the buffer and repeats. Those warnings are the advance notice for the next major's hard abort (`print_stacktrace_errors`' "Removed configurations found" branch), so they are worth surfacing where they can be read.

`_record_deprecations` collects the block per hop; `print_deprecation_summary` re-prints the unique entries after `exit_critical`, tagged with the version each was first seen at. It sits before the interrupt branch, so an interrupted run still reports what it saw and still fires the accompanying `WARN` webhook (count plus the first three entries). The webhook stays at the call site rather than inside the function — a `print_*` function that also sends network notifications would be misnamed. `print_stacktrace_errors`' "Removed configurations found" branch prints the summary too: the keys that abort reconfigure are usually the ones earlier hops already warned about, so the collected list doubles as the "which key do I delete" shortlist.

The streaming loop is deliberately untouched. `run_with_bouncing_bar` draws its bar to `$_tty` and writes the command's output to stdout, so the call site just pipes through `tee` to keep one copy. The command-substitution idiom used by `check_secrets_integrity` and `check_migration_status` (`output=$(run_with_bouncing_bar ...)`) would also capture it, but suppresses the live stream — which is precisely what must be preserved here.

Block boundaries: the header is a line that is exactly `Deprecations:`; entries run until a blank line or the next top-level Chef section (`Running handlers`, `Chef Infra Client`, `gitlab Reconfigured!`). Deprecation text never ends in a colon, so it cannot be mistaken for the header. Parse failures are silent no-ops — a missed summary must never abort an upgrade. Associative-array subscripts are quoted throughout because the entries routinely contain `]` (`nginx['listen_port'] has been deprecated.`).

### TTY-Aware Output
Terminal detected → animated spinners, progress bars with ETA. No terminal (CI) → plain text status.

## Testing

Tests use [BATS](https://github.com/bats-core/bats-core) (Bash Automated Testing System).

### Test Structure
- `tests/upgrade_path.bats` — Logic tests using `--dry-run` (path resolution, `--skip-latest`, `--version`, `--max-tier` validation)
- `tests/full_flow.bats` — Integration tests simulating full upgrade loops via mocks (includes stuck-migration scenarios)
- `tests/deprecations.bats` — Unit tests for the reconfigure deprecation collector; helpers are source-extracted with `sed` (the `preflight.bats` pattern) and the collector globals re-seeded per test
- `tests/test_helper.bash` — Shared setup; prepends `tests/mocks/` to PATH, sets default version `16.11.0-ce.0`, and defaults `CI=true` so local bats bypasses `-y` mode's `DISCORD_URL` requirement. Tests that need to exercise non-CI paths explicitly `unset CI`.

### Mock System
Stateful mock binaries in `tests/mocks/` (curl, docker, df, du, id) shadow real binaries via PATH priority. Docker mock tracks version state through `MOCK_STATE_DIR/current_version` file, enabling multi-step upgrade simulation. Curl mock routes URLs to fixture files. `MOCK_STUCK_MIGRATIONS` / `MOCK_STUCK_RESOLVE_AFTER` env vars simulate stuck batched_background_migrations for detection tests.

### Fixtures
- `tests/fixtures/path.json` — Pre-computed upgrade path waypoints (major.minor stops)
- `tests/fixtures/dockerhub_*.json` — Docker Hub API response fixtures per major version

### Integration Testing Against a Disposable GitLab (local Docker)

There is no integration job in CI (see CI Pipeline below). Anything the mocks cannot prove — how GitLab itself reacts to a signal, a lock, a real exit code, real cleanup — is verified by starting a throwaway GitLab in Docker on the work machine and running the real script against it. Needs about 4-5GB of RAM; a fresh container turned healthy in ~70s on a 32-core workstation.

```bash
docker run -d --name ugtest-gitlab --shm-size 256m \
  -p 127.0.0.1:18080:80 \
  -v ugtest-gitlab-config:/etc/gitlab \
  -v ugtest-gitlab-logs:/var/log/gitlab \
  -v ugtest-gitlab-data:/var/opt/gitlab \
  -e GITLAB_OMNIBUS_CONFIG="external_url 'http://localhost:18080'; puma['worker_processes'] = 0; sidekiq['concurrency'] = 5; prometheus_monitoring['enable'] = false; gitlab_rails['backup_path'] = '/var/opt/gitlab/backups'" \
  gitlab/gitlab-ee:19.2.6-ee.0

# run the script against it (CI=true lifts -y's DISCORD_URL requirement)
CI=true ./upgrade-gitlab -y --no-step-limit --target-url=http://localhost:18080

# cleanup; volumes too, since they cannot be reused at an older version
docker rm -f ugtest-gitlab && docker volume rm ugtest-gitlab-config ugtest-gitlab-logs ugtest-gitlab-data
```

Things that bit when this was first done:

- **An uninterrupted run really upgrades the container.** Once a run crosses a hop, the volumes hold a newer schema and cannot go back; to test at the old version again, remove the container *and* the volumes and start over. The script also deletes the previous image after a hop, so expect a re-pull.
- **Only one `gitlab/gitlab-ce|ee` container may exist on the host**, because the script auto-detects its target by image.
- **Rootless Docker fails the script's permission check.** The check greps `id` output for `docker`, and rootless Docker (`DOCKER_HOST=unix:///run/user/$UID/docker.sock`) needs no docker group. That is a limitation of the script, not of the host. For testing, put a shim `id` first on `PATH` that appends a marker when called without arguments and `exec`s the real `id` otherwise.
- **Make the backup slow enough to interrupt.** An empty instance backs up in seconds. A 3GB random file in uploads stretches the uploads stage to ~45s: `docker exec ugtest-gitlab sh -c 'dd if=/dev/urandom of=/var/opt/gitlab/gitlab-rails/uploads/big.bin bs=1M count=3000 && chown git:git /var/opt/gitlab/gitlab-rails/uploads/big.bin'`. Poll for `pgrep -f 'directory=/var/opt/gitlab/gitlab-rails/uploads'` inside the container to know when the dump is running.
- **A real Ctrl+C needs a real terminal, in the foreground.** Drive the script through `script(1)` and write `\003` into its stdin: the pty line discipline turns that into SIGINT for the foreground process group, exactly like a keypress. Keep `script(1)` in the foreground of a pipeline (`{ wait; printf '\003'; ... } | env --default-signal=INT script -q -e -f -c "..." log`) and never background it with `&`. A background job of a non-interactive shell starts with SIGINT ignored (`SigIgn: 0x6` in `/proc/<pid>/status`), and bash cannot trap a signal that was ignored on entry. The script then never sees ^C, while the docker client, whose Go runtime re-enables SIGINT, dies alone. In that state the first attempt carried on and upgraded the test container instead of cancelling. `env --default-signal=INT` makes the driver immune to how it was itself launched.

Scenarios verified this way on 19.2.6 EE (unlicensed: maintenance mode reports `unavailable`):

- Ctrl+C during the uploads dump: exit 130, the in-container backup stopped in ~1s, staging and PID file removed, no processes left, no upgrade.
- A backup already running (holding the 16.0+ lock) when the script starts: the script's backup fails with `Backup and restore in progress`, the run aborts with exit 1 and no upgrade, and the other backup is left alone to finish with `exit=0`.
- An uninterrupted run: a full 19.2.6 → 19.4.0 upgrade succeeded.

## CI Pipeline (.gitlab-ci.yml)

Stages: `lint` → `test` → `promote`

- **shellcheck**: Lints on develop, master, MRs
- **logic-test**: Runs `bats tests/` with kcov coverage on develop, master, MRs
- **promote-to-master**: Auto-pushes develop → master (canonical project only, uses `PUSH_TOKEN`)

There is no integration job. One existed — a real GitLab container upgraded end to end, then `batched_background_migrations` rows rewritten to status=4/5 to check stuck detection against a real PostgreSQL — but it had been failing continuously and was removed. Reviving it needs a privileged runner (it drove `docker:dind`) and a runner `maximum_timeout` above the default hour; a multi-hop upgrade of a real instance exceeds that. Real-GitLab verification is done locally instead — see "Integration Testing Against a Disposable GitLab" under Testing.

It also could not cross GitLab 19.0, which is worth knowing independently of CI: 19.0 dropped bundled Mattermost and its reconfigure hard-aborts with `Removed configurations found in gitlab.rb. Aborting reconfigure` when a `mattermost` key is present. On a stock install it *is* present — 18.x auto-generates a mattermost section in `gitlab-secrets.json` (salts, `sql_at_rest_encrypt_key`) even when Mattermost is unused, and regenerates it on every reconfigure, so each intermediate 18.x hop re-adds it. Crossing 19.0 cleanly would require editing secrets automatically, which is unsafe for real Mattermost users. This is an upstream GitLab issue, not a tool bug; users hit it as actionable output from `print_stacktrace_errors`' "Removed configurations found" branch (covered by a bats test).

## Key Flags

`-y` auto-confirm (requires `DISCORD_URL` unless `CI=true`) | `--dry-run` compute path only | `--version=X[.Y[.Z]]` target version | `--skip-latest`/`--n-1` previous minor | `--no-step-limit` (CI only) | `--skip-lfs` skip LFS in backup | `--skip-object-storage` skip every resource offloaded to object storage (detected via `gitlab-rails runner` reading `Gitlab.config.<type>.object_store` — both `enabled` *and* a non-empty `remote_directory`; merges into the same `SKIP=` list as `--skip-lfs`. See Object Storage Detection below) | `--no-maintenance-mode` do not enable maintenance mode for the run (see Maintenance Mode below) | `--edition=ce|ee` | `--reset-stuck-finalizing` auto-reset status=5 zombies | `--max-tier=core|starter|premium|ultimate` what's-new URL tier | `--target-url` health check URL | `--discord-url` webhook

Env-only: `UPGRADE_GITLAB_CONFIG_HOOK=PATH` runs an executable after gitlab.rb/secrets.json copies are made and pruned. If unset, an executable `upload-config.hook` next to the script is auto-detected. Hook receives `UPGRADE_GITLAB_SCRIPT_DIR` so it can locate sibling files (rclone.conf, etc.). Template at `upload-config.hook.example`.

`UPGRADE_GITLAB_LOG_DRIVER=NAME` forces the log driver of the recreated container (see Container Log Driver below).
