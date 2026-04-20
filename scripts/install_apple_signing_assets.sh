#!/bin/bash

set -euo pipefail

if [[ -z "${BUILD_CERTIFICATE_BASE64:-}" ]]; then
	echo "BUILD_CERTIFICATE_BASE64 is not set, skipping certificate import"
	exit 0
fi

if [[ -z "${P12_PASSWORD:-}" || -z "${KEYCHAIN_PASSWORD:-}" ]]; then
	echo "P12_PASSWORD and KEYCHAIN_PASSWORD are required when BUILD_CERTIFICATE_BASE64 is set" >&2
	exit 1
fi

CERTIFICATE_PATH="$RUNNER_TEMP/build_certificate.p12"
KEYCHAIN_PATH="$RUNNER_TEMP/app-signing.keychain-db"

printf '%s' "$BUILD_CERTIFICATE_BASE64" | base64 -D > "$CERTIFICATE_PATH"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$CERTIFICATE_PATH" -P "$P12_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
security default-keychain -d user -s "$KEYCHAIN_PATH"
security list-keychain -d user -s "$KEYCHAIN_PATH"
security find-identity -v -p codesigning "$KEYCHAIN_PATH"

if [[ -n "${APPLE_PROVISIONING_PROFILES_ARCHIVE_BASE64:-}" ]]; then
	ARCHIVE_PATH="$RUNNER_TEMP/apple-profiles.tar.gz"
	PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
	mkdir -p "$PROFILE_DIR"
	printf '%s' "$APPLE_PROVISIONING_PROFILES_ARCHIVE_BASE64" | base64 -D > "$ARCHIVE_PATH"
	tar -xzf "$ARCHIVE_PATH" -C "$PROFILE_DIR"
fi
