#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
workspace_root="$(cd "$repo_root/.." && pwd)"
build_dir="$repo_root/build"

scheme="${SFI_SCHEME:-SFI}"
configuration="${SFI_CONFIGURATION:-Debug}"
derived_data_path="${SFI_DERIVED_DATA_PATH:-$build_dir/DerivedData-iPhone}"
app_name="${SFI_APP_NAME:-sing-box.app}"
sing_box_version="${SING_BOX_VERSION:-1.13.12}"
sing_box_repo="${SING_BOX_REPO:-$workspace_root/sing-box}"
libbox_platforms="${LIBBOX_APPLE_PLATFORMS:-ios,iossimulator}"

mkdir -p "$build_dir"

log() {
	printf '[iphone-wlt] %s\n' "$*"
}

die() {
	printf '[iphone-wlt] error: %s\n' "$*" >&2
	exit 1
}

app_path() {
	local path="$derived_data_path/Build/Products/${configuration}-iphoneos/$app_name"
	if [[ -d "$path" ]]; then
		printf '%s\n' "$path"
		return
	fi
	find "$derived_data_path" -path "*/Build/Products/${configuration}-iphoneos/$app_name" \
		-type d 2>/dev/null | sort | tail -n 1
}

bundle_id() {
	local app="$1"
	/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist"
}

refresh_devices_json() {
	xcrun devicectl list devices --json-output "$build_dir/devices.json" >/dev/null 2>&1
}

device_id() {
	if [[ -n "${DEVICE_ID:-}" ]]; then
		printf '%s\n' "$DEVICE_ID"
		return
	fi
	refresh_devices_json
	python3 - "$build_dir/devices.json" <<'PY'
import json
import sys

path = sys.argv[1]
devices = json.load(open(path)).get("result", {}).get("devices", [])
matches = []
for device in devices:
    hardware = device.get("hardwareProperties", {})
    platform = str(hardware.get("platform", ""))
    marketing_name = str(hardware.get("marketingName", ""))
    device_type = str(hardware.get("deviceType", ""))
    if platform == "iOS" or "iPhone" in marketing_name or "iPhone" in device_type:
        matches.append(device)
if len(matches) != 1:
    raise SystemExit(f"expected exactly one iOS device, found {len(matches)}; set DEVICE_ID explicitly")
print(matches[0].get("identifier", ""))
PY
}

device_status() {
	refresh_devices_json
	python3 - "$build_dir/devices.json" <<'PY'
import json
import sys

devices = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])
for device in devices:
    hardware = device.get("hardwareProperties", {})
    platform = str(hardware.get("platform", ""))
    marketing_name = str(hardware.get("marketingName", ""))
    device_type = str(hardware.get("deviceType", ""))
    if platform != "iOS" and "iPhone" not in marketing_name and "iPhone" not in device_type:
        continue
    connection = device.get("connectionProperties", {})
    properties = device.get("deviceProperties", {})
    print("device=iphone")
    print("pairing=" + str(connection.get("pairingState", "")))
    print("tunnel=" + str(connection.get("tunnelState", "")))
    print("developer=" + str(properties.get("developerModeStatus", "")))
    print("ddi=" + str(properties.get("ddiServicesAvailable", "")))
    print("os=" + str(properties.get("osVersionNumber", "")))
PY
}

build_libbox() {
	log "building Libbox.xcframework from local sing-box"
	SING_BOX_REPO="$sing_box_repo" \
		LIBBOX_APPLE_PLATFORMS="$libbox_platforms" \
		bash "$repo_root/scripts/build_libbox.sh" "$sing_box_version" \
		>"$build_dir/build-libbox-iphone.log" 2>&1
	rg -q "LibboxStartWhitelistTransport" \
		"$repo_root/Libbox.xcframework/ios-arm64/Libbox.framework/Versions/A/Headers/Libbox.objc.h" \
		|| die "rebuilt Libbox.xcframework does not expose whitelist transport symbols"
	log "Libbox build ok"
}

build_app() {
	log "building SFI for generic iOS device"
	xcodebuild \
		-project "$repo_root/sing-box.xcodeproj" \
		-scheme "$scheme" \
		-configuration "$configuration" \
		-destination 'generic/platform=iOS' \
		-derivedDataPath "$derived_data_path" \
		-skipPackagePluginValidation \
		build >"$build_dir/xcodebuild-sfi-device.log" 2>&1
	local app
	app="$(app_path)"
	[[ -n "$app" && -d "$app" ]] || die "built app not found"
	codesign --verify --deep --strict "$app" >/dev/null 2>&1 \
		|| die "codesign verification failed"
	log "SFI build ok"
}

preflight() {
	log "device status"
	device_status || true
	local app
	app="$(app_path || true)"
	if [[ -n "$app" && -d "$app" ]]; then
		log "built app found"
		codesign --verify --deep --strict "$app" >/dev/null 2>&1 \
			&& log "codesign ok" || log "codesign failed"
	else
		log "built app not found; run build-app first"
	fi
}

prepare_devicectl_outputs() {
	local json_path="$1"
	local log_path="$2"
	rm -f "$json_path" "$log_path"
}

install_app() {
	local app device json_path log_path
	app="$(app_path)"
	[[ -n "$app" && -d "$app" ]] || die "built app not found; run build-app first"
	device="$(device_id)"
	json_path="$build_dir/devicectl-install.json"
	log_path="$build_dir/devicectl-install.log"
	prepare_devicectl_outputs "$json_path" "$log_path"
	log "installing SFI on iPhone"
	if xcrun devicectl device install app --device "$device" "$app" --timeout 120 \
		--json-output "$json_path" \
		--log-output "$log_path" >/dev/null 2>&1; then
		log "install ok"
		return
	fi
	if rg -qi "DeviceLocked|device is locked|passcode protected|kAMDMobileImageMounterDeviceLocked" \
		"$log_path" "$json_path" 2>/dev/null; then
		die "install failed because iPhone is locked; unlock it, keep the screen awake, then rerun install"
	fi
	if rg -qi "unable to locate a device matching|CoreDeviceService was unable to locate" \
		"$log_path" "$json_path" 2>/dev/null; then
		die "install failed because CoreDevice cannot access the iPhone; unlock/reconnect it, then rerun install"
	fi
	die "install failed; see build/devicectl-install.log"
}

launch_app() {
	local app device identifier json_path log_path
	app="$(app_path)"
	[[ -n "$app" && -d "$app" ]] || die "built app not found; run build-app first"
	device="$(device_id)"
	identifier="$(bundle_id "$app")"
	json_path="$build_dir/devicectl-launch.json"
	log_path="$build_dir/devicectl-launch.log"
	prepare_devicectl_outputs "$json_path" "$log_path"
	log "launching SFI"
	if xcrun devicectl device process launch --device "$device" --terminate-existing "$identifier" \
		--json-output "$json_path" \
		--log-output "$log_path" >/dev/null 2>&1; then
		log "launch ok"
		return
	fi
	if rg -qi "DeviceLocked|device is locked|reason: Locked|could not be, unlocked" \
		"$log_path" "$json_path" 2>/dev/null; then
		die "launch failed because iPhone is locked; unlock it, keep the screen awake, then rerun launch"
	fi
	if rg -qi "unable to locate a device matching|CoreDeviceService was unable to locate" \
		"$log_path" "$json_path" 2>/dev/null; then
		die "launch failed because CoreDevice cannot access the iPhone; unlock/reconnect it, then rerun launch"
	fi
	die "launch failed; see build/devicectl-launch.log"
}

usage() {
	cat <<'USAGE'
usage: scripts/iphone_whitelist_device.sh <command>

Commands:
  preflight     Print sanitized device/build readiness.
  build-libbox  Rebuild Libbox.xcframework from local sing-box.
  build-app     Build SFI for generic iOS device.
  install       Install the built app on the connected iPhone.
  launch        Launch the installed app on the connected iPhone.
  all           build-app, install, launch.
  rebuild-all   build-libbox, build-app, install, launch.

Environment:
  DEVICE_ID                Override auto-selected iPhone identifier.
  SING_BOX_REPO            Local sing-box repo; defaults to ../sing-box.
  SING_BOX_VERSION         Apple app/libbox version; defaults to 1.13.12.
  LIBBOX_APPLE_PLATFORMS   Defaults to ios,iossimulator.
USAGE
}

command="${1:-preflight}"
case "$command" in
preflight)
	preflight
	;;
build-libbox)
	build_libbox
	;;
build-app)
	build_app
	;;
install)
	install_app
	;;
launch)
	launch_app
	;;
all)
	build_app
	install_app
	launch_app
	;;
rebuild-all)
	build_libbox
	build_app
	install_app
	launch_app
	;;
-h | --help | help)
	usage
	;;
*)
	usage >&2
	exit 2
	;;
esac
