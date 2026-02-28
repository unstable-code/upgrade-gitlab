#!/usr/bin/env bats

setup() {
    load test_helper
    export COLUMNS=120
}

# ---------- Test 1: Default upgrade (16.11.0 → latest) ----------
@test "default upgrade: 16.11.0-ce → latest shows correct path" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== DRY-RUN: Upgrade Path ==="* ]]
    [[ "$output" == *"Current: 16.11.0-ce.0"* ]]
    [[ "$output" == *"Edition: ce"* ]]
    # Target should be the latest tag: 18.0.1-ce.0
    [[ "$output" == *"Target: 18.0.1-ce.0"* ]]
    # Should include required stops: 16.11, 17.3, 17.5, 17.7, 17.11, 18.0
    [[ "$output" == *"17.3.7-ce.0"* ]]
    [[ "$output" == *"17.5.5-ce.0"* ]]
    [[ "$output" == *"17.7.4-ce.0"* ]]
    [[ "$output" == *"17.11.3-ce.0"* ]]
    [[ "$output" == *"18.0.1-ce.0"* ]]
}

# ---------- Test 2: --skip-latest (N-1 strategy) ----------
@test "--skip-latest targets previous minor's latest patch" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --skip-latest
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== DRY-RUN: Upgrade Path ==="* ]]
    # Latest is 18.0.x, minor=0 → N-1 goes to previous major's last minor
    # prev_major=17, latest of 17.x = 17.11.3-ce.0
    [[ "$output" == *"Skip-latest (N-1) mode: targeting 17.11.3-ce.0"* ]]
    [[ "$output" == *"Target: 17.11.3-ce.0"* ]]
}

# ---------- Test 3: --version=17.5 (partial version resolve) ----------
@test "--version=17.5 resolves to latest 17.5.x patch" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --version=17.5
    [ "$status" -eq 0 ]
    [[ "$output" == *"Partial version provided: 17.5"* ]]
    [[ "$output" == *"Resolved partial version to: 17.5.5-ce.0"* ]]
    [[ "$output" == *"Target: 17.5.5-ce.0"* ]]
}

# ---------- Test 4: --version=17.5.2-ce.0 (exact version) ----------
@test "--version=17.5.2-ce.0 targets exact version" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --version=17.5.2-ce.0
    [ "$status" -eq 0 ]
    [[ "$output" == *"Using 17.5.2-ce.0 instead of latest"* ]]
    [[ "$output" == *"Target: 17.5.2-ce.0"* ]]
}

# ---------- Test 5: --edition=ee switches edition ----------
@test "--edition=ee switches to EE edition" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --edition=ee
    [ "$status" -eq 0 ]
    [[ "$output" == *"Edition switch requested: ce -> ee"* ]]
    [[ "$output" == *"Edition: ee"* ]]
}

# ---------- Test 6: --version + --skip-latest = error ----------
@test "--version and --skip-latest together produce error (skip-latest first)" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --skip-latest --version=17.5
    [ "$status" -eq 1 ]
    [[ "$output" == *"--version and --skip-latest cannot be used together"* ]]
}

@test "--version and --skip-latest together produce error (version first)" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --version=17.5 --skip-latest
    [ "$status" -eq 1 ]
    [[ "$output" == *"--version and --skip-latest cannot be used together"* ]]
}

# ---------- Test 7: Invalid --edition=xx = error ----------
@test "invalid --edition=xx produces error" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --edition=xx
    [ "$status" -eq 1 ]
    [[ "$output" == *"--edition must be 'ce' or 'ee'"* ]]
}

# ---------- Test 8: Already at latest version ----------
@test "already at latest version shows satisfied message" {
    export MOCK_GITLAB_VERSION="18.0.1-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Steps: 0"* ]]
}

# ---------- Test 9: -y with >= 3 steps errors (but dry-run bypasses) ----------
@test "dry-run bypasses -y step limit and shows full path" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run
    [ "$status" -eq 0 ]
    # Should list multiple steps without aborting
    [[ "$output" == *"Steps:"* ]]
    # Extract step count — it should be >= 3
    steps=$(echo "$output" | grep "^Steps:" | awk '{print $2}')
    [ "$steps" -ge 3 ]
}

# ---------- Test 10: --no-step-limit rejected outside CI ----------
@test "--no-step-limit without CI=true produces error" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    unset CI
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --no-step-limit
    [ "$status" -eq 1 ]
    [[ "$output" == *"--no-step-limit is only allowed in CI environments"* ]]
}

# ---------- Test 11: --no-step-limit accepted in CI ----------
@test "--no-step-limit with CI=true is accepted" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    export CI=true
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --no-step-limit
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== DRY-RUN: Upgrade Path ==="* ]]
}

# ---------- Test 12: --skip-lfs is accepted ----------
@test "--skip-lfs flag is accepted without error" {
    export MOCK_GITLAB_VERSION="18.0.1-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --skip-lfs
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== DRY-RUN: Upgrade Path ==="* ]]
}

# ---------- Test 13: --discord-url and --target-url are accepted ----------
@test "--discord-url and --target-url set variables correctly" {
    export MOCK_GITLAB_VERSION="18.0.1-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --discord-url=https://discord.test/hook --target-url=http://gitlab.test
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== DRY-RUN: Upgrade Path ==="* ]]
}

# ---------- Test 14: Fallback to live when pipeline failed ----------
@test "fallback to live when pipeline failed" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    export MOCK_PIPELINE_FAILED=1
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"using live source"* ]]
    [[ "$output" == *"=== DRY-RUN: Upgrade Path ==="* ]]
    [[ "$output" == *"Target: 18.0.1-ce.0"* ]]
}

# ---------- Test 15: Fallback to live when pipeline unreachable ----------
@test "fallback to live when pipeline unreachable" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    export MOCK_PIPELINE_UNAVAIL=1
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"using live source"* ]]
    [[ "$output" == *"=== DRY-RUN: Upgrade Path ==="* ]]
    [[ "$output" == *"Target: 18.0.1-ce.0"* ]]
}

# ---------- Test 16: --source=live forces direct computation ----------
@test "--source=live forces direct computation" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --source=live
    [ "$status" -eq 0 ]
    [[ "$output" == *"Using live upgrade path"* ]]
    [[ "$output" == *"=== DRY-RUN: Upgrade Path ==="* ]]
    [[ "$output" == *"Target: 18.0.1-ce.0"* ]]
}

# ---------- Test 17: --source=cached forces path.json ----------
@test "--source=cached forces path.json" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --source=cached
    [ "$status" -eq 0 ]
    [[ "$output" == *"Using cached upgrade path"* ]]
    [[ "$output" == *"=== DRY-RUN: Upgrade Path ==="* ]]
    [[ "$output" == *"Target: 18.0.1-ce.0"* ]]
}

# ---------- Test 18: Invalid --source value ----------
@test "invalid --source=xxx produces error" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --source=xxx
    [ "$status" -eq 1 ]
    [[ "$output" == *"--source must be 'cached' or 'live'"* ]]
}
