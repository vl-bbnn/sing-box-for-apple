#!/usr/bin/env bash

set -euo pipefail
umask 077

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
bounded_runner="$script_dir/run_bounded.py"
timestamp="$(date '+%Y-%m-%d-%H%M%S')"
artifact_root="${WLT_TEST_ARTIFACT_ROOT:-$repo_root/.local/wlt-test-artifacts}"
artifact_dir="${WLT_CONTROL_ARTIFACT_DIR:-$artifact_root/wlt-device-control-$timestamp}"
timeout_seconds="${WLT_CONTROL_TIMEOUT_SECONDS:-40}"
launch_timeout_seconds="${WLT_CONTROL_LAUNCH_TIMEOUT_SECONDS:-30}"
copy_timeout_seconds="${WLT_CONTROL_COPY_TIMEOUT_SECONDS:-30}"
candidate_file="${WLT_CONTROL_CANDIDATE_FILE:-}"
workload_file="${WLT_CONTROL_WORKLOAD_FILE:-}"
explicit_wlt_plan_file="${WLT_CONTROL_EXPLICIT_SAVED_WLT_PLAN_FILE:-}"
profile_file="${WLT_CONTROL_PROFILE_FILE:-}"
profile_export_file="${WLT_CONTROL_PROFILE_EXPORT_FILE:-}"
state_export_dir="${WLT_CONTROL_STATE_EXPORT_DIR:-}"
identity_ring_dir="${WLT_CONTROL_IDENTITY_RING_DIR:-}"
soak_seconds="${WLT_CONTROL_SOAK_SECONDS:-1800}"
soak_interval_seconds="${WLT_CONTROL_SOAK_INTERVAL_SECONDS:-30}"
max_successful_reconnects="${WLT_CONTROL_MAX_SUCCESSFUL_RECONNECTS:-0}"
max_reconnect_retries="${WLT_CONTROL_MAX_RECONNECT_RETRIES:-0}"

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
    run_bounded "$copy_timeout_seconds" xcrun devicectl list devices \
        --json-output "$json_path" >/dev/null
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

retryable_coredevice_launch_failure() {
    /usr/bin/python3 - "$1" <<'PY'
import json
import sys

try:
    value = json.load(open(sys.argv[1]))
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)
error = value.get("error") or {}
underlying = ((error.get("userInfo") or {}).get("NSUnderlyingError") or {}).get("error") or {}
retryable = (
    (value.get("info") or {}).get("outcome") == "failed"
    and error.get("domain") == "com.apple.dt.CoreDeviceError"
    and (
        error.get("code") == 10004
        or (
            error.get("code") == 3
            and underlying.get("domain") == "com.apple.Mercury.error"
            and underlying.get("code") == 1001
        )
    )
)
raise SystemExit(0 if retryable else 1)
PY
}

# CoreDevice's --timeout is not a host-side guarantee. The helper gives each
# invocation its own process group and cleans the whole group on timeout or
# signal without touching unrelated CoreDevice/Xcode processes.
run_bounded() {
    local seconds="$1"; shift
    /usr/bin/python3 "$bounded_runner" "$seconds" -- "$@"
}

run() {
    local action="${1:-}"
    case "$action" in
        bootstrap-profile|upsert-profile|export-profile|export-state|select-profile|assert-merged-profile|ping|probe|refresh-profile|import-identity-ring|identity-ring-status|arm-identity-ring-fault|start|start-probe|status|group-status|route-diagnostics|stop|soak|workload|network-workload|explicit_saved_WLT_outbound_reachability) ;;
        *) die "usage: $0 <bootstrap-profile|upsert-profile|export-profile|export-state|select-profile|assert-merged-profile|ping|probe|refresh-profile|import-identity-ring|identity-ring-status|arm-identity-ring-fault|start|start-probe|status|group-status|route-diagnostics|stop|soak|workload|network-workload|explicit_saved_WLT_outbound_reachability>" ;;
    esac
    [[ -n "${WLT_APP_BUNDLE_ID:-}" ]] || die "set WLT_APP_BUNDLE_ID to the installed SFI Dev bundle identifier"
    [[ "$WLT_APP_BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]] || die "WLT_APP_BUNDLE_ID has an invalid format"
    if [[ "$action" == "select-profile" ]]; then
        [[ -n "${WLT_CONTROL_PROFILE_NAME:-}" ]] || die "WLT_CONTROL_PROFILE_NAME is required for select-profile"
        (( ${#WLT_CONTROL_PROFILE_NAME} <= 128 )) || die "WLT_CONTROL_PROFILE_NAME is too long"
    elif [[ -n "${WLT_CONTROL_PROFILE_NAME:-}" ]]; then
        die "WLT_CONTROL_PROFILE_NAME is valid only for select-profile"
    fi
    # Stop waits for the core owner before requesting OS disconnection.
    # Include room for CoreDevice delivery and result collection as well.
    if [[ "$action" == "stop" ]]; then
        timeout_seconds="${WLT_CONTROL_TIMEOUT_SECONDS:-240}"
    fi
    validate_integer "$timeout_seconds" "WLT_CONTROL_TIMEOUT_SECONDS"
    validate_integer "$launch_timeout_seconds" "WLT_CONTROL_LAUNCH_TIMEOUT_SECONDS"
    validate_integer "$copy_timeout_seconds" "WLT_CONTROL_COPY_TIMEOUT_SECONDS"
    [[ "$max_successful_reconnects" =~ ^[0-9]+$ ]] \
        || die "WLT_CONTROL_MAX_SUCCESSFUL_RECONNECTS must be a non-negative integer"
    [[ "$max_reconnect_retries" =~ ^[0-9]+$ ]] \
        || die "WLT_CONTROL_MAX_RECONNECT_RETRIES must be a non-negative integer"
    if (( max_successful_reconnects > 0 || max_reconnect_retries > 0 )) \
        && [[ "$action" != "workload" ]]; then
        die "WLT reconnect allowances are valid only for workload"
    fi
    if [[ "$action" == "soak" ]]; then
        validate_integer "$soak_seconds" "WLT_CONTROL_SOAK_SECONDS"
        validate_integer "$soak_interval_seconds" "WLT_CONTROL_SOAK_INTERVAL_SECONDS"
        (( soak_seconds >= 5 && soak_seconds <= 3600 )) \
            || die "WLT_CONTROL_SOAK_SECONDS must be between 5 and 3600"
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
runtime_keys = {
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
mux_keys = {
    "vless_mux_protocol",
    "vless_mux_max_connections",
    "vless_mux_min_streams",
}
if not isinstance(value, dict) or set(value) != {"parameters"}:
    raise SystemExit("candidate must contain only the parameters object")
parameters = value["parameters"]
parameter_keys = set(parameters) if isinstance(parameters, dict) else set()
if parameter_keys not in (runtime_keys, runtime_keys | mux_keys):
    raise SystemExit("candidate parameters must contain the exact runtime schema")
if parameter_keys == runtime_keys | mux_keys:
    protocol = parameters["vless_mux_protocol"]
    max_connections = parameters["vless_mux_max_connections"]
    min_streams = parameters["vless_mux_min_streams"]
    if protocol not in {"smux", "yamux", "h2mux"}:
        raise SystemExit("candidate VLESS mux protocol is invalid")
    if (
        isinstance(max_connections, bool)
        or not isinstance(max_connections, int)
        or max_connections <= 0
        or isinstance(min_streams, bool)
        or not isinstance(min_streams, int)
        or min_streams <= 0
    ):
        raise SystemExit("candidate VLESS mux limits must be positive integers")
PY
    fi

    if [[ -n "$explicit_wlt_plan_file" ]]; then
        [[ "$action" == "explicit_saved_WLT_outbound_reachability" ]] \
            || die "WLT_CONTROL_EXPLICIT_SAVED_WLT_PLAN_FILE is valid only for explicit_saved_WLT_outbound_reachability"
        [[ -z "$workload_file" ]] || die "explicit WLT plan and native workload plan are mutually exclusive"
        [[ -f "$explicit_wlt_plan_file" ]] || die "missing explicit WLT plan file"
        /usr/bin/python3 - "$explicit_wlt_plan_file" <<'PY'
import ipaddress
import json
import re
import sys

value = json.load(open(sys.argv[1]))
if not isinstance(value, dict) or set(value) != {"schema", "scope", "requests"}:
    raise SystemExit("explicit WLT plan schema mismatch")
if value["schema"] != 1 or value["scope"] != "explicit_saved_WLT_outbound_reachability":
    raise SystemExit("explicit WLT plan scope mismatch")
requests = value["requests"]
if not isinstance(requests, list) or len(requests) != 3:
    raise SystemExit("explicit WLT plan requires DNS, 204, and 1 MiB requests")
if [item.get("kind") for item in requests if isinstance(item, dict)] != ["dns", "https", "https"]:
    raise SystemExit("explicit WLT request order mismatch")
common = {"schema", "probe_id", "kind", "group_tag", "outbound_tag", "wlt_tag", "timeout_ms"}
ids = set()
for index, request in enumerate(requests):
    if not isinstance(request, dict) or request.get("schema") != 1:
        raise SystemExit("explicit WLT request schema mismatch")
    probe_id = request.get("probe_id")
    timeout = request.get("timeout_ms")
    if (not isinstance(probe_id, str)
            or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", probe_id) is None
            or probe_id in ids or isinstance(timeout, bool) or not isinstance(timeout, int)
            or not 1 <= timeout <= 90000):
        raise SystemExit("explicit WLT request identity or timeout mismatch")
    ids.add(probe_id)
    if index == 0:
        if set(request) != common | {"server", "query_name"}:
            raise SystemExit("explicit DNS request schema mismatch")
        if (request.get("group_tag"), request.get("outbound_tag"), request.get("wlt_tag")) != (
            "ru_or_wlt-ru", "vless-wlt-ru", "wlt-ru"
        ):
            raise SystemExit("explicit DNS saved graph mismatch")
        server = request.get("server")
        match = re.fullmatch(r"(?:\[([^]]+)\]|([^:]+)):([0-9]{1,5})", server or "")
        if not match:
            raise SystemExit("explicit DNS server must be a literal IP:port")
        try:
            ipaddress.ip_address(match.group(1) or match.group(2))
        except ValueError as error:
            raise SystemExit("explicit DNS server must be literal") from error
        if not 1 <= int(match.group(3)) <= 65535:
            raise SystemExit("explicit DNS port mismatch")
        query = request.get("query_name")
        if (not isinstance(query, str) or len(query) > 253
                or re.fullmatch(r"[A-Za-z0-9.-]+", query) is None
                or not query.lower().endswith(".vercel.app")):
            raise SystemExit("explicit DNS query mismatch")
    else:
        if set(request) != common | {"url", "expected_status", "expected_bytes", "max_read_bytes"}:
            raise SystemExit("explicit HTTPS request schema mismatch")
        if (request.get("group_tag"), request.get("outbound_tag"), request.get("wlt_tag")) != (
            "eu_or_wlt-eu", "vless-wlt-eu", "wlt-eu"
        ):
            raise SystemExit("explicit HTTPS saved graph mismatch")
        if index == 1:
            expected = ("https://cp.cloudflare.com/generate_204", 204, 0, 1)
            actual = (request.get("url"), request.get("expected_status"),
                      request.get("expected_bytes"), request.get("max_read_bytes"))
            if actual != expected:
                raise SystemExit("explicit 204 contract mismatch")
        else:
            if re.fullmatch(
                r"https://speed\.cloudflare\.com/__down\?bytes=1048576&seed=[A-Za-z0-9._-]{1,64}",
                request.get("url") or "",
            ) is None:
                raise SystemExit("explicit 1 MiB URL mismatch")
            if (request.get("expected_status"), request.get("expected_bytes"),
                    request.get("max_read_bytes")) != (200, 1048576, 1048577):
                raise SystemExit("explicit 1 MiB byte contract mismatch")
PY
        workload_file="$explicit_wlt_plan_file"
    elif [[ "$action" == "explicit_saved_WLT_outbound_reachability" ]]; then
        die "WLT_CONTROL_EXPLICIT_SAVED_WLT_PLAN_FILE is required for explicit_saved_WLT_outbound_reachability"
    fi

    if [[ -n "$workload_file" && "$action" != "explicit_saved_WLT_outbound_reachability" ]]; then
        [[ "$action" == "workload" || "$action" == "network-workload" ]] \
            || die "WLT_CONTROL_WORKLOAD_FILE is valid only for workload/network-workload"
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
    or workload_keys not in (
        required_workload,
        required_workload | {"select_route"},
        required_workload | {"required_transport"},
        required_workload | {"required_transport", "select_route"},
    )
):
    raise SystemExit("workload must contain schema, route, probes, and optional transport/selection")
if value["schema"] != 1 or value["route"] not in {"eu", "ru"}:
    raise SystemExit("workload must use schema 1 and a supported ru/eu route")
if "required_transport" in value and value["required_transport"] not in {"wifi", "cellular"}:
    raise SystemExit("workload required_transport must be wifi or cellular")
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
    elif [[ "$action" == "workload" || "$action" == "network-workload" ]]; then
        die "WLT_CONTROL_WORKLOAD_FILE is required for workload/network-workload"
    fi
    if [[ -n "$profile_file" ]]; then
        [[ "$action" == "bootstrap-profile" || "$action" == "upsert-profile" ]] \
            || die "WLT_CONTROL_PROFILE_FILE is valid only for bootstrap-profile/upsert-profile"
        [[ -f "$profile_file" ]] || die "missing profile plan file"
        /usr/bin/python3 - "$profile_file" <<'PY'
import json
import sys
from urllib.parse import urlsplit

value = json.load(open(sys.argv[1]))
if not isinstance(value, dict) or set(value) != {"schema", "name", "url"}:
    raise SystemExit("profile plan schema mismatch")
parsed = urlsplit(value["url"])
valid = (
    value["schema"] == 1
    and isinstance(value["name"], str)
    and 1 <= len(value["name"]) <= 128
    and isinstance(value["url"], str)
    and len(value["url"]) <= 2048
    and parsed.scheme == "https"
    and parsed.hostname
    and parsed.username is None
    and parsed.password is None
)
if not valid:
    raise SystemExit("invalid profile plan")
PY
    elif [[ "$action" == "bootstrap-profile" || "$action" == "upsert-profile" ]]; then
        die "WLT_CONTROL_PROFILE_FILE is required for bootstrap-profile/upsert-profile"
    fi
    if [[ "$action" == "export-profile" ]]; then
        [[ -n "$profile_export_file" ]] \
            || die "WLT_CONTROL_PROFILE_EXPORT_FILE is required for export-profile"
    elif [[ -n "$profile_export_file" ]]; then
        die "WLT_CONTROL_PROFILE_EXPORT_FILE is valid only for export-profile"
    fi
    if [[ "$action" == "export-state" ]]; then
        [[ -n "$state_export_dir" ]] || die "WLT_CONTROL_STATE_EXPORT_DIR is required for export-state"
        [[ ! -e "$state_export_dir" && ! -L "$state_export_dir" ]] \
            || die "WLT_CONTROL_STATE_EXPORT_DIR must not exist"
        [[ -n "${WLT_APP_GROUP_ID:-}" && "$WLT_APP_GROUP_ID" =~ ^[A-Za-z0-9.-]+$ ]] \
            || die "WLT_APP_GROUP_ID is required for export-state"
    elif [[ -n "$state_export_dir" || -n "${WLT_APP_GROUP_ID:-}" ]]; then
        die "state export variables are valid only for export-state"
    fi
    if [[ -n "$identity_ring_dir" ]]; then
        [[ "$action" == "import-identity-ring" ]] \
            || die "WLT_CONTROL_IDENTITY_RING_DIR is valid only for import-identity-ring"
        /usr/bin/python3 - "$identity_ring_dir" <<'PY'
import base64
import os
from pathlib import Path
import stat
import sys

root = Path(sys.argv[1])
if root.is_symlink() or not root.is_dir():
    raise SystemExit("identity ring import path must be a regular directory")
root_metadata = root.lstat()
if root_metadata.st_uid != os.getuid() or root_metadata.st_mode & 0o077:
    raise SystemExit("identity ring import directory must be owned and mode 0700")
expected = {
    "auth-snapshot.json.aesgcm",
    "auth-snapshot.json.reserve.aesgcm",
    "transfer-key.base64",
}
files = list(root.iterdir())
if {item.name for item in files} != expected:
    raise SystemExit("identity ring import must contain exactly active, reserve, and key files")
for item in files:
    metadata = item.lstat()
    if (
        item.is_symlink()
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_nlink != 1
        or metadata.st_mode & 0o077
    ):
        raise SystemExit("identity ring import inputs must be owned mode-0600 regular files")
    if item.name.endswith(".aesgcm") and not 28 <= metadata.st_size <= 512 * 1024:
        raise SystemExit("identity ring encrypted input size is invalid")
key = base64.b64decode((root / "transfer-key.base64").read_text().strip(), validate=True)
if len(key) != 32:
    raise SystemExit("identity ring transfer key must contain 32 bytes")
PY
    elif [[ "$action" == "import-identity-ring" ]]; then
        die "WLT_CONTROL_IDENTITY_RING_DIR is required for import-identity-ring"
    fi

    mkdir -p "$artifact_dir"
    local device request_id result_name remote_result remote_candidate remote_workload remote_profile remote_profile_export remote_state_export remote_identity_active remote_identity_reserve remote_identity_key local_result deadline copy_log payload_url
    device="$(device_id)"
    request_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    result_name="$request_id.json"
    remote_result="Library/Caches/wlt-test-control/$result_name"
    remote_candidate="Library/Caches/wlt-test-candidate-$result_name"
    remote_workload="Library/Caches/wlt-test-workload-$result_name"
    remote_profile="Library/Caches/wlt-test-profile-$result_name"
    remote_profile_export="Library/Caches/wlt-test-profile-export-$result_name"
    remote_state_export="Library/Caches/wlt-test-state-export-$request_id"
    remote_identity_active="Library/Caches/wlt-test-identity-ring-${request_id}-active.aesgcm"
    remote_identity_reserve="Library/Caches/wlt-test-identity-ring-${request_id}-reserve.aesgcm"
    remote_identity_key="Library/Caches/wlt-test-identity-ring-${request_id}-key.base64"
    local_result="$artifact_dir/$result_name"
    copy_log="$artifact_dir/devicectl-copy.log"
    deadline=$((SECONDS + timeout_seconds))

    cleanup_identity_transfer() {
        [[ -n "$identity_ring_dir" ]] || return 0
        local cleanup_dir="$artifact_dir/identity-transfer-cleanup"
        WLT_CONTROL_IDENTITY_RING_DIR= \
        WLT_CONTROL_ARTIFACT_DIR="$cleanup_dir" \
        "$0" ping >"$artifact_dir/identity-transfer-cleanup.stdout" \
            2>"$artifact_dir/identity-transfer-cleanup.stderr"
    }

    if [[ -n "$candidate_file" ]]; then
        log "copying validated runtime parameters to the Dev app container"
        run_bounded "$copy_timeout_seconds" xcrun devicectl device copy to \
            --device "$device" \
            --domain-type appDataContainer \
            --domain-identifier "$WLT_APP_BUNDLE_ID" \
            --source "$candidate_file" \
            --destination "$remote_candidate" \
            --timeout "$copy_timeout_seconds" \
            --json-output "$artifact_dir/candidate-copy.json" \
            >"$artifact_dir/candidate-copy.log" 2>&1 \
            || die "candidate copy failed; see $artifact_dir/candidate-copy.log"
    fi

    if [[ -n "$workload_file" ]]; then
        log "copying validated workload or explicit WLT plan to the Dev app container"
        run_bounded "$copy_timeout_seconds" xcrun devicectl device copy to \
            --device "$device" \
            --domain-type appDataContainer \
            --domain-identifier "$WLT_APP_BUNDLE_ID" \
            --source "$workload_file" \
            --destination "$remote_workload" \
            --timeout "$copy_timeout_seconds" \
            --json-output "$artifact_dir/workload-copy.json" \
            >"$artifact_dir/workload-copy.log" 2>&1 \
            || die "workload copy failed; see $artifact_dir/workload-copy.log"
    fi

    if [[ -n "$profile_file" ]]; then
        log "copying validated profile bootstrap plan to the Dev app container"
        run_bounded "$copy_timeout_seconds" xcrun devicectl device copy to \
            --device "$device" \
            --domain-type appDataContainer \
            --domain-identifier "$WLT_APP_BUNDLE_ID" \
            --source "$profile_file" \
            --destination "$remote_profile" \
            --timeout "$copy_timeout_seconds" \
            --json-output "$artifact_dir/profile-copy.json" \
            >"$artifact_dir/profile-copy.log" 2>&1 \
            || die "profile plan copy failed; see $artifact_dir/profile-copy.log"
    fi

    if [[ -n "$identity_ring_dir" ]]; then
        log "copying protected identity ring to the Dev app container"
        local identity_source identity_destination identity_label
        for identity_label in active reserve key; do
            case "$identity_label" in
                active)
                    identity_source="$identity_ring_dir/auth-snapshot.json.aesgcm"
                    identity_destination="$remote_identity_active"
                    ;;
                reserve)
                    identity_source="$identity_ring_dir/auth-snapshot.json.reserve.aesgcm"
                    identity_destination="$remote_identity_reserve"
                    ;;
                key)
                    identity_source="$identity_ring_dir/transfer-key.base64"
                    identity_destination="$remote_identity_key"
                    ;;
            esac
            if ! run_bounded "$copy_timeout_seconds" xcrun devicectl device copy to \
                --device "$device" \
                --domain-type appDataContainer \
                --domain-identifier "$WLT_APP_BUNDLE_ID" \
                --source "$identity_source" \
                --destination "$identity_destination" \
                --timeout "$copy_timeout_seconds" \
                --json-output "$artifact_dir/identity-$identity_label-copy.json" \
                >"$artifact_dir/identity-$identity_label-copy.log" 2>&1
            then
                cleanup_identity_transfer \
                    || die "identity ring copy failed and remote cleanup could not be proven"
                die "identity ring $identity_label copy failed; remote cleanup succeeded"
            fi
        done
    fi

    payload_url="sing-box://wlt-test-control/$action?request=$request_id"
    if [[ "$action" == "select-profile" ]]; then
        encoded_name="$(/usr/bin/python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$WLT_CONTROL_PROFILE_NAME")"
        payload_url="$payload_url&name=$encoded_name"
    fi
    if [[ "$action" == "soak" ]]; then
        payload_url="$payload_url&duration=$soak_seconds&interval=$soak_interval_seconds"
    fi
    log "sending $action through CoreDevice (no XCTest/UI Automation)"
    local launch_attempt launch_succeeded=0
    local -a launch_arguments=(
        xcrun devicectl device process launch
        --device "$device"
    )
    # Keep every control URL on the existing Dev app instance. CoreDevice
    # `--terminate-existing` kills the coordinator before the URL reaches the
    # provider, racing NetworkExtension teardown and leaving WLT journals open.
    launch_arguments+=(
        --payload-url "$payload_url"
        --activate
        --timeout "$launch_timeout_seconds"
        --json-output "$artifact_dir/launch.json"
        "$WLT_APP_BUNDLE_ID"
    )
    for launch_attempt in 1 2; do
        if run_bounded "$launch_timeout_seconds" "${launch_arguments[@]}" \
            >"$artifact_dir/launch.log" 2>&1; then
            launch_succeeded=1
            break
        fi
        if ((launch_attempt == 1)) \
            && retryable_coredevice_launch_failure "$artifact_dir/launch.json"; then
            cp "$artifact_dir/launch.json" "$artifact_dir/launch-attempt-1.json"
            cp "$artifact_dir/launch.log" "$artifact_dir/launch-attempt-1.log"
            log "CoreDevice remote XPC connection was invalidated before launch; retrying once"
            sleep 2
            continue
        fi
        break
    done
    if ((launch_succeeded == 0)); then
        cleanup_identity_transfer \
            || die "CoreDevice launch failed and identity transfer cleanup could not be proven"
        die "CoreDevice launch failed; identity transfer cleanup succeeded"
    fi

    while (( SECONDS < deadline )); do
        if run_bounded 7 xcrun devicectl device copy from \
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
    if [[ ! -f "$local_result" ]]; then
        cleanup_identity_transfer \
            || die "timed out and identity transfer cleanup could not be proven"
        die "timed out waiting for the sanitized result; identity transfer cleanup succeeded"
    fi

    if [[ "$action" == "export-profile" ]]; then
        run_bounded "$copy_timeout_seconds" xcrun devicectl device copy from \
            --device "$device" \
            --domain-type appDataContainer \
            --domain-identifier "$WLT_APP_BUNDLE_ID" \
            --source "$remote_profile_export" \
            --destination "$profile_export_file" \
            --timeout "$copy_timeout_seconds" \
            >"$artifact_dir/profile-export-copy.log" 2>&1 \
            || die "profile export copy failed; see $artifact_dir/profile-export-copy.log"
        chmod 600 "$profile_export_file"
    fi
    if [[ "$action" == "export-state" ]]; then
        run_bounded "$copy_timeout_seconds" xcrun devicectl device copy from \
            --device "$device" \
            --domain-type appGroupDataContainer \
            --domain-identifier "$WLT_APP_GROUP_ID" \
            --source "$remote_state_export" \
            --destination "$state_export_dir" \
            --timeout "$copy_timeout_seconds" \
            >"$artifact_dir/state-export-copy.log" 2>&1 \
            || die "state export copy failed; see $artifact_dir/state-export-copy.log"
        /usr/bin/python3 - "$state_export_dir" "$artifact_dir/state-export-sidecars.json" <<'PY'
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import sqlite3
import stat
import sys

root = Path(sys.argv[1])
sidecar_evidence_path = Path(sys.argv[2])
if root.is_symlink() or not root.is_dir():
    raise SystemExit("state export is not a regular directory")
actual = set()
for item in root.rglob("*"):
    metadata = item.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not (stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode)):
        raise SystemExit("state export contains an unsafe entry")
    if metadata.st_uid != os.getuid() or (stat.S_ISREG(metadata.st_mode) and metadata.st_nlink != 1):
        raise SystemExit("state export contains unsafe ownership or links")
    relative = item.relative_to(root).as_posix()
    if any(part in {"", ".", ".."} for part in PurePosixPath(relative).parts):
        raise SystemExit("state export contains an unsafe path")
    item.chmod(0o700 if stat.S_ISDIR(metadata.st_mode) else 0o600)
    if stat.S_ISREG(metadata.st_mode):
        actual.add(relative)
manifest_path = root / "manifest.json"
manifest = json.loads(manifest_path.read_text())
if not isinstance(manifest, dict) or set(manifest) != {"schema", "database", "profiles"} or manifest["schema"] != 1:
    raise SystemExit("state export manifest schema mismatch")
expected = {"manifest.json"}
def verify_file(record):
    if not isinstance(record, dict) or set(record) != {"path", "bytes", "sha256"}:
        raise SystemExit("state export file record mismatch")
    relative = record["path"]
    if not isinstance(relative, str) or PurePosixPath(relative).is_absolute() or ".." in PurePosixPath(relative).parts:
        raise SystemExit("state export file path mismatch")
    path = root / relative
    if (isinstance(record["bytes"], bool) or not isinstance(record["bytes"], int)
            or record["bytes"] < 0 or not isinstance(record["sha256"], str)
            or re.fullmatch(r"[0-9a-f]{64}", record["sha256"]) is None
            or not path.is_file() or path.is_symlink() or path.stat().st_size != record["bytes"]):
        raise SystemExit("state export file size mismatch")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != record["sha256"]:
        raise SystemExit("state export file digest mismatch")
    expected.add(relative)
verify_file(manifest["database"])
database_relative = manifest["database"]["path"]
sidecar_evidence = {}
wal_relative = database_relative + "-wal"
shm_relative = database_relative + "-shm"
wal_path = root / wal_relative
shm_path = root / shm_relative
if wal_path.exists() or wal_path.is_symlink():
    if wal_path.is_symlink() or not wal_path.is_file() or wal_path.stat().st_size != 0:
        raise SystemExit("state export WAL must be an empty regular file")
    expected.add(wal_relative)
    sidecar_evidence["wal"] = {"path": wal_relative, "bytes": 0,
                                "sha256": hashlib.sha256(wal_path.read_bytes()).hexdigest()}
if shm_path.exists() or shm_path.is_symlink():
    if shm_path.is_symlink() or not shm_path.is_file() or shm_path.stat().st_size != 32768:
        raise SystemExit("state export SHM size mismatch")
    shm = shm_path.read_bytes()
    version = int.from_bytes(shm[0:4], "little")
    maximum_frame = int.from_bytes(shm[16:20], "little")
    if version != 3_007_000 or shm[12] != 1 or maximum_frame != 0 or shm[:48] != shm[48:96]:
        raise SystemExit("state export SHM format mismatch")
    expected.add(shm_relative)
    sidecar_evidence["shm"] = {"path": shm_relative, "bytes": len(shm),
                                "sha256": hashlib.sha256(shm).hexdigest(),
                                "wal_index_version": version, "maximum_frame": maximum_frame}
source_paths = []
if not isinstance(manifest["profiles"], list) or not 1 <= len(manifest["profiles"]) <= 64:
    raise SystemExit("state export profile count mismatch")
for profile in manifest["profiles"]:
    allowed = {"database_path", "source_relative_path", "main", "last_known_good_present", "last_known_good"}
    required = {"database_path", "source_relative_path", "main", "last_known_good_present"}
    if not isinstance(profile, dict) or not set(profile).issubset(allowed) or not required.issubset(profile):
        raise SystemExit("state export profile record mismatch")
    database_path = profile["database_path"]
    if (not isinstance(database_path, str) or not database_path
            or any(ord(character) < 32 or ord(character) == 127 for character in database_path)):
        raise SystemExit("state export database path mismatch")
    source = profile["source_relative_path"]
    if (not isinstance(source, str) or PurePosixPath(source).is_absolute()
            or ".." in PurePosixPath(source).parts
            or any(ord(character) < 32 or ord(character) == 127 for character in source)):
        raise SystemExit("state export source path mismatch")
    source_paths.append(source)
    verify_file(profile["main"])
    present = profile["last_known_good_present"]
    if not isinstance(present, bool) or present != ("last_known_good" in profile):
        raise SystemExit("state export LKG presence mismatch")
    if present:
        verify_file(profile["last_known_good"])
if actual != expected or not source_paths or len(source_paths) != len(set(source_paths)):
    raise SystemExit("state export inventory mismatch")
database_uri = (root / manifest["database"]["path"]).resolve().as_uri() + "?mode=ro&immutable=1"
connection = sqlite3.connect(database_uri, uri=True)
try:
    if connection.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
        raise SystemExit("state export database integrity failure")
    database_paths = [row[0] for row in connection.execute("SELECT path FROM profiles ORDER BY id")]
finally:
    connection.close()
manifest_database_paths = [profile["database_path"] for profile in manifest["profiles"]]
if database_paths != manifest_database_paths:
    raise SystemExit("state export profile binding mismatch")
root.chmod(0o700)
sidecar_evidence_path.write_text(json.dumps(sidecar_evidence, sort_keys=True) + "\n")
sidecar_evidence_path.chmod(0o600)
PY
    fi

    /usr/bin/python3 - "$local_result" "$request_id" "$action" "$candidate_file" "$max_successful_reconnects" "$max_reconnect_retries" "$explicit_wlt_plan_file" <<'PY'
import hashlib
import json
import re
import sys

path, request_id, action, candidate_path, max_successful_reconnects_raw, max_reconnect_retries_raw, explicit_plan_path = sys.argv[1:]
max_successful_reconnects = int(max_successful_reconnects_raw)
max_reconnect_retries = int(max_reconnect_retries_raw)
result = json.load(open(path))
if result.get("schema") not in {1, 2, 3, 4, 5, 6, 7}:
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
    "explicit_saved_WLT_outbound_reachability": result.get("explicit_saved_WLT_outbound_reachability"),
    "group_selections": result.get("group_selections"),
    "route_diagnostics": result.get("route_diagnostics"),
    "route_diagnostics_scope": result.get("route_diagnostics_scope"),
    "transport_counters": result.get("transport_counters"),
    "identity_ring": result.get("identity_ring"),
    "identity_ring_import": result.get("identity_ring_import"),
    "network_initial": result.get("network_initial"),
    "network_final": result.get("network_final"),
    "error_domain": result.get("error_domain"),
    "error_code": result.get("error_code"),
}
# Preserve a sanitized result even when a fail-closed evidence contract below
# rejects it.  Callers can then distinguish transport counters, workload
# failure, and infrastructure failure without reading private app-container
# artifacts.
print(json.dumps(allowed, sort_keys=True, separators=(",", ":")), flush=True)
if action == "explicit_saved_WLT_outbound_reachability":
    plan = json.load(open(explicit_plan_path))
    requests = plan["requests"]
    probes = result.get("explicit_saved_WLT_outbound_reachability")
    if not isinstance(probes, list):
        code = result.get("error_code")
        raise SystemExit(
            f"explicit WLT action returned no probe results (error_code={code!r})"
        )
    if not 1 <= len(probes) <= len(requests):
        raise SystemExit("explicit WLT result count mismatch")
    statuses = [probe.get("status") if isinstance(probe, dict) else None for probe in probes]
    if (
        any(status != "success" for status in statuses[:-1])
        or (len(probes) < len(requests) and statuses[-1] != "failed")
        or (statuses[-1] not in {"success", "failed"})
    ):
        raise SystemExit("explicit WLT partial result order mismatch")
    all_succeeded = len(probes) == len(requests) and all(
        status == "success" for status in statuses
    )
    if (result.get("state") == "succeeded") != all_succeeded:
        raise SystemExit("explicit WLT action state mismatch")
    common = {
        "schema", "scope", "probe_id", "kind", "status", "error_code", "group_tag",
        "outbound_tag", "wlt_tag", "network", "attempt", "fallback_attempted",
        "selection_touched", "profile_touched", "instance_current", "duration_ms",
        "request_sha256",
    }
    for request, probe in zip(requests, probes):
        specific = (
            {"dns_rcode", "dns_answer_count", "dns_question_sha256", "dns_server_sha256"}
            if request["kind"] == "dns"
            else {"http_status", "bytes_read", "destination_sha256"}
        )
        request_bytes = json.dumps(request, sort_keys=True, separators=(",", ":")).encode()
        status = probe.get("status") if isinstance(probe, dict) else None
        error_code = probe.get("error_code") if isinstance(probe, dict) else None
        duration_ms = probe.get("duration_ms") if isinstance(probe, dict) else None
        valid = (
            isinstance(probe, dict)
            and set(probe) == common | specific
            and probe.get("schema") == 1
            and probe.get("scope") == "explicit_saved_WLT_outbound_reachability"
            and probe.get("probe_id") == request["probe_id"]
            and probe.get("kind") == request["kind"]
            and status in {"success", "failed"}
            and isinstance(error_code, str)
            and re.fullmatch(r"[a-z0-9_]{0,64}", error_code) is not None
            and ((status == "success" and error_code == "")
                 or (status == "failed" and error_code != ""))
            and probe.get("group_tag") == request["group_tag"]
            and probe.get("outbound_tag") == request["outbound_tag"]
            and probe.get("wlt_tag") == request["wlt_tag"]
            and probe.get("network") == "tcp"
            and probe.get("attempt") == "primary"
            and probe.get("fallback_attempted") is False
            and probe.get("selection_touched") is False
            and probe.get("profile_touched") is False
            and type(probe.get("instance_current")) is bool
            and (status != "success" or probe["instance_current"] is True)
            and type(duration_ms) is int
            and duration_ms >= 0
            and (status != "success" or duration_ms <= request["timeout_ms"])
            and probe.get("request_sha256") == hashlib.sha256(request_bytes).hexdigest()
        )
        if not valid:
            raise SystemExit("explicit WLT common result mismatch")
        if request["kind"] == "dns":
            expected_question = request["query_name"].lower().rstrip(".").encode()
            if (
                type(probe.get("dns_rcode")) is not int
                or not -1 <= probe["dns_rcode"] <= 15
                or type(probe.get("dns_answer_count")) is not int
                or probe["dns_answer_count"] < 0
                or probe.get("dns_question_sha256") != hashlib.sha256(expected_question).hexdigest()
                or probe.get("dns_server_sha256") != hashlib.sha256(request["server"].encode()).hexdigest()
                or (status == "success" and (
                    probe["dns_rcode"] != 0 or probe["dns_answer_count"] < 1
                ))
            ):
                raise SystemExit("explicit WLT DNS result mismatch")
        else:
            if (
                type(probe.get("http_status")) is not int
                or probe["http_status"] < 0
                or type(probe.get("bytes_read")) is not int
                or not 0 <= probe["bytes_read"] <= request["max_read_bytes"]
                or probe.get("destination_sha256") != hashlib.sha256(request["url"].encode()).hexdigest()
                or (status == "success" and (
                    probe["http_status"] != request["expected_status"]
                    or probe["bytes_read"] != request["expected_bytes"]
                ))
            ):
                raise SystemExit("explicit WLT HTTPS result mismatch")
if candidate_path and result.get("state") == "succeeded":
    expected = json.load(open(candidate_path))["parameters"]
    if result.get("runtime_parameters") != expected:
        raise SystemExit("runtime candidate evidence mismatch")
if action == "import-identity-ring" and result.get("state") == "succeeded":
    imported = result.get("identity_ring_import") or {}
    expected = {
        "identities": 2,
        "independent": True,
        "validated": True,
        "stale_state_cleared": True,
        "transfer_inputs_deleted": True,
    }
    if imported != expected:
        raise SystemExit("identity ring import evidence mismatch")
    ring = result.get("identity_ring") or {}
    if not ring.get("active_present") or not ring.get("reserve_present"):
        raise SystemExit("identity ring import did not install active and reserve")
    if (
        ring.get("previous_present")
        or ring.get("quarantine_present")
        or ring.get("fault_armed")
        or ring.get("bootstrap_consumed")
    ):
        raise SystemExit("identity ring import left stale state")
if action == "export-state" and result.get("state") == "succeeded":
    if result.get("vpn_status") != "disconnected":
        raise SystemExit("state export did not prove disconnected VPN")
if action in {"start-probe", "soak"} and result.get("state") == "succeeded":
    milestones = set(result.get("startup_milestones") or [])
    required = {"carrier_ready", "traffic_ready"}
    if not required.issubset(milestones):
        raise SystemExit("successful WLT action lacks carrier traffic evidence")
    if "direct_fallback" in milestones:
        raise SystemExit("successful WLT action used direct-upstream fallback")
if action == "workload" and result.get("state") == "succeeded":
    milestones = set(result.get("startup_milestones") or [])
    if not {"carrier_ready", "core_started"}.issubset(milestones):
        raise SystemExit("successful WLT workload lacks carrier startup evidence")
    if "direct_fallback" in milestones:
        raise SystemExit("successful WLT workload used direct-upstream fallback")
    expected_counters = {
        "failed",
        "rejected",
        "reconnect_retries",
        "reconnects",
        "mux_open_errors",
        "mux_ping_timeouts",
        "mux_disconnects",
        "mux_control_errors",
        "mux_flow_drops",
        "peer_reconnect_failures",
    }
    counters = result.get("transport_counters") or {}
    if set(counters) != expected_counters:
        raise SystemExit("successful WLT workload lacks zero-tolerance counters")
    if any(not isinstance(value, int) or value < 0 for value in counters.values()):
        raise SystemExit("successful WLT workload has invalid transport counters")
    zero_tolerance = expected_counters - {"reconnects", "reconnect_retries"}
    if any(counters[name] != 0 for name in zero_tolerance):
        raise SystemExit("successful WLT workload has non-zero transport counters")
    if counters["reconnects"] > max_successful_reconnects:
        raise SystemExit("successful WLT workload exceeded reconnect allowance")
    if counters["reconnect_retries"] > max_reconnect_retries:
        raise SystemExit("successful WLT workload exceeded reconnect retry allowance")
if result.get("state") != "succeeded":
    raise SystemExit(1)
PY
    log "artifact: $artifact_dir"
}

run "$@"
