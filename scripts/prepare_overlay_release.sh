#!/bin/bash

set -euo pipefail

force=false
while [[ $# -gt 0 ]]; do
	case "$1" in
		--force)
			force=true
			shift
			;;
		*)
			echo "unknown argument: $1" >&2
			exit 1
			;;
	esac
done

origin_remote="${ORIGIN_REMOTE:-origin}"
upstream_remote="${UPSTREAM_REMOTE:-upstream}"
project_file="sing-box.xcodeproj/project.pbxproj"
tmp_branch="ci/overlay-release"

write_output() {
	local key="$1"
	local value="$2"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
	fi
	printf '%s=%s\n' "$key" "$value"
}

git fetch "$origin_remote" main overlay --prune
git fetch "$upstream_remote" main --prune

current_main_sha="$(git rev-parse "$origin_remote/main")"
current_overlay_sha="$(git rev-parse "$origin_remote/overlay")"
upstream_sha="$(git rev-parse "$upstream_remote/main")"

current_version="$(
	git show "$origin_remote/main:$project_file" \
	| python3 scripts/read_apple_project_setting.py --stdin --infoplist SFI/Info.plist --setting MARKETING_VERSION
)"
upstream_version="$(
	git show "$upstream_remote/main:$project_file" \
	| python3 scripts/read_apple_project_setting.py --stdin --infoplist SFI/Info.plist --setting MARKETING_VERSION
)"

overlay_commit_count="$(git rev-list --count "$origin_remote/main..$origin_remote/overlay")"
if [[ "$overlay_commit_count" == "0" ]]; then
	echo "expected origin/overlay to contain overlay commits relative to origin/main" >&2
	exit 1
fi

overlay_commits="$(git rev-list --reverse "$origin_remote/main..$origin_remote/overlay")"
upstream_changed=false
version_changed=false
should_release=false
should_push=false

if [[ "$upstream_sha" != "$current_main_sha" ]]; then
	upstream_changed=true
	should_push=true
fi

if [[ "$upstream_version" != "$current_version" ]]; then
	version_changed=true
fi

if [[ "$force" == true || ( "$upstream_changed" == true && "$version_changed" == true ) ]]; then
	should_release=true
fi

write_output current_main_sha "$current_main_sha"
write_output current_overlay_sha "$current_overlay_sha"
write_output upstream_sha "$upstream_sha"
write_output overlay_commit_count "$overlay_commit_count"
write_output current_version "$current_version"
write_output upstream_version "$upstream_version"
write_output upstream_changed "$upstream_changed"
write_output version_changed "$version_changed"
write_output should_release "$should_release"
write_output should_push "$should_push"

if [[ "$should_release" != "true" ]]; then
	exit 0
fi

git branch -f main "$upstream_remote/main" >/dev/null
git checkout -B "$tmp_branch" "$upstream_remote/main" >/dev/null
while IFS= read -r overlay_commit; do
	[[ -n "$overlay_commit" ]] || continue
	git cherry-pick --no-edit "$overlay_commit" >/dev/null
done <<< "$overlay_commits"

new_overlay_sha="$(git rev-parse HEAD)"
new_version="$(python3 scripts/read_apple_project_setting.py --file "$project_file" --infoplist SFI/Info.plist --setting MARKETING_VERSION)"

write_output release_branch "$tmp_branch"
write_output new_overlay_sha "$new_overlay_sha"
write_output new_version "$new_version"
