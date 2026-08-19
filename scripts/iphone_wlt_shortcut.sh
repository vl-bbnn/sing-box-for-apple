#!/usr/bin/env bash

set -euo pipefail

shortcut_name="${1:-}"
artifact_dir="${WLT_SHORTCUT_ARTIFACT_DIR:?WLT_SHORTCUT_ARTIFACT_DIR is required}"
device_id="${DEVICE_ID:?DEVICE_ID is required}"
resume_bundle_id="${WLT_SHORTCUT_RESUME_BUNDLE_ID:-}"
xcrun_bin="${XCRUN:-xcrun}"

[[ -n "$shortcut_name" && ${#shortcut_name} -le 128 ]] \
  || { echo "shortcut name must contain 1-128 characters" >&2; exit 2; }
[[ "$shortcut_name" != *$'\n'* && "$shortcut_name" != *$'\r'* ]] \
  || { echo "shortcut name must not contain line breaks" >&2; exit 2; }
[[ -z "$resume_bundle_id" || "$resume_bundle_id" =~ ^[A-Za-z0-9.-]+$ ]] \
  || { echo "WLT_SHORTCUT_RESUME_BUNDLE_ID is invalid" >&2; exit 2; }

mkdir -p "$artifact_dir"
encoded_name="$(/usr/bin/python3 - "$shortcut_name" <<'PY'
import sys
import urllib.parse

print(urllib.parse.quote(sys.argv[1], safe=""))
PY
)"

"$xcrun_bin" devicectl device process launch \
  --device "$device_id" \
  --terminate-existing \
  --payload-url "shortcuts://run-shortcut?name=$encoded_name" \
  com.apple.shortcuts \
  --timeout 30 \
  --json-output "$artifact_dir/launch.json" \
  --log-output "$artifact_dir/launch.log" >/dev/null

if [[ -n "$resume_bundle_id" ]]; then
  sleep 1
  "$xcrun_bin" devicectl device process launch \
    --device "$device_id" \
    --timeout 30 \
    --json-output "$artifact_dir/resume.json" \
    --log-output "$artifact_dir/resume.log" \
    "$resume_bundle_id" >/dev/null
fi
