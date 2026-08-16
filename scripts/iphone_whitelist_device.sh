#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
workspace_root="$(cd "$repo_root/.." && pwd)"
build_dir="$repo_root/build"

scheme="${SFI_SCHEME:-SFI Dev}"
configuration="${SFI_CONFIGURATION:-Dev}"
derived_data_path="${SFI_DERIVED_DATA_PATH:-$build_dir/DerivedData-iPhone}"
app_name="${SFI_APP_NAME:-dev-vpn.app}"
sing_box_version="${SING_BOX_VERSION:-1.13.12}"
sing_box_repo="${SING_BOX_REPO:-$workspace_root/sing-box}"
libbox_platforms="${LIBBOX_APPLE_PLATFORMS:-ios,iossimulator,macos}"
dev_xcframework="$repo_root/build/libbox/dev/Libbox.xcframework"

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

append_unique_tag() {
	local tags="$1"
	local tag="$2"
	case ",$tags," in
	*,"$tag",*)
		printf '%s\n' "$tags"
		;;
	,)
		printf '%s\n' "$tag"
		;;
	*)
		printf '%s,%s\n' "$tags" "$tag"
		;;
	esac
}

sing_box_lx_tags() {
	if [[ -n "${SING_BOX_LX_TAGS:-}" ]]; then
		printf '%s\n' "$SING_BOX_LX_TAGS"
		return
	fi
	if [[ -f "$sing_box_repo/Makefile.lx" ]]; then
		make -C "$sing_box_repo" -f Makefile.lx -s lx-print-tags
		return
	fi
	die "SING_BOX_LX=1 requires SING_BOX_LX_TAGS or Makefile.lx in $sing_box_repo"
}

sing_box_build_tags() {
	local tags
	if [[ -n "${SING_BOX_BUILD_TAGS:-}" ]]; then
		tags="$SING_BOX_BUILD_TAGS"
	elif [[ "${SING_BOX_LX:-0}" == "1" ]]; then
		tags="$(sing_box_lx_tags)"
	else
		tags="with_wlt"
	fi
	append_unique_tag "$tags" "with_wlt"
}

build_libbox() {
	log "building Libbox.xcframework from local sing-box"
	[[ "$scheme" == "SFI Dev" ]] || die "WLT device helper requires SFI Dev scheme, got: $scheme"
	[[ "$configuration" == "Dev" ]] || die "WLT device helper requires Dev configuration, got: $configuration"
	# 2b2n:begin wlt
	local sing_box_build_tags
	sing_box_build_tags="$(sing_box_build_tags)"
	# 2b2n:end wlt
	SING_BOX_REPO="$sing_box_repo" \
		LIBBOX_VARIANT=dev \
		LIBBOX_ACTIVATE=0 \
		LIBBOX_APPLE_PLATFORMS="$libbox_platforms" \
		SING_BOX_BUILD_TAGS="$sing_box_build_tags" \
		bash "$repo_root/scripts/build_libbox.sh" "$sing_box_version" \
		>"$build_dir/build-libbox-iphone.log" 2>&1
	VERIFY_LX_LIBBOX="${SING_BOX_LX:-0}" \
		bash "$repo_root/scripts/verify_wlt_libbox.sh" "$dev_xcframework" \
		>>"$build_dir/build-libbox-iphone.log" 2>&1 \
		|| die "rebuilt Dev Libbox.xcframework failed WLT verification; see build/build-libbox-iphone.log"
	log "Libbox build ok"
}

verify_libbox() {
	VERIFY_LX_LIBBOX="${SING_BOX_LX:-0}" \
		bash "$repo_root/scripts/verify_wlt_libbox.sh" "$dev_xcframework"
}

build_app() {
	log "building SFI for generic iOS device"
	[[ "$scheme" == "SFI Dev" ]] || die "WLT device helper requires SFI Dev scheme, got: $scheme"
	[[ "$configuration" == "Dev" ]] || die "WLT device helper requires Dev configuration, got: $configuration"
	xcodebuild \
		-project "$repo_root/sing-box.xcodeproj" \
		-scheme "$scheme" \
		-configuration "$configuration" \
		-destination 'generic/platform=iOS' \
		-derivedDataPath "$derived_data_path" \
		-disableAutomaticPackageResolution \
		-onlyUsePackageVersionsFromResolvedFile \
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
  verify-libbox Verify WLT symbols, module linkage, and iOS slices.
  build-app     Build the WLT-enabled SFI Dev app for a generic iOS device.
  install       Install the built app on the connected iPhone.
  launch        Launch the installed app on the connected iPhone.
  all           build-app, install, launch.
  rebuild-all   build-libbox, build-app, install, launch.

Environment:
  DEVICE_ID                Override auto-selected iPhone identifier.
  SING_BOX_REPO            Local sing-box repo; defaults to ../sing-box.
  SING_BOX_VERSION         Apple app/libbox version; defaults to 1.13.12.
  SFI_SCHEME                Must be "SFI Dev" (default).
  SFI_CONFIGURATION         Must be Dev (default).
  SFI_APP_NAME              Dev app bundle name; defaults to dev-vpn.app.
  LIBBOX_APPLE_PLATFORMS   Defaults to ios,iossimulator,macos.
  SING_BOX_BUILD_TAGS      Explicit comma-separated sing-box extra tags.
  SING_BOX_LX=1            Use Makefile.lx tags from SING_BOX_REPO plus with_wlt.
  SING_BOX_LX_TAGS         Override LX tags when SING_BOX_LX=1.
  WLT_CARRIER_MODULE       WLT private module path; defaults to github.com/vl-bbnn/wlt-carrier.
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
verify-libbox)
	verify_libbox
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
