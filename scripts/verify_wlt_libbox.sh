#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
xcframework="${1:-$repo_root/Libbox.xcframework}"

die() {
	printf '[verify-wlt-libbox] error: %s\n' "$*" >&2
	exit 1
}

device_framework="$xcframework/ios-arm64/Libbox.framework"
simulator_framework="$xcframework/ios-arm64_x86_64-simulator/Libbox.framework"
device_binary="$device_framework/Versions/A/Libbox"
simulator_binary="$simulator_framework/Versions/A/Libbox"
header="$device_framework/Versions/A/Headers/Libbox.objc.h"

[[ -f "$xcframework/Info.plist" ]] || die "Info.plist not found in $xcframework"
[[ -f "$device_binary" ]] || die "iOS arm64 binary not found"
[[ -f "$simulator_binary" ]] || die "iOS simulator binary not found"
[[ -f "$header" ]] || die "ObjC header not found"

device_archs="$(lipo -archs "$device_binary")"
simulator_archs="$(lipo -archs "$simulator_binary")"
[[ " $device_archs " == *" arm64 "* ]] || die "device slice does not contain arm64"
[[ " $simulator_archs " == *" arm64 "* ]] || die "simulator slice does not contain arm64"
[[ " $simulator_archs " == *" x86_64 "* ]] || die "simulator slice does not contain x86_64"

grep -Fq 'LibboxStartWhitelistTransport' "$header" \
	|| die "whitelist transport API is missing from the ObjC header"
LC_ALL=C grep -aFq 'github.com/vl-bbnn/wlt-carrier' "$device_binary" \
	|| die "wlt-carrier module is missing from the device binary"
LC_ALL=C grep -aFq 'with_wlt' "$device_binary" \
	|| die "with_wlt build tag is missing from the device binary"

if [[ "${VERIFY_LX_LIBBOX:-0}" == "1" ]]; then
	LC_ALL=C grep -aFq 'with_xhttp' "$device_binary" \
		|| die "with_xhttp build tag is missing from the device binary"
	LC_ALL=C grep -aFq 'with_awg' "$device_binary" \
		|| die "with_awg build tag is missing from the device binary"
fi

printf '[verify-wlt-libbox] device=%s simulator=%s\n' "$device_archs" "$simulator_archs"
