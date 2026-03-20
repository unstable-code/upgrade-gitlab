# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**upgrade-gitlab** is an automated, Docker-based GitLab upgrade tool that performs safe, step-by-step version upgrades following the official GitLab upgrade path. Single bash script (`upgrade-gitlab`, ~1600 lines) supporting CE/EE editions with background migration tracking, signal safety, and Discord notifications.

Repository: `gitlab.com/gitlab-useful-scripts/upgrade-gitlab` (GitLab, not GitHub — use `glab` instead of `gh`)

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
Critical sections (`enter_critical`/`exit_critical`) defer SIGINT/SIGTERM/SIGTSTP during container swap operations (stop → remove → pull → run). Ctrl+\\ (SIGQUIT) forces immediate exit.

### Main Upgrade Flow
1. Pre-flight checks (disk space, secrets integrity)
2. Backup (gitlab-backup or gitlab-rake for <12.2)
3. Optional edition switch (CE→EE)
4. Version upgrade loop: for each stop → pre-pull next image → wait for background migrations → swap container → health check → verify migrations
5. Post-upgrade: final health check, resume paused runners

### TTY-Aware Output
Terminal detected → animated spinners, progress bars with ETA. No terminal (CI) → plain text status.

## Testing

Tests use [BATS](https://github.com/bats-core/bats-core) (Bash Automated Testing System).

### Test Structure
- `tests/upgrade_path.bats` — Logic tests using `--dry-run` (path resolution, `--skip-latest`, `--version`)
- `tests/full_flow.bats` — Integration tests simulating full upgrade loops via mocks
- `tests/test_helper.bash` — Shared setup; prepends `tests/mocks/` to PATH, sets default version `16.11.0-ce.0`

### Mock System
Stateful mock binaries in `tests/mocks/` (curl, docker, df, du, id) shadow real binaries via PATH priority. Docker mock tracks version state through `MOCK_STATE_DIR/current_version` file, enabling multi-step upgrade simulation. Curl mock routes URLs to fixture files.

### Fixtures
- `tests/fixtures/path.json` — Pre-computed upgrade path waypoints (major.minor stops)
- `tests/fixtures/dockerhub_*.json` — Docker Hub API response fixtures per major version

## CI Pipeline (.gitlab-ci.yml)

Stages: `lint` → `test` → `promote`

- **shellcheck**: Lints on develop, master, MRs
- **logic-test**: Runs `bats tests/` with kcov coverage on develop, master, MRs
- **integration-test**: Spins up real GitLab container, runs full upgrade (schedule/manual only, self-hosted runner, 6h timeout)
- **promote-to-master**: Auto-pushes develop → master (official project only, uses `PUSH_TOKEN`)

## Key Flags

`-y` auto-confirm | `--dry-run` compute path only | `--version=X[.Y[.Z]]` target version | `--skip-latest`/`--n-1` previous minor | `--no-step-limit` (CI only) | `--skip-lfs` skip LFS in backup | `--edition=ce|ee` | `--target-url` health check URL | `--discord-url` webhook
