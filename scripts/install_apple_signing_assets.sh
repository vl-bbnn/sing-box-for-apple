#!/bin/bash

set -euo pipefail

if [[ -n "${APPLE_PROVISIONING_PROFILES_ARCHIVE_BASE64:-}" ]]; then
	archive_path="$RUNNER_TEMP/apple-profiles.tar.gz"
	profile_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
	mkdir -p "$profile_dir"
	printf '%s' "$APPLE_PROVISIONING_PROFILES_ARCHIVE_BASE64" | base64 -D > "$archive_path"
	tar -xzf "$archive_path" -C "$profile_dir"
	find "$profile_dir" -maxdepth 1 \( -name '*.mobileprovision' -o -name '*.provisionprofile' \) -print
else
	echo "No provisioning profile archive provided; relying on Xcode automatic/cloud signing"
fi
