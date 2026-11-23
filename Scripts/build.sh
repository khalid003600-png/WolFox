#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${THEOS:?Set THEOS first}"

make -C "$ROOT" clean all
test -f "$ROOT/dist/WolFox.dylib"

if command -v lipo >/dev/null 2>&1; then
  lipo -info "$ROOT/dist/WolFox.dylib"
elif command -v llvm-lipo >/dev/null 2>&1; then
  llvm-lipo -info "$ROOT/dist/WolFox.dylib"
fi
