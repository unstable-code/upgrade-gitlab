#!/usr/bin/env bash
# BATS test helper — common setup for upgrade-gitlab tests

# Project root (one level up from tests/)
export PROJECT_ROOT
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Fixtures directory
export FIXTURES_DIR="$PROJECT_ROOT/tests/fixtures"

# Prepend mocks to PATH so they shadow real binaries
export PATH="$PROJECT_ROOT/tests/mocks:$PATH"

# Default mock version (can be overridden per test)
export MOCK_GITLAB_VERSION="${MOCK_GITLAB_VERSION:-16.11.0-ce.0}"

# Default CI=true so local bats bypasses -y mode's DISCORD_URL requirement.
export CI="${CI:-true}"

# The runner-pause state file is now persistent-first (XDG_STATE_HOME → $HOME/.local/state
# → runtime tmpfs). Pin XDG_STATE_HOME to the per-test temp dir so tests never create or
# pollute the real $HOME/.local/state, and so the state-file path is deterministic.
_xdg_base="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
export XDG_STATE_HOME="$_xdg_base/xdg-state"
# Also redirect XDG_RUNTIME_DIR into the per-test temp so the script's tmpfs fallback
# (${XDG_RUNTIME_DIR:-...}) can NEVER touch the real /run/user/$UID. Both live under
# BATS_TEST_TMPDIR (auto-removed), so tests must never `rm -rf "$XDG_RUNTIME_DIR"` —
# doing so with the real value would wipe the live session's runtime dir.
export XDG_RUNTIME_DIR="$_xdg_base/xdg-runtime"
mkdir -p "$XDG_RUNTIME_DIR"
# Convenience for tests that read/seed the state file:
export RUNNER_STATE_FILE="$XDG_STATE_HOME/upgrade-gitlab/upgrade-gitlab-gitlab.paused-runners"
export MAINTENANCE_STATE_FILE="$XDG_STATE_HOME/upgrade-gitlab/upgrade-gitlab-gitlab.maintenance-mode"
export RESTART_POLICY_STATE_FILE="$XDG_STATE_HOME/upgrade-gitlab/upgrade-gitlab-gitlab.restart-policy"

# Note: UID is a readonly bash variable, no need to set it

# State management for full-flow tests
setup_mock_state() {
    MOCK_STATE_DIR=$(mktemp -d)
    export MOCK_STATE_DIR
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
}

# wait_for_marker <file> — poll up to ~20s for a mock state marker; fails if it never shows.
# Used to signal a backgrounded run at a deterministic point instead of a fixed sleep.
wait_for_marker() {
    local _
    for _ in $(seq 1 200); do
        [ -f "$1" ] && return 0
        sleep 0.1
    done
    return 1
}

# run_and_group_signal <marker> <script args...> — run the script in its own process group (output
# in $MOCK_STATE_DIR/out.log), signal the whole group once the mock writes <marker>, as a terminal
# Ctrl+C does, and set status. SIGTERM stands in for SIGINT, which background jobs ignore;
# _handle_signal traps both.
run_and_group_signal() {
    local marker=$1 pid
    shift
    set -m                                        # own process group: pgid == pid
    timeout -s KILL 120 bash "$PROJECT_ROOT/upgrade-gitlab" "$@" > "$MOCK_STATE_DIR/out.log" 2>&1 &
    pid=$!
    set +m
    wait_for_marker "$MOCK_STATE_DIR/$marker"
    kill -TERM -- "-$pid"
    status=0
    wait "$pid" || status=$?
}

teardown_mock_state() {
    [ -n "$MOCK_STATE_DIR" ] && rm -rf "$MOCK_STATE_DIR"
    unset MOCK_STATE_DIR
}
