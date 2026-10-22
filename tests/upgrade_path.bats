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
    export MOCK_EOS_UNAVAIL=1  # bypass EOS check (17.5 is EOS in mock)
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --version=17.5
    [ "$status" -eq 0 ]
    [[ "$output" == *"Partial version provided: 17.5"* ]]
    [[ "$output" == *"Resolved partial version to: 17.5.5-ce.0"* ]]
    [[ "$output" == *"Target: 17.5.5-ce.0"* ]]
}

# ---------- Test 4: --version=17.5.2-ce.0 (exact version) ----------
@test "--version=17.5.2-ce.0 targets exact version" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    export MOCK_EOS_UNAVAIL=1  # bypass EOS check (17.5 is EOS in mock)
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

# ---------- Test 6: --version (non-major) + --skip-latest = error ----------
@test "--version=17.5 and --skip-latest together produce error (skip-latest first)" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --skip-latest --version=17.5
    [ "$status" -eq 1 ]
    [[ "$output" == *"--skip-latest can only be combined with major-only --version"* ]]
}

@test "--version=17.5 and --skip-latest together produce error (version first)" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --version=17.5 --skip-latest
    [ "$status" -eq 1 ]
    [[ "$output" == *"--skip-latest can only be combined with major-only --version"* ]]
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

# ---------- Test 13: --discord-url is accepted, --target-url is removed (#25) ----------
@test "--discord-url sets the variable correctly" {
    export MOCK_GITLAB_VERSION="18.0.1-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --discord-url=https://discord.test/hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== DRY-RUN: Upgrade Path ==="* ]]
}

@test "--target-url is rejected as removed" {
    export MOCK_GITLAB_VERSION="18.0.1-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --target-url=http://gitlab.test
    [ "$status" -eq 1 ]
    [[ "$output" == *"--target-url has been removed"* ]]
}

@test "--ready-timeout rejects a non-numeric value" {
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --ready-timeout=10m
    [ "$status" -eq 1 ]
    [[ "$output" == *"--ready-timeout must be a whole number of seconds"* ]]
}

# ---------- Test 14: --source flag is removed ----------
@test "--source flag produces deprecation error" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --source=cached
    [ "$status" -eq 1 ]
    [[ "$output" == *"--source flag has been removed"* ]]
}

# ---------- Test 15: --version=17 --skip-latest → major-scoped N-1 ----------
@test "--version=17 --skip-latest targets N-1 within major 17" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --version=17 --skip-latest
    [ "$status" -eq 0 ]
    # Latest in major 17 = 17.11.3, N-1 = 17.10 (arithmetic: 11-1=10)
    # Docker Hub → 17.10.2-ce.0
    [[ "$output" == *"Skip-latest (N-1) mode: targeting 17.10.2-ce.0"* ]]
    [[ "$output" == *"Target: 17.10.2-ce.0"* ]]
}

# ---------- Test 16: --version=18 --skip-latest → minor=0, N-1 crosses major ----------
@test "--version=18 --skip-latest targets previous major's last minor" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --version=18 --skip-latest
    [ "$status" -eq 0 ]
    # 18.0 → minor=0 → N-1 = prev major's latest = 17.11.3
    [[ "$output" == *"Skip-latest (N-1) mode: targeting 17.11.3-ce.0"* ]]
    [[ "$output" == *"Target: 17.11.3-ce.0"* ]]
}

# ---------- --skip-latest=unpatched: N-1 only while the latest minor is still X.Y.0 (#28) ----------
# Copies the fixtures without the given tags, so the latest of a minor becomes its .0.
_fixtures_without() {
    local dir="$BATS_TEST_TMPDIR/fixtures" f tag
    cp -r "$FIXTURES_DIR" "$dir"
    for tag in "$@"; do
        f="$dir/dockerhub_${tag%%.*}.json"
        jq --arg t "$tag" '.results |= map(select(.name != $t))' "$f" > "$f.new" && mv "$f.new" "$f"
    done
    export FIXTURES_DIR="$dir"
}

@test "--skip-latest=unpatched keeps a latest that has a patch release" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --skip-latest=unpatched
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skip-latest (unpatched) mode: latest 18.0.1-ce.0 already has a patch release, keeping it"* ]]
    [[ "$output" != *"Skip-latest (N-1) mode"* ]]
    [[ "$output" == *"Target: 18.0.1-ce.0"* ]]
}

@test "--skip-latest=unpatched targets N-1 while the latest is a new major's .0" {
    _fixtures_without 18.0.1-ce.0
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --skip-latest=unpatched
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skip-latest (unpatched) mode: latest 18.0.0-ce.0 has no patch release yet"* ]]
    [[ "$output" == *"Skip-latest (N-1) mode: targeting 17.11.3-ce.0"* ]]
    [[ "$output" == *"Target: 17.11.3-ce.0"* ]]
}

@test "--version=17 --skip-latest=unpatched targets N-1 while 17.11 is .0" {
    _fixtures_without 17.11.3-ce.0
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --version=17 --skip-latest=unpatched
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skip-latest (unpatched) mode: latest 17.11.0-ce.0 has no patch release yet"* ]]
    [[ "$output" == *"Skip-latest (N-1) mode: targeting 17.10.2-ce.0"* ]]
    [[ "$output" == *"Target: 17.10.2-ce.0"* ]]
}

@test "--version=17 --n-1=unpatched keeps 17.11.3" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --version=17 --n-1=unpatched
    [ "$status" -eq 0 ]
    [[ "$output" == *"latest 17.11.3-ce.0 already has a patch release, keeping it"* ]]
    [[ "$output" == *"Target: 17.11.3-ce.0"* ]]
}

@test "--skip-latest=always behaves like --skip-latest" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --skip-latest=always
    [ "$status" -eq 0 ]
    [[ "$output" != *"(unpatched)"* ]]
    [[ "$output" == *"Skip-latest (N-1) mode: targeting 17.11.3-ce.0"* ]]
}

@test "--skip-latest with an unknown mode produces error" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --skip-latest=sometimes
    [ "$status" -eq 1 ]
    [[ "$output" == *"--skip-latest must be 'always' (the default) or 'unpatched'"* ]]
}

# ---------- Test 17: --version=16 → EOS error ----------
@test "--version=16 is rejected as end-of-support" {
    export MOCK_GITLAB_VERSION="15.0.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --version=16
    [ "$status" -eq 1 ]
    # mock releases: [18.0, 17.11, 17.10] → 16.11 not supported
    [[ "$output" == *"end-of-support"* ]]
    [[ "$output" == *"Supported tracks:"* ]]
}

# ---------- Test 18: --version=17.3 → EOS error ----------
@test "--version=17.3 is rejected as end-of-support" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --version=17.3
    [ "$status" -eq 1 ]
    # 17.3 not in supported tracks [18.0, 17.11, 17.10]
    [[ "$output" == *"end-of-support"* ]]
}

# ---------- Test 19: EOS API failure → warning only, continues ----------
@test "EOS API failure shows warning but continues" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    export MOCK_EOS_UNAVAIL=1
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --version=17.7
    [ "$status" -eq 0 ]
    [[ "$output" == *"Could not check EOS status"* ]]
    [[ "$output" == *"=== DRY-RUN: Upgrade Path ==="* ]]
}

# ---------- Test 20: --version=17.10 resolves via Docker Hub ----------
@test "--version=17.10 resolves via Docker Hub when not in path.json" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --version=17.10
    [ "$status" -eq 0 ]
    # 17.10 not in path.json stops, but exists on Docker Hub → fallback
    [[ "$output" == *"Resolved partial version to: 17.10.2-ce.0"* ]]
    [[ "$output" == *"Target: 17.10.2-ce.0"* ]]
    # the unresolved string must not become a step of its own (#62)
    [ "$(_steps)" = "16.11.10-ce.0 17.3.7-ce.0 17.5.5-ce.0 17.7.4-ce.0 17.10.2-ce.0" ]
}

# ---------- Partial versions never enter the steps unresolved (#62) ----------
# The step tags of the dry-run listing, on one line.
_steps() {
    printf '%s\n' "$output" | sed -n 's/^  [0-9]*\. //p' | paste -sd' '
}

@test "--version=17 lists only resolved tags as steps" {
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --version=17
    [ "$status" -eq 0 ]
    [[ "$output" == *"Resolved partial version to: 17.11.3-ce.0"* ]]
    [[ "$output" == *"Target: 17.11.3-ce.0"* ]]
    [ "$(_steps)" = "16.11.10-ce.0 17.3.7-ce.0 17.5.5-ce.0 17.7.4-ce.0 17.11.3-ce.0" ]
}

@test "--version=17 resolves to the major's latest even when it is not a path stop" {
    _fixtures_without
    jq '.all |= map(select(. != "17.11.3"))' "$FIXTURES_DIR/path.json" > "$FIXTURES_DIR/path.json.new" \
        && mv "$FIXTURES_DIR/path.json.new" "$FIXTURES_DIR/path.json"
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --version=17
    [ "$status" -eq 0 ]
    [[ "$output" == *"Target: 17.11.3-ce.0"* ]]
    [ "$(_steps)" = "16.11.10-ce.0 17.3.7-ce.0 17.5.5-ce.0 17.7.4-ce.0 17.11.3-ce.0" ]
}

@test "an unresolvable partial version falls back to latest without a stray step" {
    # latest off the path, so only the fallback can put it into the steps
    _fixtures_without
    jq '.all |= map(select(. != "18.0.1"))' "$FIXTURES_DIR/path.json" > "$FIXTURES_DIR/path.json.new" \
        && mv "$FIXTURES_DIR/path.json.new" "$FIXTURES_DIR/path.json"
    export MOCK_GITLAB_VERSION="16.11.0-ce.0"
    export MOCK_EOS_UNAVAIL=1  # 17.99 is not a release track
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --version=17.99
    [ "$status" -eq 0 ]
    [[ "$output" == *"No tags matching '17.99.*' found."* ]]
    [[ "$output" == *"Target: 18.0.1-ce.0"* ]]
    [ "$(_steps)" = "16.11.10-ce.0 17.3.7-ce.0 17.5.5-ce.0 17.7.4-ce.0 17.11.3-ce.0 18.0.1-ce.0" ]
}

# ---------- Test 21: --max-tier accepts valid values ----------
@test "--max-tier=premium is accepted" {
    export MOCK_GITLAB_VERSION="18.0.1-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --max-tier=premium
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== DRY-RUN: Upgrade Path ==="* ]]
}

# ---------- Test 22: --max-tier rejects invalid values ----------
@test "--max-tier=enterprise produces error" {
    export MOCK_GITLAB_VERSION="18.0.1-ce.0"
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run --max-tier=enterprise
    [ "$status" -eq 1 ]
    [[ "$output" == *"--max-tier must be one of"* ]]
}

# ---------- Unreachable Docker daemon: the startup probe reports docker's own error (#18) ----------
@test "unreachable docker daemon fails with the docker error" {
    export MOCK_DOCKER_UNREACHABLE=1
    run bash "$PROJECT_ROOT/upgrade-gitlab" --dry-run
    [ "$status" -eq 1 ]
    [[ "$output" == *"Cannot reach the Docker daemon as"* ]]
    [[ "$output" == *"  permission denied while trying to connect"* ]]
}
