#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/ClipboardArchiv.app"
BIN="$APP/Contents/MacOS/ClipboardArchiv"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

swiftc \
  -O \
  -parse-as-library \
  "$ROOT/Sources/ClipboardArchiv.swift" \
  -o "$BIN" \
  -framework AppKit \
  -framework SwiftUI \
  -framework ApplicationServices \
  -framework Carbon \
  -framework CryptoKit \
  -framework LocalAuthentication \
  -framework Network \
  -framework Security

chmod +x "$BIN"

if command -v codesign >/dev/null 2>&1; then
  SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
  if [[ -z "$SIGN_IDENTITY" ]] && command -v security >/dev/null 2>&1; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)"
  fi

  if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP"
  else
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
  fi
fi

echo "$APP"
