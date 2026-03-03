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
