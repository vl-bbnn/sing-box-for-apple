#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
mode="${1:-}"
device_id="${DEVICE_ID:-}"
bundle_id="${WLT_TRANSITION_BUNDLE_ID:-pro.2b2n.vpn.dev}"
app_group="${WLT_TRANSITION_APP_GROUP:-group.pro.2b2n.vpn.dev}"
timeout_seconds="${WLT_TRANSITION_TIMEOUT_SECONDS:-120}"
poll_seconds="${WLT_TRANSITION_POLL_SECONDS:-5}"
restore_on_failure="${WLT_TRANSITION_RESTORE_ON_FAILURE:-1}"
lte_rescan_shortcut="${WLT_TRANSITION_LTE_RESCAN_SHORTCUT:-wltrescan}"
lte_rescan_attempts="${WLT_TRANSITION_LTE_RESCAN_ATTEMPTS:-2}"
lte_rescan_wait_seconds="${WLT_TRANSITION_LTE_RESCAN_WAIT_SECONDS:-12}"
force_lte_rescan="${WLT_TRANSITION_FORCE_LTE_RESCAN:-0}"
allow_mixed_wifi="${WLT_TRANSITION_ALLOW_MIXED_WIFI:-0}"
coredevice_cli="${WLT_TRANSITION_COREDEVICE_CLI:-/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl}"
timestamp="$(date '+%Y-%m-%d-%H%M%S')"
artifact_dir="${WLT_TRANSITION_ARTIFACT_DIR:-$repo_root/.local/iphone-network-transition-$timestamp}"
result_name="wlt-headless-result.json"
last_non_lte_result=""
probe_generation=0

log() {
    printf '[iphone-network-transition] %s\n' "$*" >&2
}

die() {
    printf '[iphone-network-transition] error: %s\n' "$*" >&2
    exit 1
}

validate_positive_integer() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$name must be a positive integer"
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

copy_probe_result() {
    local destination="$1"
    "$coredevice_cli" device copy from \
        --device "$device_id" \
        --domain-type appGroupDataContainer \
        --domain-identifier "$app_group" \
        --source "Library/Caches/$result_name" \
        --destination "$destination" \
        --timeout 30 \
        --quiet >/dev/null 2>&1
}

launch_network_probe() {
    local run_id="$1"
    local expected="$2"
    local encoded_configuration environment_json
    jq -cn \
        --arg run_id "$run_id" \
        --arg required_transport "$expected" \
        '{
          run_id:$run_id,
          repetitions:1,
          required_transport:$required_transport,
          startup_timeout_seconds:30,
          settle_seconds:0,
          route_workloads:[{
            route:"ru",
            http_probes:[{
              name:"network-probe-placeholder",
              url:"https://example.com/",
              minimum_bytes:0,
              timeout_seconds:5,
              resource_sample_limit:0,
              policy_status_codes:[]
            }],
            playback_probes:[]
          }]
        }' >"$temporary_dir/probe-configuration.json"
    encoded_configuration="$(base64 <"$temporary_dir/probe-configuration.json" | tr -d '\n')"
    environment_json="$(jq -cn \
        --arg encoded "$encoded_configuration" \
        --arg run_id "$run_id" \
        '{
          WLT_HEADLESS_SCENARIO:"1",
          WLT_HEADLESS_SCENARIO_BASE64:$encoded,
          WLT_HEADLESS_RUN_ID:$run_id,
          WLT_HEADLESS_CLEANUP:"1"
        }')"
    "$coredevice_cli" device process launch \
        --device "$device_id" \
        --terminate-existing \
        --environment-variables "$environment_json" \
        "$bundle_id" \
        --timeout 45 \
        --json-output "$artifact_dir/probe-launch-$run_id.json" \
        --log-output "$artifact_dir/probe-launch-$run_id.log" >/dev/null
}

probe_matches() {
    local path="$1"
    local expected="$2"
    if [[ "$expected" == "cellular" ]]; then
        jq -e '
          .status == "cleanup_completed" and
          .network_final.status == "satisfied" and
          .network_final.wifi == false and
          .network_final.cellular == true and
          (.network_final.radio_technology |
            IN("CTRadioAccessTechnologyLTE", "CTRadioAccessTechnologyNR", "CTRadioAccessTechnologyNRNSA"))
        ' "$path" >/dev/null
    else
        if [[ "$allow_mixed_wifi" == "1" ]]; then
            jq -e '
              .status == "cleanup_completed" and
              .network_final.status == "satisfied" and
              .network_final.wifi == true
            ' "$path" >/dev/null
        else
            jq -e '
              .status == "cleanup_completed" and
              .network_final.status == "satisfied" and
              .network_final.wifi == true and
              .network_final.cellular == false
            ' "$path" >/dev/null
        fi
    fi
}

probe_is_non_lte_cellular() {
    local path="$1"
    jq -e '
      .status == "cleanup_completed" and
      .network_final.status == "satisfied" and
      .network_final.wifi == false and
      .network_final.cellular == true and
      ((.network_final.radio_technology // "") |
        IN("CTRadioAccessTechnologyLTE", "CTRadioAccessTechnologyNR", "CTRadioAccessTechnologyNRNSA") | not)
    ' "$path" >/dev/null
}

wait_for_transport() {
    local expected="$1"
    local deadline attempt run_id result_path poll_deadline
    probe_generation=$((probe_generation + 1))
    deadline=$((SECONDS + timeout_seconds))
    attempt=0
    while ((SECONDS < deadline)); do
        attempt=$((attempt + 1))
        run_id="wlt-network-$expected-$timestamp-$probe_generation-$attempt"
        result_path="$temporary_dir/result-$attempt.json"
        launch_network_probe "$run_id" "$expected"
        poll_deadline=$((SECONDS + 20))
        while ((SECONDS < poll_deadline)); do
            if copy_probe_result "$result_path" \
                && jq -e --arg run_id "$run_id" \
                    '.run_id == $run_id and .status == "cleanup_completed"' \
                    "$result_path" >/dev/null 2>&1; then
                cp "$result_path" "$artifact_dir/network-probe-$probe_generation-$attempt.json"
                jq -c '.network_final' "$result_path" >&2
                if probe_matches "$result_path" "$expected"; then
                    cp "$result_path" "$artifact_dir/result.json"
                    return 0
                fi
                if [[ "$expected" == "cellular" ]] \
                    && probe_is_non_lte_cellular "$result_path"; then
                    last_non_lte_result="$artifact_dir/non-lte-cellular-$probe_generation-$attempt.json"
                    cp "$result_path" "$last_non_lte_result"
                    return 2
                fi
                break
            fi
            sleep 1
        done
        sleep "$poll_seconds"
    done
    return 1
}

case "$mode" in
    lte)
        shortcut_name="WLT LTE"
        expected_transport="cellular"
        ;;
    wifi)
        shortcut_name="WLT WiFi"
        expected_transport="wifi"
        ;;
    *) die "usage: $0 lte|wifi" ;;
esac

[[ -x "$coredevice_cli" ]] || die "devicectl is not executable: $coredevice_cli"
[[ -n "$device_id" ]] || die "DEVICE_ID is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
validate_positive_integer WLT_TRANSITION_TIMEOUT_SECONDS "$timeout_seconds"
validate_positive_integer WLT_TRANSITION_POLL_SECONDS "$poll_seconds"
[[ "$lte_rescan_attempts" =~ ^[0-9]+$ ]] \
    || die "WLT_TRANSITION_LTE_RESCAN_ATTEMPTS must be a non-negative integer"
validate_positive_integer WLT_TRANSITION_LTE_RESCAN_WAIT_SECONDS "$lte_rescan_wait_seconds"
[[ "$force_lte_rescan" == "0" || "$force_lte_rescan" == "1" ]] \
    || die "WLT_TRANSITION_FORCE_LTE_RESCAN must be 0 or 1"
[[ "$allow_mixed_wifi" == "0" || "$allow_mixed_wifi" == "1" ]] \
    || die "WLT_TRANSITION_ALLOW_MIXED_WIFI must be 0 or 1"
[[ "$restore_on_failure" == "0" || "$restore_on_failure" == "1" ]] \
    || die "WLT_TRANSITION_RESTORE_ON_FAILURE must be 0 or 1"

mkdir -p "$artifact_dir"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

"$coredevice_cli" device info lockState \
    --device "$device_id" \
    --json-output "$artifact_dir/lock-state.json" \
    --quiet >/dev/null
jq -e '.result.passcodeRequired == false and .result.unlockedSinceBoot == true' \
    "$artifact_dir/lock-state.json" >/dev/null \
    || die "iPhone must be unlocked before running the network transition"

"$coredevice_cli" device capture screenshot \
    --device "$device_id" \
    --destination "$artifact_dir/screen-before.png" \
    --json-output "$artifact_dir/screen-before.json" \
    --timeout 20 \
    --quiet >/dev/null 2>&1 || true

log "running '$shortcut_name' through CoreDevice"
launch_shortcut "$shortcut_name" "$mode"
sleep 8
rescan_count=0
if [[ "$mode" == "lte" && "$force_lte_rescan" == "1" ]]; then
    rescan_count=1
    log "forcing '$lte_rescan_shortcut' for transition qualification"
    launch_shortcut "$lte_rescan_shortcut" "lte-rescan-forced"
    sleep "$lte_rescan_wait_seconds"
fi
transport_proven=0
while true; do
    wait_status=0
    wait_for_transport "$expected_transport" || wait_status=$?
    if [[ "$wait_status" == "0" ]]; then
        transport_proven=1
        break
    fi
    if [[ "$mode" == "lte" && "$wait_status" == "2" \
        && "$rescan_count" -lt "$lte_rescan_attempts" ]]; then
        rescan_count=$((rescan_count + 1))
        radio="$(jq -r '.network_final.radio_technology // "unknown"' \
            "$last_non_lte_result")"
        log "cellular attached as $radio; running '$lte_rescan_shortcut' ($rescan_count/$lte_rescan_attempts)"
        launch_shortcut "$lte_rescan_shortcut" "lte-rescan-$rescan_count"
        sleep "$lte_rescan_wait_seconds"
        continue
    fi
    break
done

if [[ "$transport_proven" != "1" ]]; then
    if [[ "$mode" == "lte" && "$restore_on_failure" == "1" ]]; then
        log "LTE/5G was not proven; restoring Wi-Fi"
        launch_shortcut "WLT WiFi" "failure-restore" || true
        sleep 8
        wait_for_transport wifi || true
    fi
    printf 'mode=%s\nstatus=precondition_failed\n' "$mode" >"$artifact_dir/status.txt"
    die "did not prove the requested $expected_transport path within ${timeout_seconds}s"
fi

"$coredevice_cli" device capture screenshot \
    --device "$device_id" \
    --destination "$artifact_dir/screen-after.png" \
    --json-output "$artifact_dir/screen-after.json" \
    --timeout 20 \
    --quiet >/dev/null 2>&1 || true
printf 'mode=%s\nstatus=passed\nlte_rescans=%s\nallow_mixed_wifi=%s\n' \
    "$mode" "$rescan_count" "$allow_mixed_wifi" >"$artifact_dir/status.txt"
printf '%s\n' "$artifact_dir"
