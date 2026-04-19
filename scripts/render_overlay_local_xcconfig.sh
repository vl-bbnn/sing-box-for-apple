#!/bin/sh

set -eu

config_path="Config/Overlay.local.xcconfig"
base_package_identifier="${OVERLAY_BASE_PACKAGE_IDENTIFIER:-}"
development_team="${OVERLAY_DEVELOPMENT_TEAM:-}"

if [ -z "$base_package_identifier" ] || [ -z "$development_team" ]; then
    if [ -x "./scripts/overlay_setting.sh" ]; then
        base_package_identifier="${base_package_identifier:-$(./scripts/overlay_setting.sh OVERLAY_BASE_PACKAGE_IDENTIFIER)}"
        development_team="${development_team:-$(./scripts/overlay_setting.sh OVERLAY_DEVELOPMENT_TEAM)}"
        macos_system_profile_specifier="${OVERLAY_MACOS_SYSTEM_PROFILE_SPECIFIER:-$(./scripts/overlay_setting.sh OVERLAY_MACOS_SYSTEM_PROFILE_SPECIFIER)}"
        macos_standalone_profile_specifier="${OVERLAY_MACOS_STANDALONE_PROFILE_SPECIFIER:-$(./scripts/overlay_setting.sh OVERLAY_MACOS_STANDALONE_PROFILE_SPECIFIER)}"
    fi
fi

if [ -z "$base_package_identifier" ] || [ -z "$development_team" ]; then
    exit 0
fi

profile_name_base=$(printf '%s' "$base_package_identifier" | tr '.' ' ')
macos_system_profile_specifier="${macos_system_profile_specifier:-${OVERLAY_MACOS_SYSTEM_PROFILE_SPECIFIER:-XC $profile_name_base system}}"
macos_standalone_profile_specifier="${macos_standalone_profile_specifier:-${OVERLAY_MACOS_STANDALONE_PROFILE_SPECIFIER:-XC $profile_name_base standalone}}"

mkdir -p "$(dirname "$config_path")"

cat > "$config_path" <<EOF
OVERLAY_BASE_PACKAGE_IDENTIFIER = $base_package_identifier
OVERLAY_DEVELOPMENT_TEAM = $development_team
OVERLAY_MACOS_SYSTEM_PROFILE_SPECIFIER = $macos_system_profile_specifier
OVERLAY_MACOS_STANDALONE_PROFILE_SPECIFIER = $macos_standalone_profile_specifier
EOF

helper_plist_path="HelperService/LaunchDaemons/HelperService.plist"
helper_plist_template="HelperService/LaunchDaemons/HelperService.plist.in"

if [ -f "$helper_plist_template" ]; then
    mkdir -p "$(dirname "$helper_plist_path")"
    sed \
        -e "s|__BASE_PACKAGE_IDENTIFIER__|$base_package_identifier|g" \
        -e "s|__DEVELOPMENT_TEAM__|$development_team|g" \
        "$helper_plist_template" > "$helper_plist_path"
fi
