#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
device_id="${DEVICE_ID:-}"
configuration="${WLT_DUAL_SIM_CONFIGURATION:-$script_dir/device-scenarios/wlt-headless-lte-ru-sites-1mib.json}"
shortcut_name="${WLT_DUAL_SIM_SHORTCUT:-WLT Switch SIM}"
timeout_seconds="${WLT_DUAL_SIM_TIMEOUT_SECONDS:-600}"
timestamp="$(date '+%Y-%m-%d-%H%M%S')"
artifact_dir="${WLT_DUAL_SIM_ARTIFACT_DIR:-$repo_root/.local/wlt-dual-sim-$timestamp}"
coredevice_cli="${WLT_DUAL_SIM_COREDEVICE_CLI:-/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl}"
headless_script="$script_dir/iphone_wlt_headless.sh"
switched=0

log() {
    printf '[wlt-dual-sim] %s\n' "$*" >&2
}

die() {
    printf '[wlt-dual-sim] error: %s\n' "$*" >&2
    exit 1
}

shortcut_url() {
    local encoded
    encoded="$(jq -rn --arg value "$shortcut_name" '$value | @uri')"
    printf 'shortcuts://run-shortcut?name=%s' "$encoded"
}

capture_cellular_settings() {
    local label="$1"
    "$coredevice_cli" device process launch \
        --device "$device_id" \
        --payload-url 'prefs:root=MOBILE_DATA_SETTINGS_ID' \
        com.apple.Preferences \
        --timeout 45 \
        --quiet >/dev/null
    sleep 2
    "$coredevice_cli" device capture screenshot \
        --device "$device_id" \
        --destination "$artifact_dir/cellular-$label.png" \
        --json-output "$artifact_dir/cellular-$label.json" \
        --timeout 20 \
        --quiet >/dev/null
}

switch_data_sim() {
    local label="$1"
    log "running '$shortcut_name' on the physical iPhone ($label)"
    "$coredevice_cli" device process launch \
        --device "$device_id" \
        --terminate-existing \
        --payload-url "$(shortcut_url)" \
        com.apple.shortcuts \
        --timeout 45 \
        --json-output "$artifact_dir/shortcut-$label.json" \
        --log-output "$artifact_dir/shortcut-$label.log" >/dev/null
    sleep 8
}

restore_original_data_sim() {
    if [[ "$switched" == "1" ]]; then
        log "restoring the original cellular-data line"
        switch_data_sim restore
        switched=0
        capture_cellular_settings restored || true
    fi
}

run_headless() {
    local label="$1"
    local run_id="wlt-dual-sim-$timestamp-$label"
    log "running WLT scenario on $label"
    DEVICE_ID="$device_id" \
    WLT_HEADLESS_CONFIGURATION="$configuration" \
    WLT_HEADLESS_ARTIFACT_DIR="$artifact_dir/$label" \
    WLT_HEADLESS_RUN_ID="$run_id" \
    WLT_HEADLESS_TIMEOUT_SECONDS="$timeout_seconds" \
        "$headless_script"
}

[[ -n "$device_id" ]] || die "DEVICE_ID is required"
[[ -x "$coredevice_cli" ]] || die "devicectl is not executable: $coredevice_cli"
[[ -x "$headless_script" ]] || die "headless runner is not executable: $headless_script"
[[ -f "$configuration" ]] || die "configuration does not exist: $configuration"
command -v jq >/dev/null 2>&1 || die "jq is required"
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] \
    || die "WLT_DUAL_SIM_TIMEOUT_SECONDS must be a positive integer"

mkdir -p "$artifact_dir"
trap restore_original_data_sim EXIT

capture_cellular_settings original
run_headless sim-1

# The iPhone Shortcut owns line selection.  This host wrapper never opens an
# individual SIM row and never changes Default Voice Line or a plan's On/Off
# state.  Set the restoration flag before launch so even a partially completed
# Shortcut receives a compensating invocation on exit.
switched=1
switch_data_sim to-sim-2
capture_cellular_settings sim-2
run_headless sim-2

restore_original_data_sim
trap - EXIT
printf '%s\n' "$artifact_dir"
