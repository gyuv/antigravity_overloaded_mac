#!/usr/bin/env bash
# Builds Antigravity Code as a Universal 2 (arm64 + x86_64) .app bundle and optional .dmg.
#
# Env:
#   VERSION            marketing version (default: from Sources/AntigravityCore/Version.swift)
#   SIGN_IDENTITY      "Developer ID Application: Name (TEAMID)" — omit for ad-hoc signing
#   NOTARY_PROFILE     notarytool keychain profile name (xcrun notarytool store-credentials) — enables notarization
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT=$(pwd)
BUILD="$ROOT/.build"
DIST="$ROOT/dist"
APP="$DIST/Antigravity Code.app"
VERSION=${VERSION:-$(sed -n 's/.*version = "\(.*\)".*/\1/p' Sources/AntigravityCore/Version.swift)}
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
ARCHS=(arm64 x86_64)
STEP=${1:-app}

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

universal() {
  for a in "${ARCHS[@]}"; do
    log "Compiling release for $a"
    swift build -c release --triple "$a-apple-macosx12.0"
    eval "BIN_$a=\"\$(swift build -c release --triple $a-apple-macosx12.0 --show-bin-path)\""
  done
  mkdir -p "$BUILD/universal"
  for product in agcode AntigravityCodeApp; do
    log "lipo → $product (universal)"
    lipo -create \
      "$BIN_arm64/$product" \
      "$BIN_x86_64/$product" \
      -output "$BUILD/universal/$product"
    lipo -info "$BUILD/universal/$product"
  done
}

sign() {
  local target=$1
  if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp --options runtime \
      --entitlements Packaging/AntigravityCode.entitlements \
      --sign "$SIGN_IDENTITY" "$target"
  else
    codesign --force --sign - "$target"
  fi
}

bundle() {
  log "Assembling $APP"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
  cp "$BUILD/universal/AntigravityCodeApp" "$APP/Contents/MacOS/AntigravityCode"
  cp "$BUILD/universal/agcode" "$APP/Contents/Helpers/agcode"
  sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Packaging/Info.plist > "$APP/Contents/Info.plist"
  [[ -f Packaging/AppIcon.icns ]] && cp Packaging/AppIcon.icns "$APP/Contents/Resources/" \
    && /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" || true
  printf 'APPL????' > "$APP/Contents/PkgInfo"
  log "Signing (${SIGN_IDENTITY:-ad-hoc})"
  sign "$APP/Contents/Helpers/agcode"
  sign "$APP"
  codesign --verify --deep --strict "$APP"
}

dmg() {
  local out="$DIST/AntigravityCode-$VERSION-universal.dmg"
  log "Creating $out"
  rm -f "$out"
  local stage; stage=$(mktemp -d)
  cp -R "$APP" "$stage/"
  ln -s /Applications "$stage/Applications"
  hdiutil create -volname "Antigravity Code" -srcfolder "$stage" -ov -format UDZO "$out"
  rm -rf "$stage"
  [[ -n "${SIGN_IDENTITY:-}" ]] && codesign --force --timestamp --sign "$SIGN_IDENTITY" "$out"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    log "Notarizing"
    xcrun notarytool submit "$out" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$out"
  fi
  log "Done: $out"
}

case "$STEP" in
  universal) universal ;;
  app) universal; bundle ;;
  dmg) universal; bundle; dmg ;;
  *) echo "usage: $0 [universal|app|dmg]"; exit 2 ;;
esac
