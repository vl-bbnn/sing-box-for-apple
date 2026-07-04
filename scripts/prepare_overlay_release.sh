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
version_ceiling="$(tr -d '[:space:]' < Config/Overlay.version-ceiling)"
application_name="${OVERLAY_APPLICATION_NAME:-$(./scripts/overlay_setting.sh OVERLAY_APPLICATION_NAME)}"
tmp_branch="ci/overlay-release"

write_output() {
	local key="$1"
	local value="$2"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
	fi
	printf '%s=%s\n' "$key" "$value"
}

write_multiline_output() {
	local key="$1"
	local value="$2"
	local delimiter="EOF_$(date +%s%N)"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		{
			printf '%s<<%s\n' "$key" "$delimiter"
			printf '%s\n' "$value"
			printf '%s\n' "$delimiter"
		} >> "$GITHUB_OUTPUT"
	fi
	printf '%s:\n%s\n' "$key" "$value"
}

version_lte() {
	python3 - "$1" "$2" <<'PY'
import sys

def version(value):
    core = value.split("-", 1)[0]
    return tuple(int(part) for part in core.split("."))

raise SystemExit(0 if version(sys.argv[1]) <= version(sys.argv[2]) else 1)
PY
}

resolve_project_version_conflict() {
	local overlay_commit="$1"
	local conflicted_paths

	conflicted_paths="$(git diff --name-only --diff-filter=U || true)"
	if [[ "$version_changed" != "true" || "$conflicted_paths" != "$project_file" ]]; then
		return 1
	fi

	git checkout "$overlay_commit" -- "$project_file"
	python3 - "$project_file" "$current_version" "$upstream_version" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
current_version = sys.argv[2]
upstream_version = sys.argv[3]
old = f'MARKETING_VERSION = "{current_version}";'
new = f'MARKETING_VERSION = "{upstream_version}";'
text = path.read_text()
if old not in text:
    raise SystemExit(f"expected {old!r} in {path}")
path.write_text(text.replace(old, new))
PY
	git add "$project_file"
	git cherry-pick --continue >/dev/null
}

resolve_initial_overlay_conflict() {
	local overlay_commit="$1"
	local conflicted_paths
	local subject

	subject="$(git log -1 --format=%s "$overlay_commit")"
	conflicted_paths="$(git diff --name-only --diff-filter=U | sort || true)"
	if [[ "$subject" != "ci: automate TestFlight sync from upstream main" ]]; then
		return 1
	fi
	case "$conflicted_paths" in
		"Makefile")
			git checkout --theirs -- Makefile
			;;
		$'.gitignore\nMakefile')
			git checkout --theirs -- .gitignore Makefile
			;;
		*)
			return 1
			;;
	esac

	python3 <<'PY'
from pathlib import Path

path = Path("Makefile")
text = path.read_text()
replacements = {
    "-archivePath build/SFM.System-arm64.xcarchive ARCHS=arm64":
        "-archivePath build/SFM.System-arm64.xcarchive -derivedDataPath build/SFM.System-arm64.dd ARCHS=arm64",
    "-archivePath build/SFM.System-x86_64.xcarchive ARCHS=x86_64":
        "-archivePath build/SFM.System-x86_64.xcarchive -derivedDataPath build/SFM.System-x86_64.dd ARCHS=x86_64",
    "-archivePath build/SFM.System-universal.xcarchive -allowProvisioningUpdates":
        "-archivePath build/SFM.System-universal.xcarchive -derivedDataPath build/SFM.System-universal.dd -allowProvisioningUpdates",
}
for old, new in replacements.items():
    if new in text:
        continue
    if old not in text:
        raise SystemExit(f"expected Makefile fragment not found: {old}")
    text = text.replace(old, new)
path.write_text(text)
PY
	git add .gitignore Makefile
	git cherry-pick --continue >/dev/null
}

git fetch "$origin_remote" main overlay --prune
git fetch "$upstream_remote" main --prune
if ! git config user.name >/dev/null; then
	git config user.name "${GIT_AUTHOR_NAME:-github-actions[bot]}"
fi
if ! git config user.email >/dev/null; then
	git config user.email "${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
fi

current_main_sha="$(git rev-parse "$origin_remote/main")"
current_overlay_sha="$(git rev-parse "$origin_remote/overlay")"
upstream_sha="$(git rev-parse "$upstream_remote/main")"
checked_out_sha="$(git rev-parse HEAD)"
release_overlay_ref="$origin_remote/overlay"

if [[ "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" && "$checked_out_sha" != "$current_overlay_sha" ]]; then
	if git merge-base --is-ancestor "$origin_remote/main" "$checked_out_sha"; then
		release_overlay_ref="$checked_out_sha"
		current_overlay_sha="$checked_out_sha"
	else
		echo "workflow_dispatch ref $checked_out_sha is not based on $origin_remote/main; using $origin_remote/overlay" >&2
	fi
fi

current_version="$(
	git show "$origin_remote/main:$project_file" \
	| python3 scripts/read_apple_project_setting.py --stdin --infoplist SFI/Info.plist --setting MARKETING_VERSION
)"
upstream_version="$(
	git show "$upstream_remote/main:$project_file" \
	| python3 scripts/read_apple_project_setting.py --stdin --infoplist SFI/Info.plist --setting MARKETING_VERSION
)"
release_overlay_version="$(
	git show "$release_overlay_ref:$project_file" \
	| python3 scripts/read_apple_project_setting.py --stdin --infoplist SFI/Info.plist --setting MARKETING_VERSION
)"

manual_checked_out_release=false
if [[ "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" && "$force" == true && "$release_overlay_ref" == "$checked_out_sha" ]]; then
	if version_lte "$release_overlay_version" "$version_ceiling"; then
		manual_checked_out_release=true
	fi
fi

if ! version_lte "$upstream_version" "$version_ceiling"; then
	if [[ "$manual_checked_out_release" == "true" ]]; then
		release_notes="sing-box $release_overlay_version"

		write_output current_main_sha "$current_main_sha"
		write_output current_overlay_sha "$current_overlay_sha"
		write_output upstream_sha "$upstream_sha"
		write_output overlay_commit_count "$(git rev-list --count "$origin_remote/main..$release_overlay_ref")"
		write_output current_version "$current_version"
		write_output upstream_version "$upstream_version"
		write_output upstream_changed false
		write_output version_changed false
		write_output should_release true
		write_output should_push false
		write_multiline_output release_notes "$release_notes"

		git checkout -B "$tmp_branch" "$release_overlay_ref" >/dev/null
		new_overlay_sha="$(git rev-parse HEAD)"
		new_version="$(python3 scripts/read_apple_project_setting.py --file "$project_file" --infoplist SFI/Info.plist --setting MARKETING_VERSION)"

		write_output release_branch "$tmp_branch"
		write_output new_overlay_sha "$new_overlay_sha"
		write_output new_version "$new_version"
		exit 0
	fi

	echo "upstream version $upstream_version exceeds overlay ceiling $version_ceiling; skipping" >&2
	write_output upstream_version "$upstream_version"
	write_output version_ceiling "$version_ceiling"
	write_output should_release false
	write_output should_push false
	exit 0
fi

overlay_commit_count="$(git rev-list --count "$origin_remote/main..$release_overlay_ref")"
if [[ "$overlay_commit_count" == "0" ]]; then
	echo "expected $release_overlay_ref to contain overlay commits relative to origin/main" >&2
	exit 1
fi

overlay_commits="$(git rev-list --reverse "$origin_remote/main..$release_overlay_ref")"
upstream_changed=false
version_changed=false
should_release=false
should_push=false
release_notes=""

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

release_notes="$(
	VERSION="$upstream_version" APPLICATION_NAME="$application_name" CURRENT_MAIN_SHA="$current_main_sha" UPSTREAM_SHA="$upstream_sha" python3 <<'PY'
import os
import subprocess

version = os.environ["VERSION"]
application_name = os.environ["APPLICATION_NAME"]
current_main_sha = os.environ["CURRENT_MAIN_SHA"]
upstream_sha = os.environ["UPSTREAM_SHA"]
max_length = 3900

subjects = subprocess.check_output(
    ["git", "log", "--reverse", "--pretty=format:%s", f"{current_main_sha}..{upstream_sha}"],
    text=True,
).splitlines()
subjects = [
    subject.strip()
    for subject in subjects
    if subject.strip() and not subject.strip().lower().startswith("bump version")
]

header = f"{application_name} {version}"
if not subjects:
    print(header)
    raise SystemExit(0)

notes = f"{header}\n\nChanges:"
for subject in subjects:
    line = f"\n- {subject}"
    if len(notes) + len(line) > max_length:
        if len(notes) + len("\n- ...") <= max_length:
            notes += "\n- ..."
        break
    notes += line

print(notes)
PY
)"

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
write_multiline_output release_notes "$release_notes"

if [[ "$should_release" != "true" ]]; then
	exit 0
fi

git branch -f main "$upstream_remote/main" >/dev/null
git checkout -B "$tmp_branch" "$upstream_remote/main" >/dev/null
while IFS= read -r overlay_commit; do
	[[ -n "$overlay_commit" ]] || continue
	if ! git cherry-pick --no-edit "$overlay_commit" >/dev/null 2>&1; then
		if ! resolve_project_version_conflict "$overlay_commit" && ! resolve_initial_overlay_conflict "$overlay_commit"; then
			git cherry-pick --abort >/dev/null 2>&1 || true
			echo "failed to cherry-pick overlay commit $overlay_commit" >&2
			exit 1
		fi
	fi
done <<< "$overlay_commits"

new_overlay_sha="$(git rev-parse HEAD)"
new_version="$(python3 scripts/read_apple_project_setting.py --file "$project_file" --infoplist SFI/Info.plist --setting MARKETING_VERSION)"

write_output release_branch "$tmp_branch"
write_output new_overlay_sha "$new_overlay_sha"
write_output new_version "$new_version"
