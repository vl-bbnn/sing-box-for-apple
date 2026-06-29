#!/bin/bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
	echo "usage: $0 <version> [destination]" >&2
	exit 1
fi

version="$1"
destination="${2:-$(pwd)/Libbox.xcframework}"
workspace_root="${RUNNER_TEMP:-$(pwd)/build}"
build_root="$workspace_root/libbox-build"
repo_dir="${SING_BOX_REPO:-}"
repo_url="${SING_BOX_REPO_URL:-https://github.com/SagerNet/sing-box.git}"
repo_ref="${SING_BOX_REPO_REF:-}"
platforms="${LIBBOX_APPLE_PLATFORMS:-ios,macos}"

rm -rf "$destination"
mkdir -p "$build_root"

if [[ -n "$repo_dir" ]]; then
	repo_dir="$(cd "$repo_dir" && pwd)"
	if ! git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		echo "SING_BOX_REPO is not a git working tree: $repo_dir" >&2
		exit 1
	fi
	echo "using local sing-box source $repo_dir"
else
	repo_dir="$build_root/sing-box"
	rm -rf "$repo_dir"
	git clone --filter=blob:none "$repo_url" "$repo_dir" >/dev/null 2>&1
	cd "$repo_dir"
	git fetch --tags --force >/dev/null 2>&1

	if [[ -n "$repo_ref" ]]; then
		git fetch origin "$repo_ref" --depth=1 >/dev/null 2>&1
		git checkout -q FETCH_HEAD
		echo "using sing-box source $repo_url@$repo_ref ($(git rev-parse --short HEAD))"
	else
		target_ref="v$version"
		if ! git rev-parse -q --verify "refs/tags/$target_ref" >/dev/null; then
			minor_branch="${version%.*}"
			target_ref="$(git tag -l "v${minor_branch}.*" --sort=-version:refname | head -n 1)"
			if [[ -z "$target_ref" ]]; then
				echo "unable to find a sing-box tag matching Apple version $version" >&2
				exit 1
			fi
			echo "using fallback libbox source tag $target_ref for Apple version $version"
		fi

		git checkout -q "$target_ref"
	fi
fi

cd "$repo_dir"

make lib_install
export PATH="$PATH:$(go env GOPATH)/bin"
go run ./cmd/internal/build_libbox -target apple -platform "$platforms"

mv Libbox.xcframework "$destination"
