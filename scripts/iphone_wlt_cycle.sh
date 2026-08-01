#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
scenario_runner="${WLT_CYCLE_SCENARIO_RUNNER:-$script_dir/iphone_wlt_scenario.sh}"
artifact_root="${WLT_TEST_ARTIFACT_ROOT:-$repo_root/.local/wlt-test-artifacts}"
runs="${WLT_CYCLE_RUNS:-1}"
pause_seconds="${WLT_CYCLE_PAUSE_SECONDS:-5}"
continue_on_failure="${WLT_CYCLE_CONTINUE_ON_FAILURE:-0}"
heartbeat_seconds="${WLT_CYCLE_HEARTBEAT_SECONDS:-30}"
timestamp="$(date '+%Y-%m-%d-%H%M%S')"
cycle_dir="${WLT_CYCLE_ARTIFACT_DIR:-$artifact_root/wlt-device-cycle-$timestamp}"
initial_skip_build="${WLT_SCENARIO_SKIP_BUILD:-0}"
lock_dir="${WLT_CYCLE_LOCK_DIR:-$artifact_root/.iphone-wlt-cycle.lock}"
heartbeat_pid=""
candidate_label="${WLT_CANDIDATE_LABEL:-unlabeled}"
optimization_parameter="${WLT_OPTIMIZATION_PARAMETER:-}"
optimization_value="${WLT_OPTIMIZATION_VALUE:-}"
expected_core_sha="${WLT_EXPECTED_CORE_SHA:-}"

die() {
    printf '[wlt-device-cycle] error: %s\n' "$*" >&2
    exit 1
}

terminate_process_tree() {
    local parent="$1"
    local child
    while IFS= read -r child; do
        [[ -n "$child" ]] || continue
        terminate_process_tree "$child"
    done < <(pgrep -P "$parent" 2>/dev/null || true)
    kill -TERM "$parent" >/dev/null 2>&1 || true
}

[[ "$runs" =~ ^[1-9][0-9]*$ ]] || die "WLT_CYCLE_RUNS must be a positive integer"
[[ "$pause_seconds" =~ ^[0-9]+$ ]] || die "WLT_CYCLE_PAUSE_SECONDS must be a non-negative integer"
[[ "$heartbeat_seconds" =~ ^[1-9][0-9]*$ ]] || die "WLT_CYCLE_HEARTBEAT_SECONDS must be a positive integer"
[[ -x "$scenario_runner" ]] || die "scenario runner is not executable: $scenario_runner"
if [[ -n "$expected_core_sha" ]]; then
    [[ "$expected_core_sha" =~ ^[0-9a-f]{40}$ ]] || die "WLT_EXPECTED_CORE_SHA must be a 40-character commit SHA"
    marker="$repo_root/build/libbox/dev/Libbox.xcframework/.libbox-source-ref"
    [[ -f "$marker" ]] || die "Apple Libbox source marker is missing: $marker"
    [[ "$(<"$marker")" == "$expected_core_sha" ]] || die "Apple Libbox core marker does not match WLT_EXPECTED_CORE_SHA"
fi

cleanup() {
    if [[ -n "$heartbeat_pid" ]]; then
        terminate_process_tree "$heartbeat_pid"
        wait "$heartbeat_pid" >/dev/null 2>&1 || true
    fi
    rm -f "$lock_dir/pid"
    rmdir "$lock_dir" >/dev/null 2>&1 || true
}

acquire_lock() {
    if mkdir "$lock_dir" 2>/dev/null; then
        printf '%s\n' "$$" >"$lock_dir/pid"
        return
    fi
    local owner=""
    [[ -f "$lock_dir/pid" ]] && owner="$(<"$lock_dir/pid")"
    if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" >/dev/null 2>&1; then
        die "another iPhone WLT cycle is already running with pid=$owner"
    fi
    rm -f "$lock_dir/pid"
    rmdir "$lock_dir" >/dev/null 2>&1 || die "stale cycle lock could not be removed: $lock_dir"
    mkdir "$lock_dir"
    printf '%s\n' "$$" >"$lock_dir/pid"
}

write_progress() {
    local state="$1"
    local run="$2"
    local detail="$3"
    local temporary="$cycle_dir/.cycle-progress.$$"
    printf 'timestamp_utc\tpid\tstate\trun\tdetail\n%s\t%s\t%s\t%s\t%s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$$" "$state" "$run" "$detail" >"$temporary"
    mv "$temporary" "$cycle_dir/cycle-progress.tsv"
}

start_heartbeat() {
    local run="$1"
    local detail="$2"
    local parent="$$"
    (
        while kill -0 "$parent" >/dev/null 2>&1; do
            write_progress running "$run" "$detail"
            sleep "$heartbeat_seconds"
        done
    ) &
    heartbeat_pid=$!
}

stop_heartbeat() {
    [[ -n "$heartbeat_pid" ]] || return
    terminate_process_tree "$heartbeat_pid"
    wait "$heartbeat_pid" >/dev/null 2>&1 || true
    heartbeat_pid=""
}

acquire_lock
trap cleanup EXIT

mkdir -p "$cycle_dir"
status_file="$cycle_dir/cycle-status.tsv"
printf 'run\texit_status\tclassification\tartifact_dir\n' >"$status_file"
python3 - "$cycle_dir/cycle-metadata.json" "$candidate_label" "$optimization_parameter" "$optimization_value" "$expected_core_sha" <<'PY'
import json
import pathlib
import sys

output, label, parameter, value, core_sha = sys.argv[1:]
pathlib.Path(output).write_text(json.dumps({
    "candidate_label": label,
    "optimization_parameter": parameter or None,
    "optimization_value": value or None,
    "expected_core_sha": core_sha or None,
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

overall_status=0
for ((run = 1; run <= runs; run++)); do
    run_dir="$cycle_dir/run-$(printf '%02d' "$run")"
    skip_build="$initial_skip_build"
    if ((run > 1)); then
        skip_build=1
    fi

    printf '[wlt-device-cycle] run %s/%s\n' "$run" "$runs" >&2
    start_heartbeat "$run" "$(basename "$scenario_runner")"
    status=0
    WLT_SCENARIO_SKIP_BUILD="$skip_build" \
    WLT_SCENARIO_ARTIFACT_DIR="$run_dir" \
        "$scenario_runner" || status=$?
    stop_heartbeat

    classification="missing_result"
    if [[ -f "$run_dir/result.json" ]]; then
        classification="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["classification"])' "$run_dir/result.json")"
    fi
    printf '%s\t%s\t%s\t%s\n' "$run" "$status" "$classification" "$run_dir" >>"$status_file"
    write_progress completed "$run" "$classification"

    if ((status != 0)); then
        overall_status="$status"
        if [[ "$continue_on_failure" != "1" ]]; then
            break
        fi
    fi
    if ((run < runs && pause_seconds > 0)); then
        sleep "$pause_seconds"
    fi
done

printf '%s\n' "$cycle_dir"
exit "$overall_status"
