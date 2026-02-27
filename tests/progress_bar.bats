#!/usr/bin/env bats

setup() {
    load test_helper
    export COLUMNS=120
    setup_mock_state
}

teardown() {
    teardown_mock_state
}

# ---------- Test 1: psql 데이터 있을 때 백업 정상 완료 ----------
@test "progress-bar: backup completes with psql stats available" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"Creating backups"* ]]
}

# ---------- Test 2: psql 실패 시 폴백으로 백업 정상 완료 ----------
@test "progress-bar: backup completes when psql stats unavailable (fallback)" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    export MOCK_PSQL_NO_STATS=1
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"Creating backups"* ]]
}

# ---------- Test 3: --skip-lfs와 함께 사용 시 정상 완료 ----------
@test "progress-bar: backup completes with --skip-lfs flag" {
    export MOCK_GITLAB_VERSION="17.11.3-ce.0"
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
    run bash "$PROJECT_ROOT/upgrade-gitlab" -y --skip-lfs --target-url=http://mock
    [ "$status" -eq 0 ]
    [[ "$output" == *"Creating backups"* ]]
    [[ "$output" == *"LFS objects will be skipped"* ]]
}
