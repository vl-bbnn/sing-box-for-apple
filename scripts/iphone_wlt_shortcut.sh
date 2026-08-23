#!/usr/bin/env bash

set -euo pipefail

shortcut_name="${1:-}"
artifact_dir="${WLT_SHORTCUT_ARTIFACT_DIR:?WLT_SHORTCUT_ARTIFACT_DIR is required}"
device_id="${DEVICE_ID:?DEVICE_ID is required}"
resume_bundle_id="${WLT_SHORTCUT_RESUME_BUNDLE_ID:-}"
warmup_seconds="${WLT_IOS_SHORTCUT_WARMUP_SECONDS:-2}"
xcrun_bin="${XCRUN:-xcrun}"

[[ -n "$shortcut_name" && ${#shortcut_name} -le 128 ]] \
  || { echo "shortcut name must contain 1-128 characters" >&2; exit 2; }
[[ "$shortcut_name" != *$'\n'* && "$shortcut_name" != *$'\r'* ]] \
  || { echo "shortcut name must not contain line breaks" >&2; exit 2; }
[[ -z "$resume_bundle_id" || "$resume_bundle_id" =~ ^[A-Za-z0-9.-]+$ ]] \
  || { echo "WLT_SHORTCUT_RESUME_BUNDLE_ID is invalid" >&2; exit 2; }
[[ "$warmup_seconds" =~ ^[0-9]+$ ]] \
  || { echo "WLT_IOS_SHORTCUT_WARMUP_SECONDS must be non-negative" >&2; exit 2; }

mkdir -p "$artifact_dir"
encoded_name="$(/usr/bin/python3 - "$shortcut_name" <<'PY'
import sys
import urllib.parse

print(urllib.parse.quote(sys.argv[1], safe=""))
PY
)"

warm_status=1
for warm_attempt in 1 2; do
  if "$xcrun_bin" devicectl device process launch \
    --device "$device_id" \
    --terminate-existing \
    com.apple.shortcuts \
    --timeout 30 \
    --json-output "$artifact_dir/warm-$warm_attempt.json" \
    --log-output "$artifact_dir/warm-$warm_attempt.log" >/dev/null
  then
    warm_status=0
    break
  else
    warm_status=$?
  fi
  sleep 2
done
(( warm_status == 0 )) || exit "$warm_status"

if (( warmup_seconds > 0 )); then
  sleep "$warmup_seconds"
fi

"$xcrun_bin" devicectl device process launch \
  --device "$device_id" \
  --payload-url "shortcuts://run-shortcut?name=$encoded_name" \
  com.apple.shortcuts \
  --timeout 30 \
  --json-output "$artifact_dir/launch.json" \
  --log-output "$artifact_dir/launch.log" >/dev/null

if [[ -n "$resume_bundle_id" ]]; then
  sleep 1
  resume_status=1
  for resume_attempt in 1 2; do
    if "$xcrun_bin" devicectl device process launch \
      --device "$device_id" \
      --timeout 30 \
      --json-output "$artifact_dir/resume-$resume_attempt.json" \
      --log-output "$artifact_dir/resume-$resume_attempt.log" \
      "$resume_bundle_id" >/dev/null
    then
      resume_status=0
      break
    else
      resume_status=$?
    fi
    sleep 2
  done
  (( resume_status == 0 )) || exit "$resume_status"
fi
