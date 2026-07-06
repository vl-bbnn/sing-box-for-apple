#!/bin/bash

set -euo pipefail

expected="${1:-ordinary}"
xcframework="${2:-Libbox.xcframework}"
require_wlt="${SFI_REQUIRE_WLT_LIBBOX:-NO}"

case "$expected" in
	ordinary|dev)
		;;
	*)
		echo "usage: $0 ordinary|dev [Libbox.xcframework]" >&2
		exit 1
		;;
esac

if [[ ! -d "$xcframework" ]]; then
	echo "missing libbox artifact: $xcframework" >&2
	exit 1
fi
if [[ ! -f "$xcframework/.libbox-variant" || ! -f "$xcframework/.libbox-source-ref" ]]; then
	echo "libbox artifact lacks variant/source provenance manifests: $xcframework" >&2
	exit 1
fi
actual_variant="$(cat "$xcframework/.libbox-variant")"
source_ref="$(cat "$xcframework/.libbox-source-ref")"
if [[ "$actual_variant" != "$expected" || ! "$source_ref" =~ ^[0-9a-f]{40}$ ]]; then
	echo "libbox provenance mismatch: expected=$expected actual=$actual_variant source=$source_ref" >&2
	exit 1
fi

found_wlt=0
if LC_ALL=C grep -R -a -q -E 'with_wlt|LibboxStartWhitelistTransport|wlt-carrier' "$xcframework"; then
	found_wlt=1
fi

if [[ "$expected" == "ordinary" && "$found_wlt" == "1" ]]; then
	echo "ordinary build requires WLT-free Libbox.xcframework" >&2
	exit 1
fi

if [[ "$expected" == "dev" && "$require_wlt" == "YES" && "$found_wlt" != "1" ]]; then
	echo "dev build requires WLT-enabled Libbox.xcframework when SFI_REQUIRE_WLT_LIBBOX=YES" >&2
	exit 1
fi

echo "libbox variant ok: expected=$expected require_wlt=$require_wlt source=$source_ref artifact=$xcframework"
