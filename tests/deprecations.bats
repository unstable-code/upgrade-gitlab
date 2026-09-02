#!/usr/bin/env bats
# Unit tests for the reconfigure deprecation collector (issue #13).
# The helpers are source-extracted with sed, mirroring the preflight.bats pattern;
# the collector state lives in globals, so setup() re-seeds them per test.

setup() {
    load test_helper
    eval "$(sed -n '/^_extract_deprecations()/,/^}/p' "$PROJECT_ROOT/upgrade-gitlab")"
    eval "$(sed -n '/^_record_deprecations()/,/^}/p' "$PROJECT_ROOT/upgrade-gitlab")"
    eval "$(sed -n '/^print_deprecation_summary()/,/^}/p' "$PROJECT_ROOT/upgrade-gitlab")"
    eval "$(sed -n '/^_deprecation_discord_note()/,/^}/p' "$PROJECT_ROOT/upgrade-gitlab")"
    declare -gA _deprecation_first_seen=()
    _deprecation_order=()
    # No terminal: keeps the summary free of escape sequences so tests compare plain text.
    _tty=/dev/null
    LOG="$BATS_TEST_TMPDIR/reconfigure.log"
}

# ---------- _extract_deprecations ----------
@test "_extract_deprecations: pulls the block and stops at the blank line" {
    cat > "$LOG" <<'EOF'
Recipe: gitlab::default
  * execute[reload nginx] action run

Deprecations:
nginx['listen_https'] has been deprecated. Please use gitlab_rails['nginx']['listen_https'] instead.
nginx['listen_port'] has been deprecated. Please use gitlab_rails['nginx']['listen_port'] instead.

Running handlers complete
EOF
    out=$(_extract_deprecations < "$LOG")
    [ "$(echo "$out" | wc -l)" -eq 2 ]
    [[ "$out" == *"nginx['listen_https'] has been deprecated"* ]]
    [[ "$out" != *"Running handlers"* ]]
    [[ "$out" != *"Recipe: gitlab::default"* ]]
}

@test "_extract_deprecations: stops at the next chef section without a blank line" {
    cat > "$LOG" <<'EOF'
Deprecations:
foo['a'] has been deprecated.
Running handlers complete
Chef Infra Client finished, 3/912 resources updated
EOF
    out=$(_extract_deprecations < "$LOG")
    [ "$out" = "foo['a'] has been deprecated." ]
}

@test "_extract_deprecations: trims surrounding whitespace on entries" {
    printf 'Deprecations:\n    indented["x"] has been deprecated.   \n\n' > "$LOG"
    out=$(_extract_deprecations < "$LOG")
    [ "$out" = 'indented["x"] has been deprecated.' ]
}

@test "_extract_deprecations: empty output when no Deprecations header is present" {
    printf 'Recipe: gitlab::default\nRunning handlers complete\n' > "$LOG"
    out=$(_extract_deprecations < "$LOG")
    [ -z "$out" ]
}

# ---------- _record_deprecations ----------
@test "_record_deprecations: de-duplicates across hops and keeps the first version" {
    printf "Deprecations:\nnginx['listen_port'] has been deprecated.\n\n" > "$LOG"
    _record_deprecations "17.11.3-ce.0" "$LOG"
    # Same warning again on the next hop, plus a new one.
    printf "Deprecations:\nnginx['listen_port'] has been deprecated.\nmattermost['enable'] has been deprecated.\n\n" > "$LOG"
    _record_deprecations "18.0.1-ce.0" "$LOG"

    [ "${#_deprecation_order[@]}" -eq 2 ]
    [ "${_deprecation_first_seen["nginx['listen_port'] has been deprecated."]}" = "17.11.3-ce.0" ]
    [ "${_deprecation_first_seen["mattermost['enable'] has been deprecated."]}" = "18.0.1-ce.0" ]
}

@test "_record_deprecations: missing file is a silent no-op" {
    run _record_deprecations "17.11.3-ce.0" "$BATS_TEST_TMPDIR/nope.log"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "${#_deprecation_order[@]}" -eq 0 ]
}

# ---------- print_deprecation_summary ----------
@test "print_deprecation_summary: prints nothing when nothing was collected" {
    run print_deprecation_summary
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "print_deprecation_summary: reports count and first-seen version per entry" {
    printf "Deprecations:\nnginx['listen_port'] has been deprecated.\n\n" > "$LOG"
    _record_deprecations "17.11.3-ce.0" "$LOG"
    run print_deprecation_summary
    [ "$status" -eq 0 ]
    [[ "$output" == *"reconfigure (1)"* ]]
    [[ "$output" == *"[17.11.3-ce.0] nginx['listen_port'] has been deprecated."* ]]
}

# ---------- _deprecation_discord_note ----------
@test "_deprecation_discord_note: truncates to the first few and counts the rest" {
    printf 'Deprecations:\na has been deprecated.\nb has been deprecated.\nc has been deprecated.\nd has been deprecated.\ne has been deprecated.\n\n' > "$LOG"
    _record_deprecations "17.11.3-ce.0" "$LOG"
    out=$(_deprecation_discord_note)
    [[ "$out" == *"5 deprecation(s)"* ]]
    [[ "$out" == *"- a has been deprecated."* ]]
    [[ "$out" == *"- c has been deprecated."* ]]
    [[ "$out" != *"- d has been deprecated."* ]]
    [[ "$out" == *"and 2 more"* ]]
}

@test "_deprecation_discord_note: no 'more' suffix when everything fits" {
    printf 'Deprecations:\na has been deprecated.\nb has been deprecated.\n\n' > "$LOG"
    _record_deprecations "17.11.3-ce.0" "$LOG"
    out=$(_deprecation_discord_note)
    [[ "$out" == *"2 deprecation(s)"* ]]
    [[ "$out" != *"more"* ]]
}
