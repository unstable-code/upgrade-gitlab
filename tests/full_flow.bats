#!/usr/bin/env bats

setup() {
    load test_helper
    export COLUMNS=120
    setup_mock_state
}

teardown() {
    teardown_mock_state
}

# ---------- Test 1: 1-step upgrade ----------
@test "full-flow: 1-step upgrade succeeds" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"Successfully updated"* ]]
}

# ---------- Test 2: Multi-step upgrade ----------
@test "full-flow: multi-step upgrade with --no-step-limit succeeds" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export CI=true
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --no-step-limit --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"Successfully updated"* ]]
    [[ "$output" == *"ROUTING COUNT: 6"* ]]
}

# ---------- Test 3: Already up-to-date ----------
@test "full-flow: already up-to-date shows satisfied message" {
    export MOCK_GITLAB_VERSION="18.0.1-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"Requirements already satisfied"* ]]
}

# ---------- Test 4: Step limit enforced ----------
@test "full-flow: step limit enforced with >= 3 steps" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export CI=true
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 1 ]
    [[ "$output" == *"Too many steps"* ]]
}

# ---------- Test 5: Edition switch CE → EE ----------
@test "full-flow: edition switch CE to EE succeeds" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export CI=true
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --no-step-limit --edition=ee --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"Successfully updated"* ]]
    [[ "$output" == *"Edition switch"* ]]
}

# ---------- Test 6: 2-step upgrade ----------
@test "full-flow: 2-step upgrade succeeds within step limit" {
    export MOCK_GITLAB_VERSION="17.7.4-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"Successfully updated"* ]]
}

# ---------- Test 7: Missing TARGET_URL ----------
@test "full-flow: missing TARGET_URL errors in unattended mode" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    unset TARGET_URL
    unset CI
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"TARGET_URL is required"* ]]
}

# ---------- Test 7b: Missing DISCORD_URL ----------
@test "full-flow: missing DISCORD_URL errors in unattended mode outside CI" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    unset CI
    unset DISCORD_URL
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 1 ]
    [[ "$output" == *"DISCORD_URL is required"* ]]
}

# ---------- Test 8: Backup messages ----------
@test "full-flow: upgrade shows backup creation messages" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"Creating backups"* ]]
}

# ---------- Test 9: EE upgrade ----------
@test "full-flow: EE 2-step upgrade succeeds" {
    export MOCK_GITLAB_VERSION="17.7.4-ee.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"Successfully updated"* ]]
}

# ---------- Test 10: Runner pause/resume ----------
@test "full-flow: runners are paused and resumed during upgrade" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_RUNNER_COUNT=2
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"Resumed previously paused runners"* ]]
}

# ---------- Test 11: Backup with progress bar ----------
@test "full-flow: backup uses progress bar when stats available" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_PROJECT_COUNT=5
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"Creating backups"* ]]
    [[ "$output" == *"Successfully updated"* ]]
    # Verify repositories stage output is present
    [[ "$output" == *"Dumping repositories"* ]]
}

# ---------- Test 12: Backup fallback on psql failure ----------
@test "full-flow: backup falls back to bouncing bar when psql fails" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_PSQL_STATS_FAIL=1
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"Creating backups"* ]]
    [[ "$output" == *"Successfully updated"* ]]
}

# ---------- Test 13: Stuck failed(4) migration is fatal ----------
@test "full-flow: status=4 (failed) migration triggers FATAL exit" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    # id|job|table|column|jargs|status|age_sec  (1209600 sec = 14 days)
    export MOCK_STUCK_MIGRATIONS="42|FailingMigration|some_table|id|[]|4|1209600"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL ERROR! MANUAL INTERVENTION REQUIRED"* ]]
    [[ "$output" == *"failed(4)"* ]]
    [[ "$output" == *"id=42"* ]]
    [[ "$output" == *"FailingMigration"* ]]
    [[ "$output" == *"split_and_retry"* ]]
}

# ---------- Test 14: Stuck finalizing(5) in -y mode is fatal ----------
@test "full-flow: status=5 (finalizing) stuck triggers FATAL exit in -y mode" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_STUCK_MIGRATIONS="12|BackfillShardingKeyAndCleanLabelLinksTable|label_links|id|[]|5|1209600"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL ERROR! MANUAL INTERVENTION REQUIRED"* ]]
    [[ "$output" == *"finalizing(5)"* ]]
    [[ "$output" == *"id=12"* ]]
    [[ "$output" == *"--reset-stuck-finalizing"* ]]
}

# ---------- Test 15: --reset-stuck-finalizing auto-resets and proceeds ----------
@test "full-flow: --reset-stuck-finalizing auto-resets status=5 and proceeds" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_STUCK_MIGRATIONS="12|BackfillShardingKeyAndCleanLabelLinksTable|label_links|id|[]|5|1209600"
    # After auto-reset, the next stuck poll should return empty.
    export MOCK_STUCK_RESOLVE_AFTER=1
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --reset-stuck-finalizing --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"Auto-resetting stuck finalizing(5)"* ]]
    [[ "$output" == *"reset to active(1)"* ]]
    [[ "$output" == *"Successfully updated"* ]]
}

# ---------- Test 16: status=1 (active) stale -> warning only, proceeds ----------
@test "full-flow: status=1 (active) stale only warns and proceeds" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_STUCK_MIGRATIONS="7|SlowActiveMigration|t|c|[]|1|1209600"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"appears stale but is not finalized"* ]]
    [[ "$output" == *"id=7"* ]]
    [[ "$output" == *"Successfully updated"* ]]
}

# ---------- Test 17: failed(4) is fatal even with --reset-stuck-finalizing ----------
@test "full-flow: --reset-stuck-finalizing does not bypass failed(4)" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_STUCK_MIGRATIONS="42|FailingMigration|t|c|[]|4|1209600"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --reset-stuck-finalizing --target-url=http://mock
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL ERROR! MANUAL INTERVENTION REQUIRED"* ]]
    [[ "$output" == *"failed(4)"* ]]
}

# ---------- Test 18: post-config-backup hook receives expected env ----------
@test "full-flow: post-config-backup hook is invoked with expected env vars" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    HOOK_DIR=$(mktemp -d)
    HOOK_OUT="$HOOK_DIR/captured.env"
    cat > "$HOOK_DIR/hook.sh" <<HOOK
#!/usr/bin/env bash
{
    echo "version=\$UPGRADE_GITLAB_VERSION"
    echo "container=\$UPGRADE_GITLAB_CONTAINER"
    echo "backup_dir=\$UPGRADE_GITLAB_BACKUP_DIR"
} > "$HOOK_OUT"
HOOK
    chmod +x "$HOOK_DIR/hook.sh"
    export UPGRADE_GITLAB_CONFIG_HOOK="$HOOK_DIR/hook.sh"

    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"Running post-config-backup hook"* ]]
    [ -f "$HOOK_OUT" ]
    grep -q "^version=17.11.3-ce.0" "$HOOK_OUT"
    grep -q "^container=gitlab" "$HOOK_OUT"
    # Hook receives the container-side BACKUP_DIR (use `docker cp` from there).
    grep -q "^backup_dir=/var/opt/gitlab/backups$" "$HOOK_OUT"

    rm -rf "$HOOK_DIR"
    unset UPGRADE_GITLAB_CONFIG_HOOK
}

# ---------- Test 19: post-config-backup hook failure is non-fatal ----------
@test "full-flow: post-config-backup hook failure logs warning but continues" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    HOOK_DIR=$(mktemp -d)
    cat > "$HOOK_DIR/hook.sh" <<'HOOK'
#!/usr/bin/env bash
exit 13
HOOK
    chmod +x "$HOOK_DIR/hook.sh"
    export UPGRADE_GITLAB_CONFIG_HOOK="$HOOK_DIR/hook.sh"

    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"hook exited non-zero"* ]]
    [[ "$output" == *"Successfully updated"* ]]

    rm -rf "$HOOK_DIR"
    unset UPGRADE_GITLAB_CONFIG_HOOK
}

# ---------- Test 20: auto-discover upload-config.hook next to script ----------
@test "full-flow: auto-discovers upload-config.hook next to script" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"

    SCRIPT_DIR_TEST=$(mktemp -d)
    cp "$PROJECT_ROOT/upgrade-gitlab" "$SCRIPT_DIR_TEST/upgrade-gitlab"
    chmod +x "$SCRIPT_DIR_TEST/upgrade-gitlab"

    HOOK_OUT="$SCRIPT_DIR_TEST/captured.env"
    cat > "$SCRIPT_DIR_TEST/upload-config.hook" <<HOOK
#!/usr/bin/env bash
{
    echo "auto_hook_ran=yes"
    echo "script_dir=\$UPGRADE_GITLAB_SCRIPT_DIR"
} > "$HOOK_OUT"
HOOK
    chmod +x "$SCRIPT_DIR_TEST/upload-config.hook"

    unset UPGRADE_GITLAB_CONFIG_HOOK
    run bash "$SCRIPT_DIR_TEST/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"Auto-detected post-config-backup hook"* ]]
    [ -f "$HOOK_OUT" ]
    grep -q "^auto_hook_ran=yes" "$HOOK_OUT"
    grep -q "^script_dir=$SCRIPT_DIR_TEST$" "$HOOK_OUT"

    rm -rf "$SCRIPT_DIR_TEST"
}

# ---------- Test 21: warn when upload-config.hook exists but not executable ----------
@test "full-flow: warns when sibling upload-config.hook is non-executable" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"

    SCRIPT_DIR_TEST=$(mktemp -d)
    cp "$PROJECT_ROOT/upgrade-gitlab" "$SCRIPT_DIR_TEST/upgrade-gitlab"
    chmod +x "$SCRIPT_DIR_TEST/upgrade-gitlab"
    echo "#!/bin/bash" > "$SCRIPT_DIR_TEST/upload-config.hook"
    # intentionally NOT chmod +x

    unset UPGRADE_GITLAB_CONFIG_HOOK
    run bash "$SCRIPT_DIR_TEST/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"exists but is not executable"* ]]
    [[ "$output" == *"Successfully updated"* ]]

    rm -rf "$SCRIPT_DIR_TEST"
}

# ---------- Test 22: background-migration check skipped only when table truly absent ----------
@test "full-flow: skips background migration check when table is genuinely absent (old version)" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_BBM_TABLE=missing
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 0 ]
    # Accurate "table not present (GitLab < 13.10)" wording, NOT the old generic one
    [[ "$output" == *"table not present (GitLab < 13.10)"* ]]
    [[ "$output" != *"table not available in this version"* ]]
    [[ "$output" == *"Successfully updated"* ]]
}

# ---------- Test 23: genuine secrets failure (findings, exit 0) is detected via row count ----------
@test "full-flow: real doctor:secrets findings are detected from row count, not exit code" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_SECRETS=bad
    # Rake exits 0 but reports "Total: 2 row(s) affected"; pre-upgrade check aborts in -y mode.
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -ne 0 ]
    [[ "$output" == *"found 2 undecryptable row(s) (pre-upgrade)"* ]]
    # The captured rake output is now shown (was hidden behind "review manually" before)
    [[ "$output" == *"Total: 2 row(s) affected"* ]]
    [[ "$output" == *"Aborted due to secrets integrity check failure"* ]]
}

# ---------- Test 24: transient post-restart secrets failure recovers via retry ----------
@test "full-flow: incomplete doctor:secrets run retries until services are ready" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    # First 2 invocations fail WITHOUT 'Done!' (restart window), then succeed.
    export MOCK_SECRETS=ok
    export MOCK_SECRETS_CRASH_BEFORE=2
    export _SECRETS_RETRY_SLEEP=0
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"retrying in 0s"* ]]
    [[ "$output" == *"Successfully updated"* ]]
    # Must NOT have given up with a false failure
    [[ "$output" != *"Secrets integrity check failed"* ]]
}

# ---------- Test 25: transient db:migrate:status failure recovers via retry ----------
@test "full-flow: incomplete db:migrate:status retries until the status table appears" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    # First 2 status reads return no up/down table (restart window), then recover.
    export MOCK_MIGRATE_STATUS_CRASH_BEFORE=2
    export _MIGRATE_STATUS_RETRY_SLEEP=0
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"Migration status not available yet"* ]]
    [[ "$output" == *"Successfully updated"* ]]
    # Empty output must NOT be silently treated as a clean "0 down" result
    [[ "$output" != *"could not read migration status after"* ]]
}

# ---------- Test 26: transient gitlab-ctl status flap does not skip reconfigure block ----------
@test "full-flow: gitlab-ctl status gate retries instead of skipping reconfigure/migrate" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    # status fails twice (services still starting), then comes up.
    export MOCK_CTL_STATUS_CRASH_BEFORE=2
    export _HEALTH_STATUS_RETRY_SLEEP=0
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"gitlab-ctl status not ready yet"* ]]
    [[ "$output" == *"Successfully updated"* ]]
}

# ---------- Test 27: failed runner-count query is handled gracefully ----------
@test "full-flow: runner table query failure warns and skips pause without crashing" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_RUNNER_QUERY_FAIL=1
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not query the runner table"* ]]
    [[ "$output" == *"Successfully updated"* ]]
    # An empty count must not have triggered a bash "integer expression expected" error
    [[ "$output" != *"integer expression expected"* ]]
}

# ---------- Test 28: missing backup_path falls back to GitLab default ----------
@test "full-flow: empty backup_path parse falls back to the GitLab default dir" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_NO_BACKUP_PATH=1
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"using GitLab default /var/opt/gitlab/backups"* ]]
    [[ "$output" == *"Successfully updated"* ]]
}

# ---------- Test 29: reconfigure abort on removed config keys gives accurate guidance ----------
@test "full-flow: 'Removed configurations found' yields remove-keys guidance, not restore-backup" {
    # Already at latest + abnormal previous exit → recovery path runs check_gitlab_server_healthy.
    export MOCK_GITLAB_VERSION="18.0.1-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_EXIT_CODE=1                  # _prev_exit != 0 → recovery branch
    export MOCK_CTL_STATUS_CRASH_BEFORE=99   # gitlab-ctl status never recovers → print_stacktrace_errors
    export _HEALTH_STATUS_RETRY_SLEEP=0
    export MOCK_LOGS="WARN: mattermost has been deprecated since 19.0 and was removed in 19.0.
Removed configurations found in gitlab.rb. Aborting reconfigure."
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -ne 0 ]
    # Accurate guidance: the stock-install trigger lives in gitlab-secrets.json, not gitlab.rb
    [[ "$output" == *"gitlab-secrets.json"* ]]
    [[ "$output" == *"mattermost"* ]]
    # Must NOT give the misleading restore-backup advice for this failure mode
    [[ "$output" != *"restore previous backup"* ]]
}

# ---------- Test 30: recovery resumes runners from the persistent state file ----------
@test "full-flow: recovery path resumes runners recorded in the persistent state file" {
    # Already at latest + abnormal previous exit → recovery branch (no fresh backup).
    # Simulates a prior run that paused runners then aborted before the end-of-upgrade resume.
    export MOCK_GITLAB_VERSION="18.0.1-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_EXIT_CODE=137                    # _prev_exit != 0 → recovery branch
    export XDG_RUNTIME_DIR=$(mktemp -d)         # state-dir override (runtime dir is preferred)
    sf="$XDG_RUNTIME_DIR/upgrade-gitlab-gitlab.paused-runners"
    printf '3\n7\n' > "$sf"

    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"Resuming post-upgrade checks"* ]]
    [[ "$output" == *"Resumed previously paused runners: 3,7"* ]]
    [ ! -f "$sf" ]                              # state file consumed after resume

    rm -rf "$XDG_RUNTIME_DIR"
}

# ---------- Test 31: recovery without a state file is an idempotent no-op ----------
@test "full-flow: recovery path without a state file does not resume any runner" {
    export MOCK_GITLAB_VERSION="18.0.1-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_EXIT_CODE=137
    export XDG_RUNTIME_DIR=$(mktemp -d)         # empty: no leftover state file

    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"Resuming post-upgrade checks"* ]]
    # No file → must not touch runners we never paused (e.g. admin-paused ones).
    [[ "$output" != *"Resumed previously paused runners"* ]]

    rm -rf "$XDG_RUNTIME_DIR"
}

# ---------- Test 31b: recovery starts a stopped container before version detection ----------
@test "full-flow: recovery starts a stopped container without a poll_with_bouncing_bar ordering error" {
    # Regression: the container-start + wait_for_healthy block once ran as top-level
    # code positioned BEFORE the bouncing-bar/poll helper definitions, so a stopped
    # container (crash-recovery) hit "poll_with_bouncing_bar: command not found" and
    # skipped the health wait. The always-running mock never took the docker-start
    # branch, so CI missed it — hence this test forces a stopped container on entry.
    export MOCK_GITLAB_VERSION="18.0.1-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_EXIT_CODE=1                  # _prev_exit != 0 → recovery branch
    touch "$MOCK_STATE_DIR/stopped"          # container exited → absent from `docker ps`

    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 0 ]
    # The stopped-container branch was actually taken (early "GitLab server" health wait ran)...
    [[ "$output" == *"waiting until GitLab server container is ready"* ]]
    # ...without the function-ordering bug...
    [[ "$output" != *"poll_with_bouncing_bar"* ]]
    [[ "$output" != *"command not found"* ]]
    # ...and recovery reported success rather than a bare alarming WARNING.
    [[ "$output" == *"Recovery completed successfully"* ]]
}

# ---------- Test 32: pause merges leftover IDs with newly paused runners (union) ----------
@test "full-flow: pause merges leftover paused-runner IDs and resumes the union" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"   # 1-step upgrade
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_RUNNER_COUNT=2                   # SELECT id ... active=true → 1,2
    export XDG_RUNTIME_DIR=$(mktemp -d)
    sf="$XDG_RUNTIME_DIR/upgrade-gitlab-gitlab.paused-runners"
    printf '9\n' > "$sf"                         # leftover from a prior aborted run

    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 0 ]
    # union {9} ∪ {1,2}, sorted-unique = 1,2,9 → proves the file is merged AND used as source of truth
    # (the in-memory fallback alone would yield only 1,2).
    [[ "$output" == *"Resumed previously paused runners: 1,2,9"* ]]
    [ ! -f "$sf" ]

    rm -rf "$XDG_RUNTIME_DIR"
}
