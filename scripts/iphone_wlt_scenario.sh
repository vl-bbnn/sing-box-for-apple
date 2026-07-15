#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
build_dir="${WLT_SCENARIO_BUILD_DIR:-$repo_root/build/DerivedData-WLTScenario}"
scenario_path="${WLT_DEVICE_SCENARIO:-$repo_root/SFIUITests/wlt-mobile.json}"
scheme="${SFI_SCHEME:-SFI Dev}"
configuration="${SFI_CONFIGURATION:-Dev}"
timestamp="$(date '+%Y-%m-%d-%H%M%S')"
artifact_dir="${WLT_SCENARIO_ARTIFACT_DIR:-$HOME/Desktop/wlt-device-scenario-$timestamp}"

log() {
    printf '[wlt-device-scenario] %s\n' "$*" >&2
}

die() {
    printf '[wlt-device-scenario] error: %s\n' "$*" >&2
    exit 1
}

device_id() {
    if [[ -n "${DEVICE_ID:-}" ]]; then
        printf '%s\n' "$DEVICE_ID"
        return
    fi

    local json_path="$artifact_dir/devices.json"
    xcrun devicectl list devices --json-output "$json_path" >/dev/null
    /usr/bin/python3 - "$json_path" <<'PY'
import json
import sys

devices = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])
matches = []
for device in devices:
    hardware = device.get("hardwareProperties", {})
    if hardware.get("deviceType") != "iPhone":
        continue
    state = str(device.get("deviceProperties", {}).get("bootState", ""))
    connection = device.get("connectionProperties", {})
    if connection.get("tunnelState") == "connected" or "available" in str(device.get("state", "")) or state == "booted":
        matches.append(device)
if len(matches) != 1:
    raise SystemExit(f"expected exactly one available iPhone, found {len(matches)}; connect by USB, unlock it, or set DEVICE_ID")
print(matches[0]["identifier"])
PY
}

patch_xctestrun_environment() {
    local plist="$1"
    local encoded="$2"
    /usr/bin/python3 - "$plist" "$encoded" <<'PY'
import plistlib
import sys

path, encoded = sys.argv[1:]
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
    matched += 1

if matched != 1:
    raise SystemExit(f"expected one SFIUITests entry in xctestrun, found {matched}")
with open(path, "wb") as handle:
    plistlib.dump(root, handle, fmt=plistlib.FMT_BINARY)
PY
}

find_xctestrun() {
    find "$build_dir/Build/Products" -maxdepth 2 -name '*.xctestrun' \
        ! -name 'wlt-device-scenario.xctestrun' -type f -print | sort | tail -n 1
}

find_target_app() {
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
    local destination="$artifact_dir/$source_name"
    xcrun devicectl device copy from \
        --device "$device" \
        --domain-type appGroupDataContainer \
        --domain-identifier "$group_id" \
        --source "Library/Caches/$source_name" \
        --destination "$destination" \
        --timeout 60 >/dev/null 2>"$artifact_dir/devicectl-copy-$source_name.log" || true
}

run() {
    [[ -f "$scenario_path" ]] || die "scenario does not exist: $scenario_path"
    [[ "$scheme" == "SFI Dev" ]] || die "device scenario requires SFI Dev scheme"
    [[ "$configuration" == "Dev" ]] || die "device scenario requires Dev configuration"

    mkdir -p "$artifact_dir" "$build_dir"
    trap 'status=$?; printf "exit_status=%s\n" "$status" >"$artifact_dir/status.txt"; printf "%s\n" "$artifact_dir"' EXIT
    local device
    device="$(device_id)"

    log "building UI test for the connected iPhone"
    xcodebuild \
        -project "$repo_root/sing-box.xcodeproj" \
        -scheme "$scheme" \
        -configuration "$configuration" \
        -destination "id=$device" \
        -derivedDataPath "$build_dir" \
        -skipPackagePluginValidation \
        build-for-testing >"$artifact_dir/xcodebuild-build.log" 2>&1 \
        || die "build-for-testing failed; see $artifact_dir/xcodebuild-build.log"

    local source_xctestrun patched_xctestrun encoded
    source_xctestrun="$(find_xctestrun)"
    [[ -n "$source_xctestrun" ]] || die "xctestrun was not produced"
    patched_xctestrun="$build_dir/Build/Products/wlt-device-scenario.xctestrun"
    cp "$source_xctestrun" "$patched_xctestrun"
    encoded="$(base64 <"$scenario_path" | tr -d '\n')"
    patch_xctestrun_environment "$patched_xctestrun" "$encoded"
    cp "$patched_xctestrun" "$artifact_dir/$(basename "$source_xctestrun")"
    cp "$scenario_path" "$artifact_dir/scenario.json"

    log "running $(basename "$scenario_path")"
    local test_status=0
    xcodebuild \
        -xctestrun "$patched_xctestrun" \
        -destination "id=$device" \
        -only-testing:SFIUITests/DeviceScenarioTests/testScenario \
        -resultBundlePath "$artifact_dir/test.xcresult" \
        test-without-building >"$artifact_dir/xcodebuild-test.log" 2>&1 || test_status=$?

    local app group_id
    app="$(find_target_app)"
    if [[ -n "$app" ]]; then
        group_id="$(app_group_id "$app" 2>/dev/null || true)"
        if [[ -n "$group_id" ]]; then
            copy_cache_file "$device" "$group_id" "stderr.log"
            copy_cache_file "$device" "$group_id" "stderr.log.old"
            copy_cache_file "$device" "$group_id" "packet-tunnel-diagnostics.log"
            copy_cache_file "$device" "$group_id" "packet-tunnel-incidents.log"
        fi
    fi

    return "$test_status"
}

run
