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

tmp_dir="${TARGET_TEMP_DIR:-${DERIVED_FILE_DIR:-${TMPDIR:-/tmp}}}"

for icon_suffix in \
  "20x20@2x.png" \
  "20x20@3x.png" \
  "29x29@2x.png" \
  "29x29@3x.png" \
  "40x40@2x.png" \
  "40x40@3x.png" \
  "60x60@2x.png" \
  "60x60@3x.png" \
  "76x76@2x~ipad.png" \
  "83.5x83.5@2x~ipad.png"
do
  icon_path="${resources_dir}/${icon_name}${icon_suffix}"
  if [ ! -f "$icon_path" ]; then
    continue
  fi

  if /usr/bin/sips -g hasAlpha "$icon_path" 2>/dev/null | /usr/bin/grep -q "hasAlpha: yes"; then
    tmp_path="${tmp_dir}/${icon_name}${icon_suffix}.noalpha"
    /bin/rm -f "$tmp_path"
    "$pngcrush" -q -rem alla -reduce "$icon_path" "$tmp_path"
    /bin/mv "$tmp_path" "$icon_path"
  fi
done
