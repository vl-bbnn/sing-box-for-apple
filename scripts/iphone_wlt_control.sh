#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
timestamp="$(date '+%Y-%m-%d-%H%M%S')"
artifact_root="${WLT_TEST_ARTIFACT_ROOT:-$repo_root/.local/wlt-test-artifacts}"
artifact_dir="${WLT_CONTROL_ARTIFACT_DIR:-$artifact_root/wlt-device-control-$timestamp}"
timeout_seconds="${WLT_CONTROL_TIMEOUT_SECONDS:-40}"

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
    if hardware.get("deviceType") == "iPhone" and connection.get("pairingState") == "paired":
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
        ping|probe|start|start-probe|status|stop) ;;
        *) die "usage: $0 <ping|probe|start|start-probe|status|stop>" ;;
    esac
    [[ -n "${WLT_APP_BUNDLE_ID:-}" ]] || die "set WLT_APP_BUNDLE_ID to the installed SFI Dev bundle identifier"
    [[ "$WLT_APP_BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]] || die "WLT_APP_BUNDLE_ID has an invalid format"
    validate_integer "$timeout_seconds" "WLT_CONTROL_TIMEOUT_SECONDS"

    mkdir -p "$artifact_dir"
    local device request_id result_name remote_result local_result deadline copy_log
    device="$(device_id)"
    request_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    result_name="$request_id.json"
    remote_result="Library/Caches/wlt-test-control/$result_name"
    local_result="$artifact_dir/$result_name"
    copy_log="$artifact_dir/devicectl-copy.log"
    deadline=$((SECONDS + timeout_seconds))

    log "sending $action through CoreDevice (no XCTest/UI Automation)"
    xcrun devicectl device process launch \
        --device "$device" \
        --payload-url "sing-box://wlt-test-control/$action?request=$request_id" \
        --activate \
        --timeout 20 \
        --json-output "$artifact_dir/launch.json" \
        "$WLT_APP_BUNDLE_ID" >"$artifact_dir/launch.log" 2>&1 \
        || die "CoreDevice launch failed; see $artifact_dir/launch.log"

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

    /usr/bin/python3 - "$local_result" "$request_id" "$action" <<'PY'
import json
import sys

path, request_id, action = sys.argv[1:]
result = json.load(open(path))
if result.get("schema") != 1:
    raise SystemExit("unexpected result schema")
if result.get("request_id") != request_id:
    raise SystemExit("result request mismatch")
if result.get("action") != action:
    raise SystemExit("result action mismatch")

allowed = {
    "action": result.get("action"),
    "state": result.get("state"),
    "vpn_status": result.get("vpn_status"),
    "elapsed_ms": result.get("elapsed_ms"),
    "error_domain": result.get("error_domain"),
    "error_code": result.get("error_code"),
}
print(json.dumps(allowed, sort_keys=True, separators=(",", ":")))
if result.get("state") != "succeeded":
    raise SystemExit(1)
PY
    log "artifact: $artifact_dir"
}

run "$@"
