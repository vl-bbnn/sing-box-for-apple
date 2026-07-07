#!/bin/bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
	echo "usage: $0 <version> [destination]" >&2
	exit 1
fi

version="$1"
client_root="$(pwd)"
variant="${LIBBOX_VARIANT:-ordinary}"
case "$variant" in
	ordinary|dev)
		;;
	*)
		echo "LIBBOX_VARIANT must be ordinary or dev, got: $variant" >&2
		exit 1
		;;
esac
default_destination="build/libbox/$variant/Libbox.xcframework"
destination="${2:-$default_destination}"
if [[ "$destination" != /* ]]; then
	destination="$client_root/$destination"
fi
workspace_root="${RUNNER_TEMP:-$(pwd)/build}"
build_root="$workspace_root/libbox-build"
repo_dir="${SING_BOX_REPO:-}"
repo_url="${SING_BOX_REPO_URL:-https://github.com/SagerNet/sing-box.git}"
repo_ref="${SING_BOX_REPO_REF:-ef1d02148a66158e23fc22d4e372f4f3bf855bc1}"
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
		git fetch origin "$repo_ref" >/dev/null 2>&1
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

libbox_version="$(go run ./cmd/internal/read_tag)"
if [[ -z "$libbox_version" || "$libbox_version" == "unknown" ]]; then
	echo "unable to resolve sing-box version for libbox build from $repo_dir" >&2
	echo "make sure the checkout has release tags matching v[0-9]* before building TestFlight artifacts" >&2
	exit 1
fi
echo "using sing-box libbox version: $libbox_version"

wireguard_submodule="$(
	git config -f .gitmodules --get submodule.submodules/wireguard-go.path 2>/dev/null \
		|| true
)"
if [[ -n "$wireguard_submodule" ]]; then
	git submodule sync -- "$wireguard_submodule"
	git submodule update --init --depth=1 --recursive -- "$wireguard_submodule"
fi

extra_tag_list=()
split_tags() {
	local value="$1"
	[[ -n "$value" ]] || return 0
	local tag
	while IFS= read -r tag; do
		[[ -n "$tag" ]] || continue
		extra_tag_list+=("$tag")
	done < <(printf '%s\n' "$value" | tr ', \t' '\n')
}

if [[ "${SING_BOX_LX:-}" == "1" ]]; then
	if [[ ! -f Makefile.lx ]]; then
		echo "SING_BOX_LX=1 requires Makefile.lx in $repo_dir" >&2
		exit 1
	fi
	split_tags "$(make -f Makefile.lx -s lx-print-tags)"
fi
split_tags "${SING_BOX_BUILD_TAGS:-}"
split_tags "${SING_BOX_EXTRA_TAGS:-}"

if [[ "${#extra_tag_list[@]}" -gt 0 ]]; then
	extra_tags="$(
		printf '%s\n' "${extra_tag_list[@]}" \
			| awk '!seen[$0]++' \
			| paste -sd, -
	)"
	export SING_BOX_EXTRA_TAGS="$extra_tags"
	echo "using extra sing-box build tags: $SING_BOX_EXTRA_TAGS"
fi
if [[ "$variant" == "ordinary" && ",${SING_BOX_EXTRA_TAGS:-}," == *",with_wlt,"* ]]; then
	echo "ordinary libbox builds must be WLT-free; refusing with_wlt tag" >&2
	exit 1
fi

if [[ "${LIBBOX_SKIP_TOOL_INSTALL:-0}" != "1" ]]; then
	make lib_install
fi
export PATH="$PATH:$(go env GOPATH)/bin"
go run ./cmd/internal/build_libbox -target apple -platform "$platforms"

source_xcframework="$repo_dir/Libbox.xcframework"
if [[ ! -d "$source_xcframework" && -d "$client_root/Libbox.xcframework" ]]; then
	source_xcframework="$client_root/Libbox.xcframework"
fi
if [[ ! -d "$source_xcframework" ]]; then
	echo "Libbox.xcframework was not produced" >&2
	exit 1
fi
if [[ "$source_xcframework" != "$destination" ]]; then
	rm -rf "$destination"
	mkdir -p "$(dirname "$destination")"
	mv "$source_xcframework" "$destination"
fi
printf '%s\n' "$variant" > "$destination/.libbox-variant"
printf '%s\n' "$libbox_version" > "$destination/.libbox-version"
git rev-parse HEAD > "$destination/.libbox-source-ref"
active_xcframework="$client_root/Libbox.xcframework"
if [[ "${LIBBOX_ACTIVATE:-1}" == "1" && "$destination" != "$active_xcframework" ]]; then
	rm -rf "$active_xcframework"
	cp -R "$destination" "$active_xcframework"
fi
