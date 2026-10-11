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
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"Successfully updated"* ]]
}

# ---------- Test 2: Multi-step upgrade ----------
@test "full-flow: multi-step upgrade with --no-step-limit succeeds" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export CI=true
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --no-step-limit
    [ "$status" -eq 0 ]
    [[ "$output" == *"Successfully updated"* ]]
    [[ "$output" == *"ROUTING COUNT: 6"* ]]
}

# ---------- Test 3: Already up-to-date ----------
@test "full-flow: already up-to-date shows satisfied message" {
    export MOCK_GITLAB_VERSION="18.0.1-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"Requirements already satisfied"* ]]
}

# ---------- Test 4: Step limit enforced ----------
@test "full-flow: step limit enforced with >= 3 steps" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export CI=true
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"Too many steps"* ]]
}

# ---------- Test 5: Edition switch CE → EE ----------
@test "full-flow: edition switch CE to EE succeeds" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export CI=true
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --no-step-limit --edition=ee
    [ "$status" -eq 0 ]
    [[ "$output" == *"Successfully updated"* ]]
    [[ "$output" == *"Edition switch"* ]]
}

# ---------- Test 5b: edition switch with no version hop (#21) ----------
@test "full-flow: an edition switch alone reports the switch and exits 0" {
    # A switch-only run still reports the whole route from the starting version.
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export CI=true
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --no-step-limit --edition=ee --version=17.11.3
    [ "$status" -eq 0 ]
    [[ "$output" != *"bad array subscript"* ]]
    [[ "$output" == *"Successfully updated GitLab server from 17.11.3-ce.0 to 17.11.3-ee.0"* ]]
    [[ "$output" == *"Updated traceroute: 17.11.3-ee.0"* ]]
    [ "$(wc -l < "$MOCK_STATE_DIR/api_create")" -eq 1 ]
}

# ---------- Test 5c: the switch is the first hop of the loop (#27) ----------
@test "full-flow: the edition switch hop removes the old edition's image, later hops the new one's" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export CI=true
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --no-step-limit --edition=ee
    [ "$status" -eq 0 ]
    [[ "$output" == *"Switching edition at current version: 17.11.3-ce.0 -> 17.11.3-ee.0 (1/"* ]]
    [ "$(wc -l < "$MOCK_STATE_DIR/image_rm_args")" -ge 2 ]
    [ "$(sed -n 1p "$MOCK_STATE_DIR/image_rm_args")" = "gitlab/gitlab-ce:17.11.3-ce.0" ]
    [ "$(sed -n 2p "$MOCK_STATE_DIR/image_rm_args")" = "gitlab/gitlab-ee:17.11.3-ee.0" ]
    # The report covers the whole route from the starting version, switch included.
    [[ "$output" == *"Successfully updated GitLab server from 17.11.3-ce.0 to "* ]]
    [[ "$output" == *"Updated traceroute: 17.11.3-ee.0 "* ]]
}

@test "full-flow: an interrupt during the edition switch stops after it and reports the switch tag" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export CI=true
    bash "$PROJECT_ROOT/upgrade-gitlab" -y --no-step-limit --edition=ee > "$MOCK_STATE_DIR/out.log" 2>&1 &
    pid=$!
    wait_for_marker "$MOCK_STATE_DIR/api_create"
    kill -TERM "$pid"   # SIGINT is ignored by background jobs; _handle_signal traps both
    status=0
    wait "$pid" || status=$?
    [ "$status" -eq 130 ]
    [ "$(wc -l < "$MOCK_STATE_DIR/api_create")" -eq 1 ]
    [ "$(cat "$MOCK_STATE_DIR/current_version")" = "17.11.3-ee.0" ]
    grep -q "gitlab is running 17.11.3-ee.0\.$" "$MOCK_STATE_DIR/out.log"
}

# ---------- Test 6: 2-step upgrade ----------
@test "full-flow: 2-step upgrade succeeds within step limit" {
    export MOCK_GITLAB_VERSION="17.7.4-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"Successfully updated"* ]]
}

# ---------- Test 7b: Missing DISCORD_URL ----------
@test "full-flow: missing DISCORD_URL errors in unattended mode outside CI" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    unset CI
    unset DISCORD_URL
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"DISCORD_URL is required"* ]]
}

# ---------- Test 8: Backup messages ----------
@test "full-flow: upgrade shows backup creation messages" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"Creating backups"* ]]
}

# ---------- Test 9: EE upgrade ----------
@test "full-flow: EE 2-step upgrade succeeds" {
    export MOCK_GITLAB_VERSION="17.7.4-ee.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"Successfully updated"* ]]
}

# ---------- Test 10: Runner pause/resume ----------
@test "full-flow: runners are paused and resumed during upgrade" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_RUNNER_COUNT=2
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"Resumed previously paused runners"* ]]
}

# ---------- Test 11: Backup with progress bar ----------
@test "full-flow: backup uses progress bar when stats available" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_PROJECT_COUNT=5
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
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
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"Creating backups"* ]]
    [[ "$output" == *"Successfully updated"* ]]
}

# ---------- --skip-object-storage: detected resources become SKIP= ----------
@test "full-flow: --skip-object-storage passes detected resources as SKIP" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_OBJECT_STORAGE="lfs artifacts packages"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --skip-object-storage
    [ "$status" -eq 0 ]
    [[ "$output" == *"will be skipped during backup"* ]]
    # detected components reach gitlab-backup as a single SKIP= env, in detection order
    grep -q "SKIP=lfs,artifacts,packages" "$MOCK_STATE_DIR/backup_args"
}

# ---------- --skip-object-storage merges with --skip-lfs without duplicating ----------
@test "full-flow: --skip-object-storage merges with --skip-lfs without duplicating lfs" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_OBJECT_STORAGE="lfs uploads"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --skip-lfs --skip-object-storage
    [ "$status" -eq 0 ]
    # --skip-lfs seeds lfs; detection adds uploads but must not re-add lfs
    grep -q "SKIP=lfs,uploads" "$MOCK_STATE_DIR/backup_args"
    ! grep -qE "lfs,lfs|lfs,uploads,lfs" "$MOCK_STATE_DIR/backup_args"
}

# ---------- reconfigure deprecations are summarized at the end of the run ----------
@test "full-flow: reconfigure deprecations are re-printed as an end-of-run summary" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_DEPRECATIONS="nginx['listen_port'] has been deprecated. Please use gitlab_rails['nginx']['listen_port'] instead."
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"Deprecations reported by gitlab-ctl reconfigure (1)"* ]]
    [[ "$output" == *"[17.11.3-ce.0] nginx['listen_port'] has been deprecated."* ]]
    # reconfigure runs once per hop and streams the same warning every time; the
    # summary must collapse those into a single entry.
    [ "$(grep -c "^  \[17.11.3-ce.0\] nginx" <<< "$output")" -eq 1 ]
}

@test "full-flow: no deprecation summary when reconfigure reports none" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    unset MOCK_DEPRECATIONS
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" != *"Deprecations reported by gitlab-ctl reconfigure"* ]]
}

# ---------- the boot reconfigure of each new container is collected too (#29) ----------
@test "full-flow: deprecations from the new container's boot are tagged with its version" {
    # The pre-swap reconfigure only sees the version running before each hop, so a warning that
    # only the new version prints used to be lost on the last hop.
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    unset MOCK_DEPRECATIONS
    export MOCK_BOOT_DEPRECATIONS="gitlab_exporter['server_name'] is deprecated and has no effect."
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    first=$(sed -n 's/^Updated traceroute: \([^ ]*\).*/\1/p' <<< "$output")
    [ -n "$first" ]
    [[ "$output" == *"Deprecations reported by gitlab-ctl reconfigure (1)"* ]]
    [[ "$output" == *"[$first] gitlab_exporter['server_name'] is deprecated"* ]]
}

@test "full-flow: the recovery path collects the deprecations of the running boot" {
    # Recovery never runs a reconfigure of its own, so it used to report nothing.
    export MOCK_GITLAB_VERSION="18.0.1-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_EXIT_CODE=137                    # _prev_exit != 0 → recovery branch
    export MOCK_BOOT_DEPRECATIONS="gitlab_exporter['server_name'] is deprecated and has no effect."
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"Resuming post-upgrade checks"* ]]
    [[ "$output" == *"[18.0.1-ce.0] gitlab_exporter['server_name'] is deprecated"* ]]
}

# ---------- --skip-object-storage: agent_plan_content survives the whitelist ----------
@test "full-flow: --skip-object-storage skips agent_plan_content" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    # agent_plan_content is both a gitlab-backup target and an object storage type,
    # so detection must let it through to SKIP= instead of dropping it.
    export MOCK_OBJECT_STORAGE="artifacts agent_plan_content"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --skip-object-storage
    [ "$status" -eq 0 ]
    grep -q "SKIP=artifacts,agent_plan_content" "$MOCK_STATE_DIR/backup_args"
}

# ---------- --skip-object-storage: non-backup-target types never reach SKIP= ----------
@test "full-flow: --skip-object-storage drops types that are not backup targets" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    # dependency_proxy uses object storage but has no lib/backup/tasks/ entry, so
    # SKIP=dependency_proxy would be meaningless; the whitelist must filter it out.
    export MOCK_OBJECT_STORAGE="dependency_proxy lfs"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --skip-object-storage
    [ "$status" -eq 0 ]
    grep -q "SKIP=lfs" "$MOCK_STATE_DIR/backup_args"
    ! grep -q "dependency_proxy" "$MOCK_STATE_DIR/backup_args"
}

# ---------- no skip flags: backup receives no SKIP= ----------
@test "full-flow: backup passes no SKIP when no skip flags are given" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    ! grep -q "SKIP=" "$MOCK_STATE_DIR/backup_args"
}

# ---------- Test 12b: "Creating backup archive" is a determinate stage ----------
# MOCK_PACK_SLEEP holds the mock inside the pack stage so the polling loop samples
# it; the bar itself renders to _tty (/dev/null under bats), so what this asserts is
# that the tar-size/staging-total math runs to completion without erroring.
@test "full-flow: backup archive stage computes progress from tar vs staging total" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_PACK_SLEEP=1
    export MOCK_PACK_TOTAL=1000000
    export MOCK_BACKUP_TAR_SIZE=500000
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"Creating backup archive"* ]]
    [[ "$output" == *"Successfully updated"* ]]
}

# ---------- Test 12c: pack progress degrades to bouncing bar when du fails ----------
@test "full-flow: backup archive stage survives a failed staging-total probe" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_PACK_SLEEP=1
    export MOCK_PACK_TOTAL_FAIL=1
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"Creating backup archive"* ]]
    [[ "$output" == *"Successfully updated"* ]]
}

# ---------- Test 12d: LFS denominator comes from the deduplicated on-disk total ----------
@test "full-flow: lfs progress denominator queries lfs_objects, not project_statistics" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [ -f "$MOCK_STATE_DIR/lfs_disk_query" ]
    [[ "$output" == *"Successfully updated"* ]]
}

# ---------- Test 12e: LFS denominator falls back when lfs_objects is unqueryable ----------
@test "full-flow: lfs denominator falls back to project_statistics on query failure" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_LFS_DISK_FAIL=1
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [ -f "$MOCK_STATE_DIR/lfs_disk_query" ]
    [[ "$output" == *"Dumping lfs objects"* ]]
    [[ "$output" == *"Successfully updated"* ]]
}

# ---------- Test 13: Stuck failed(4) migration is fatal ----------
@test "full-flow: status=4 (failed) migration triggers FATAL exit" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    # id|job|table|column|jargs|status|age_sec  (1209600 sec = 14 days)
    export MOCK_STUCK_MIGRATIONS="42|FailingMigration|some_table|id|[]|4|1209600"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
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
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
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
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --reset-stuck-finalizing
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
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
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
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --reset-stuck-finalizing
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
    echo "config_archive=\$UPGRADE_GITLAB_CONFIG_ARCHIVE"
} > "$HOOK_OUT"
HOOK
    chmod +x "$HOOK_DIR/hook.sh"
    export UPGRADE_GITLAB_CONFIG_HOOK="$HOOK_DIR/hook.sh"

    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"Running post-config-backup hook"* ]]
    [ -f "$HOOK_OUT" ]
    grep -q "^version=17.11.3-ce.0" "$HOOK_OUT"
    grep -q "^container=gitlab" "$HOOK_OUT"
    # Hook receives the container-side BACKUP_DIR (use `docker cp` from there).
    grep -q "^backup_dir=/var/opt/gitlab/backups$" "$HOOK_OUT"
    # ...and the container-side path of the whole /etc/gitlab archive (#26).
    grep -qx "config_archive=/etc/gitlab/config_backup/gitlab_config_1700000000_2026_01_01.tar" "$HOOK_OUT"

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

    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
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
    run bash "$SCRIPT_DIR_TEST/upgrade-gitlab" -y
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
    run bash "$SCRIPT_DIR_TEST/upgrade-gitlab" -y
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
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
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
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
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
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
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
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
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
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"gitlab-ctl status not ready yet"* ]]
    [[ "$output" == *"Successfully updated"* ]]
}

# ---------- Test 27: failed runner-count query is handled gracefully ----------
@test "full-flow: runner table query failure warns and skips pause without crashing" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_RUNNER_QUERY_FAIL=1
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
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
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
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
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
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
    sf="$RUNNER_STATE_FILE"                       # persistent-first state path (see test_helper)
    mkdir -p "$(dirname "$sf")"
    printf '3\n7\n' > "$sf"

    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"Resuming post-upgrade checks"* ]]
    [[ "$output" == *"Resumed previously paused runners: 3,7"* ]]
    [ ! -f "$sf" ]                              # state file consumed after resume
}

# ---------- Test 31: recovery without a state file is an idempotent no-op ----------
@test "full-flow: recovery path without a state file does not resume any runner" {
    export MOCK_GITLAB_VERSION="18.0.1-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_EXIT_CODE=137
    # No state file is seeded → RUNNER_STATE_FILE does not exist (empty leftover case).

    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"Resuming post-upgrade checks"* ]]
    # No file → must not touch runners we never paused (e.g. admin-paused ones).
    [[ "$output" != *"Resumed previously paused runners"* ]]
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

    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    # The stopped-container branch was actually taken (early "GitLab server" health wait ran)...
    [[ "$output" == *"waiting until GitLab server is ready"* ]]
    # ...without the function-ordering bug...
    [[ "$output" != *"poll_with_bouncing_bar"* ]]
    [[ "$output" != *"command not found"* ]]
    # ...and recovery reported success rather than a bare alarming WARNING.
    [[ "$output" == *"Recovery completed successfully"* ]]
}

# ---------- Test 31c: SIGINT during backup (pre-critical zone) resumes paused runners ----------
@test "full-flow: SIGINT during backup (pre-critical zone) resumes the runners it paused" {
    # #10 follow-up: runners are paused BEFORE the backup, and the backup runs BEFORE
    # enter_critical. A Ctrl+C during backup must not strand the paused runners — the
    # non-critical signal handler resumes them before exiting.
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"   # a real 1-step upgrade → pauses + backs up
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_RUNNER_COUNT=2                    # active runners 1,2 get paused
    export MOCK_PSQL_STATS_FAIL=1                 # route to the simple (bouncing-bar) backup branch
    export MOCK_BACKUP_SLEEP=5                    # hold inside backup so we can signal mid-backup
    sf="$RUNNER_STATE_FILE"                        # persistent-first state path (see test_helper)

    bash "$PROJECT_ROOT/upgrade-gitlab" -y > "$MOCK_STATE_DIR/out.log" 2>&1 &
    pid=$!
    # wait deterministically until the backup has started (runners are already paused by now)
    wait_for_marker "$MOCK_STATE_DIR/backup_started"   # sanity: execution reached the backup
    [ -f "$sf" ]                                  # sanity: runners were paused (state file written)

    # Use SIGTERM, not SIGINT: a non-interactive shell sets background jobs to ignore
    # SIGINT, so kill -INT on a backgrounded script is unreliable here. The real-world
    # trigger is a foreground Ctrl+C (SIGINT), but _handle_signal is the shared trap for
    # SIGINT/SIGTERM/SIGTSTP/SIGHUP, so SIGTERM exercises the exact same non-critical path.
    kill -TERM "$pid"
    status=0
    wait "$pid" || status=$?                                       # don't let bats errexit abort on the non-zero exit

    [ "$status" -eq 130 ]                                          # signal-interrupted exit
    grep -q "Resumed previously paused runners: 1,2" "$MOCK_STATE_DIR/out.log"
    ! grep -q "Entering critical section" "$MOCK_STATE_DIR/out.log"  # stopped in backup, before the upgrade
    [ ! -f "$sf" ]                                                 # state file consumed by resume
}

# ---------- #17: CI jobs still running when the upgrade starts ----------
@test "full-flow: running CI jobs are waited for (default) before the backup" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_RUNNER_COUNT=2
    export MOCK_RUNNING_JOBS=2
    export MOCK_RUNNING_JOBS_FINISH_AFTER=3      # notice, post-pause recount, one wait poll
    export _RUNNING_JOBS_POLL=0
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 CI job(s) are running right now (--running-jobs=wait"* ]]
    [[ "$output" == *"group/app"* ]]                                   # the job list is shown
    [[ "$output" == *"Running CI jobs: [2 running]"* ]]
    [[ "$output" == *"Running CI jobs: all finished"* ]]
    [[ "$output" == *"Successfully updated"* ]]
    # waiting must end before the backup — and so before maintenance mode is enabled
    done_line=$(grep -n "Running CI jobs: all finished" <<< "$output" | cut -d: -f1)
    backup_line=$(grep -n "Creating backups" <<< "$output" | cut -d: -f1)
    [ "$done_line" -lt "$backup_line" ]
}

@test "full-flow: --running-jobs-timeout aborts the upgrade and resumes the runners" {
    export MOCK_GITLAB_VERSION="17.11.3-ee.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_RUNNER_COUNT=2
    export MOCK_RUNNING_JOBS=1                    # never finishes
    export MOCK_MAINTENANCE=enabled
    export _RUNNING_JOBS_POLL=1
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --running-jobs-timeout=1
    [ "$status" -eq 1 ]
    [[ "$output" == *"Aborted: 1 CI job(s) still running (not finished within --running-jobs-timeout=1s)"* ]]
    [[ "$output" == *"Resumed previously paused runners: 1,2"* ]]
    [ ! -f "$MOCK_STATE_DIR/backup_args" ]        # never reached the backup
    [ ! -f "$MOCK_STATE_DIR/maintenance_probe" ]  # nor the maintenance-mode boot
}

@test "full-flow: --running-jobs=abort leaves running jobs alone and does not upgrade" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_RUNNER_COUNT=2
    export MOCK_RUNNING_JOBS=1
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --running-jobs=abort
    [ "$status" -eq 1 ]
    [[ "$output" == *"Aborted: 1 CI job(s) still running (--running-jobs=abort)"* ]]
    [[ "$output" != *"Running CI jobs: ["* ]]
    [[ "$output" == *"Resumed previously paused runners: 1,2"* ]]
    [ ! -f "$MOCK_STATE_DIR/backup_args" ]
    # counted twice (notice + post-pause recount) and never polled
    [ "$(cat "$MOCK_STATE_DIR/running_jobs_polls")" -eq 2 ]
}

@test "full-flow: jobs that finish before the runners are paused need no wait" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_RUNNING_JOBS=1
    export MOCK_RUNNING_JOBS_FINISH_AFTER=1       # only the notice sees it
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 CI job(s) are running right now"* ]]
    [[ "$output" != *"Running CI jobs: ["* ]]
    [[ "$output" == *"Successfully updated"* ]]
}

@test "full-flow: invalid --running-jobs values are rejected" {
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --running-jobs=cancel
    [ "$status" -eq 1 ]
    [[ "$output" == *"--running-jobs must be 'wait' or 'abort'"* ]]
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --running-jobs-timeout=30m
    [ "$status" -eq 1 ]
    [[ "$output" == *"--running-jobs-timeout must be a whole number of seconds"* ]]
}

# ---------- #16: cancelling the backup stops the one inside the container too ----------
@test "full-flow: SIGTERM during backup stops the in-container backup before releasing holds" {
    # The docker exec client dies with the script, but gitlab-backup inside the container
    # does not — it would keep dumping, uploading and pruning after the holds were
    # released. It must be stopped first, and the holds released only afterwards.
    export MOCK_GITLAB_VERSION="17.11.3-ee.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_RUNNER_COUNT=2
    export MOCK_MAINTENANCE=enabled
    export MOCK_PSQL_STATS_FAIL=1                 # simple (bouncing-bar) backup branch
    export MOCK_BACKUP_SLEEP=2                    # only needs to outlast the signal below

    bash "$PROJECT_ROOT/upgrade-gitlab" -y > "$MOCK_STATE_DIR/out.log" 2>&1 &
    pid=$!
    wait_for_marker "$MOCK_STATE_DIR/backup_started"
    kill -TERM "$pid"
    status=0
    wait "$pid" || status=$?

    [ "$status" -eq 130 ]
    [ -f "$MOCK_STATE_DIR/backup_term_sent" ]
    grep -q "Backup stopped." "$MOCK_STATE_DIR/out.log"
    # stop first, release second: a backup still running while holds are released
    # would dump the very writes maintenance mode and the runner pause kept out
    stop_line=$(grep -n "Stopping the backup still running" "$MOCK_STATE_DIR/out.log" | cut -d: -f1)
    resume_line=$(grep -n "Resumed previously paused runners: 1,2" "$MOCK_STATE_DIR/out.log" | cut -d: -f1)
    disable_line=$(grep -n "Maintenance mode disabled." "$MOCK_STATE_DIR/out.log" | cut -d: -f1)
    [ "$stop_line" -lt "$resume_line" ]
    [ "$stop_line" -lt "$disable_line" ]
}

@test "full-flow: a backup that ignores SIGTERM times out with guidance, holds still released" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_RUNNER_COUNT=2
    export MOCK_PSQL_STATS_FAIL=1
    export MOCK_BACKUP_SLEEP=3                    # still "running" when the stop is attempted
    export MOCK_BACKUP_IGNORES_TERM=1
    export _BACKUP_STOP_TIMEOUT=2

    bash "$PROJECT_ROOT/upgrade-gitlab" -y > "$MOCK_STATE_DIR/out.log" 2>&1 &
    pid=$!
    wait_for_marker "$MOCK_STATE_DIR/backup_started"
    kill -TERM "$pid"
    status=0
    wait "$pid" || status=$?

    [ "$status" -eq 130 ]
    grep -q "still running after 2s (PID 4242)" "$MOCK_STATE_DIR/out.log"
    grep -q "do not re-run this script until" "$MOCK_STATE_DIR/out.log"
    grep -q "Resumed previously paused runners: 1,2" "$MOCK_STATE_DIR/out.log"
}

@test "full-flow: a failed backup aborts the upgrade and releases holds" {
    # Previously the exit code was ignored and the run went on to swap the container —
    # an irreversible upgrade with no complete backup of the current version.
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_RUNNER_COUNT=2
    export MOCK_BACKUP_FAIL=1
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"backup failed (exit code 1)"* ]]
    [[ "$output" == *"not upgrading without a complete backup"* ]]
    [[ "$output" != *"Entering critical section"* ]]
    [[ "$output" == *"Resumed previously paused runners: 1,2"* ]]
    [ ! -f "$MOCK_STATE_DIR/api_create" ]        # the container was never recreated
    # the backup had already returned, so there is nothing inside the container to stop
    [ ! -f "$MOCK_STATE_DIR/backup_term_sent" ]
}

@test "full-flow: a failed /etc/gitlab archive aborts the upgrade and releases holds" {
    # Without gitlab-secrets.json and the keys in /etc/gitlab, the app backup cannot be restored (#26).
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_RUNNER_COUNT=2
    export MOCK_CONFIG_BACKUP_FAIL=1
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"configuration backup of /etc/gitlab failed"* ]]
    [[ "$output" == *"No space left on device"* ]]        # the command's own output is shown
    [[ "$output" != *"Entering critical section"* ]]
    [[ "$output" == *"Resumed previously paused runners: 1,2"* ]]
    [ ! -f "$MOCK_STATE_DIR/api_create" ]                # the container was never recreated
}

@test "full-flow: the container definition is appended to the /etc/gitlab archive" {
    # The recreate spec lives only in memory; losing the host loses GITLAB_OMNIBUS_CONFIG (#26 E).
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    def=/etc/gitlab/config_backup/upgrade-gitlab-container.json
    grep -q " gitlab:$def$" "$MOCK_STATE_DIR/cp_args"
    jq -e '.Config.Env' "$MOCK_STATE_DIR/cp_content" > /dev/null   # the inspect JSON itself
    grep -qx "$def" "$MOCK_STATE_DIR/config_append_args"
    [[ "$output" == *"Added to the archive: $def"* ]]
}

@test "full-flow: encrypted settings and global server hooks are appended to the archive" {
    # Both live under /var/opt/gitlab but outside the app backup (#26 B).
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_DATA_PATHS=$'/var/opt/gitlab/gitlab-rails/shared/encrypted_settings\n/var/opt/gitlab/gitaly/custom_hooks\n/var/opt/gitlab/gitaly/custom_hooks'   # reported twice
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    grep -qx /var/opt/gitlab/gitlab-rails/shared/encrypted_settings "$MOCK_STATE_DIR/config_append_args"
    [ "$(grep -cx /var/opt/gitlab/gitaly/custom_hooks "$MOCK_STATE_DIR/config_append_args")" -eq 1 ]
}

@test "full-flow: gitlab.rb paths that cannot be resolved are named before the backup" {
    # The archive cannot include them; saying so before the backup keeps it from passing as complete (#26 D).
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_CONFIG_WARNINGS=$'gitlab.rb:7\tnginx[\'ssl_certificate\'] = ENV[\'CERT_PATH\']'
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"these settings point to files the configuration archive cannot include"* ]]
    [[ "$output" == *"  gitlab.rb:7: nginx['ssl_certificate'] = ENV['CERT_PATH']"* ]]
    warned=$(grep -n "cannot include" <<< "$output" | cut -d: -f1)
    backup=$(grep -n "Creating backups" <<< "$output" | cut -d: -f1)
    [ "$warned" -lt "$backup" ]
}

@test "full-flow: a failed append to the archive only warns" {
    # /etc/gitlab is already archived; the files outside it are an addition.
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_CONFIG_APPEND_FAIL=1
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not add files outside /etc/gitlab to the archive"* ]]
    [[ "$output" == *"No space left on device"* ]]
    [[ "$output" == *"Successfully updated"* ]]
}

# ---------- Test 31d: non-signal abort before the critical zone resumes paused runners ----------
@test "full-flow: abort on pre-upgrade secrets failure resumes the paused runners (EXIT trap)" {
    # #10 follow-up, non-signal path: the pre-upgrade secrets check runs after the pause and
    # after the backup but before enter_critical. A failure there exits without reaching the
    # end-of-upgrade resume; the EXIT trap must release the runners it paused.
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_RUNNER_COUNT=2                    # active runners 1,2 get paused
    export MOCK_SECRETS=bad                       # pre-upgrade secrets integrity check fails
    sf="$RUNNER_STATE_FILE"                        # persistent-first state path (see test_helper)

    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 1 ]                                            # aborted on secrets failure
    [[ "$output" == *"secrets integrity check failure"* ]]
    [[ "$output" == *"Resumed previously paused runners: 1,2"* ]]  # EXIT trap caught the abort
    ! [[ "$output" == *"Entering critical section"* ]]             # aborted before the upgrade
    [ ! -f "$sf" ]                                                 # state file consumed by resume
}

# ---------- Test 32: pause merges leftover IDs with newly paused runners (union) ----------
@test "full-flow: pause merges leftover paused-runner IDs and resumes the union" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"   # 1-step upgrade
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_RUNNER_COUNT=2                   # SELECT id ... active=true → 1,2
    sf="$RUNNER_STATE_FILE"                       # persistent-first state path (see test_helper)
    mkdir -p "$(dirname "$sf")"
    printf '9\n' > "$sf"                         # leftover from a prior aborted run

    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    # union {9} ∪ {1,2}, sorted-unique = 1,2,9 → proves the file is merged AND used as source of truth
    # (the in-memory fallback alone would yield only 1,2).
    [[ "$output" == *"Resumed previously paused runners: 1,2,9"* ]]
    [ ! -f "$sf" ]
}

# ---------- maintenance mode (#15) ----------
@test "full-flow: maintenance mode is enabled before backup and disabled at the end" {
    export MOCK_GITLAB_VERSION="17.11.3-ee.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_MAINTENANCE=enabled
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"Maintenance mode enabled"* ]]
    [[ "$output" == *"Maintenance mode disabled."* ]]
    # enabled before the backup runs, not somewhere later in the run
    enable_line=$(grep -n "Maintenance mode enabled" <<< "$output" | cut -d: -f1)
    backup_line=$(grep -n "Dumping repositories" <<< "$output" | head -n1 | cut -d: -f1)
    [ "$enable_line" -lt "$backup_line" ]
    [ -f "$MOCK_STATE_DIR/maintenance_disabled" ]
    [ ! -f "$MAINTENANCE_STATE_FILE" ]
}

@test "full-flow: maintenance mode that was already on is left on" {
    export MOCK_GITLAB_VERSION="17.11.3-ee.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_MAINTENANCE=already
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"Maintenance mode is already enabled."* ]]
    [ ! -f "$MOCK_STATE_DIR/maintenance_disabled" ]
}

@test "full-flow: unavailable maintenance mode does not block the upgrade" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_MAINTENANCE=unavailable
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"Maintenance mode is not available"* ]]
    [[ "$output" == *"Successfully updated"* ]]
    [ ! -f "$MOCK_STATE_DIR/maintenance_disabled" ]
}

@test "full-flow: rails failure while enabling maintenance mode warns and continues" {
    export MOCK_GITLAB_VERSION="17.11.3-ee.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_MAINTENANCE=fail
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not enable maintenance mode"* ]]
    [[ "$output" == *"Successfully updated"* ]]
}

@test "full-flow: --no-maintenance-mode skips the probe entirely" {
    export MOCK_GITLAB_VERSION="17.11.3-ee.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_MAINTENANCE=enabled
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --no-maintenance-mode
    [ "$status" -eq 0 ]
    [ ! -f "$MOCK_STATE_DIR/maintenance_probe" ]
    [ ! -f "$MOCK_STATE_DIR/rails_runner_calls" ]   # no flag needs rails → no boot at all
    [[ "$output" != *"Maintenance mode"* ]]
}

@test "full-flow: maintenance mode shares the rails boot with --skip-object-storage" {
    export MOCK_GITLAB_VERSION="17.11.3-ee.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_MAINTENANCE=enabled
    export MOCK_OBJECT_STORAGE="lfs artifacts"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --skip-object-storage
    [ "$status" -eq 0 ]
    # the maintenance_mode= result line must not leak into SKIP=
    grep -q "SKIP=lfs,artifacts" "$MOCK_STATE_DIR/backup_args"
    ! grep -q "maintenance" "$MOCK_STATE_DIR/backup_args"
    # one boot before the backup (both snippets) + one to disable at the end
    [ "$(wc -l < "$MOCK_STATE_DIR/rails_runner_calls")" -eq 2 ]
}

@test "full-flow: abort before the critical zone disables maintenance mode (EXIT trap)" {
    export MOCK_GITLAB_VERSION="17.11.3-ee.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_MAINTENANCE=enabled
    export MOCK_SECRETS=bad                       # pre-upgrade secrets check fails after the backup
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"secrets integrity check failure"* ]]
    [[ "$output" == *"Maintenance mode disabled."* ]]
    [ ! -f "$MAINTENANCE_STATE_FILE" ]
}

@test "full-flow: leftover maintenance-mode state from a prior run is released" {
    export MOCK_GITLAB_VERSION="18.0.1-ee.0"     # already at target, previous exit clean
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    mkdir -p "$(dirname "$MAINTENANCE_STATE_FILE")"
    : > "$MAINTENANCE_STATE_FILE"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"Requirements already satisfied"* ]]
    [[ "$output" == *"Maintenance mode disabled."* ]]
    [ ! -f "$MAINTENANCE_STATE_FILE" ]
}

@test "full-flow: Ctrl+C while maintenance mode is being enabled still disables it" {
    # A terminal Ctrl+C signals the whole foreground process group, so the docker exec
    # client dies with the script — but the rails runner inside the container does not.
    # It went on to enable maintenance mode minutes after the script had exited, with no
    # state file behind it, leaving the instance read-only. The client must be shielded
    # from the group signal and the signal deferred until the result is recorded.
    export MOCK_GITLAB_VERSION="17.11.3-ee.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_RUNNER_COUNT=2
    export MOCK_MAINTENANCE=enabled
    export MOCK_RAILS_SLEEP=3                     # hold inside the enable boot

    set -m                                        # own process group: pgid == pid
    bash "$PROJECT_ROOT/upgrade-gitlab" -y > "$MOCK_STATE_DIR/out.log" 2>&1 &
    pid=$!
    set +m
    wait_for_marker "$MOCK_STATE_DIR/maintenance_probe"   # sanity: the enable is in flight

    # Signal the whole group, as a terminal does. SIGTERM stands in for SIGINT for the
    # reason given in the SIGINT-during-backup test; _handle_signal traps both.
    kill -TERM -- "-$pid"
    status=0
    wait "$pid" || status=$?

    [ "$status" -eq 130 ]
    grep -q "Maintenance mode enabled" "$MOCK_STATE_DIR/out.log"     # the result was not lost...
    grep -q "Maintenance mode disabled." "$MOCK_STATE_DIR/out.log"   # ...so it could be undone
    grep -q "Resumed previously paused runners: 1,2" "$MOCK_STATE_DIR/out.log"
    [ -f "$MOCK_STATE_DIR/maintenance_disabled" ]
    [ ! -f "$MAINTENANCE_STATE_FILE" ]
    [ ! -f "$MOCK_STATE_DIR/backup_args" ]        # stopped before the backup started
}

@test "full-flow: --dry-run leaves leftover runner and maintenance state untouched" {
    # --dry-run only computes the path; releasing another run's holds would be a side effect.
    export MOCK_GITLAB_VERSION="17.11.3-ee.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    mkdir -p "$(dirname "$MAINTENANCE_STATE_FILE")"
    : > "$MAINTENANCE_STATE_FILE"
    printf '5\n' > "$RUNNER_STATE_FILE"

    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN: Upgrade Path"* ]]
    [ -f "$MAINTENANCE_STATE_FILE" ]
    [ -f "$RUNNER_STATE_FILE" ]
    [ ! -f "$MOCK_STATE_DIR/maintenance_disabled" ]
    [[ "$output" != *"Resumed previously paused runners"* ]]
}

@test "full-flow: failing to disable maintenance mode keeps the state file for the next run" {
    export MOCK_GITLAB_VERSION="17.11.3-ee.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_MAINTENANCE=enabled
    export MOCK_MAINTENANCE_DISABLE_FAIL=1
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [[ "$output" == *"could not disable maintenance mode"* ]]
    [ -f "$MAINTENANCE_STATE_FILE" ]
    # The kept state file would otherwise make the EXIT trap retry immediately; a second
    # multi-minute rails boot cannot succeed where the first just failed, so the retry waits for
    # the next run. Boots: one to enable, exactly one to disable.
    [ "$(wc -l < "$MOCK_STATE_DIR/rails_runner_calls")" -eq 2 ]
    [ "$(grep -c "could not disable maintenance mode" <<< "$output")" -eq 1 ]
}

# ---------- Test 33: Synology 'db' log driver is replaced with json-file ----------
@test "full-flow: Synology db log driver is replaced with json-file on recreate" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"   # 1-step upgrade
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_LOG_DRIVER=db                    # Synology ContainerManager default

    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"recreated with json-file"* ]]
    # db deadlocks dockerd when stop races an attached `docker logs --follow`, so it must not survive.
    jq -e '.HostConfig.LogConfig == {Type: "json-file", Config: {"max-size": "50m", "max-file": "3"}}' "$MOCK_STATE_DIR/api_create"
}

# ---------- Test 34: non-Synology log driver is preserved as-is ----------
@test "full-flow: existing log driver and options are preserved on recreate" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_LOG_DRIVER=syslog
    export MOCK_LOG_OPTS='{"syslog-address":"udp://1.2.3.4:514"}'

    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    # Previously the recreate dropped log settings, silently reverting to the daemon default.
    jq -e '.HostConfig.LogConfig == {Type: "syslog", Config: {"syslog-address": "udp://1.2.3.4:514"}}' \
        "$MOCK_STATE_DIR/api_create"
}

# ---------- Test 35: UPGRADE_GITLAB_LOG_DRIVER overrides the db replacement ----------
@test "full-flow: UPGRADE_GITLAB_LOG_DRIVER overrides driver selection" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_LOG_DRIVER=db
    export UPGRADE_GITLAB_LOG_DRIVER=db          # opt back in despite the deadlock risk

    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    jq -e '.HostConfig.LogConfig.Type == "db"' "$MOCK_STATE_DIR/api_create"
}

# ---------- Test 36: container stop uses a grace period long enough for GitLab ----------
@test "full-flow: docker stop passes an explicit grace period" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"   # 1-step upgrade
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"

    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    # The 10s default SIGKILLs GitLab (ExitCode 137); a real shutdown measures 32-55s.
    grep -q -- 'stop -t 300' "$MOCK_STATE_DIR/stop_args"
}

# ---------- Image hook (#20): derived images, an official image plus local patches ----------

# _write_image_hook <mode>: an image hook in MOCK_STATE_DIR, exported as UPGRADE_GITLAB_IMAGE_HOOK.
#   ok       builds gitlab-<edition>-patched:<tag> (the mock gives it the matching base label)
#   fail     exits non-zero, like a patch that no longer applies
#   official returns the base image itself, which carries no base label
_write_image_hook() {
    cat > "$MOCK_STATE_DIR/build-image.hook" <<HOOK
#!/usr/bin/env bash
echo "base=\$UPGRADE_GITLAB_BASE_IMAGE edition=\$UPGRADE_GITLAB_EDITION version=\$UPGRADE_GITLAB_VERSION" >> "$MOCK_STATE_DIR/image_hook_calls"
case "$1" in
    fail)
        echo "error: patch does not apply" >&2
        exit 3
        ;;
    official)
        echo "\$UPGRADE_GITLAB_BASE_IMAGE"
        ;;
    *)
        echo "Step 1/3 : FROM \$UPGRADE_GITLAB_BASE_IMAGE" >&2
        repo=\${UPGRADE_GITLAB_BASE_IMAGE%%:*}
        echo "gitlab-\${repo##*-}-patched:\${UPGRADE_GITLAB_BASE_IMAGE##*:}"
        ;;
esac
HOOK
    chmod +x "$MOCK_STATE_DIR/build-image.hook"
    export UPGRADE_GITLAB_IMAGE_HOOK="$MOCK_STATE_DIR/build-image.hook"
}

@test "file hooks: -y refuses to drop file hooks added to the container, even with an image hook" {
    # file_hooks/ is an image path: one added after the container was created (docker cp) is in the
    # writable layer, which every hop discards. The example image hook only applies patches (#26 C).
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    hook=/opt/gitlab/embedded/service/gitlab-rails/file_hooks/notify.rb
    export MOCK_FILE_HOOKS=$hook MOCK_ADDED_FILE_HOOKS=$hook
    _write_image_hook ok
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"file hooks that were added to the container, not the image"* ]]
    [[ "$output" == *"  $hook"* ]]
    [[ "$output" == *"refusing to drop the file hooks in unattended mode"* ]]
    [ ! -f "$MOCK_STATE_DIR/backup_args" ]               # stopped before the backup
}

@test "file hooks: hooks that are part of the image are archived without asking" {
    # Not in the writable layer: a derived image carries them, and its hook rebuilds it.
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_FILE_HOOKS=/opt/gitlab/embedded/service/gitlab-rails/file_hooks/notify.rb
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" != *"the first hop will drop them"* ]]
    grep -qx /opt/gitlab/embedded/service/gitlab-rails/file_hooks/notify.rb "$MOCK_STATE_DIR/config_append_args"
}

@test "image hook: a derived container is upgraded onto the image the hook builds" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0" MOCK_DERIVED_IMAGE=1
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    _write_image_hook ok
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"Container runs a derived image: gitlab-ce-patched:17.11.3-ce.0"* ]]
    [[ "$output" == *"Successfully updated"* ]]
    new=$(cat "$MOCK_STATE_DIR/current_version")
    # The hook got the official base of the new version, and that is what the container runs.
    grep -qx "base=gitlab/gitlab-ce:$new edition=ce version=$new" "$MOCK_STATE_DIR/image_hook_calls"
    [ "$(tail -n1 "$MOCK_STATE_DIR/api_create" | jq -r .Image)" = "gitlab-ce-patched:$new" ]
    # Both the previous derived image and its official base are removed, in one call.
    grep -qx "gitlab-ce-patched:17.11.3-ce.0 gitlab/gitlab-ce:17.11.3-ce.0" "$MOCK_STATE_DIR/image_rm_args"
}

@test "image hook: -y refuses a derived container without a hook before anything runs" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0" MOCK_DERIVED_IMAGE=1
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    unset UPGRADE_GITLAB_IMAGE_HOOK
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"runs a derived image (gitlab-ce-patched:17.11.3-ce.0) but no image hook is configured"* ]]
    [[ "$output" == *"refusing to drop the patches in unattended mode (-y)"* ]]
    [ ! -f "$MOCK_STATE_DIR/backup_args" ]
    [ ! -f "$MOCK_STATE_DIR/stop_args" ]
}

@test "image hook: --dry-run warns about a derived container without a hook and still shows the path" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0" MOCK_DERIVED_IMAGE=1
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    unset UPGRADE_GITLAB_IMAGE_HOOK
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"no image hook is configured"* ]]
    [[ "$output" == *"Image hook: none (official images)"* ]]
    [[ "$output" == *"=== DRY-RUN: Upgrade Path ==="* ]]
}

@test "image hook: a failing hook stops the upgrade with the old container still running" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0" MOCK_DERIVED_IMAGE=1
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    _write_image_hook fail
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"image hook failed for gitlab/gitlab-ce:"* ]]
    # The hook's own output is shown so the cause is visible.
    [[ "$output" == *"patch does not apply"* ]]
    [[ "$output" == *"is still running 17.11.3-ce.0"* ]]
    [ ! -f "$MOCK_STATE_DIR/stop_args" ]
    [ ! -f "$MOCK_STATE_DIR/api_create" ]
    [ "$(cat "$MOCK_STATE_DIR/current_version")" = "17.11.3-ce.0" ]
}

@test "image hook: an image without the matching base label is rejected" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0" MOCK_DERIVED_IMAGE=1
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    _write_image_hook official
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"which is not derived from gitlab/gitlab-ce:"* ]]
    [ ! -f "$MOCK_STATE_DIR/stop_args" ]
}

@test "image hook: a configured hook that is not executable is fatal" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    echo '#!/bin/bash' > "$MOCK_STATE_DIR/build-image.hook"
    export UPGRADE_GITLAB_IMAGE_HOOK="$MOCK_STATE_DIR/build-image.hook"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"UPGRADE_GITLAB_IMAGE_HOOK is not executable"* ]]
    [ ! -f "$MOCK_STATE_DIR/backup_args" ]
}

@test "image hook: --dry-run names the hook without running it" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0" MOCK_DERIVED_IMAGE=1
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    _write_image_hook ok
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Image hook: $MOCK_STATE_DIR/build-image.hook"* ]]
    [ ! -f "$MOCK_STATE_DIR/image_hook_calls" ]
}

@test "image hook: the CE to EE switch also runs on the built image" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0" MOCK_DERIVED_IMAGE=1
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export CI=true
    _write_image_hook ok
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --no-step-limit --edition=ee
    [ "$status" -eq 0 ]
    [[ "$output" == *"Edition switch"* ]]
    grep -q "^base=gitlab/gitlab-ee:17.11.3-ee.0 edition=ee " "$MOCK_STATE_DIR/image_hook_calls"
    [ "$(head -n1 "$MOCK_STATE_DIR/api_create" | jq -r .Image)" = "gitlab-ee-patched:17.11.3-ee.0" ]
}

@test "image prep: a failed pull stops before the old container is stopped" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0" MOCK_PULL_FAIL=1
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not pull gitlab/gitlab-ce:"* ]]
    [[ "$output" == *"is still running 17.11.3-ce.0"* ]]
    [ ! -f "$MOCK_STATE_DIR/stop_args" ]
    [ ! -f "$MOCK_STATE_DIR/api_create" ]
}

# ---------- Container recreate (#22): the whole configuration carries over ----------

# A container as the official Docker docs set one up, plus a user network, an anonymous volume
# and a legacy link: everything the per-flag `docker run` used to drop.
_inspect_patch_full='
  .Config.Env += ["GITLAB_OMNIBUS_CONFIG=external_url '"'"'http://gitlab.test'"'"'"]
  | .Config.Labels += {"com.docker.compose.project": "gitlab"}
  | .Config.Hostname = "gitlab.example.com"
  | .HostConfig.ShmSize = 536870912
  | .HostConfig.PortBindings["80/tcp"] = [{HostIp: "127.0.0.1", HostPort: "8080"}, {HostIp: "::1", HostPort: "8080"}]
  | .HostConfig.NetworkMode = "proxy"
  | .HostConfig.Links = ["/redis:/gitlab/cache"]
  | .Mounts += [{Type: "volume", Name: "anonvol", Source: "/var/lib/docker/volumes/anonvol/_data", Destination: "/assets/extra", RW: true}]
  | .NetworkSettings.Networks = {
      proxy: {Aliases: ["0123456789ab", "gitlab", "git"], NetworkID: "proxyid", IPAMConfig: {IPv4Address: "172.20.0.10"}},
      runners: {Aliases: ["0123456789ab"], NetworkID: "runnersid"}
    }'

@test "recreate: user settings carry over and image defaults are left to the new image" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_INSPECT_PATCH="$_inspect_patch_full"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    body=$(tail -n1 "$MOCK_STATE_DIR/api_create")
    # Only what the user added; PATH/LANG from the old image would pin it onto the new one.
    jq -e '.Env == ["GITLAB_OMNIBUS_CONFIG=external_url '"'"'http://gitlab.test'"'"'"]' <<<"$body"
    jq -e '.Labels == {"com.docker.compose.project": "gitlab"}' <<<"$body"
    jq -e '.Hostname == "gitlab.example.com"' <<<"$body"
    jq -e 'has("Cmd") or has("Healthcheck") or has("Volumes") | not' <<<"$body"
    jq -e '.Image == "gitlab/gitlab-ce:'"$(cat "$MOCK_STATE_DIR/current_version")"'"' <<<"$body"
    # Bind IPs and every binding of a port.
    jq -e '.HostConfig.PortBindings["80/tcp"] == [{HostIp: "127.0.0.1", HostPort: "8080"}, {HostIp: "::1", HostPort: "8080"}]' <<<"$body"
    jq -e '.HostConfig.ShmSize == 536870912' <<<"$body"   # larger than 256MB: kept
    # The anonymous volume is reattached by name instead of being recreated empty.
    jq -e '.HostConfig.Binds | index("anonvol:/assets/extra") != null' <<<"$body"
    jq -e '.HostConfig.Binds | length == 4' <<<"$body"
    jq -e '.HostConfig.Links == ["redis:cache"]' <<<"$body"
    # The NetworkMode network at create, without the aliases Docker added itself.
    jq -e '.NetworkingConfig.EndpointsConfig | keys == ["proxy"]' <<<"$body"
    jq -e '.NetworkingConfig.EndpointsConfig.proxy.Aliases == ["git"]' <<<"$body"
    jq -e '.NetworkingConfig.EndpointsConfig.proxy.IPAMConfig.IPv4Address == "172.20.0.10"' <<<"$body"
    # The other network is connected before start (API < 1.44 takes one network at create).
    connect=$(tail -n1 "$MOCK_STATE_DIR/api_connect")
    jq -e '.url | endswith("/v1.43/networks/runners/connect")' <<<"$connect"
    jq -e '.Container == "gitlab-upgrade-next" and .EndpointConfig.Aliases == null' <<<"$connect"
    grep -qx "rename gitlab-upgrade-next gitlab" "$MOCK_STATE_DIR/rename_args"
}

@test "recreate: a 64MB /dev/shm is raised to 256MB" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_INSPECT_PATCH='.HostConfig.ShmSize = 67108864'
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"runs with a 64MB /dev/shm"*"recreated with 256MB"* ]]
    jq -e '.HostConfig.ShmSize == 268435456' "$MOCK_STATE_DIR/api_create"
}

@test "recreate: a derived image's base label stays with the image" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0" MOCK_DERIVED_IMAGE=1
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    _write_image_hook ok
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    # Copied onto the container, the old base would outlive the new image's own label.
    jq -e '.Labels == {}' "$MOCK_STATE_DIR/api_create"
}

@test "recreate: a rejected create stops before the old container is stopped" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0" MOCK_CREATE_FAIL=1
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not create the replacement container (HTTP 400): mock create rejected"* ]]
    [[ "$output" == *"is still running 17.11.3-ce.0"* ]]
    [ ! -f "$MOCK_STATE_DIR/stop_args" ]
    [ "$(cat "$MOCK_STATE_DIR/current_version")" = "17.11.3-ce.0" ]
}

@test "recreate: a non-unix Docker endpoint is refused before anything runs" {
    export MOCK_DOCKER_ENDPOINT="ssh://admin@nas"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"'ssh://admin@nas' is not a unix socket"* ]]
    [ ! -f "$MOCK_STATE_DIR/backup_args" ]
}

@test "recreate: an unreachable Engine API is refused before anything runs" {
    export MOCK_API_UNREACHABLE=1
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot call the Docker Engine API on /var/run/docker.sock (API version: 1.43)"* ]]
    [ ! -f "$MOCK_STATE_DIR/backup_args" ]
}

@test "recreate: the swap runs with restart policy no and the original is restored afterwards" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_INSPECT_PATCH='.HostConfig.RestartPolicy = {Name: "on-failure", MaximumRetryCount: 3}'
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    # A new version that dies in reconfigure must not be rebooted in a loop.
    jq -e '.HostConfig.RestartPolicy == {Name: "no", MaximumRetryCount: 0}' "$MOCK_STATE_DIR/api_create"
    # Restored once verification passed, retry count included.
    grep -qx "update --restart=on-failure:3 gitlab" "$MOCK_STATE_DIR/update_args"
    [[ "$output" == *"Restoring gitlab RestartPolicy to on-failure:3"* ]]
}

@test "recreate: an interrupted run still restores the restart policy" {
    # 3-hop path; the signal arrives once the first replacement exists, so the loop stops at
    # the next checkpoint with the hop-1 container (created with no) up and verified.
    export MOCK_GITLAB_VERSION="17.3.7-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    bash "$PROJECT_ROOT/upgrade-gitlab" -y --no-step-limit > "$MOCK_STATE_DIR/out.log" 2>&1 &
    pid=$!
    wait_for_marker "$MOCK_STATE_DIR/api_create"
    kill -TERM "$pid"   # SIGINT is ignored by background jobs; _handle_signal traps both
    status=0
    wait "$pid" || status=$?
    [ "$status" -eq 130 ]
    grep -qx "update --restart=unless-stopped gitlab" "$MOCK_STATE_DIR/update_args"
    # The version reported is the one running now, not the one the run started from.
    now=$(cat "$MOCK_STATE_DIR/current_version")
    [ "$now" != "17.3.7-ce.0" ]
    grep -q "gitlab is running $now\.$" "$MOCK_STATE_DIR/out.log"
}

# ---------- HTTP readiness is checked inside the container, at the healthcheck rc address (#24) ----------
@test "http ready: the in-container check uses the address from gitlab-healthcheck-rc" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    # external_url 'https://gitlab.test:8443/gitlab': nginx answers on 8443 under /gitlab only,
    # so the old fixed http://localhost/users/sign_in would poll forever.
    printf '%s\n' "url='https://localhost:8443/gitlab/help'" 'flags=(--insecure)' > "$MOCK_STATE_DIR/healthcheck-rc"
    export MOCK_HEALTHCHECK_RC="$MOCK_STATE_DIR/healthcheck-rc"
    export MOCK_READY_URL="https://localhost:8443/gitlab/users/sign_in"
    # SIGKILL: a SIGTERM inside the critical zone is only deferred, so it would not end a hung poll.
    run timeout -s KILL 120 bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    grep -q -- "--insecure $MOCK_READY_URL$" "$MOCK_STATE_DIR/sign_in_curl_args"
}

@test "http ready: without the rc file the check falls back to http://localhost" {
    # An old version without the rc, or a new container before its first reconfigure.
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    unset MOCK_HEALTHCHECK_RC
    export MOCK_READY_URL="http://localhost/users/sign_in"
    run timeout -s KILL 120 bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    grep -q "http://localhost/users/sign_in$" "$MOCK_STATE_DIR/sign_in_curl_args"
}

@test "recreate: a replacement that cannot start ends the run instead of waiting forever" {
    # The original is already removed at that point, so the readiness wait could never succeed.
    export MOCK_GITLAB_VERSION="17.11.3-ce.0" MOCK_RENAME_FAIL=1
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    # SIGKILL: a SIGTERM inside the critical zone is only deferred, so it would not end a hung poll.
    run timeout -s KILL 120 bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not start the replacement container"* ]]
    [[ "$output" == *"FATAL ERROR: MANUAL INTERVENTION IS REQUIRED"* ]]
    [[ "$output" != *"waiting until"*"is ready"* ]]
}

@test "recreate: a run logging to a file keeps the whole log" {
    # The Engine API call once sent curl's stderr to /dev/stderr. With the script's stderr on a
    # regular file (`> log 2>&1`, as under cron), that reopened the file with O_TRUNC and erased
    # everything logged before the container was created. `run` captures through a pipe, so the
    # script is redirected to a file here instead.
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    status=0
    timeout -s KILL 120 bash "$PROJECT_ROOT/upgrade-gitlab" -y \
        > "$MOCK_STATE_DIR/run.log" 2>&1 || status=$?
    [ "$status" -eq 0 ]
    [ -f "$MOCK_STATE_DIR/api_create" ]                       # the API was called
    grep -q "Detected gitlab container" "$MOCK_STATE_DIR/run.log"   # logged before that call
    grep -q "Successfully updated" "$MOCK_STATE_DIR/run.log"
}

# ---------- Readiness waits end (#25) ----------
@test "ready wait: a container that never turns healthy stops the run at --ready-timeout" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0" MOCK_HEALTH_STATUS=starting
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    # SIGKILL: a SIGTERM inside the critical zone is only deferred, so it would not end a hung poll.
    run timeout -s KILL 120 bash "$PROJECT_ROOT/upgrade-gitlab" -y --ready-timeout=2
    [ "$status" -eq 1 ]
    [[ "$output" == *"gave up waiting for"*"after 2s (--ready-timeout)"* ]]
    [[ "$output" == *"FATAL ERROR: MANUAL INTERVENTION IS REQUIRED"* ]]
    [[ "$output" == *"Runners stay paused and maintenance mode stays on"* ]]
    # Holds are kept like a fatal error: the restart policy is not restored.
    [ ! -f "$MOCK_STATE_DIR/update_args" ]
}

@test "ready wait: a container stopped with exit code 0 is treated as dead" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0" MOCK_HEALTH_STATUS=starting MOCK_RUNNING=false
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    run timeout -s KILL 120 bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"gitlab container is not running (exit code 0)"* ]]
    [[ "$output" == *"FATAL ERROR: MANUAL INTERVENTION IS REQUIRED"* ]]
}

@test "ready wait: an image without a health check relies on the HTTP check" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0" MOCK_HEALTH_STATUS=none
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    run timeout -s KILL 120 bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"has no health check; relying on the HTTP check only."* ]]
    [[ "$output" == *"Successfully updated"* ]]
}

@test "ready wait: an interrupt during the wait is announced and the wait goes on" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0" MOCK_HEALTH_STATUS=starting
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    # Signal the script alone, as the other interrupt tests do. A group-wide signal (a terminal's
    # Ctrl+C, or `timeout` forwarding one) also kills the docker client of the swap itself; that is
    # a separate gap (#31), not what this test covers. --ready-timeout bounds the run.
    bash "$PROJECT_ROOT/upgrade-gitlab" -y --ready-timeout=4 > "$MOCK_STATE_DIR/out.log" 2>&1 &
    pid=$!
    wait_for_marker "$MOCK_STATE_DIR/rename_args"   # the replacement is up, the wait has begun
    kill -TERM "$pid"   # SIGINT is ignored by background jobs; _handle_signal traps both
    status=0
    wait "$pid" || status=$?
    # The wait did not break on the signal; the timeout ended it.
    [ "$status" -eq 1 ]
    grep -q "Interrupt received. The container is already running" "$MOCK_STATE_DIR/out.log"
    grep -q "gave up waiting for" "$MOCK_STATE_DIR/out.log"
}

@test "ready wait: the boot reconfigure must finish before the container counts as ready" {
    # Services answer while the image's start-up reconfigure is still running; it then restarts
    # them once more and prints its Deprecations block (#29).
    export MOCK_GITLAB_VERSION="17.11.3-ce.0" MOCK_BOOT_RECONFIGURE_POLLS=3
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    run timeout -s KILL 120 bash "$PROJECT_ROOT/upgrade-gitlab" -y
    [ "$status" -eq 0 ]
    [ "$(cat "$MOCK_STATE_DIR/boot_reconfigure_count")" -gt 3 ]
}

@test "ready wait: a boot reconfigure that never ends stops the run at --ready-timeout" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0" MOCK_BOOT_RECONFIGURE_POLLS=always
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    run timeout -s KILL 120 bash "$PROJECT_ROOT/upgrade-gitlab" -y --ready-timeout=2
    [ "$status" -eq 1 ]
    [[ "$output" == *"gave up waiting for"* ]]
}
