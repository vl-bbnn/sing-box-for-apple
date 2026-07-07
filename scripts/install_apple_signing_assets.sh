#!/bin/bash

set -euo pipefail

KEYCHAIN_PATH="${RUNNER_TEMP:-/tmp}/app-signing.keychain-db"
KEYCHAIN_READY=0

ensure_keychain() {
	if [[ "$KEYCHAIN_READY" == "1" ]]; then
		return
	fi
	if [[ -z "${KEYCHAIN_PASSWORD:-}" ]]; then
		echo "KEYCHAIN_PASSWORD is required to install Apple signing assets" >&2
		exit 1
	fi
	security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
	security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
	security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
	security default-keychain -d user -s "$KEYCHAIN_PATH"
	security list-keychain -d user -s "$KEYCHAIN_PATH"
	KEYCHAIN_READY=1
}

codesigning_identities() {
	security find-identity -v -p codesigning "$KEYCHAIN_PATH" || true
}

has_distribution_identity() {
	grep -Eq '"(Apple|iPhone) Distribution:' <<< "$1"
}

has_development_identity() {
	grep -Eq '"(Apple Development|iPhone Developer):' <<< "$1"
}

create_signing_certificate() {
	local certificate_type="$1"
	local file_label="$2"
	local common_name="$3"

	if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_KEY_ISSUER_ID:-}" || -z "${ASC_KEY_PATH:-}" ]]; then
		echo "App Store Connect credentials are required to create $certificate_type" >&2
		exit 1
	fi

	ensure_keychain
	local private_key_path="$RUNNER_TEMP/${file_label}.key"
	local csr_path="$RUNNER_TEMP/${file_label}.certSigningRequest"
	local certificate_der_path="$RUNNER_TEMP/${file_label}.cer"
	local certificate_pem_path="$RUNNER_TEMP/${file_label}.pem"
	local certificate_p12_path="$RUNNER_TEMP/${file_label}.p12"

	echo "Creating temporary $certificate_type certificate via App Store Connect API"
	openssl genrsa -out "$private_key_path" 2048 >/dev/null 2>&1
	openssl req -new -key "$private_key_path" -out "$csr_path" -subj "/CN=$common_name/O=CI/C=US"
	ruby scripts/app_store_connect.rb create-certificate \
		--certificate-type "$certificate_type" \
		--csr-path "$csr_path" \
		--certificate-output-path "$certificate_der_path"
	openssl x509 -inform DER -in "$certificate_der_path" -out "$certificate_pem_path"
	openssl pkcs12 -export \
		-inkey "$private_key_path" \
		-in "$certificate_pem_path" \
		-out "$certificate_p12_path" \
		-password "pass:$KEYCHAIN_PASSWORD"
	security import "$certificate_p12_path" -P "$KEYCHAIN_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
	security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
}

if [[ -n "${BUILD_CERTIFICATE_BASE64:-}" && "${APPLE_IGNORE_BUILD_CERTIFICATE:-0}" != "1" ]]; then
	if [[ -z "${P12_PASSWORD:-}" || -z "${KEYCHAIN_PASSWORD:-}" ]]; then
		echo "P12_PASSWORD and KEYCHAIN_PASSWORD are required when BUILD_CERTIFICATE_BASE64 is set" >&2
		exit 1
	fi

	CERTIFICATE_PATH="$RUNNER_TEMP/build_certificate.p12"

	printf '%s' "$BUILD_CERTIFICATE_BASE64" | base64 -D > "$CERTIFICATE_PATH"

	ensure_keychain
	security import "$CERTIFICATE_PATH" -P "$P12_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
	security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
	IDENTITIES_OUTPUT="$(codesigning_identities)"
	printf '%s\n' "$IDENTITIES_OUTPUT"
	if [[ "$IDENTITIES_OUTPUT" == *"0 valid identities found"* ]]; then
		echo "No valid code signing identities were imported from BUILD_CERTIFICATE_BASE64" >&2
		exit 1
	fi
else
	echo "BUILD_CERTIFICATE_BASE64 is not set or is ignored for this job"
fi

IDENTITIES_OUTPUT="$(codesigning_identities)"
if ! has_development_identity "$IDENTITIES_OUTPUT" && [[ "${APPLE_CREATE_DEVELOPMENT_CERTIFICATE:-0}" == "1" ]]; then
	create_signing_certificate DEVELOPMENT apple_development "Apple Development CI"
	IDENTITIES_OUTPUT="$(codesigning_identities)"
	printf '%s\n' "$IDENTITIES_OUTPUT"
fi

IDENTITIES_OUTPUT="$(codesigning_identities)"
if ! has_distribution_identity "$IDENTITIES_OUTPUT" && [[ "${APPLE_CREATE_DISTRIBUTION_CERTIFICATE:-1}" == "1" ]]; then
	DISTRIBUTION_CERTIFICATE_TYPE="${APPLE_DISTRIBUTION_CERTIFICATE_TYPE:-IOS_DISTRIBUTION}"
	create_signing_certificate "$DISTRIBUTION_CERTIFICATE_TYPE" apple_distribution "Apple Distribution CI"
	IDENTITIES_OUTPUT="$(codesigning_identities)"
	printf '%s\n' "$IDENTITIES_OUTPUT"
fi

if [[ "${APPLE_REQUIRE_DEVELOPMENT_CERTIFICATE:-0}" == "1" ]] && ! has_development_identity "$IDENTITIES_OUTPUT"; then
	echo "No Apple Development code signing identity is available" >&2
	exit 1
fi

if ! has_distribution_identity "$IDENTITIES_OUTPUT"; then
	echo "No Apple Distribution code signing identity is available" >&2
	exit 1
fi

if [[ -n "${APPLE_PROVISIONING_PROFILES_ARCHIVE_BASE64:-}" ]]; then
	ARCHIVE_PATH="$RUNNER_TEMP/apple-profiles.tar.gz"
	PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
	mkdir -p "$PROFILE_DIR"
	printf '%s' "$APPLE_PROVISIONING_PROFILES_ARCHIVE_BASE64" | base64 -D > "$ARCHIVE_PATH"
	tar -xzf "$ARCHIVE_PATH" -C "$PROFILE_DIR"
	find "$PROFILE_DIR" -maxdepth 1 \( -name '*.mobileprovision' -o -name '*.provisionprofile' \) -print
else
	echo "APPLE_PROVISIONING_PROFILES_ARCHIVE_BASE64 is not set, relying on Xcode automatic/cloud signing"
fi
