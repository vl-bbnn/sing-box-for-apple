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

if [[ -n "${BUILD_CERTIFICATE_BASE64:-}" ]]; then
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
	echo "BUILD_CERTIFICATE_BASE64 is not set, relying on Xcode automatic/cloud signing"
fi

IDENTITIES_OUTPUT="$(codesigning_identities)"
if [[ "$IDENTITIES_OUTPUT" != *"Apple Distribution:"* && "${APPLE_CREATE_DISTRIBUTION_CERTIFICATE:-1}" == "1" ]]; then
	if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_KEY_ISSUER_ID:-}" || -z "${ASC_KEY_PATH:-}" ]]; then
		echo "No Apple Distribution identity is installed and App Store Connect credentials are unavailable" >&2
		exit 1
	fi

	ensure_keychain
	DISTRIBUTION_CERTIFICATE_TYPE="${APPLE_DISTRIBUTION_CERTIFICATE_TYPE:-IOS_DISTRIBUTION}"
	PRIVATE_KEY_PATH="$RUNNER_TEMP/apple_distribution.key"
	CSR_PATH="$RUNNER_TEMP/apple_distribution.certSigningRequest"
	CERTIFICATE_DER_PATH="$RUNNER_TEMP/apple_distribution.cer"
	CERTIFICATE_PEM_PATH="$RUNNER_TEMP/apple_distribution.pem"
	CERTIFICATE_P12_PATH="$RUNNER_TEMP/apple_distribution.p12"

	echo "Creating temporary $DISTRIBUTION_CERTIFICATE_TYPE certificate via App Store Connect API"
	openssl genrsa -out "$PRIVATE_KEY_PATH" 2048 >/dev/null 2>&1
	openssl req -new -key "$PRIVATE_KEY_PATH" -out "$CSR_PATH" -subj "/CN=Apple Distribution CI/O=CI/C=US"
	ruby scripts/app_store_connect.rb create-certificate \
		--certificate-type "$DISTRIBUTION_CERTIFICATE_TYPE" \
		--csr-path "$CSR_PATH" \
		--certificate-output-path "$CERTIFICATE_DER_PATH"
	openssl x509 -inform DER -in "$CERTIFICATE_DER_PATH" -out "$CERTIFICATE_PEM_PATH"
	openssl pkcs12 -export \
		-inkey "$PRIVATE_KEY_PATH" \
		-in "$CERTIFICATE_PEM_PATH" \
		-out "$CERTIFICATE_P12_PATH" \
		-password "pass:$KEYCHAIN_PASSWORD"
	security import "$CERTIFICATE_P12_PATH" -P "$KEYCHAIN_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
	security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
	IDENTITIES_OUTPUT="$(codesigning_identities)"
	printf '%s\n' "$IDENTITIES_OUTPUT"
fi

if [[ "$IDENTITIES_OUTPUT" != *"Apple Distribution:"* ]]; then
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
