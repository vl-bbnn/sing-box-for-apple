#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
device_id="${DEVICE_ID:?DEVICE_ID is required}"
bundle_id="${WLT_APP_BUNDLE_ID:?WLT_APP_BUNDLE_ID is required}"
control_script="${WLT_STABILITY_CONTROL_SCRIPT:-$script_dir/iphone_wlt_control.sh}"
shortcut_script="${WLT_STABILITY_SHORTCUT_SCRIPT:-$script_dir/iphone_wlt_shortcut.sh}"
duration_seconds="${WLT_STABILITY_DURATION_SECONDS:-1800}"
probe_interval_seconds="${WLT_STABILITY_PROBE_INTERVAL_SECONDS:-30}"
allow_short="${WLT_STABILITY_ALLOW_SHORT:-0}"
inject_loss="${WLT_STABILITY_INJECT_LOSS:-1}"
loss_after_seconds="${WLT_STABILITY_LOSS_AFTER_SECONDS:-}"
prepare_lte="${WLT_STABILITY_PREPARE_LTE:-1}"
restore_wifi="${WLT_STABILITY_RESTORE_WIFI:-1}"
lte_shortcut="${WLT_STABILITY_LTE_SHORTCUT:-WLT LTE}"
loss_shortcut="${WLT_STABILITY_LOSS_SHORTCUT:-wltrescan}"
wifi_shortcut="${WLT_STABILITY_WIFI_SHORTCUT:-WLT WiFi}"
transport_timeout_seconds="${WLT_STABILITY_TRANSPORT_TIMEOUT_SECONDS:-90}"
candidate_file="${WLT_STABILITY_CANDIDATE_FILE:-}"
workload_file="${WLT_STABILITY_WORKLOAD_FILE:-}"
timestamp="$(date '+%Y-%m-%d-%H%M%S')"
artifact_dir="${WLT_STABILITY_ARTIFACT_DIR:-$repo_root/.local/wlt-stability-$timestamp}"
vpn_started=0
wifi_restored=0

log() {
  printf '[wlt-stability] %s\n' "$*" >&2
}

die() {
  printf '[wlt-stability] error: %s\n' "$*" >&2
  exit 1
}

require_positive_integer() {
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "$1 must be a positive integer"
}

run_control() {
  local action="$1" label="$2"
  shift 2
  DEVICE_ID="$device_id" \
  WLT_APP_BUNDLE_ID="$bundle_id" \
  WLT_CONTROL_ARTIFACT_DIR="$artifact_dir/$label" \
    "$@" "$control_script" "$action"
}

run_shortcut() {
  local shortcut="$1" label="$2" resume="${3:-$bundle_id}"
  DEVICE_ID="$device_id" \
  WLT_SHORTCUT_ARTIFACT_DIR="$artifact_dir/$label" \
  WLT_SHORTCUT_RESUME_BUNDLE_ID="$resume" \
    "$shortcut_script" "$shortcut"
}

strict_cellular_status() {
  /usr/bin/python3 -c '
import json, sys
value = json.load(sys.stdin)
network = value.get("network_final") or {}
ok = (
    value.get("state") == "succeeded"
    and network.get("status") == "satisfied"
    and network.get("cellular") is True
    and network.get("wifi") is False
)
raise SystemExit(0 if ok else 1)
'
}

wait_for_cellular() {
  local deadline status_file attempt=0
  deadline=$((SECONDS + transport_timeout_seconds))
  while (( SECONDS < deadline )); do
    attempt=$((attempt + 1))
    status_file="$artifact_dir/lte-status-$(printf '%03d' "$attempt").json"
    if run_control status "lte-status-$(printf '%03d' "$attempt")" \
      >"$status_file" 2>"$status_file.log" \
      && strict_cellular_status <"$status_file"
    then
      cp "$status_file" "$artifact_dir/lte-ready.json"
      return 0
    fi
    sleep 1
  done
  return 1
}

retryable_start_failure() {
  /usr/bin/python3 -c '
import json, sys
try:
    value = json.load(sys.stdin)
except (json.JSONDecodeError, OSError):
    raise SystemExit(1)
milestones = value.get("startup_milestones") or []
retryable = (
    value.get("state") == "failed"
    and value.get("vpn_status") == "disconnected"
    and value.get("error_code") == 10
    and "carrier_start_failed_connect" in milestones
)
raise SystemExit(0 if retryable else 1)
'
}

classify_injected_recovery() {
  local soak_file="$1"
  /usr/bin/python3 - "$soak_file" "$loss_after_seconds" "$probe_interval_seconds" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
loss_after_ms = int(sys.argv[2]) * 1000
interval_ms = int(sys.argv[3]) * 1000
value = json.loads(path.read_text())
samples = value.get("soak_probe_samples") or []
pre_loss_success = any(
    sample.get("success") is True
    and (sample.get("offset_ms") or 0) < loss_after_ms
    for sample in samples
)
post_window = [
    sample for sample in samples
    if (sample.get("offset_ms") or 0) >= loss_after_ms - interval_ms // 2
]
failure_index = next(
    (index for index, sample in enumerate(post_window)
     if sample.get("success") is False),
    None,
)
recovered = bool(
    failure_index is not None
    and any(sample.get("success") is True for sample in post_window[failure_index + 1:])
)
if pre_loss_success and failure_index is not None:
    value["network_loss_observed"] = True
    value["network_loss_source"] = "probe_transition_after_host_injection"
if pre_loss_success and recovered:
    value["network_recovered"] = True
    value["network_recovery_source"] = "probe_success_after_observed_loss"
temporary = path.with_suffix(path.suffix + ".tmp")
temporary.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
temporary.replace(path)
PY
}

run_host_driven_soak() {
  local started_at="$SECONDS" deadline next_probe sample=0 probe_status=0
  local probe_file delay attempt
  deadline=$((started_at + duration_seconds))
  next_probe="$started_at"
  while true; do
    sample=$((sample + 1))
    probe_file="$artifact_dir/soak-probe-$(printf '%03d' "$sample").json"
    for attempt in 1 2; do
      probe_status=0
      run_control probe \
        "soak-probe-$(printf '%03d' "$sample")-attempt-$attempt" \
        >"$probe_file" 2>"$probe_file.log" || probe_status=$?
      # Retry only a missing control result. A sanitized failed probe is real
      # transport evidence and must remain a failed sample.
      [[ "$probe_status" == "0" || -s "$probe_file" ]] && break
      sleep 2
    done
    printf '%s\t%s\t%s\t%s\n' \
      "$sample" "$probe_status" "$((SECONDS - started_at))" "$attempt" \
      >>"$artifact_dir/soak-probe-status.tsv"
    if [[ "$probe_status" != "0" && ! -s "$probe_file" ]]; then
      log "CoreDevice produced no result for soak sample $sample after $attempt attempts"
      return 2
    fi
    (( SECONDS >= deadline )) && break
    next_probe=$((next_probe + probe_interval_seconds))
    (( next_probe > deadline )) && next_probe="$deadline"
    delay=$((next_probe - SECONDS))
    (( delay > 0 )) && sleep "$delay"
  done

  /usr/bin/python3 - \
    "$artifact_dir" "$((SECONDS - started_at))" >"$artifact_dir/soak.json" <<'PY'
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
elapsed_ms = int(sys.argv[2]) * 1000
offsets = {}
try:
    for line in (root / "soak-probe-status.tsv").read_text().splitlines():
        index, _, offset, _ = line.split("\t")
        offsets[int(index)] = int(offset) * 1000
except (OSError, ValueError):
    pass
samples = []
paths = sorted(root.glob("soak-probe-*.json"))
for index, path in enumerate(paths, 1):
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        value = {}
    success = (
        value.get("state") == "succeeded"
        and value.get("vpn_status") == "connected"
    )
    samples.append({
        "offset_ms": offsets.get(index, 0),
        "success": success,
        "elapsed_ms": value.get("probe_elapsed_ms") or value.get("elapsed_ms") or 0,
        "network": value.get("network_final"),
        "error_domain": value.get("error_domain"),
        "error_code": value.get("error_code"),
    })
failures = sum(not sample["success"] for sample in samples)
last = {}
if paths:
    try:
        last = json.loads(paths[-1].read_text())
    except (OSError, json.JSONDecodeError):
        pass
payload = {
    "schema": 4,
    "action": "soak",
    "state": "succeeded" if samples and failures == 0 else "failed",
    "vpn_status": last.get("vpn_status", "unknown"),
    "elapsed_ms": elapsed_ms,
    "soak_elapsed_ms": elapsed_ms,
    "soak_samples": len(samples),
    "soak_successes": len(samples) - failures,
    "soak_failures": failures,
    "soak_probe_samples": samples,
    "network_loss_observed": False,
    "network_recovered": False,
    "network_initial": samples[0].get("network") if samples else None,
    "network_final": last.get("network_final"),
    "error_domain": None,
    "error_code": None,
}
print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
PY
}

restore_baseline() {
  local status=$?
  trap - EXIT INT TERM HUP
  if [[ "$vpn_started" == "1" ]]; then
    run_control stop emergency-stop >/dev/null 2>&1 || true
    vpn_started=0
  fi
  if [[ "$restore_wifi" == "1" && "$wifi_restored" != "1" ]]; then
    run_shortcut "$wifi_shortcut" emergency-wifi-restore "" >/dev/null 2>&1 || true
  fi
  exit "$status"
}

[[ -x "$control_script" ]] || die "missing control script: $control_script"
[[ -x "$shortcut_script" ]] || die "missing shortcut script: $shortcut_script"
[[ "$bundle_id" =~ ^[A-Za-z0-9.-]+$ ]] || die "WLT_APP_BUNDLE_ID is invalid"
for pair in \
  "WLT_STABILITY_DURATION_SECONDS:$duration_seconds" \
  "WLT_STABILITY_PROBE_INTERVAL_SECONDS:$probe_interval_seconds" \
  "WLT_STABILITY_TRANSPORT_TIMEOUT_SECONDS:$transport_timeout_seconds"
do
  require_positive_integer "${pair%%:*}" "${pair#*:}"
done
[[ "$allow_short" == "0" || "$allow_short" == "1" ]] \
  || die "WLT_STABILITY_ALLOW_SHORT must be 0 or 1"
[[ "$inject_loss" == "0" || "$inject_loss" == "1" ]] \
  || die "WLT_STABILITY_INJECT_LOSS must be 0 or 1"
[[ "$prepare_lte" == "0" || "$prepare_lte" == "1" ]] \
  || die "WLT_STABILITY_PREPARE_LTE must be 0 or 1"
[[ "$restore_wifi" == "0" || "$restore_wifi" == "1" ]] \
  || die "WLT_STABILITY_RESTORE_WIFI must be 0 or 1"
(( duration_seconds <= 1800 )) || die "duration must not exceed 1800 seconds"
if [[ "$allow_short" != "1" ]]; then
  (( duration_seconds >= 900 )) || die "acceptance soak must last at least 900 seconds"
fi
(( probe_interval_seconds <= 300 && probe_interval_seconds <= duration_seconds )) \
  || die "probe interval must be at most 300 seconds and no greater than duration"
if [[ -z "$loss_after_seconds" ]]; then
  loss_after_seconds=$((duration_seconds / 2))
fi
if [[ "$inject_loss" == "1" ]]; then
  require_positive_integer WLT_STABILITY_LOSS_AFTER_SECONDS "$loss_after_seconds"
  (( loss_after_seconds < duration_seconds )) \
    || die "loss injection must occur before the soak ends"
fi
if [[ -n "$candidate_file" ]]; then
  [[ -f "$candidate_file" ]] || die "candidate file does not exist"
fi
if [[ -n "$workload_file" ]]; then
  [[ -f "$workload_file" ]] || die "workload file does not exist"
fi

mkdir -p "$artifact_dir"
trap restore_baseline EXIT INT TERM HUP
printf 'duration_seconds=%s\nprobe_interval_seconds=%s\ninject_loss=%s\n' \
  "$duration_seconds" "$probe_interval_seconds" "$inject_loss" \
  >"$artifact_dir/plan.txt"

log "normalizing stopped VPN"
run_control stop initial-stop >"$artifact_dir/initial-stop.json"

if [[ "$prepare_lte" == "1" ]]; then
  log "requesting strict cellular path through the iPhone Shortcut"
  run_shortcut "$lte_shortcut" prepare-lte
  wait_for_cellular || die "iPhone did not reach strict cellular transport"
fi

log "starting WLT and proving traffic"
vpn_started=1
start_succeeded=0
for start_attempt in 1 2; do
  start_attempt_file="$artifact_dir/start-probe-attempt-$start_attempt.json"
  start_status=0
  if [[ -n "$candidate_file" ]]; then
    run_control start-probe "start-probe-attempt-$start_attempt" \
      env \
        WLT_CONTROL_CANDIDATE_FILE="$candidate_file" \
        WLT_CONTROL_TIMEOUT_SECONDS=120 \
      >"$start_attempt_file" || start_status=$?
  else
    run_control start-probe "start-probe-attempt-$start_attempt" \
      env WLT_CONTROL_TIMEOUT_SECONDS=120 \
      >"$start_attempt_file" || start_status=$?
  fi
  cp "$start_attempt_file" "$artifact_dir/start-probe.json"
  if (( start_status == 0 )); then
    start_succeeded=1
    break
  fi
  if (( start_attempt == 1 )) && retryable_start_failure <"$start_attempt_file"; then
    log "carrier connect did not settle; retrying startup once after bounded cooldown"
    run_control stop startup-retry-stop >/dev/null 2>&1 || true
    sleep 15
    continue
  fi
  exit "$start_status"
done
(( start_succeeded == 1 )) || die "start-probe did not succeed"
strict_cellular_status <"$artifact_dir/start-probe.json" \
  || die "start-probe did not prove strict cellular transport"

if [[ -n "$workload_file" ]]; then
  log "selecting the EU WLT route and running the configured transport workload"
  run_control workload workload \
    env \
      WLT_CONTROL_WORKLOAD_FILE="$workload_file" \
      WLT_CONTROL_TIMEOUT_SECONDS=240 \
    >"$artifact_dir/workload.json"
fi

if [[ "$inject_loss" == "0" ]]; then
  log "starting host-observed soak for ${duration_seconds}s"
  run_host_driven_soak
else
  log "starting app-observed loss/recovery window for ${duration_seconds}s"
  run_control soak soak \
    env \
      WLT_CONTROL_SOAK_SECONDS="$duration_seconds" \
      WLT_CONTROL_SOAK_INTERVAL_SECONDS="$probe_interval_seconds" \
      WLT_CONTROL_TIMEOUT_SECONDS="$((duration_seconds + 90))" \
    >"$artifact_dir/soak.json" 2>"$artifact_dir/soak.log" &
  soak_pid=$!
  loss_deadline=$((SECONDS + loss_after_seconds))
  while (( SECONDS < loss_deadline )); do
    sleep 1
    kill -0 "$soak_pid" 2>/dev/null \
      || { wait "$soak_pid" || true; die "soak ended before connection-loss injection"; }
  done
  log "injecting a bounded radio loss/recovery cycle"
  run_shortcut "$loss_shortcut" connection-loss
  soak_status=0
  wait "$soak_pid" || soak_status=$?
  (( soak_status == 0 )) || die "soak control action failed; see $artifact_dir/soak.log"
  classify_injected_recovery "$artifact_dir/soak.json"
fi

log "proving traffic after soak/recovery"
final_probe_status=0
run_control probe final-probe >"$artifact_dir/final-probe.json" \
  || final_probe_status=$?

log "stopping WLT and checking idempotent cleanup"
run_control stop final-stop >"$artifact_dir/final-stop.json"
vpn_started=0
run_control stop idempotent-stop >"$artifact_dir/idempotent-stop.json"
run_control status final-status >"$artifact_dir/final-status.json"

if [[ "$restore_wifi" == "1" ]]; then
  run_shortcut "$wifi_shortcut" final-wifi-restore ""
  wifi_restored=1
fi

/usr/bin/python3 - \
  "$artifact_dir" "$duration_seconds" "$probe_interval_seconds" "$inject_loss" <<'PY'
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
duration = int(sys.argv[2])
interval = int(sys.argv[3])
inject_loss = sys.argv[4] == "1"

def load(name):
    return json.loads((root / name).read_text())

start = load("start-probe.json")
soak = load("soak.json")
probe = load("final-probe.json")
stop = load("final-stop.json")
second_stop = load("idempotent-stop.json")
status = load("final-status.json")
failures = []
infrastructure_failures = []

if start.get("state") != "succeeded" or start.get("vpn_status") != "connected":
    failures.append("start_probe_failed")
network = start.get("network_final") or {}
if not (network.get("cellular") is True and network.get("wifi") is False):
    failures.append("strict_cellular_not_proved")
if soak.get("state") != "succeeded" or soak.get("vpn_status") != "connected":
    failures.append("soak_did_not_finish_connected")
if (soak.get("soak_elapsed_ms") or 0) < duration * 1000:
    failures.append("soak_too_short")
minimum_samples = max(2, duration // (interval + 8))
if (soak.get("soak_samples") or 0) < minimum_samples:
    failures.append("insufficient_soak_samples")
if inject_loss:
    if soak.get("network_loss_observed") is not True:
        if (
            soak.get("state") == "succeeded"
            and soak.get("vpn_status") == "connected"
            and (soak.get("soak_failures") or 0) == 0
        ):
            infrastructure_failures.append("connection_loss_injection_ineffective")
        else:
            failures.append("connection_loss_not_observed")
    elif soak.get("network_recovered") is not True:
        failures.append("connection_recovery_not_observed")
elif (soak.get("soak_failures") or 0) != 0:
    failures.append("unexpected_soak_probe_failure")
if probe.get("state") != "succeeded" or probe.get("vpn_status") != "connected":
    failures.append("post_soak_probe_failed")
for label, value in (("final_stop", stop), ("idempotent_stop", second_stop), ("final_status", status)):
    if value.get("state") != "succeeded" or value.get("vpn_status") != "disconnected":
        failures.append(f"{label}_failed")

classification = (
    "failed" if failures
    else ("infrastructure" if infrastructure_failures else "success")
)
payload = {
    "schema": 1,
    "classification": classification,
    "duration_seconds": duration,
    "probe_interval_seconds": interval,
    "connection_loss_injected": inject_loss,
    "soak_elapsed_ms": soak.get("soak_elapsed_ms"),
    "soak_samples": soak.get("soak_samples"),
    "soak_successes": soak.get("soak_successes"),
    "soak_failures": soak.get("soak_failures"),
    "network_loss_observed": soak.get("network_loss_observed"),
    "network_recovered": soak.get("network_recovered"),
    "cleanup_succeeded": not any("stop" in value or "status" in value for value in failures),
    "infrastructure_failures": infrastructure_failures,
    "failures": failures,
}
temporary = root / "result.json.tmp"
temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
temporary.replace(root / "result.json")
print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
raise SystemExit(0 if classification == "success" else (2 if classification == "infrastructure" else 1))
PY

trap - EXIT INT TERM HUP
printf '%s\n' "$artifact_dir" >&2
