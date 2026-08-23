#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
timestamp="$(date '+%Y-%m-%d-%H%M%S')"
artifact_root="${WLT_TEST_ARTIFACT_ROOT:-$repo_root/.local/wlt-test-artifacts}"
artifact_dir="${WLT_CONTROL_ARTIFACT_DIR:-$artifact_root/wlt-device-control-$timestamp}"
timeout_seconds="${WLT_CONTROL_TIMEOUT_SECONDS:-40}"
launch_timeout_seconds="${WLT_CONTROL_LAUNCH_TIMEOUT_SECONDS:-30}"
candidate_file="${WLT_CONTROL_CANDIDATE_FILE:-}"
workload_file="${WLT_CONTROL_WORKLOAD_FILE:-}"
soak_seconds="${WLT_CONTROL_SOAK_SECONDS:-1800}"
soak_interval_seconds="${WLT_CONTROL_SOAK_INTERVAL_SECONDS:-30}"

log() {
    printf '[wlt-device-control] %s\n' "$*" >&2
}

die() {
    printf '[wlt-device-control] error: %s\n' "$*" >&2
    exit 1
}

device_id() {
    if [[ -n "${DEVICE_ID:-}" ]]; then
        printf '%s\n' "$DEVICE_ID"
        return
    fi

    local json_path="$artifact_dir/devices.json"
    xcrun devicectl list devices --json-output "$json_path" >/dev/null
    /usr/bin/python3 - "$json_path" <<'PY'
import json
import sys

devices = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])
matches = []
for device in devices:
    hardware = device.get("hardwareProperties", {})
    connection = device.get("connectionProperties", {})
    if (
        hardware.get("deviceType") == "iPhone"
        and connection.get("pairingState") == "paired"
        and connection.get("tunnelState") == "connected"
    ):
        matches.append(device)
if len(matches) != 1:
    raise SystemExit(
        f"expected exactly one paired iPhone, found {len(matches)}; connect it or set DEVICE_ID"
    )
print(matches[0]["identifier"])
PY
}

validate_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]] || die "$2 must be a positive integer"
}

run() {
    local action="${1:-}"
    case "$action" in
        ping|probe|refresh-profile|start|start-probe|status|stop|soak|workload) ;;
        *) die "usage: $0 <ping|probe|refresh-profile|start|start-probe|status|stop|soak|workload>" ;;
    esac
    [[ -n "${WLT_APP_BUNDLE_ID:-}" ]] || die "set WLT_APP_BUNDLE_ID to the installed SFI Dev bundle identifier"
    [[ "$WLT_APP_BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]] || die "WLT_APP_BUNDLE_ID has an invalid format"
    validate_integer "$timeout_seconds" "WLT_CONTROL_TIMEOUT_SECONDS"
    validate_integer "$launch_timeout_seconds" "WLT_CONTROL_LAUNCH_TIMEOUT_SECONDS"
    if [[ "$action" == "soak" ]]; then
        validate_integer "$soak_seconds" "WLT_CONTROL_SOAK_SECONDS"
        validate_integer "$soak_interval_seconds" "WLT_CONTROL_SOAK_INTERVAL_SECONDS"
        (( soak_seconds >= 5 && soak_seconds <= 1800 )) \
            || die "WLT_CONTROL_SOAK_SECONDS must be between 5 and 1800"
        (( soak_interval_seconds <= 300 && soak_interval_seconds <= soak_seconds )) \
            || die "WLT_CONTROL_SOAK_INTERVAL_SECONDS must be at most 300 and no greater than soak duration"
        if (( timeout_seconds <= soak_seconds )); then
            timeout_seconds=$((soak_seconds + 60))
        fi
    fi
    if [[ -n "$candidate_file" ]]; then
        [[ "$action" == "start" || "$action" == "start-probe" ]] \
            || die "WLT_CONTROL_CANDIDATE_FILE is valid only for start/start-probe"
        [[ -f "$candidate_file" ]] || die "missing candidate file: $candidate_file"
        /usr/bin/python3 - "$candidate_file" <<'PY'
import json
import sys

path = sys.argv[1]
value = json.load(open(path))
keys = {
    "max_active",
    "max_open",
    "dns_open_reserve",
    "max_pending",
    "queue_timeout",
    "idle_timeout",
    "peer_write_buffer",
    "kcp_window",
    "kcp_buffer",
}
if not isinstance(value, dict) or set(value) != {"parameters"}:
    raise SystemExit("candidate must contain only the parameters object")
parameters = value["parameters"]
if not isinstance(parameters, dict) or set(parameters) != keys:
    raise SystemExit("candidate parameters must contain the exact runtime schema")
PY
    fi

    if [[ -n "$workload_file" ]]; then
        [[ "$action" == "workload" ]] \
            || die "WLT_CONTROL_WORKLOAD_FILE is valid only for workload"
        [[ -f "$workload_file" ]] || die "missing workload file: $workload_file"
        /usr/bin/python3 - "$workload_file" <<'PY'
import json
import re
import sys
from urllib.parse import urlsplit

value = json.load(open(sys.argv[1]))
required_workload = {"schema", "route", "probes"}
workload_keys = set(value) if isinstance(value, dict) else set()
if (
    not isinstance(value, dict)
    or not required_workload.issubset(value)
    or workload_keys not in (required_workload, required_workload | {"select_route"})
):
    raise SystemExit("workload must contain schema, route, probes, and optional select_route")
if value["schema"] != 1 or value["route"] != "eu":
    raise SystemExit("workload must use schema 1 and the eu route")
if "select_route" in value and not isinstance(value["select_route"], bool):
    raise SystemExit("workload select_route must be boolean")
probes = value["probes"]
if not isinstance(probes, list) or not 1 <= len(probes) <= 32:
    raise SystemExit("workload must contain 1..32 probes")
names = set()
for probe in probes:
    required = {"name", "url", "minimum_bytes", "timeout_seconds", "accepted_status_codes"}
    if not isinstance(probe, dict) or set(probe) != required:
        raise SystemExit("workload probe schema mismatch")
    name = probe["name"]
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", name):
        raise SystemExit("invalid workload probe name")
    if name in names:
        raise SystemExit("duplicate workload probe name")
    names.add(name)
    parsed = urlsplit(probe["url"])
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise SystemExit("workload probes require credential-free HTTPS URLs")
    if not isinstance(probe["minimum_bytes"], int) or not 0 <= probe["minimum_bytes"] <= 4_194_304:
        raise SystemExit("invalid workload minimum_bytes")
    if not isinstance(probe["timeout_seconds"], int) or not 1 <= probe["timeout_seconds"] <= 180:
        raise SystemExit("invalid workload timeout_seconds")
    statuses = probe["accepted_status_codes"]
    if not isinstance(statuses, list) or any(not isinstance(code, int) or not 100 <= code <= 599 for code in statuses):
        raise SystemExit("invalid workload accepted_status_codes")
PY
    elif [[ "$action" == "workload" ]]; then
        die "WLT_CONTROL_WORKLOAD_FILE is required for workload"
    fi

    mkdir -p "$artifact_dir"
    local device request_id result_name remote_result remote_candidate remote_workload local_result deadline copy_log payload_url
    device="$(device_id)"
    request_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    result_name="$request_id.json"
    remote_result="Library/Caches/wlt-test-control/$result_name"
    remote_candidate="Library/Caches/wlt-test-candidate-$result_name"
    remote_workload="Library/Caches/wlt-test-workload-$result_name"
    local_result="$artifact_dir/$result_name"
    copy_log="$artifact_dir/devicectl-copy.log"
    deadline=$((SECONDS + timeout_seconds))

    if [[ -n "$candidate_file" ]]; then
        log "copying validated runtime parameters to the Dev app container"
        xcrun devicectl device copy to \
            --device "$device" \
            --domain-type appDataContainer \
            --domain-identifier "$WLT_APP_BUNDLE_ID" \
            --source "$candidate_file" \
            --destination "$remote_candidate" \
            --timeout 10 \
            --json-output "$artifact_dir/candidate-copy.json" \
            >"$artifact_dir/candidate-copy.log" 2>&1 \
            || die "candidate copy failed; see $artifact_dir/candidate-copy.log"
    fi

    if [[ -n "$workload_file" ]]; then
        log "copying validated EU workload plan to the Dev app container"
        xcrun devicectl device copy to \
            --device "$device" \
            --domain-type appDataContainer \
            --domain-identifier "$WLT_APP_BUNDLE_ID" \
            --source "$workload_file" \
            --destination "$remote_workload" \
            --timeout 10 \
            --json-output "$artifact_dir/workload-copy.json" \
            >"$artifact_dir/workload-copy.log" 2>&1 \
            || die "workload copy failed; see $artifact_dir/workload-copy.log"
    fi

    payload_url="sing-box://wlt-test-control/$action?request=$request_id"
    if [[ "$action" == "soak" ]]; then
        payload_url="$payload_url&duration=$soak_seconds&interval=$soak_interval_seconds"
    fi
    log "sending $action through CoreDevice (no XCTest/UI Automation)"
    if [[ "$action" == "stop" ]]; then
        xcrun devicectl device process launch \
            --device "$device" \
            --terminate-existing \
            --payload-url "$payload_url" \
            --activate \
            --timeout "$launch_timeout_seconds" \
            --json-output "$artifact_dir/launch.json" \
            "$WLT_APP_BUNDLE_ID" >"$artifact_dir/launch.log" 2>&1 \
            || die "CoreDevice launch failed; see $artifact_dir/launch.log"
    else
        xcrun devicectl device process launch \
            --device "$device" \
            --payload-url "$payload_url" \
            --activate \
            --timeout "$launch_timeout_seconds" \
            --json-output "$artifact_dir/launch.json" \
            "$WLT_APP_BUNDLE_ID" >"$artifact_dir/launch.log" 2>&1 \
            || die "CoreDevice launch failed; see $artifact_dir/launch.log"
    fi

    while (( SECONDS < deadline )); do
        if xcrun devicectl device copy from \
            --device "$device" \
            --domain-type appDataContainer \
            --domain-identifier "$WLT_APP_BUNDLE_ID" \
            --source "$remote_result" \
            --destination "$local_result" \
            --timeout 5 >"$copy_log" 2>&1
        then
            break
        fi
        sleep 0.2
    done
    [[ -f "$local_result" ]] || die "timed out waiting for the sanitized result; see $artifact_dir"

    /usr/bin/python3 - "$local_result" "$request_id" "$action" "$candidate_file" <<'PY'
import json
import sys

path, request_id, action, candidate_path = sys.argv[1:]
result = json.load(open(path))
if result.get("schema") not in {1, 2, 3, 4, 5}:
    raise SystemExit("unexpected result schema")
if result.get("request_id") != request_id:
    raise SystemExit("result request mismatch")
if result.get("action") != action:
    raise SystemExit("result action mismatch")

allowed = {
    "action": result.get("action"),
    "state": result.get("state"),
    "vpn_status": result.get("vpn_status"),
    "received_at_unix_ms": result.get("received_at_unix_ms"),
    "finished_at_unix_ms": result.get("finished_at_unix_ms"),
    "elapsed_ms": result.get("elapsed_ms"),
    "vpn_startup_ms": result.get("vpn_startup_ms"),
    "probe_elapsed_ms": result.get("probe_elapsed_ms"),
    "soak_elapsed_ms": result.get("soak_elapsed_ms"),
    "soak_samples": result.get("soak_samples"),
    "soak_successes": result.get("soak_successes"),
    "soak_failures": result.get("soak_failures"),
    "soak_probe_samples": result.get("soak_probe_samples"),
    "network_loss_observed": result.get("network_loss_observed"),
    "network_recovered": result.get("network_recovered"),
    "startup_milestones": result.get("startup_milestones"),
    "runtime_parameters": result.get("runtime_parameters"),
    "workload_route": result.get("workload_route"),
    "workload_probes": result.get("workload_probes"),
    "network_initial": result.get("network_initial"),
    "network_final": result.get("network_final"),
    "error_domain": result.get("error_domain"),
    "error_code": result.get("error_code"),
}
if candidate_path and result.get("state") == "succeeded":
    expected = json.load(open(candidate_path))["parameters"]
    if result.get("runtime_parameters") != expected:
        raise SystemExit("runtime candidate evidence mismatch")
print(json.dumps(allowed, sort_keys=True, separators=(",", ":")))
if result.get("state") != "succeeded":
    raise SystemExit(1)
PY
    log "artifact: $artifact_dir"
}

run "$@"
