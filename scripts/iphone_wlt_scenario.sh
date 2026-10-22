#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
build_dir="${WLT_SCENARIO_BUILD_DIR:-$repo_root/build/DerivedData-WLTScenario}"
artifact_root="${WLT_TEST_ARTIFACT_ROOT:-$repo_root/.local/wlt-test-artifacts}"
scenario_path="${WLT_DEVICE_SCENARIO:-$repo_root/SFIUITests/wlt-mobile.json}"
scheme="${SFI_SCHEME:-SFI Dev}"
configuration="${SFI_CONFIGURATION:-Dev}"
use_destination_artifacts="${WLT_SCENARIO_USE_DESTINATION_ARTIFACTS:-0}"
skip_build="${WLT_SCENARIO_SKIP_BUILD:-0}"
timestamp="$(date '+%Y-%m-%d-%H%M%S')"
artifact_dir="${WLT_SCENARIO_ARTIFACT_DIR:-$artifact_root/wlt-device-scenario-$timestamp}"

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
    connection = device.get("connectionProperties", {})
    if connection.get("pairingState") == "paired":
        matches.append(device)
if len(matches) != 1:
    raise SystemExit(f"expected exactly one available iPhone, found {len(matches)}; connect by USB, unlock it, or set DEVICE_ID")
print(matches[0]["identifier"])
PY
}

patch_xctestrun_environment() {
    local plist="$1"
    local encoded="$2"
    local target_app_bundle_id="$3"
    /usr/bin/python3 - "$plist" "$encoded" "$use_destination_artifacts" "$target_app_bundle_id" <<'PY'
import plistlib
import sys

path, encoded, use_destination_artifacts, target_app_bundle_id = sys.argv[1:]
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
    target["EnvironmentVariables"].pop("APP_DISTRIBUTOR_ID_OVERRIDE", None)
    target.setdefault("UITargetAppEnvironmentVariables", {}).pop("APP_DISTRIBUTOR_ID_OVERRIDE", None)
    if use_destination_artifacts == "1":
        test_bundle_path = target.get("TestBundlePath", "__TESTHOST__/PlugIns/SFIUITests.xctest")
        target["UseDestinationArtifacts"] = True
        target["TestBundleDestinationRelativePath"] = test_bundle_path
        target["UITargetAppBundleIdentifier"] = target_app_bundle_id
        for key in (
            "TestBundlePath",
            "TestHostPath",
            "UITargetAppPath",
            "DependentProductPaths",
        ):
            target.pop(key, None)
    matched += 1

if matched != 1:
    raise SystemExit(f"expected one SFIUITests entry in xctestrun, found {matched}")
with open(path, "wb") as handle:
    plistlib.dump(root, handle, fmt=plistlib.FMT_BINARY)
PY
}

target_app_bundle_id() {
    local app="$1"
    plutil -extract CFBundleIdentifier raw "$app/Info.plist"
}

device_aliases() {
    local device="$1"
    local details="$artifact_dir/device-details.json"
    xcrun devicectl device info details --device "$device" --json-output "$details" --timeout 30 >/dev/null
    /usr/bin/python3 - "$device" "$details" <<'PY'
import json
import sys

device, path = sys.argv[1:]
values = {device}

def visit(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key.lower() in {"identifier", "udid"} and isinstance(child, str):
                values.add(child)
            visit(child)
    elif isinstance(value, list):
        for child in value:
            visit(child)

visit(json.load(open(path)))
for value in sorted(values):
    print(value)
PY
}

check_competing_xcodebuild() {
    local device="$1"
    local aliases
    aliases="$(device_aliases "$device")"
    if ps -axo pid=,command= | /usr/bin/python3 -c '
import sys
aliases = [value for value in sys.argv[1].splitlines() if value]
for line in sys.stdin:
    fields = line.strip().split(None, 1)
    if len(fields) != 2:
        continue
    executable = fields[1].split(None, 1)[0]
    if executable.rsplit("/", 1)[-1] == "xcodebuild" and any(alias in fields[1] for alias in aliases):
        raise SystemExit(1)
' "$aliases"
    then
        return
    fi
    die "another xcodebuild is using this iPhone; wait for it to finish (set WLT_ALLOW_CONCURRENT_XCODEBUILD=1 only when intentional)"
}

test_host_bundle_id() {
    local plist="$1"
    /usr/bin/python3 - "$plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    root = plistlib.load(handle)
for configuration in root.get("TestConfigurations", []):
    for target in configuration.get("TestTargets", []):
        if target.get("BlueprintName") == "SFIUITests":
            print(target["TestHostBundleIdentifier"])
            raise SystemExit(0)
raise SystemExit("SFIUITests host bundle identifier was not found")
PY
}

require_installed_app() {
    local device="$1"
    local bundle_id="$2"
    local label="$3"
    local output="$artifact_dir/installed-$label.json"
    xcrun devicectl device info apps \
        --device "$device" \
        --bundle-id "$bundle_id" \
        --json-output "$output" \
        --timeout 30 >/dev/null
    /usr/bin/python3 - "$output" "$bundle_id" <<'PY'
import json
import sys

root = json.load(open(sys.argv[1]))
apps = root.get("result", {}).get("apps", [])
if not any(app.get("bundleIdentifier") == sys.argv[2] for app in apps):
    raise SystemExit(f"required destination artifact is not installed: {sys.argv[2]}")
PY
}

find_xctestrun() {
    find "$build_dir/Build/Products" -maxdepth 2 -name '*.xctestrun' \
        ! -name 'wlt-device-scenario*.xctestrun' -type f -print | sort | tail -n 1
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
    [[ "$use_destination_artifacts" == "0" || "$use_destination_artifacts" == "1" ]] || die "WLT_SCENARIO_USE_DESTINATION_ARTIFACTS must be 0 or 1"
    [[ "$skip_build" == "0" || "$skip_build" == "1" ]] || die "WLT_SCENARIO_SKIP_BUILD must be 0 or 1"

    mkdir -p "$artifact_dir" "$build_dir"
    trap 'status=$?; printf "exit_status=%s\n" "$status" >"$artifact_dir/status.txt"; printf "%s\n" "$artifact_dir"' EXIT
    local device
    device="$(device_id)"
    if [[ "${WLT_ALLOW_CONCURRENT_XCODEBUILD:-0}" != "1" ]]; then
        check_competing_xcodebuild "$device"
    fi

    if [[ "$skip_build" == "0" ]]; then
        log "building UI test for the connected iPhone"
        xcodebuild \
            -project "$repo_root/sing-box.xcodeproj" \
            -scheme "$scheme" \
            -configuration "$configuration" \
            -destination "id=$device" \
            -derivedDataPath "$build_dir" \
            -disablePackageRepositoryCache \
            -skipPackagePluginValidation \
            build-for-testing >"$artifact_dir/xcodebuild-build.log" 2>&1 \
            || die "build-for-testing failed; see $artifact_dir/xcodebuild-build.log"
    else
        log "reusing build products from $build_dir"
    fi

    local source_xctestrun patched_xctestrun encoded app app_bundle_id runner_bundle_id
    source_xctestrun="$(find_xctestrun)"
    [[ -n "$source_xctestrun" ]] || die "xctestrun was not produced"
    app="$(find_target_app)"
    [[ -n "$app" ]] || die "target application was not produced"
    app_bundle_id="$(target_app_bundle_id "$app")"
    patched_xctestrun="$build_dir/Build/Products/wlt-device-scenario.xctestrun"
    cp "$source_xctestrun" "$patched_xctestrun"
    encoded="$(base64 <"$scenario_path" | tr -d '\n')"
    patch_xctestrun_environment "$patched_xctestrun" "$encoded" "$app_bundle_id"
    runner_bundle_id="$(test_host_bundle_id "$patched_xctestrun")"
    cp "$patched_xctestrun" "$artifact_dir/$(basename "$source_xctestrun")"
    cp "$scenario_path" "$artifact_dir/scenario.json"

    if [[ "$use_destination_artifacts" == "1" ]]; then
        log "using already installed app and UI-test runner to preserve device state"
        require_installed_app "$device" "$app_bundle_id" "target-app"
        require_installed_app "$device" "$runner_bundle_id" "ui-test-runner"
    fi

    if [[ "${WLT_ALLOW_CONCURRENT_XCODEBUILD:-0}" != "1" ]]; then
        check_competing_xcodebuild "$device"
    fi

    log "running $(basename "$scenario_path")"
    local test_status=0
    xcodebuild \
        -xctestrun "$patched_xctestrun" \
        -destination "id=$device" \
        -only-testing:SFIUITests/DeviceScenarioTests/testScenario \
        -resultBundlePath "$artifact_dir/test.xcresult" \
        test-without-building >"$artifact_dir/xcodebuild-test.log" 2>&1 || test_status=$?

    local group_id
    if [[ -n "$app" ]]; then
        group_id="$(app_group_id "$app" 2>/dev/null || true)"
        if [[ -n "$group_id" ]]; then
            copy_cache_file "$device" "$group_id" "stderr.log"
            copy_cache_file "$device" "$group_id" "stderr.log.old"
            copy_cache_file "$device" "$group_id" "packet-tunnel-diagnostics.log"
            copy_cache_file "$device" "$group_id" "packet-tunnel-incidents.log"
        fi
    fi

    if [[ "$test_status" -ne 0 ]] && rg -qi "timed out while enabling automation mode|failed to enable automation mode|automation mode.*passcode" "$artifact_dir/xcodebuild-test.log"; then
        die "Xcode could not enable UI Automation. Keep the iPhone connected and unlocked, enter its passcode when prompted, and do not stop the automation-mode helper. See $artifact_dir/xcodebuild-test.log"
    fi

    return "$test_status"
}

run
