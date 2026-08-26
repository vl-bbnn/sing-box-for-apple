#!/bin/sh

set -eu

config_path="Config/Overlay.local.xcconfig"
base_package_identifier="${OVERLAY_BASE_PACKAGE_IDENTIFIER:-}"
development_team="${OVERLAY_DEVELOPMENT_TEAM:-}"
application_name="${OVERLAY_APPLICATION_NAME:-$(./scripts/overlay_setting.sh OVERLAY_APPLICATION_NAME)}"
dev_application_name="${OVERLAY_DEV_APPLICATION_NAME:-$(./scripts/overlay_setting.sh OVERLAY_DEV_APPLICATION_NAME)}"
url_scheme="${OVERLAY_URL_SCHEME:-$(./scripts/overlay_setting.sh OVERLAY_URL_SCHEME)}"
dev_url_scheme="${OVERLAY_DEV_URL_SCHEME:-$(./scripts/overlay_setting.sh OVERLAY_DEV_URL_SCHEME)}"
client_import_scheme="${VPN_CLIENT_IMPORT_SCHEME:?VPN_CLIENT_IMPORT_SCHEME must be set by the build environment}"
application_link="${OVERLAY_APPLICATION_LINK:-$(./scripts/overlay_setting.sh OVERLAY_APPLICATION_LINK)}"
changelog_link="${OVERLAY_CHANGELOG_LINK:-$(./scripts/overlay_setting.sh OVERLAY_CHANGELOG_LINK)}"
configuration_link="${OVERLAY_CONFIGURATION_LINK:-$(./scripts/overlay_setting.sh OVERLAY_CONFIGURATION_LINK)}"
source_link="${OVERLAY_SOURCE_LINK:-$(./scripts/overlay_setting.sh OVERLAY_SOURCE_LINK)}"
releases_link="${OVERLAY_RELEASES_LINK:-$(./scripts/overlay_setting.sh OVERLAY_RELEASES_LINK)}"

validate_url_scheme() {
    setting_name="$1"
    setting_value="$2"
    if ! printf '%s' "$setting_value" | grep -Eq '^[A-Za-z][A-Za-z0-9+.-]*$'; then
        echo "$setting_name is not a valid URI scheme" >&2
        exit 1
    fi
}

validate_url_scheme VPN_CLIENT_IMPORT_SCHEME "$client_import_scheme"

xcconfig_url() {
    printf '%s' "$1" | sed 's|://|:/$()/|'
}

application_link="$(xcconfig_url "$application_link")"
changelog_link="$(xcconfig_url "$changelog_link")"
configuration_link="$(xcconfig_url "$configuration_link")"
source_link="$(xcconfig_url "$source_link")"
releases_link="$(xcconfig_url "$releases_link")"

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
OVERLAY_APPLICATION_NAME = $application_name
OVERLAY_DEV_APPLICATION_NAME = $dev_application_name
OVERLAY_URL_SCHEME = $url_scheme
OVERLAY_DEV_URL_SCHEME = $dev_url_scheme
VPN_CLIENT_IMPORT_SCHEME = $client_import_scheme
OVERLAY_APPLICATION_LINK = $application_link
OVERLAY_CHANGELOG_LINK = $changelog_link
OVERLAY_CONFIGURATION_LINK = $configuration_link
OVERLAY_SOURCE_LINK = $source_link
OVERLAY_RELEASES_LINK = $releases_link
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
