#!/bin/bash

set -euo pipefail

apple_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace_root="$(cd "$apple_root/.." && pwd)"
wlt_root="${WLT_REPO:-$workspace_root/whitelist-transport}"
destination="${1:-$apple_root/build/wlt-client/wlt-client}"

if [[ ! -d "$wlt_root" ]]; then
	echo "whitelist-transport repository not found: $wlt_root" >&2
	exit 1
fi

mkdir -p "$(dirname "$destination")"

(
	cd "$wlt_root"
	CGO_ENABLED=1 GOOS=darwin GOARCH="$(go env GOARCH)" go build -trimpath -o "$destination" ./cmd/wlt-client
)

chmod 0755 "$destination"
echo "$destination"
