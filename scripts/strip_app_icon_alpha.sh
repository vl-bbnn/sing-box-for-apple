#!/bin/sh
set -eu

resources_dir="${TARGET_BUILD_DIR:-}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}"
icon_name="${ASSETCATALOG_COMPILER_APPICON_NAME:-}"

if [ -z "$icon_name" ] || [ ! -d "$resources_dir" ]; then
  exit 0
fi

pngcrush="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}/usr/bin/pngcrush"
if [ ! -x "$pngcrush" ]; then
  pngcrush="/Applications/Xcode.app/Contents/Developer/usr/bin/pngcrush"
fi

if [ ! -x "$pngcrush" ]; then
  echo "warning: pngcrush not found; app icon alpha channel was not stripped"
  exit 0
fi

find "$resources_dir" -maxdepth 1 -type f -name "${icon_name}*.png" -exec sh -c '
pngcrush="$1"
shift

for icon_path do
  if /usr/bin/sips -g hasAlpha "$icon_path" 2>/dev/null | /usr/bin/grep -q "hasAlpha: yes"; then
    tmp_path="${icon_path}.noalpha"
    "$pngcrush" -q -rem alla -reduce "$icon_path" "$tmp_path"
    /bin/mv "$tmp_path" "$icon_path"
  fi
done
' sh "$pngcrush" {} +
