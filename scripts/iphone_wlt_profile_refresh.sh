#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
device_id="${DEVICE_ID:-}"
bundle_id="${WLT_REFRESH_BUNDLE_ID:-pro.2b2n.vpn.dev}"
app_group="${WLT_REFRESH_APP_GROUP:-group.pro.2b2n.vpn.dev}"
candidate_file="${WLT_REFRESH_CANDIDATE_FILE:-}"
timeout_seconds="${WLT_REFRESH_TIMEOUT_SECONDS:-120}"
poll_seconds="${WLT_REFRESH_POLL_SECONDS:-2}"
timestamp="$(date '+%Y-%m-%d-%H%M%S')"
artifact_dir="${WLT_REFRESH_ARTIFACT_DIR:-$repo_root/.local/wlt-profile-refresh-$timestamp}"
coredevice_cli="${WLT_REFRESH_COREDEVICE_CLI:-/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl}"
transition_script="$script_dir/iphone_network_transition.sh"
verifier="$script_dir/verify_wlt_runtime_candidate.py"
service_log_name="wlt-device-service.log"
refresh_verified=0
wifi_restored=0

log() {
    printf '[wlt-profile-refresh] %s\n' "$*" >&2
}

die() {
    printf '[wlt-profile-refresh] error: %s\n' "$*" >&2
    exit 2
}

copy_service_log() {
    local destination="$1"
    "$coredevice_cli" device copy from \
        --device "$device_id" \
        --domain-type appGroupDataContainer \
        --domain-identifier "$app_group" \
        --source "Library/Caches/$service_log_name" \
        --destination "$destination" \
        --timeout 30 \
        --quiet >/dev/null 2>&1
}

restore_wifi() {
    if [[ "$wifi_restored" == "1" ]]; then
        return
    fi
    DEVICE_ID="$device_id" \
    WLT_TRANSITION_BUNDLE_ID="$bundle_id" \
    WLT_TRANSITION_APP_GROUP="$app_group" \
    WLT_TRANSITION_ARTIFACT_DIR="$artifact_dir/final-wifi" \
    WLT_TRANSITION_COREDEVICE_CLI="$coredevice_cli" \
    WLT_TRANSITION_ALLOW_MIXED_WIFI=1 \
        "$transition_script" wifi >/dev/null 2>&1 || true
}

[[ -n "$device_id" ]] || die "DEVICE_ID is required"
[[ -x "$coredevice_cli" ]] || die "devicectl is not executable: $coredevice_cli"
[[ -x "$transition_script" ]] || die "network transition runner is missing"
[[ -x "$verifier" ]] || die "runtime candidate verifier is missing"
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] \
    || die "WLT_REFRESH_TIMEOUT_SECONDS must be a positive integer"
[[ "$poll_seconds" =~ ^[1-9][0-9]*$ ]] \
    || die "WLT_REFRESH_POLL_SECONDS must be a positive integer"
if [[ -n "$candidate_file" ]]; then
    [[ -f "$candidate_file" ]] || die "candidate file does not exist"
    verifier_status=0
    "$verifier" "$candidate_file" /dev/null >/dev/null 2>&1 \
        || verifier_status=$?
    [[ "$verifier_status" == "1" ]] \
        || die "candidate file failed schema validation"
fi

mkdir -p "$artifact_dir"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"; restore_wifi' EXIT

"$coredevice_cli" device info lockState \
    --device "$device_id" \
    --json-output "$artifact_dir/lock-state.json" \
    --quiet >/dev/null
jq -e '.result.passcodeRequired == false and .result.unlockedSinceBoot == true' \
    "$artifact_dir/lock-state.json" >/dev/null \
    || die "iPhone must be unlocked before refreshing the profile"

"$coredevice_cli" device info apps \
    --device "$device_id" \
    --bundle-id "$bundle_id" \
    --json-output "$artifact_dir/installed-app.json" \
    --quiet >/dev/null
jq -e --arg bundle "$bundle_id" '
  [.result.apps[]? | select(.bundleIdentifier == $bundle)] | length == 1
' "$artifact_dir/installed-app.json" >/dev/null \
    || die "$bundle_id is not installed"

log "proving unrestricted Wi-Fi before remote-profile refresh"
DEVICE_ID="$device_id" \
WLT_TRANSITION_BUNDLE_ID="$bundle_id" \
WLT_TRANSITION_APP_GROUP="$app_group" \
WLT_TRANSITION_ARTIFACT_DIR="$artifact_dir/initial-wifi" \
WLT_TRANSITION_COREDEVICE_CLI="$coredevice_cli" \
    "$transition_script" wifi >/dev/null

before_hash="missing"
if copy_service_log "$temporary_dir/before.log"; then
    before_hash="$(shasum -a 256 "$temporary_dir/before.log" | awk '{print $1}')"
fi

environment_json="$(jq -cn '{
  WLT_DEVICE_AUTOSTART:"1",
  WLT_DEVICE_AUTOSTART_REFRESH_PROFILE:"1",
  WLT_DEVICE_SCENARIO:"1"
}')"
log "refreshing selected remote profile inside the installed app"
"$coredevice_cli" device process launch \
    --device "$device_id" \
    --terminate-existing \
    --environment-variables "$environment_json" \
    "$bundle_id" \
    --timeout 60 \
    --json-output "$artifact_dir/launch.json" \
    --log-output "$artifact_dir/launch.log" >/dev/null

deadline=$((SECONDS + timeout_seconds))
while ((SECONDS < deadline)); do
    current_log="$temporary_dir/current.log"
    if copy_service_log "$current_log"; then
        current_hash="$(shasum -a 256 "$current_log" | awk '{print $1}')"
        if [[ "$current_hash" != "$before_hash" ]]; then
            if [[ -z "$candidate_file" ]]; then
                cp "$current_log" "$artifact_dir/$service_log_name"
                refresh_verified=1
                break
            fi
            if "$verifier" "$candidate_file" "$current_log" \
                >"$artifact_dir/runtime-verification.json"; then
                cp "$current_log" "$artifact_dir/$service_log_name"
                refresh_verified=1
                break
            fi
        fi
    fi
    sleep "$poll_seconds"
done

[[ "$refresh_verified" == "1" ]] \
    || die "remote profile did not expose the requested runtime candidate"

log "refresh verified; stopping VPN and restoring Wi-Fi"
DEVICE_ID="$device_id" \
WLT_TRANSITION_BUNDLE_ID="$bundle_id" \
WLT_TRANSITION_APP_GROUP="$app_group" \
WLT_TRANSITION_ARTIFACT_DIR="$artifact_dir/final-wifi" \
WLT_TRANSITION_COREDEVICE_CLI="$coredevice_cli" \
WLT_TRANSITION_ALLOW_MIXED_WIFI=1 \
    "$transition_script" wifi >/dev/null
wifi_restored=1
printf 'status=passed\ncandidate_verified=%s\n' \
    "$([[ -n "$candidate_file" ]] && printf true || printf false)" \
    >"$artifact_dir/status.txt"
trap - EXIT
rm -rf "$temporary_dir"
printf '%s\n' "$artifact_dir"
