#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
build_dir="${WLT_SCENARIO_BUILD_DIR:-$repo_root/build/DerivedData-WLTScenario}"
artifact_root="${WLT_TEST_ARTIFACT_ROOT:-$repo_root/.local/wlt-test-artifacts}"
scenario_path="${WLT_DEVICE_SCENARIO:-$repo_root/SFIUITests/wlt-mobile.json}"
scheme="${SFI_SCHEME:-SFI Dev}"
configuration="${SFI_CONFIGURATION:-Dev}"
skip_build="${WLT_SCENARIO_SKIP_BUILD:-0}"
development_team="${WLT_SCENARIO_DEVELOPMENT_TEAM:-}"
coredevice_retries="${WLT_SCENARIO_COREDEVICE_RETRIES:-3}"
coredevice_host_timeout="${WLT_SCENARIO_COREDEVICE_HOST_TIMEOUT:-180}"
build_host_timeout="${WLT_SCENARIO_BUILD_HOST_TIMEOUT:-1800}"
test_host_timeout="${WLT_SCENARIO_TEST_HOST_TIMEOUT:-3600}"
close_mirroring="${WLT_SCENARIO_CLOSE_MIRRORING:-0}"
preflight_app="${WLT_SCENARIO_PREFLIGHT_APP:-1}"
test_attempt_limit="${WLT_SCENARIO_TEST_ATTEMPTS:-2}"
reset_automation_on_timeout="${WLT_SCENARIO_RESET_AUTOMATION_ON_TIMEOUT:-0}"
reset_runners_before_test="${WLT_SCENARIO_RESET_RUNNERS_BEFORE_TEST:-0}"
preflight_wait_seconds="${WLT_SCENARIO_PREFLIGHT_WAIT_SECONDS:-180}"
install_app_mode="${WLT_SCENARIO_INSTALL_APP:-auto}"
target_app_override="${WLT_SCENARIO_TARGET_APP:-}"
leave_running="${WLT_SCENARIO_LEAVE_RUNNING:-0}"
scenario_repetitions="${WLT_SCENARIO_REPETITIONS:-1}"
ui_authorization="${WLT_SCENARIO_UI_AUTHORIZATION:-deny}"
coredevice_framework_cli="/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl"
coredevice_cli_path="${WLT_SCENARIO_COREDEVICE_CLI:-}"
if [[ -z "$coredevice_cli_path" && -x "$coredevice_framework_cli" ]]; then
    # The xcrun wrapper compares its bundled expected CoreDevice version with
    # the globally installed framework and may invoke xcodebuild -runFirstLaunch
    # on every call. This is harmful when a newer macOS/iOS beta has already
    # installed a compatible CoreDevice framework next to an older Xcode.
    coredevice_cli_path="$coredevice_framework_cli"
fi
timestamp="$(date '+%Y-%m-%d-%H%M%S')"
artifact_dir="${WLT_SCENARIO_ARTIFACT_DIR:-$artifact_root/wlt-device-scenario-$timestamp}"
final_classification="not_started"
test_attempts=0
automation_authorization_prompt=0

log() {
    printf '[wlt-device-scenario] %s\n' "$*" >&2
}

die() {
    printf '[wlt-device-scenario] error: %s\n' "$*" >&2
    exit 1
}

run_devicectl() {
    if [[ -n "$coredevice_cli_path" ]]; then
        "$coredevice_cli_path" "$@"
    else
        xcrun devicectl "$@"
    fi
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

process_is_descendant() {
    local child="$1"
    local ancestor="$2"
    local parent
    while [[ "$child" =~ ^[0-9]+$ ]] && ((child > 1)); do
        [[ "$child" == "$ancestor" ]] && return 0
        parent="$(ps -o ppid= -p "$child" 2>/dev/null | tr -d ' ')"
        [[ "$parent" =~ ^[0-9]+$ ]] || break
        child="$parent"
    done
    return 1
}

stop_interactive_xcode_diagnostics() {
    local xcode_pid="$1"
    local diagnostic_pid command
    while kill -0 "$xcode_pid" >/dev/null 2>&1; do
        while IFS= read -r diagnostic_pid; do
            [[ "$diagnostic_pid" =~ ^[0-9]+$ ]] || continue
            process_is_descendant "$diagnostic_pid" "$xcode_pid" || continue
            command="$(ps -o command= -p "$diagnostic_pid" 2>/dev/null || true)"
            [[ "$command" == *"devicectl diagnose"* ]] || continue
            log "stopping automatic devicectl diagnostics so XCTest recovery remains unattended"
            terminate_process_tree "$diagnostic_pid"
        done < <(pgrep -f '/devicectl diagnose' 2>/dev/null || true)
        sleep 2
    done
}

run_with_host_timeout() {
    local timeout_seconds="$1"
    shift
    local marker pid watchdog diagnostics_watchdog status
    marker="$(mktemp "${TMPDIR:-/tmp}/wlt-host-timeout.XXXXXX")"
    # Night cycles can run under a managed PTY. Never let xcodebuild or a
    # devicectl diagnostics child inherit that terminal as stdin: a background
    # child that probes the TTY can be job-control stopped and defeat the host
    # watchdog until its full deadline.
    "$@" </dev/null &
    pid=$!
    stop_interactive_xcode_diagnostics "$pid" &
    diagnostics_watchdog=$!
    (
        sleep "$timeout_seconds"
        if kill -0 "$pid" >/dev/null 2>&1; then
            printf 'timeout\n' >"$marker"
            terminate_process_tree "$pid"
            sleep 3
            kill -KILL "$pid" >/dev/null 2>&1 || true
        fi
    ) &
    watchdog=$!
    if wait "$pid"; then
        status=0
    else
        status=$?
    fi
    terminate_process_tree "$diagnostics_watchdog"
    wait "$diagnostics_watchdog" >/dev/null 2>&1 || true
    terminate_process_tree "$watchdog"
    wait "$watchdog" >/dev/null 2>&1 || true
    if [[ -s "$marker" ]]; then
        printf 'WLT_HOST_TIMEOUT seconds=%s command=%q\n' "$timeout_seconds" "$1" >&2
        status=124
    fi
    rm -f "$marker"
    return "$status"
}

validate_positive_integer() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$name must be a positive integer"
}

validate_non_negative_integer() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be a non-negative integer"
}

is_coredevice_failure() {
    local path="$1"
    rg -qi \
        'CoreDeviceService to fully initialize|XPCConnectionDescription.*CoreDeviceService|connection was invalidated|CoreDeviceCLISupport|com\.apple\.coredevice\.devicectl error 1|Timed out while enabling automation mode|Unable to find a destination matching the provided destination specifier' \
        "$path"
}

is_xctest_session_failure() {
    local path="$1"
    rg -qi \
        'Not authorized for performing UI testing actions|Failed to determine whether continuity display is enabled|Timed out while checking for continuity enablement|Failed to create directory on device .* to hold runtime profiles|The system failed to get the path on the remote device for the provided domain|<unknown>:0: error: .* : .* crashed' \
        "$path"
}

repair_coredevice() {
    local expected_device="${1:-}"
    log "repairing the local CoreDevice service"
    killall CoreDeviceService >/dev/null 2>&1 || true
    if [[ -z "$coredevice_cli_path" ]]; then
        run_with_host_timeout "$coredevice_host_timeout" \
            xcodebuild -runFirstLaunch >/dev/null 2>&1 || true
    fi
    local destinations="$artifact_dir/devicectl-devices-after-repair.json"
    local recovery_log="$artifact_dir/devicectl-devices-after-repair.log"
    local attempt
    for ((attempt = 1; attempt <= 15; attempt++)); do
        if run_with_host_timeout "$coredevice_host_timeout" run_devicectl list devices \
            --timeout 15 \
            --json-output "$destinations" \
            --quiet >"$recovery_log" 2>&1; then
            if select_wired_device_from_inventory "$destinations" "$expected_device" >/dev/null 2>&1; then
                log "CoreDevice recovered and the wired iPhone is available"
                return 0
            fi
        fi
        sleep 2
    done
    log "CoreDevice recovery timed out; the next command will preserve the detailed failure"
    return 1
}

reset_device_automation() {
    local device="$1"
    local mode="${2:-full}"
    local processes="$artifact_dir/device-processes-before-automation-reset-${mode}.json"
    local reset_log="$artifact_dir/device-automation-reset-${mode}.log"
    : >"$reset_log"
    if ! run_with_host_timeout "$coredevice_host_timeout" run_devicectl device info processes \
        --device "$device" \
        --json-output "$processes" \
        --quiet >>"$reset_log" 2>&1; then
        log "could not inspect device automation processes; preserving the failure log"
        return 1
    fi
    local pid
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        printf 'terminating pid=%s mode=%s\n' "$pid" "$mode" >>"$reset_log"
        run_with_host_timeout "$coredevice_host_timeout" run_devicectl device process terminate \
            --device "$device" \
            --pid "$pid" \
            --kill >>"$reset_log" 2>&1 || true
    done < <(/usr/bin/python3 - "$processes" "$mode" <<'PY'
import json
import sys
from urllib.parse import unquote, urlparse

path, mode = sys.argv[1:]
root = json.load(open(path, encoding="utf-8"))
processes = root.get("result", {}).get("runningProcesses", [])
for process in processes:
    executable = str(process.get("executable", ""))
    parsed = urlparse(executable)
    executable_path = unquote(parsed.path if parsed.scheme == "file" else executable)
    executable_name = executable_path.rsplit("/", 1)[-1]
    bundle_name = executable_path.rsplit("/", 2)[-2] if "/" in executable_path else ""
    is_runner = (
        executable_path.endswith("/Runner.app/Runner")
        or (
            bundle_name.endswith("UITests-Runner.app")
            and executable_name == bundle_name.removesuffix(".app")
        )
        or executable_path.endswith("/XCTRunner.app/XCTRunner")
    )
    is_automation_writer = executable_path.endswith(
        "/AutomationMode.framework/automationmode-writer"
    )
    selected = (
        is_runner if mode == "runners"
        else is_automation_writer if mode == "writer"
        else False
    )
    if not selected:
        continue
    pid = process.get("processIdentifier")
    if isinstance(pid, int) and pid > 1:
        print(pid)
PY
    )
    sleep 2
}

automation_mode_requires_authentication() {
    local status
    status="$(/usr/bin/automationmodetool status 2>&1 || true)"
    printf '%s\n' "$status" >"$artifact_dir/automation-mode-status.txt"
    rg -q '^This device requires user authentication to enable Automation Mode\.$' \
        "$artifact_dir/automation-mode-status.txt"
}

capture_automation_timeout_state() {
    local device="$1"
    run_devicectl device info lockState \
        --device "$device" \
        --timeout 15 \
        --json-output "$artifact_dir/automation-timeout-lock-state.json" \
        --quiet >/dev/null 2>&1 || true
    run_devicectl device capture screenshot \
        --device "$device" \
        --destination "$artifact_dir/automation-timeout-screen.png" \
        --timeout 20 \
        --json-output "$artifact_dir/automation-timeout-screenshot.json" \
        --quiet >/dev/null 2>&1 || true
}

automation_timeout_requires_device_passcode() {
    local screenshot="$artifact_dir/automation-timeout-screen.png"
    local ocr="$artifact_dir/automation-timeout-ocr.txt"
    [[ -s "$screenshot" ]] || return 1
    xcrun swift -e '
import Foundation
import ImageIO
import Vision

let imageURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard
    let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    exit(2)
}
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
let handler = VNImageRequestHandler(cgImage: image, options: [:])
try handler.perform([request])
for observation in request.results ?? [] {
    if let text = observation.topCandidates(1).first?.string {
        print(text)
    }
}
' "$screenshot" >"$ocr" 2>/dev/null || return 1
    rg -qi 'Enter iPhone Passcode for.*XCTest|Enable UI Automation' "$ocr"
}

record_competing_coredevice_sessions() {
    local destination="$artifact_dir/coredevice-competing-sessions.txt"
    local current_user
    current_user="$(id -un)"
    {
        printf '[other CoreDeviceService owners]\n'
        ps ax -o user=,command= | /usr/bin/awk -v current="$current_user" '
            $1 != current && $NF ~ /\/CoreDeviceService$/ { print }
        '
        printf '[other logged-in console sessions]\n'
        who | /usr/bin/awk -v current="$current_user" '
            $1 != current && $2 == "console" { print }
        '
    } >"$destination"
    # A second Aqua session alone is not proof of ownership: a device-side
    # AutomationMode writer reset can recover while that session remains logged
    # in. Classify competition only when another user actually owns a live
    # CoreDeviceService process; keep the console list as supporting evidence.
    /usr/bin/awk '
        /^\[other CoreDeviceService owners\]/ { section=1; next }
        /^\[/ { section=0; next }
        section && NF { found=1 }
        END { exit !found }
    ' "$destination"
}

devicectl_retry() {
    local label="$1"
    shift
    local log_path="$artifact_dir/devicectl-$label.log"
    local attempt status
    : >"$log_path"
    for ((attempt = 1; attempt <= coredevice_retries; attempt++)); do
        printf 'attempt=%s command=devicectl %q\n' "$attempt" "$*" >>"$log_path"
        if run_with_host_timeout "$coredevice_host_timeout" \
            run_devicectl "$@" >>"$log_path" 2>&1; then
            return 0
        else
            status=$?
        fi
        if ((attempt == coredevice_retries)) || ! is_coredevice_failure "$log_path"; then
            return "$status"
        fi
        log "CoreDevice failed during $label; retrying ($attempt/$coredevice_retries)"
        repair_coredevice "${DEVICE_ID:-}" || true
    done
    return 1
}

classify_log_failure() {
    local path="$1"
    if rg -qi 'WLT_HOST_TIMEOUT' "$path"; then
        printf 'host_command_timeout\n'
    elif rg -qi 'Timed out while enabling automation mode' "$path"; then
        printf 'automation_mode_timeout\n'
    elif rg -qi 'device was not, or could not be, unlocked|reason: Locked|DeviceLocked|device is locked' "$path"; then
        printf 'device_locked\n'
    elif rg -qi 'invalid code signature|profile has not been explicitly trusted|untrusted developer|RequestDenied.*Security' "$path"; then
        printf 'trust_required\n'
    elif rg -qi 'Developer Mode.*disabled|developer mode is not enabled' "$path"; then
        printf 'developer_mode_required\n'
    elif rg -qi 'application.*not (found|installed)|ApplicationNotFound|Failed to find.*application' "$path"; then
        printf 'app_not_installed\n'
    elif is_xctest_session_failure "$path"; then
        printf 'xctest_automation_unavailable\n'
    elif rg -qi 'Step [0-9]+ failed|failed - Step [0-9]+|Test Case .* failed' "$path"; then
        printf 'scenario_failed\n'
    elif is_coredevice_failure "$path"; then
        printf 'coredevice_unavailable\n'
    else
        printf 'test_infrastructure_failed\n'
    fi
}

classify_wlt_diagnostics() {
    local path="$1"
    local baseline_path="${2:-}"
    [[ -s "$path" ]] || return 1
    if [[ -n "$baseline_path" && -s "$baseline_path" ]] \
        && ! diagnostics_has_new_session "$path" "$baseline_path"; then
        return 1
    fi
    local last_start_failure
    last_start_failure="$(/usr/bin/python3 - "$path" "$baseline_path" <<'PY'
import re
import sys

path, baseline_path = sys.argv[1:]
session_pattern = re.compile(r"\[session=([0-9a-f]+)\b")
baseline_sessions = set()
if baseline_path:
    try:
        with open(baseline_path, "r", encoding="utf-8", errors="replace") as handle:
            baseline_sessions = set(session_pattern.findall(handle.read()))
    except FileNotFoundError:
        pass

last_failure = ""
with open(path, "r", encoding="utf-8", errors="replace") as handle:
    for line in handle:
        if "starttunnel failed:" not in line.lower():
            continue
        match = session_pattern.search(line)
        if baseline_sessions and match and match.group(1) in baseline_sessions:
            continue
        last_failure = line.rstrip("\n")
print(last_failure)
PY
)"
    if [[ "$last_start_failure" =~ (manual[[:space:]]+captcha|human[[:space:]]+challenge|required) ]]; then
        printf 'wlt_auth_required\n'
    elif [[ "$last_start_failure" =~ (platform[[:space:]]+signaling[[:space:]]+ended|relay[[:space:]]+session[[:space:]]+connected|carrier.*deadline) ]]; then
        printf 'wlt_carrier_connect_failed\n'
    else
        return 1
    fi
}

diagnostics_has_new_session() {
    local path="$1"
    local baseline_path="$2"
    /usr/bin/python3 - "$path" "$baseline_path" <<'PY'
import re
import sys

path, baseline_path = sys.argv[1:]
session_pattern = re.compile(r"diagnostics session started.*\[session=([0-9a-f]+)\b")

with open(path, "r", encoding="utf-8", errors="replace") as handle:
    current_sessions = set(session_pattern.findall(handle.read()))
with open(baseline_path, "r", encoding="utf-8", errors="replace") as handle:
    baseline_sessions = set(session_pattern.findall(handle.read()))

raise SystemExit(0 if current_sessions - baseline_sessions else 1)
PY
}

scenario_expects_vpn_session() {
    local scenario="$1"
    /usr/bin/python3 - "$scenario" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    scenario = json.load(handle)
expects_started = any(
    step.get("action") == "assert_text"
    and step.get("app", "vpn") == "vpn"
    and step.get("text") == "Started"
    for step in scenario.get("steps", [])
)
raise SystemExit(0 if expects_started else 1)
PY
}

scenario_uninstall_apps() {
    local scenario="$1"
    /usr/bin/python3 - "$scenario" <<'PY'
import json
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    scenario = json.load(handle)
apps = scenario.get("host_preflight", {}).get("uninstall_apps", [])
if not isinstance(apps, list):
    raise SystemExit("host_preflight.uninstall_apps must be an array")
for bundle_id in apps:
    if not isinstance(bundle_id, str) or not re.fullmatch(r"[A-Za-z0-9.-]+", bundle_id):
        raise SystemExit(f"invalid uninstall bundle identifier: {bundle_id!r}")
    print(bundle_id)
PY
}

uninstall_scenario_apps() {
    local device="$1"
    local bundle_id index=0 apps_json
    while IFS= read -r bundle_id; do
        [[ -n "$bundle_id" ]] || continue
        index=$((index + 1))
        apps_json="$artifact_dir/apps-before-uninstall-$(printf '%02d' "$index").json"
        if ! devicectl_retry "list-apps-before-uninstall-$(printf '%02d' "$index")" \
            device info apps \
            --device "$device" \
            --json-output "$apps_json" \
            --timeout 60; then
            final_classification="app_reset_failed"
            die "failed to list installed apps before reset: $bundle_id"
        fi
        if ! /usr/bin/python3 - "$apps_json" "$bundle_id" <<'PY'
import json
import sys

path, bundle_id = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    root = json.load(handle)
apps = root.get("result", {}).get("apps", [])
raise SystemExit(0 if any(app.get("bundleIdentifier") == bundle_id for app in apps) else 1)
PY
        then
            log "scenario app already absent before XCTest: $bundle_id"
            continue
        fi
        log "uninstalling scenario app before XCTest: $bundle_id"
        if ! devicectl_retry "uninstall-app-$(printf '%02d' "$index")" \
            device uninstall app \
            --device "$device" \
            "$bundle_id" \
            --timeout 60; then
            final_classification="app_reset_failed"
            die "failed to uninstall scenario app: $bundle_id"
        fi
    done < <(scenario_uninstall_apps "$scenario_path")
}

write_result() {
    local status="$1"
    local classification="$2"
    local test_attempts="$3"
    /usr/bin/python3 - "$artifact_dir/result.json" "$status" "$classification" "$test_attempts" <<'PY'
import json
import sys

path, status, classification, attempts = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "exit_status": int(status),
            "classification": classification,
            "test_attempts": int(attempts),
        },
        handle,
        indent=2,
    )
    handle.write("\n")
PY
}

write_scenario_report() {
    local test_log="$1"
    local metrics_dir="${2:-}"
    local scenario="$artifact_dir/scenario.json"
    [[ -f "$scenario" && -f "$test_log" ]] || return 0
    /usr/bin/python3 - "$scenario" "$test_log" "$artifact_dir/scenario-report.json" "$artifact_dir/scenario-report.tsv" <<'PY'
import csv
import json
import re
import sys

scenario_path, log_path, json_path, tsv_path = sys.argv[1:]
with open(scenario_path, "r", encoding="utf-8") as handle:
    scenario = json.load(handle)

pattern = re.compile(r"failed - Step (\d+) failed: (.*?): (.*)$")
failures = []
seen = set()
with open(log_path, "r", encoding="utf-8", errors="replace") as handle:
    for raw_line in handle:
        match = pattern.search(raw_line.rstrip("\n"))
        if not match:
            continue
        step_number = int(match.group(1))
        summary = match.group(2)
        error = match.group(3)
        key = (step_number, error)
        if key in seen:
            continue
        seen.add(key)
        step = scenario.get("steps", [])[step_number - 1] if step_number <= len(scenario.get("steps", [])) else {}
        lowered = error.lower()
        if "web_error_page" in lowered:
            category = "web_error_page"
        elif "web_load_stalled" in lowered:
            category = "web_load_stalled"
        elif "web_empty_or_stalled" in lowered:
            category = "web_empty_or_stalled"
        elif "web_expected_content_missing" in lowered or "web_missing_view" in lowered:
            category = "web_content_missing"
        elif "app_error_state" in lowered:
            category = "app_error_state"
        elif "app_loading_stalled" in lowered:
            category = "app_loading_stalled"
        elif "app_auth_required" in lowered:
            category = "app_auth_required"
        elif "app_ready_timeout" in lowered:
            category = "app_ready_timeout"
        elif "screen_static" in lowered:
            category = "playback_stalled"
        elif "element value did not change" in lowered:
            category = "playback_stalled"
        elif "quality" in lowered:
            category = "quality_unavailable"
        elif "element not found" in lowered or "text not found" in lowered:
            category = "selector_or_content_missing"
        else:
            category = "scenario_step_failed"
        failures.append(
            {
                "step": step_number,
                "action": step.get("action", ""),
                "app": step.get("app", "vpn"),
                "name": step.get("name", ""),
                "summary": summary,
                "category": category,
                "error": error,
            }
        )

report = {
    "scenario": scenario.get("name", ""),
    "total_steps": len(scenario.get("steps", [])),
    "failure_count": len(failures),
    "failures": failures,
}
with open(json_path, "w", encoding="utf-8") as handle:
    json.dump(report, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
with open(tsv_path, "w", encoding="utf-8", newline="") as handle:
    writer = csv.writer(handle, delimiter="\t")
    writer.writerow(["step", "app", "action", "name", "category", "error"])
    for item in failures:
        writer.writerow([item["step"], item["app"], item["action"], item["name"], item["category"], item["error"]])
PY
    /usr/bin/python3 "$script_dir/iphone_wlt_xcresult_metrics.py" \
        --report "$artifact_dir/scenario-report.json" \
        --attachments "$metrics_dir" \
        >"$artifact_dir/wlt-metric-merge.json"
}

export_wlt_metric_attachments() {
    local result_bundle="$1"
    local output_dir="$2"
    [[ -d "$result_bundle" ]] || return 1
    xcrun xcresulttool export attachments \
        --path "$result_bundle" \
        --output-path "$output_dir" \
        --filter 'wlt-metric-*' \
        >"$artifact_dir/xcresult-metric-export.log" 2>&1
}

close_iphone_mirroring() {
    [[ "$close_mirroring" == "1" ]] || return 0
    if pgrep -x 'iPhone Mirroring' >/dev/null 2>&1; then
        log "closing iPhone Mirroring before XCTest"
        killall 'iPhone Mirroring' >/dev/null 2>&1 || true
        sleep 1
    fi
}

select_wired_device_from_inventory() {
    local json_path="$1"
    local expected_device="${2:-}"
    /usr/bin/python3 - "$json_path" "$expected_device" <<'PY'
import json
import sys

path, expected = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    devices = json.load(handle).get("result", {}).get("devices", [])

matches = []
for device in devices:
    hardware = device.get("hardwareProperties", {})
    connection = device.get("connectionProperties", {})
    if hardware.get("deviceType") != "iPhone":
        continue
    # Never allow a paired Wi-Fi device or a local simulator to satisfy a
    # physical acceptance run. XCTest control must remain on the USB cable
    # while the scenario turns the iPhone Wi-Fi radio off.
    if connection.get("transportType") != "wired":
        continue
    identifiers = {
        str(device.get("identifier", "")),
        str(hardware.get("udid", "")),
    }
    if expected and expected not in identifiers:
        continue
    matches.append(device)

if len(matches) != 1:
    requested = " matching DEVICE_ID" if expected else ""
    raise SystemExit(
        f"expected exactly one wired physical iPhone{requested}, found {len(matches)}; "
        "connect it by USB, unlock it, and retry"
    )

hardware = matches[0].get("hardwareProperties", {})
print(hardware.get("udid") or matches[0]["identifier"])
PY
}

device_id() {
    local json_path="$artifact_dir/devices.json"
    devicectl_retry list-devices list devices --json-output "$json_path" --timeout 30 \
        || die "CoreDevice could not enumerate the iPhone; see $artifact_dir/devicectl-list-devices.log"
    select_wired_device_from_inventory "$json_path" "${DEVICE_ID:-}"
}

patch_xctestrun_environment() {
    local plist="$1"
    local encoded="$2"
    local persistent="$3"
    local target_app="$4"
    /usr/bin/python3 - "$plist" "$encoded" "$persistent" "$target_app" <<'PY'
import plistlib
import sys

path, encoded, persistent, target_app = sys.argv[1:]
with open(path, "rb") as handle:
    root = plistlib.load(handle)

targets = []
for configuration in root.get("TestConfigurations", []):
    targets.extend(configuration.get("TestTargets", []))
if not targets:
    targets.extend(value for key, value in root.items() if key != "__xctestrun_metadata__" and isinstance(value, dict))

matched = 0
for target in targets:
    blueprint = str(target.get("BlueprintName", ""))
    bundle_path = str(target.get("TestBundlePath", ""))
    if blueprint != "SFIUITests" and "SFIUITests" not in bundle_path:
        continue
    target.setdefault("EnvironmentVariables", {})["WLT_DEVICE_SCENARIO_BASE64"] = encoded
    target.setdefault("EnvironmentVariables", {})["WLT_DEVICE_LEAVE_RUNNING"] = persistent
    if target_app:
        target["UITargetAppPath"] = target_app
        dependent_paths = target.get("DependentProductPaths")
        if isinstance(dependent_paths, list):
            target["DependentProductPaths"] = [
                target_app
                if str(item).rstrip("/").endswith(("/dev-vpn.app", "/SFI.app"))
                else item
                for item in dependent_paths
            ]
    matched += 1

if matched != 1:
    raise SystemExit(f"expected one SFIUITests entry in xctestrun, found {matched}")
with open(path, "wb") as handle:
    plistlib.dump(root, handle, fmt=plistlib.FMT_BINARY)
PY
}

build_effective_scenario() {
    local source="$1"
    local destination="$2"
    local repetitions="$3"
    /usr/bin/python3 - "$source" "$destination" "$repetitions" <<'PY'
import copy
import json
import sys

source, destination, repetitions_text = sys.argv[1:]
repetitions = int(repetitions_text)
with open(source, "r", encoding="utf-8") as handle:
    scenario = json.load(handle)

if repetitions == 1:
    effective = scenario
else:
    source_steps = scenario.get("steps")
    cleanup_steps = scenario.get("cleanup_steps", [])
    if not isinstance(source_steps, list) or not source_steps:
        raise SystemExit("repeated scenario requires a non-empty steps array")
    if not isinstance(cleanup_steps, list):
        raise SystemExit("cleanup_steps must be an array")

    def tagged(step, repetition, boundary_cleanup=False):
        result = copy.deepcopy(step)
        prefix = f"r{repetition:02d}-"
        if result.get("name"):
            result["name"] = prefix + str(result["name"])
        if result.get("section"):
            result["section"] = prefix + str(result["section"])
        if boundary_cleanup:
            # A failed boundary would contaminate the next repetition. Abort
            # the single XCTest session so it cannot manufacture apparently
            # comparable samples from an unknown device state.
            result["fatal"] = True
        return result

    steps = []
    for repetition in range(1, repetitions + 1):
        steps.extend(tagged(step, repetition) for step in source_steps)
        if repetition != repetitions:
            steps.extend(
                tagged(step, repetition, boundary_cleanup=True)
                for step in cleanup_steps
            )

    effective = copy.deepcopy(scenario)
    effective["name"] = (
        f"{scenario.get('name', 'WLT device scenario')} "
        f"[{repetitions} repetitions; one XCTest session]"
    )
    effective["steps"] = steps
    effective["wlt_single_session_repetitions"] = repetitions

with open(destination, "w", encoding="utf-8") as handle:
    json.dump(effective, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
}

find_xctestrun() {
    find "$build_dir/Build/Products" -maxdepth 2 -name '*.xctestrun' \
        ! -name 'wlt-device-scenario.xctestrun' -type f -print | sort | tail -n 1
}

find_target_app() {
    if [[ -n "$target_app_override" ]]; then
        printf '%s\n' "$target_app_override"
        return
    fi
    find "$build_dir/Build/Products/${configuration}-iphoneos" -maxdepth 1 -name '*.app' -type d -print |
        while IFS= read -r candidate; do
            case "$(basename "$candidate")" in
                *UITests-Runner.app) continue ;;
            esac
            printf '%s\n' "$candidate"
        done | head -n 1
}

app_group_id() {
    local app="$1"
    local entitlements="$artifact_dir/app-entitlements.plist"
    codesign -d --entitlements :- "$app" >"$entitlements" 2>/dev/null
    plutil -extract 'com\.apple\.security\.application-groups.0' raw "$entitlements"
}

copy_cache_file() {
    local device="$1"
    local group_id="$2"
    local source_name="$3"
    local destination_name="${4:-$source_name}"
    local destination="$artifact_dir/$destination_name"
    devicectl_retry "copy-$source_name" device copy from \
        --device "$device" \
        --domain-type appGroupDataContainer \
        --domain-identifier "$group_id" \
        --source "Library/Caches/$source_name" \
        --destination "$destination" \
        --timeout 60 || true
}

preflight_target_app() {
    local device="$1"
    local app="$2"
    local bundle_identifier
    bundle_identifier="$(plutil -extract CFBundleIdentifier raw "$app/Info.plist")"

    local should_install=0
    local app_installed=0
    case "$install_app_mode" in
        always | 1) should_install=1 ;;
        never | 0) should_install=0 ;;
        auto)
            if [[ "$skip_build" != "1" ]]; then
                should_install=1
            fi
            ;;
    esac

    if ((should_install == 1)); then
        log "installing the signed target app for trust preflight"
        if ! devicectl_retry install-app device install app --device "$device" "$app" --timeout 120; then
            local install_classification
            install_classification="$(classify_log_failure "$artifact_dir/devicectl-install-app.log")"
            final_classification="$install_classification"
            die "app preflight install failed ($install_classification); see $artifact_dir/devicectl-install-app.log"
        fi
        app_installed=1
    else
        log "reusing the installed target app to preserve developer trust"
    fi

    log "launching the target app for trust preflight"
    local launch_label="launch-app"
    local launch_classification=""
    local wait_attempt=0
    local deadline=$((SECONDS + preflight_wait_seconds))
    while true; do
        if devicectl_retry "$launch_label" device process launch \
            --device "$device" \
            --terminate-existing \
            --environment-variables '{"WLT_DEVICE_SCENARIO":"1"}' \
            "$bundle_identifier" \
            --timeout 60; then
            return 0
        fi
        if rg -q 'CoreDeviceError error 10004|process identifier of the launched application could not be determined' \
            "$artifact_dir/devicectl-$launch_label.log"; then
            # The test-only launch environment can make SwiftUI hand off the
            # scene before CoreDevice observes a stable PID.  That is not a
            # trust verdict: the same signed app can still launch normally and
            # XCTest applies its own launch environment later.  Confirm the
            # installed app and developer trust with one plain launch instead
            # of blocking an otherwise unattended cycle.
            log "test-environment trust preflight exited before PID; retrying one plain app launch"
            launch_label="launch-app-plain"
            if devicectl_retry "$launch_label" device process launch \
                --device "$device" \
                --terminate-existing \
                "$bundle_identifier" \
                --timeout 60; then
                return 0
            fi
        fi
        launch_classification="$(classify_log_failure "$artifact_dir/devicectl-$launch_label.log")"
        if [[ "$launch_classification" == "app_not_installed" && "$app_installed" == "0" && "$install_app_mode" != "never" && "$install_app_mode" != "0" ]]; then
            log "target app is missing; installing the existing build once"
            if ! devicectl_retry install-app-fallback device install app --device "$device" "$app" --timeout 120; then
                launch_classification="$(classify_log_failure "$artifact_dir/devicectl-install-app-fallback.log")"
                break
            fi
            app_installed=1
            launch_label="launch-app-after-install"
            continue
        fi
        if [[ "$launch_classification" != "device_locked" && "$launch_classification" != "trust_required" ]]; then
            break
        fi
        if ((SECONDS >= deadline)); then
            break
        fi
        if ((wait_attempt == 0)); then
            if [[ "$launch_classification" == "device_locked" ]]; then
                log "waiting up to ${preflight_wait_seconds}s for one physical iPhone unlock"
            else
                log "waiting up to ${preflight_wait_seconds}s for one Wi-Fi launch of dev-vpn to refresh trust"
            fi
        fi
        sleep 5
        wait_attempt=$((wait_attempt + 1))
        launch_label="launch-app-wait-$(printf '%02d' "$wait_attempt")"
    done

    final_classification="$launch_classification"
    case "$launch_classification" in
        device_locked)
            die "app preflight failed (device_locked): unlock the iPhone once, keep it awake, and rerun"
            ;;
        trust_required)
            die "app preflight failed (trust_required): connect the iPhone to unrestricted Wi-Fi and open dev-vpn once, then rerun"
            ;;
        developer_mode_required)
            die "app preflight failed (developer_mode_required): enable Developer Mode and rerun"
            ;;
        *)
            die "app preflight failed ($launch_classification); see $artifact_dir/devicectl-$launch_label.log"
            ;;
    esac
}

run() {
    [[ -f "$scenario_path" ]] || die "scenario does not exist: $scenario_path"
    [[ "$scheme" == "SFI Dev" ]] || die "device scenario requires SFI Dev scheme"
    [[ "$configuration" == "Dev" ]] || die "device scenario requires Dev configuration"

    validate_positive_integer WLT_SCENARIO_COREDEVICE_RETRIES "$coredevice_retries"
    validate_positive_integer WLT_SCENARIO_COREDEVICE_HOST_TIMEOUT "$coredevice_host_timeout"
    validate_positive_integer WLT_SCENARIO_BUILD_HOST_TIMEOUT "$build_host_timeout"
    validate_positive_integer WLT_SCENARIO_TEST_HOST_TIMEOUT "$test_host_timeout"
    validate_positive_integer WLT_SCENARIO_TEST_ATTEMPTS "$test_attempt_limit"
    validate_positive_integer WLT_SCENARIO_REPETITIONS "$scenario_repetitions"
    validate_non_negative_integer WLT_SCENARIO_PREFLIGHT_WAIT_SECONDS "$preflight_wait_seconds"
    case "$ui_authorization" in
        supervised) ;;
        deny)
            die "XCUITest is disabled by default because iOS can require a device passcode for Automation Mode. Use iphone_wlt_headless.sh for unattended transport tests, or set WLT_SCENARIO_UI_AUTHORIZATION=supervised only while an operator is present"
            ;;
        *) die "WLT_SCENARIO_UI_AUTHORIZATION must be deny or supervised" ;;
    esac
    [[ "$reset_automation_on_timeout" == "0" ]] \
        || die "WLT_SCENARIO_RESET_AUTOMATION_ON_TIMEOUT=1 is unsafe: a writer reset can discard the iPhone Automation Mode grant and require a device passcode"
    [[ "$reset_runners_before_test" == "0" || "$reset_runners_before_test" == "1" ]] \
        || die "WLT_SCENARIO_RESET_RUNNERS_BEFORE_TEST must be 0 or 1"
    case "$install_app_mode" in
        auto | always | never | 0 | 1) ;;
        *) die "WLT_SCENARIO_INSTALL_APP must be auto, always, never, 0, or 1" ;;
    esac
    [[ "$leave_running" == "0" || "$leave_running" == "1" ]] \
        || die "WLT_SCENARIO_LEAVE_RUNNING must be 0 or 1"
    if [[ -n "$coredevice_cli_path" && ! -x "$coredevice_cli_path" ]]; then
        die "WLT_SCENARIO_COREDEVICE_CLI is not executable: $coredevice_cli_path"
    fi
    /usr/bin/python3 -m json.tool "$scenario_path" >/dev/null \
        || die "scenario is not valid JSON: $scenario_path"

    mkdir -p "$artifact_dir" "$build_dir"
    final_classification="host_setup_failed"
    test_attempts=0
    automation_authorization_prompt=0
    trap 'status=$?; printf "exit_status=%s\nclassification=%s\ntest_attempts=%s\n" "$status" "$final_classification" "$test_attempts" >"$artifact_dir/status.txt"; write_result "$status" "$final_classification" "$test_attempts"; printf "%s\n" "$artifact_dir"' EXIT
    close_iphone_mirroring
    final_classification="device_unavailable"
    local device
    device="$(device_id)"

    if [[ "$skip_build" == "1" ]]; then
        log "reusing the existing UI-test build"
        [[ -d "$build_dir/Build/Products" ]] || die "existing build directory is missing: $build_dir"
    else
        log "building UI test for the connected iPhone"
        final_classification="build_failed"
        local build_args=(
            -project "$repo_root/sing-box.xcodeproj"
            -scheme "$scheme"
            -configuration "$configuration"
            -destination "id=$device"
            -derivedDataPath "$build_dir"
            -skipPackagePluginValidation
        )
        if [[ -n "$development_team" ]]; then
            build_args+=("DEVELOPMENT_TEAM=$development_team")
        fi
        run_with_host_timeout "$build_host_timeout" xcodebuild \
            "${build_args[@]}" \
            build-for-testing >"$artifact_dir/xcodebuild-build.log" 2>&1 \
            || die "build-for-testing failed; see $artifact_dir/xcodebuild-build.log"
    fi

    local source_xctestrun patched_xctestrun encoded effective_scenario
    source_xctestrun="$(find_xctestrun)"
    [[ -n "$source_xctestrun" ]] || die "xctestrun was not produced"
    patched_xctestrun="$build_dir/Build/Products/wlt-device-scenario.xctestrun"
    cp "$source_xctestrun" "$patched_xctestrun"
    effective_scenario="$artifact_dir/scenario.json"
    build_effective_scenario "$scenario_path" "$effective_scenario" "$scenario_repetitions"
    encoded="$(base64 <"$effective_scenario" | tr -d '\n')"
    patch_xctestrun_environment "$patched_xctestrun" "$encoded" "$leave_running" "$target_app_override"
    cp "$patched_xctestrun" "$artifact_dir/$(basename "$source_xctestrun")"
    if [[ "$scenario_repetitions" != "1" ]]; then
        cp "$scenario_path" "$artifact_dir/scenario-source.json"
    fi

    local app
    app="$(find_target_app)"
    [[ -n "$app" ]] || die "target application was not produced"
    if [[ "$preflight_app" == "1" ]]; then
        final_classification="app_preflight_failed"
        preflight_target_app "$device" "$app"
    fi

    uninstall_scenario_apps "$device"

    if automation_mode_requires_authentication; then
        final_classification="automation_authorization_required"
        die "the Mac requires Automation Mode authentication; configure the dedicated Mac once with automationmodetool. This does not suppress a separate iPhone passcode sheet on current iOS betas"
    fi

    # Preserve an already-authorized Runner by default. Current iOS betas can
    # tie the device-side Automation Mode grant to that process; killing it
    # before every XCTest invocation causes a fresh passcode sheet even though
    # the Mac is configured for passwordless Automation Mode. A proven XCTest
    # session failure is still recovered inside the retry loop below. Keep the
    # eager reset as an explicit diagnostic escape hatch only.
    if [[ "$reset_runners_before_test" == "1" ]]; then
        reset_device_automation "$device" runners || true
    else
        log "preserving existing device Runner processes and Automation Mode grant"
        reset_device_automation "$device" inventory || true
    fi

    log "running $(basename "$scenario_path")"
    final_classification="test_infrastructure_failed"
    local test_status=0
    local test_log result_bundle attempt
    local group_id
    group_id="$(app_group_id "$app" 2>/dev/null || true)"
    if [[ -n "$group_id" ]]; then
        copy_cache_file "$device" "$group_id" "packet-tunnel-diagnostics.log" \
            "packet-tunnel-diagnostics.before.log"
    fi
    for ((attempt = 1; attempt <= test_attempt_limit; attempt++)); do
        test_attempts="$attempt"
        test_log="$artifact_dir/xcodebuild-test.log"
        result_bundle="$artifact_dir/test.xcresult"
        if ((attempt > 1)); then
            test_log="$artifact_dir/xcodebuild-test-attempt-$(printf '%02d' "$attempt").log"
            result_bundle="$artifact_dir/test-attempt-$(printf '%02d' "$attempt").xcresult"
        fi
        test_status=0
        run_with_host_timeout "$test_host_timeout" xcodebuild \
            -xctestrun "$patched_xctestrun" \
            -destination "id=$device" \
            -only-testing:SFIUITests/DeviceScenarioTests/testScenario \
            -resultBundlePath "$result_bundle" \
            test-without-building >"$test_log" 2>&1 || test_status=$?
        if ((test_status == 0)); then
            break
        fi
        if rg -qi 'Timed out while enabling automation mode' "$test_log"; then
            # A new XCTest session can raise a fresh device-passcode prompt on
            # current iOS betas. Retrying the same command cannot authorize it
            # and merely produces another prompt, so preserve the screen and
            # stop after exactly one attempt. The next run must follow an
            # explicit external authorization or another material state fix.
            capture_automation_timeout_state "$device"
            if automation_timeout_requires_device_passcode; then
                automation_authorization_prompt=1
                log "iPhone passcode is required to enable UI Automation; refusing an identical automatic retry"
            else
                log "Automation Mode timed out; refusing an identical automatic retry"
            fi
            break
        fi
        if ((attempt < test_attempt_limit)); then
            if is_xctest_session_failure "$test_log"; then
                log "XCTest automation session failed; resetting stale device runners before retry ($attempt/$test_attempt_limit)"
                reset_device_automation "$device" runners || true
                sleep 3
                continue
            fi
            if is_coredevice_failure "$test_log" \
                && ! rg -q 'Test Suite .*DeviceScenarioTests.* started|testScenario.*started|Step [0-9]+ failed|failed - Step [0-9]+' "$test_log"; then
                log "XCTest did not start because CoreDevice failed; retrying ($attempt/$test_attempt_limit)"
                reset_device_automation "$device" runners || true
                repair_coredevice "$device" || true
                continue
            fi
        fi
        break
    done

    if [[ -n "$app" ]]; then
        if [[ -n "$group_id" ]]; then
            copy_cache_file "$device" "$group_id" "stderr.log"
            copy_cache_file "$device" "$group_id" "stderr.log.old"
            copy_cache_file "$device" "$group_id" "wlt-device-service.log"
            copy_cache_file "$device" "$group_id" "packet-tunnel-diagnostics.log"
            copy_cache_file "$device" "$group_id" "packet-tunnel-incidents.log"
        fi
    fi

    if [[ "$test_status" == "0" ]]; then
        final_classification="passed"
    else
        if [[ "$automation_authorization_prompt" == "1" ]]; then
            final_classification="automation_authorization_required"
        else
            final_classification="$(classify_log_failure "$test_log")"
        fi
        if [[ "$final_classification" == "coredevice_unavailable" ]] \
            && rg -qi 'Timed out while enabling automation mode' "$test_log" \
            && record_competing_coredevice_sessions; then
            final_classification="coredevice_competing_console_session"
            log "another macOS console session can retain Automation Mode; log it out before retrying XCTest"
        fi
        local diagnostics_classification=""
        diagnostics_classification="$(classify_wlt_diagnostics \
            "$artifact_dir/packet-tunnel-diagnostics.log" \
            "$artifact_dir/packet-tunnel-diagnostics.before.log" || true)"
        if [[ -n "$diagnostics_classification" ]]; then
            final_classification="$diagnostics_classification"
        elif [[ -s "$artifact_dir/packet-tunnel-diagnostics.before.log" ]] \
            && scenario_expects_vpn_session "$artifact_dir/scenario.json" \
            && ! diagnostics_has_new_session \
                "$artifact_dir/packet-tunnel-diagnostics.log" \
                "$artifact_dir/packet-tunnel-diagnostics.before.log" \
            && rg -q 'Step [0-9]+ failed: assert_text vpn:.*text not found: Started' "$test_log"; then
            final_classification="vpn_extension_not_started"
        fi
        log "test failed: $final_classification"
    fi
    local metric_attachments="$artifact_dir/wlt-metric-attachments"
    if ! export_wlt_metric_attachments "$result_bundle" "$metric_attachments"; then
        log "could not export WLT metric attachments; optimizer will classify the missing metrics as infrastructure"
    fi
    write_scenario_report "$test_log" "$metric_attachments"
    return "$test_status"
}

if [[ "${WLT_SCENARIO_LIBRARY_ONLY:-0}" != "1" ]]; then
    run
fi
