#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
device_id="${DEVICE_ID:-}"
base_configuration="${WLT_COMPARISON_CONFIGURATION:-$script_dir/device-scenarios/wlt-headless-lte.json}"
repetitions="${WLT_COMPARISON_REPETITIONS:-3}"
headless_timeout="${WLT_COMPARISON_HEADLESS_TIMEOUT_SECONDS:-2400}"
timestamp="$(date '+%Y-%m-%d-%H%M%S')"
artifact_dir="${WLT_COMPARISON_ARTIFACT_DIR:-$repo_root/.local/wlt-comparison-$timestamp}"
transition_script="$script_dir/iphone_network_transition.sh"
headless_script="$script_dir/iphone_wlt_headless.sh"
summarizer="$script_dir/summarize_wlt_comparison.py"
restored=0

log() {
    printf '[wlt-comparison] %s\n' "$*" >&2
}

die() {
    printf '[wlt-comparison] error: %s\n' "$*" >&2
    exit 1
}

validate_positive_integer() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$name must be a positive integer"
}

transition() {
    local mode="$1"
    local output_dir="$artifact_dir/transition-$mode"
    if [[ "$mode" == "wifi" ]]; then
        DEVICE_ID="$device_id" \
        WLT_TRANSITION_ALLOW_MIXED_WIFI=1 \
        WLT_TRANSITION_ARTIFACT_DIR="$output_dir" \
            "$transition_script" "$mode"
    else
        DEVICE_ID="$device_id" \
        WLT_TRANSITION_ARTIFACT_DIR="$output_dir" \
            "$transition_script" "$mode"
    fi
}

restore_wifi() {
    if [[ "$restored" == "1" ]]; then
        return
    fi
    log "restoring Wi-Fi and stopped VPN"
    if transition wifi; then
        restored=1
    fi
}

run_phase() {
    local name="$1"
    local configuration="$2"
    local output_dir="$artifact_dir/$name"
    local exit_status=0
    log "running $name"
    DEVICE_ID="$device_id" \
    WLT_HEADLESS_TIMEOUT_SECONDS="$headless_timeout" \
    WLT_HEADLESS_CONFIGURATION="$configuration" \
    WLT_HEADLESS_ARTIFACT_DIR="$output_dir" \
        "$headless_script" || exit_status=$?
    [[ -s "$output_dir/result.json" ]] \
        || die "$name produced no result.json"
    printf '%s\n' "$exit_status" >"$output_dir/exit-status.txt"
}

[[ -n "$device_id" ]] || die "DEVICE_ID is required"
[[ -f "$base_configuration" ]] || die "missing configuration: $base_configuration"
[[ -x "$transition_script" ]] || die "missing transition runner: $transition_script"
[[ -x "$headless_script" ]] || die "missing headless runner: $headless_script"
[[ -f "$summarizer" ]] || die "missing summarizer: $summarizer"
validate_positive_integer WLT_COMPARISON_REPETITIONS "$repetitions"
validate_positive_integer WLT_COMPARISON_HEADLESS_TIMEOUT_SECONDS "$headless_timeout"

mkdir -p "$artifact_dir/configuration"
trap restore_wifi EXIT

jq --argjson repetitions "$repetitions" '
  .run_id = "host-overrides-this-value" |
  .repetitions = $repetitions |
  .required_transport = "wifi" |
  .vpn_mode = "off" |
  # Web embeds are not acceptance-grade media oracles: YouTube can return
  # anti-bot/referrer error 152 and a fixed Twitch live channel can be offline.
  # Native YouTube/Twitch app scenarios provide the playback gate separately.
  .route_workloads |= map(.playback_probes = [])
' "$base_configuration" >"$artifact_dir/configuration/wifi-no-vpn.json"
jq --argjson repetitions "$repetitions" '
  .run_id = "host-overrides-this-value" |
  .repetitions = $repetitions |
  .required_transport = "cellular" |
  .vpn_mode = "wlt" |
  .route_workloads |= map(.playback_probes = [])
' "$base_configuration" >"$artifact_dir/configuration/lte-wlt.json"

transition wifi
run_phase wifi-no-vpn "$artifact_dir/configuration/wifi-no-vpn.json"
transition lte
run_phase lte-wlt "$artifact_dir/configuration/lte-wlt.json"
restore_wifi

python3 "$summarizer" \
    --wifi "$artifact_dir/wifi-no-vpn/result.json" \
    --wlt "$artifact_dir/lte-wlt/result.json" \
    --json-output "$artifact_dir/comparison.json" \
    --markdown-output "$artifact_dir/comparison.md"

verdict="$(jq -r '.verdict' "$artifact_dir/comparison.json")"
printf 'status=completed\nverdict=%s\nbaseline_restored=true\n' "$verdict" \
    >"$artifact_dir/status.txt"
printf '%s\n' "$artifact_dir"
[[ "$verdict" != "fail" ]]
