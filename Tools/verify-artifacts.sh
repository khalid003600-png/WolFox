#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: verify-artifacts.sh WolFox.dylib [WolFox_YouTube.ipa]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DYLIB="$1"
test -f "$DYLIB"

if command -v lipo >/dev/null 2>&1; then
  INFO="$(lipo -info "$DYLIB")"
elif command -v llvm-lipo >/dev/null 2>&1; then
  INFO="$(llvm-lipo -info "$DYLIB")"
else
  INFO=""
fi

if [[ -n "$INFO" ]]; then
  [[ "$INFO" == *arm64* ]]
fi

if command -v otool >/dev/null 2>&1; then
  DEPS="$(otool -L "$DYLIB")"
  [[ "$DEPS" != *CydiaSubstrate* ]]
  [[ "$DEPS" != *MobileSubstrate* ]]
fi

if [[ $# -eq 2 ]]; then
  IPA="$2"
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  unzip -q "$IPA" -d "$WORK"
  APP="$(find "$WORK/Payload" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print -quit)"
  test -n "$APP"
  [[ "${APP##*/}" == "WolFox.app" ]]
  test ! -e "$APP/Frameworks/CydiaSubstrate.framework"
  test -f "$APP/Frameworks/WolFox.dylib"
  test ! -e "$APP/Frameworks/YTKACE.dylib"
  test -f "$APP/WolFox.bundle/Info.plist"
  test ! -e "$APP/YTKACE.bundle"

  python3 - "$APP/Info.plist" "$APP/WolFox.bundle/Info.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "rb") as handle:
    app = plistlib.load(handle)
with open(sys.argv[2], "rb") as handle:
    resources = plistlib.load(handle)
assert app.get("CFBundleDisplayName") == "WolFox", app.get("CFBundleDisplayName")
assert app.get("CFBundleName") == "WolFox", app.get("CFBundleName")
assert app.get("CFBundleIdentifier") == "com.google.ios.youtube", app.get("CFBundleIdentifier")
assert app.get("CFBundleExecutable") == "WolFox", app.get("CFBundleExecutable")
assert resources.get("CFBundleName") == "WolFox", resources.get("CFBundleName")
assert resources.get("CFBundleShortVersionString") == "1.2.1", resources.get("CFBundleShortVersionString")
PY

  EXECUTABLE="$APP/WolFox"
  test -f "$EXECUTABLE"
  LOADS="$(python3 "$ROOT/Tools/macho_inject.py" "$EXECUTABLE" --list)"
  [[ "$LOADS" == *'@rpath/WolFox.dylib'* ]]
  [[ "$LOADS" != *'YTKACE.dylib'* ]]
fi

echo "verified"
