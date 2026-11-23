#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: sideload-repack.sh input.ipa WolFox.dylib [WolFox_YouTube.ipa]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INPUT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
DYLIB="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
OUTPUT="${3:-$PWD/WolFox_YouTube.ipa}"
OUTPUT="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$OUTPUT")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v unzip >/dev/null 2>&1
command -v zip >/dev/null 2>&1
command -v python3 >/dev/null 2>&1
test -f "$INPUT"
test -f "$DYLIB"

unzip -q "$INPUT" -d "$WORK"
APP="$(find "$WORK/Payload" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print -quit)"
test -n "$APP"

case "$(cd "$APP" && pwd)" in
  "$WORK"/*) ;;
  *) echo "invalid app path" >&2; exit 1 ;;
esac

BUNDLE_ID="$(python3 - "$APP/Info.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "rb") as handle:
    print(plistlib.load(handle).get("CFBundleIdentifier", ""))
PY
)"
if [[ "$BUNDLE_ID" != "com.google.ios.youtube" ]]; then
  echo "unexpected app bundle identifier: $BUNDLE_ID" >&2
  exit 1
fi

rm -rf "$APP/Extensions/AppMigrationExtension.appex"
rm -rf "$APP/_CodeSignature"
find "$APP" -maxdepth 1 -type f \( -name 'YTK@*' -o -name 'YTK-*' \) -delete
python3 "$ROOT/Tools/sanitize_plist.py" "$APP/Info.plist"
python3 "$ROOT/Tools/set_app_display_name.py" "$APP" "WolFox" "WolFox"

APP_PARENT="${APP%/*}"
if [[ "${APP##*/}" != "WolFox.app" ]]; then
  mv "$APP" "$APP_PARENT/WolFox.app"
  APP="$APP_PARENT/WolFox.app"
fi
MAIN="$APP/WolFox"
test -f "$MAIN"

# Replace artifacts from a prior YTKACE-branded IPA; the bundle identifier stays YouTube's.
rm -rf "$APP/YTKACE.bundle" "$APP/WolFox.bundle"
rm -f "$APP/Frameworks/YTKACE.dylib" "$APP/Frameworks/WolFox.dylib"
python3 "$ROOT/Tools/macho_inject.py" "$MAIN" \
  --remove-load 'YTKACE.dylib' \
  --add-load '@rpath/WolFox.dylib'

mkdir -p "$APP/Frameworks"
cp "$DYLIB" "$APP/Frameworks/WolFox.dylib"
cp -R "$ROOT/Resources/WolFox.bundle" "$APP/WolFox.bundle"

# Optional Safari extension; its bundle identity follows the host app's YouTube ID.
if [[ -n "${SAFARI_EXTENSION_APPEX:-}" ]]; then
  test -f "$SAFARI_EXTENSION_APPEX/Info.plist"
  EXTENSION="$APP/PlugIns/OpenInWolFox.appex"
  mkdir -p "$APP/PlugIns"
  rm -rf "$EXTENSION" "$APP/PlugIns/OpenInYTKACE.appex"
  cp -R "$SAFARI_EXTENSION_APPEX" "$EXTENSION"
  python3 "$ROOT/Tools/set_app_display_name.py" "$EXTENSION" "WolFox Link Helper"
  python3 - "$APP/Info.plist" "$EXTENSION/Info.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "rb") as handle:
    app = plistlib.load(handle)
with open(sys.argv[2], "rb") as handle:
    ext = plistlib.load(handle)
# The extension must remain a child of YouTube's unchanged bundle identifier.
ext["CFBundleIdentifier"] = app["CFBundleIdentifier"] + ".OpenInWolFox"
ext["CFBundleShortVersionString"] = app["CFBundleShortVersionString"]
ext["CFBundleVersion"] = app["CFBundleVersion"]
with open(sys.argv[2], "wb") as handle:
    plistlib.dump(ext, handle, sort_keys=False)
PY
fi

python3 - "$APP/Info.plist" "$MAIN" <<'PY'
import pathlib
import plistlib
import sys
with open(sys.argv[1], "rb") as handle:
    info = plistlib.load(handle)
assert info.get("CFBundleIdentifier") == "com.google.ios.youtube", info.get("CFBundleIdentifier")
assert info.get("CFBundleDisplayName") == "WolFox", info.get("CFBundleDisplayName")
assert info.get("CFBundleExecutable") == "WolFox", info.get("CFBundleExecutable")
assert pathlib.Path(sys.argv[2]).is_file(), sys.argv[2]
PY

bash "$ROOT/Scripts/sign-bundle.sh" "$APP"

mkdir -p "$(dirname "$OUTPUT")"
ARCHIVE="$WORK/WolFox_YouTube.ipa"
(
  cd "$WORK"
  zip -qry "$ARCHIVE" Payload
)
mv -f "$ARCHIVE" "$OUTPUT"

echo "$OUTPUT"
