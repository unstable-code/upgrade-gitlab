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

# Note: UID is a readonly bash variable, no need to set it

# State management for full-flow tests
setup_mock_state() {
    MOCK_STATE_DIR=$(mktemp -d)
    export MOCK_STATE_DIR
    echo "$MOCK_GITLAB_VERSION" > "$MOCK_STATE_DIR/current_version"
}

teardown_mock_state() {
    [ -n "$MOCK_STATE_DIR" ] && rm -rf "$MOCK_STATE_DIR"
    unset MOCK_STATE_DIR
}
