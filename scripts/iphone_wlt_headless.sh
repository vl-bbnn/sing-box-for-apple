#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
device_id="${DEVICE_ID:-}"
configuration="${WLT_HEADLESS_CONFIGURATION:-$script_dir/device-scenarios/wlt-headless-lte.json}"
bundle_id="${WLT_HEADLESS_BUNDLE_ID:-pro.2b2n.vpn.dev}"
app_group="${WLT_HEADLESS_APP_GROUP:-group.pro.2b2n.vpn.dev}"
timeout_seconds="${WLT_HEADLESS_TIMEOUT_SECONDS:-1800}"
poll_seconds="${WLT_HEADLESS_POLL_SECONDS:-3}"
run_id="${WLT_HEADLESS_RUN_ID:-wlt-headless-$(date -u '+%Y%m%dT%H%M%SZ')}"
timestamp="$(date '+%Y-%m-%d-%H%M%S')"
artifact_dir="${WLT_HEADLESS_ARTIFACT_DIR:-$repo_root/.local/wlt-headless-$timestamp}"
coredevice_cli="${WLT_HEADLESS_COREDEVICE_CLI:-/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl}"
result_name="wlt-headless-result.json"
service_log_name="wlt-headless-service.log"
stderr_log_name="stderr.log"
wifi_shortcut="${WLT_HEADLESS_WIFI_SHORTCUT:-WLT WiFi}"
lte_shortcut="${WLT_HEADLESS_LTE_SHORTCUT:-WLT LTE}"
lte_rescan_shortcut="${WLT_HEADLESS_LTE_RESCAN_SHORTCUT:-wltrescan}"
lte_rescan_after_seconds="${WLT_HEADLESS_LTE_RESCAN_AFTER_SECONDS:-25}"
lte_rescan_attempts="${WLT_HEADLESS_LTE_RESCAN_ATTEMPTS:-2}"
prepare_transport="${WLT_HEADLESS_PREPARE_TRANSPORT:-1}"
refresh_profile="${WLT_HEADLESS_REFRESH_PROFILE:-0}"
candidate_file="${WLT_HEADLESS_CANDIDATE_FILE:-}"
transition_script="$script_dir/iphone_network_transition.sh"
refresh_script="$script_dir/iphone_wlt_profile_refresh.sh"

log() {
    printf '[wlt-headless] %s\n' "$*" >&2
}

die() {
    printf '[wlt-headless] error: %s\n' "$*" >&2
    exit 1
}

validate_positive_integer() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$name must be a positive integer"
}

copy_app_group_file() {
    local source_name="$1"
    local destination="$2"
    "$coredevice_cli" device copy from \
        --device "$device_id" \
        --domain-type appGroupDataContainer \
        --domain-identifier "$app_group" \
        --source "Library/Caches/$source_name" \
        --destination "$destination" \
        --timeout 30 \
        --quiet >/dev/null 2>&1
}

launch() {
    local cleanup="${1:-0}"
    local environment_json
    environment_json="$(jq -cn \
        --arg encoded "$encoded_configuration" \
        --arg run_id "$run_id" \
        --arg cleanup "$cleanup" \
        '{
          WLT_HEADLESS_SCENARIO:"1",
          WLT_HEADLESS_SCENARIO_BASE64:$encoded,
          WLT_HEADLESS_RUN_ID:$run_id,
          WLT_HEADLESS_CLEANUP:$cleanup
        }')"
    "$coredevice_cli" device process launch \
        --device "$device_id" \
        --terminate-existing \
        --environment-variables "$environment_json" \
        "$bundle_id" \
        --timeout 60 \
        --json-output "$artifact_dir/launch-cleanup-$cleanup.json" \
        --log-output "$artifact_dir/launch-cleanup-$cleanup.log"
}

shortcut_url() {
    local name="$1"
    local encoded
    encoded="$(jq -rn --arg value "$name" '$value | @uri')"
    printf 'shortcuts://run-shortcut?name=%s' "$encoded"
}

launch_shortcut() {
    local name="$1"
    local label="$2"
    "$coredevice_cli" device process launch \
        --device "$device_id" \
        --terminate-existing \
        --payload-url "$(shortcut_url "$name")" \
        com.apple.shortcuts \
        --timeout 45 \
        --json-output "$artifact_dir/shortcut-$label.json" \
        --log-output "$artifact_dir/shortcut-$label.log" >/dev/null
}

resume_headless_app() {
    local label="$1"
    # Running a Shortcut leaves Shortcuts in the foreground. iOS can then
    # suspend the app-side scenario before it observes the requested NWPath.
    # Launching the already-running app without --terminate-existing resumes
    # the same task and preserves the active VPN session.
    "$coredevice_cli" device process launch \
        --device "$device_id" \
        --timeout 60 \
        --json-output "$artifact_dir/resume-$label.json" \
        --log-output "$artifact_dir/resume-$label.log" \
        "$bundle_id" >/dev/null
}

launch_transition_shortcut() {
    local name="$1"
    local label="$2"
    launch_shortcut "$name" "$label"
    sleep 1
    resume_headless_app "$label"
}

copy_final_evidence() {
    copy_app_group_file "$result_name" "$artifact_dir/result.json" || true
    copy_support_evidence
}

copy_support_evidence() {
    copy_app_group_file "$service_log_name" "$artifact_dir/$service_log_name" || true
    copy_app_group_file "$stderr_log_name" "$artifact_dir/$stderr_log_name" || true
    copy_app_group_file "packet-tunnel-diagnostics.log" "$artifact_dir/packet-tunnel-diagnostics.log" || true
    copy_app_group_file "packet-tunnel-incidents.log" "$artifact_dir/packet-tunnel-incidents.log" || true
}

[[ -x "$coredevice_cli" ]] || die "devicectl is not executable: $coredevice_cli"
[[ -n "$device_id" ]] || die "DEVICE_ID is required"
[[ -f "$configuration" ]] || die "configuration does not exist: $configuration"
command -v jq >/dev/null 2>&1 || die "jq is required"
validate_positive_integer WLT_HEADLESS_TIMEOUT_SECONDS "$timeout_seconds"
validate_positive_integer WLT_HEADLESS_POLL_SECONDS "$poll_seconds"
validate_positive_integer WLT_HEADLESS_LTE_RESCAN_AFTER_SECONDS "$lte_rescan_after_seconds"
[[ "$lte_rescan_attempts" =~ ^[0-9]+$ ]] \
    || die "WLT_HEADLESS_LTE_RESCAN_ATTEMPTS must be a non-negative integer"
[[ "$prepare_transport" == "0" || "$prepare_transport" == "1" ]] \
    || die "WLT_HEADLESS_PREPARE_TRANSPORT must be 0 or 1"
[[ "$refresh_profile" == "0" || "$refresh_profile" == "1" ]] \
    || die "WLT_HEADLESS_REFRESH_PROFILE must be 0 or 1"
if [[ "$refresh_profile" == "1" ]]; then
    [[ -x "$refresh_script" ]] || die "profile refresh runner is missing"
    [[ -n "$candidate_file" && -f "$candidate_file" ]] \
        || die "WLT_HEADLESS_CANDIDATE_FILE is required for profile refresh"
fi

mkdir -p "$artifact_dir"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

jq --arg run_id "$run_id" '.run_id = $run_id' "$configuration" \
    >"$temporary_dir/configuration.json"
jq -e '
  (.run_id | type == "string" and length > 0) and
  (.repetitions | type == "number" and . >= 1) and
  (.required_transport == "cellular" or .required_transport == "wifi") and
  (.route_workloads | type == "array" and length > 0)
' "$temporary_dir/configuration.json" >/dev/null \
    || die "configuration failed host validation"
cp "$temporary_dir/configuration.json" "$artifact_dir/configuration.json"
encoded_configuration="$(base64 <"$temporary_dir/configuration.json" | tr -d '\n')"
has_network_recovery="$(jq -r '(.network_recovery_phases // []) | length > 0' \
    "$temporary_dir/configuration.json")"
required_transport="$(jq -r '.required_transport' "$temporary_dir/configuration.json")"
requires_wifi_restore="false"
if [[ "$required_transport" == "cellular" || "$has_network_recovery" == "true" ]]; then
    requires_wifi_restore="true"
fi

"$coredevice_cli" device info lockState \
    --device "$device_id" \
    --json-output "$artifact_dir/lock-state.json" \
    --quiet >/dev/null
jq -e '.result.passcodeRequired == false and .result.unlockedSinceBoot == true' \
    "$artifact_dir/lock-state.json" >/dev/null \
    || die "iPhone must be unlocked before launching the headless runner"

"$coredevice_cli" device capture screenshot \
    --device "$device_id" \
    --destination "$artifact_dir/screen-before.png" \
    --json-output "$artifact_dir/screen-before.json" \
    --timeout 20 \
    --quiet >/dev/null 2>&1 || true
"$coredevice_cli" device info apps \
    --device "$device_id" \
    --bundle-id "$bundle_id" \
    --json-output "$artifact_dir/installed-app.json" \
    --quiet >/dev/null
jq -e --arg bundle "$bundle_id" '
  [.result.apps[]? | select(.bundleIdentifier == $bundle)] | length == 1
' "$artifact_dir/installed-app.json" >/dev/null \
    || die "$bundle_id is not installed; install/trust it once on unrestricted Wi-Fi"

if [[ "$refresh_profile" == "1" ]]; then
    log "refreshing and verifying the selected remote profile on Wi-Fi"
    DEVICE_ID="$device_id" \
    WLT_REFRESH_BUNDLE_ID="$bundle_id" \
    WLT_REFRESH_APP_GROUP="$app_group" \
    WLT_REFRESH_CANDIDATE_FILE="$candidate_file" \
    WLT_REFRESH_ARTIFACT_DIR="$artifact_dir/profile-refresh" \
    WLT_REFRESH_COREDEVICE_CLI="$coredevice_cli" \
        "$refresh_script" >/dev/null
fi

if [[ "$prepare_transport" == "1" ]]; then
    transition_mode="wifi"
    if [[ "$required_transport" == "cellular" ]]; then
        transition_mode="lte"
    fi
    log "preparing initial $required_transport path through device-only transition"
    DEVICE_ID="$device_id" \
    WLT_TRANSITION_BUNDLE_ID="$bundle_id" \
    WLT_TRANSITION_APP_GROUP="$app_group" \
    WLT_TRANSITION_ARTIFACT_DIR="$artifact_dir/initial-$transition_mode" \
    WLT_TRANSITION_COREDEVICE_CLI="$coredevice_cli" \
    WLT_TRANSITION_LTE_RESCAN_SHORTCUT="$lte_rescan_shortcut" \
    WLT_TRANSITION_LTE_RESCAN_ATTEMPTS="$lte_rescan_attempts" \
        "$transition_script" "$transition_mode" >/dev/null
fi

log "launching installed app without XCTest or Automation Mode (run_id=$run_id)"
launch 0 >/dev/null

deadline=$((SECONDS + timeout_seconds))
attempt=0
final_status=""
handled_transition_id=""
handled_transition_transport=""
transition_started_seconds=0
transition_attempt=0
lte_rescan_count=0
while ((SECONDS < deadline)); do
    attempt=$((attempt + 1))
    poll_file="$temporary_dir/result-$attempt.json"
    if copy_app_group_file "$result_name" "$poll_file" \
        && jq -e --arg run_id "$run_id" '.run_id == $run_id' "$poll_file" >/dev/null 2>&1; then
        final_status="$(jq -r '.status // "unknown"' "$poll_file")"
        cp "$poll_file" "$artifact_dir/result.json"
        log "status=$final_status"
        transition_id="$(jq -r '.transition_request.id // empty' "$poll_file")"
        transition_transport="$(jq -r '.transition_request.transport // empty' "$poll_file")"
        if [[ -n "$transition_id" && ( \
            "$transition_id" != "$handled_transition_id" || \
            "$transition_transport" != "$handled_transition_transport" \
        ) ]]; then
            transition_attempt=$((transition_attempt + 1))
            handled_transition_id="$transition_id"
            handled_transition_transport="$transition_transport"
            transition_started_seconds=$SECONDS
            lte_rescan_count=0
            case "$transition_transport" in
                wifi)
                    log "checkpoint=$transition_id: requesting device-only Wi-Fi"
                    launch_transition_shortcut \
                        "$wifi_shortcut" "transition-$transition_attempt-wifi"
                    ;;
                cellular)
                    log "checkpoint=$transition_id: requesting device-only LTE"
                    launch_transition_shortcut \
                        "$lte_shortcut" "transition-$transition_attempt-lte"
                    ;;
                *)
                    die "unsupported app-side transition request: $transition_transport"
                    ;;
            esac
        elif [[ -n "$transition_id" \
            && "$transition_transport" == "cellular" \
            && "$handled_transition_transport" == "cellular" \
            && "$lte_rescan_count" -lt "$lte_rescan_attempts" \
            && $((SECONDS - transition_started_seconds)) -ge "$lte_rescan_after_seconds" ]]; then
            lte_rescan_count=$((lte_rescan_count + 1))
            transition_started_seconds=$SECONDS
            log "LTE checkpoint still pending; requesting airplane-mode rescan ($lte_rescan_count/$lte_rescan_attempts)"
            launch_transition_shortcut "$lte_rescan_shortcut" \
                "transition-$transition_attempt-rescan-$lte_rescan_count"
        fi
        case "$final_status" in
            passed | failed)
                break
                ;;
        esac
    fi
    sleep "$poll_seconds"
done

if [[ "$final_status" != "passed" && "$final_status" != "failed" ]]; then
    log "runner timed out; launching the app-side cleanup path"
    copy_app_group_file "$result_name" "$artifact_dir/partial-result.json" || true
    launch 1 >/dev/null || true
    sleep 5
    copy_app_group_file "$result_name" "$artifact_dir/cleanup-result.json" || true
    if [[ "$requires_wifi_restore" == "true" ]]; then
        DEVICE_ID="$device_id" \
        WLT_TRANSITION_ARTIFACT_DIR="$artifact_dir/timeout-wifi-restore" \
        WLT_TRANSITION_ALLOW_MIXED_WIFI=1 \
            "$transition_script" wifi || true
    fi
    copy_support_evidence
    printf 'run_id=%s\nstatus=host_timeout\n' "$run_id" >"$artifact_dir/status.txt"
    die "headless runner did not finish within ${timeout_seconds}s"
fi

copy_final_evidence
wifi_restored="not_requested"
if [[ "$requires_wifi_restore" == "true" ]]; then
    log "cellular scenario finished; restoring stopped VPN plus Wi-Fi"
    if DEVICE_ID="$device_id" \
        WLT_TRANSITION_ARTIFACT_DIR="$artifact_dir/final-wifi-restore" \
        WLT_TRANSITION_ALLOW_MIXED_WIFI=1 \
        "$transition_script" wifi; then
        wifi_restored="true"
    else
        wifi_restored="false"
    fi
fi
"$coredevice_cli" device capture screenshot \
    --device "$device_id" \
    --destination "$artifact_dir/screen-after.png" \
    --json-output "$artifact_dir/screen-after.json" \
    --timeout 20 \
    --quiet >/dev/null 2>&1 || true
printf 'run_id=%s\nstatus=%s\nwifi_restored=%s\n' \
    "$run_id" "$final_status" "$wifi_restored" >"$artifact_dir/status.txt"
printf '%s\n' "$artifact_dir"
[[ "$final_status" == "passed" && "$wifi_restored" != "false" ]]
