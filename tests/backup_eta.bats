#!/usr/bin/env bats
# Unit tests for the backup progress ETA formatting helpers (issue #7).
# These are pure functions, so we source just their definitions out of the script
# rather than driving the whole upgrade flow.

setup() {
    load test_helper
    eval "$(sed -n '/^_fmt_duration()/,/^}/p' "$PROJECT_ROOT/upgrade-gitlab")"
    eval "$(sed -n '/^_backup_progress_extra()/,/^}/p' "$PROJECT_ROOT/upgrade-gitlab")"
}

# ---------- _fmt_duration: always hh:mm:ss (unambiguous, fixed-width, consistent) ----------
@test "_fmt_duration: under 1h still renders 00:mm:ss" {
    [ "$(_fmt_duration 9)" = "00:00:09" ]
    [ "$(_fmt_duration 754)" = "00:12:34" ]
    [ "$(_fmt_duration 1827)" = "00:30:27" ]
    [ "$(_fmt_duration 3599)" = "00:59:59" ]
}

@test "_fmt_duration: 1h+ renders hh:mm:ss" {
    [ "$(_fmt_duration 3600)" = "01:00:00" ]
    [ "$(_fmt_duration 5025)" = "01:23:45" ]
}

# ---------- _backup_progress_extra: dump phases ----------
@test "_backup_progress_extra: dump shows ETA when pct>1 and elapsed>=5" {
    # eta = 754 * (100-47) / 47 = 850s -> 00:14:10
    [ "$(_backup_progress_extra 0 47 754)" = " ETA 00:14:10" ]
}

@test "_backup_progress_extra: dump suppresses ETA when elapsed<5" {
    [ "$(_backup_progress_extra 0 47 4)" = "" ]
}

@test "_backup_progress_extra: dump suppresses ETA when pct<=1" {
    [ "$(_backup_progress_extra 0 1 60)" = "" ]
    [ "$(_backup_progress_extra 0 0 60)" = "" ]
}

@test "_backup_progress_extra: dump suppresses ETA when pct>=100" {
    [ "$(_backup_progress_extra 0 100 60)" = "" ]
}

# ---------- _backup_progress_extra: upload phase (approx, ~ prefix; no elapsed) ----------
@test "_backup_progress_extra: upload shows approx ETA with ~ prefix" {
    # eta = 60 * (100-50) / 50 = 60s -> 00:01:00
    [ "$(_backup_progress_extra 1 50 60)" = " ETA ~00:01:00" ]
}

@test "_backup_progress_extra: upload suppresses ETA when pct too low" {
    [ "$(_backup_progress_extra 1 1 60)" = "" ]
}
