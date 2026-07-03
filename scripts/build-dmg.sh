#!/usr/bin/env bash
#
# build-dmg.sh — Build RelayBack.app in Release and package it into a distributable .dmg.
#
# Usage:
#   ./scripts/build-dmg.sh                 # unsigned local build → dist/RelayBack-<ver>.dmg
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./scripts/build-dmg.sh
#   NOTARY_PROFILE="relayback-notary" ./scripts/build-dmg.sh   # also notarize + staple
#
# Env vars (all optional):
#   SIGN_IDENTITY   codesign identity for Developer ID signing the .app
#   NOTARY_PROFILE  `notarytool` keychain profile name (implies notarize + staple)
#   CONFIGURATION   xcodebuild configuration (default: Release)
#
# Notarization prerequisites (one-time):
#   xcrun notarytool store-credentials "relayback-notary" \
#     --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-pw"
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SCHEME="RelayBack"
APP_NAME="RelayBack"
PROJECT="$REPO_ROOT/RelayBack/RelayBack.xcodeproj"
CONFIGURATION="${CONFIGURATION:-Release}"

BUILD_DIR="$REPO_ROOT/build"
DIST_DIR="$REPO_ROOT/dist"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
STAGING_DIR="$BUILD_DIR/dmg-staging"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

# 1. Archive -------------------------------------------------------------------
log "Archiving $SCHEME ($CONFIGURATION)…"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  archive

# 2. Export the .app from the archive -----------------------------------------
# We copy the app out of the archive directly. A Developer ID export plist path
# would work too, but a copy keeps this dependency-free for unsigned local builds.
log "Exporting $APP_NAME.app…"
mkdir -p "$EXPORT_DIR"
cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME.app" "$APP_PATH"

# 3. Read version for the dmg filename ----------------------------------------
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo '0.0.0')"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"

# 4. (Optional) Developer ID sign ---------------------------------------------
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  log "Codesigning with: $SIGN_IDENTITY"
  codesign --force --deep --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$APP_PATH"
  codesign --verify --strict --verbose=2 "$APP_PATH"
else
  log "No SIGN_IDENTITY set — producing an UNSIGNED build (Gatekeeper will warn)."
fi

# 5. Build the DMG -------------------------------------------------------------
log "Building disk image…"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov -format UDZO \
  "$DMG_PATH"

# 6. (Optional) Notarize + staple ---------------------------------------------
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    echo "error: NOTARY_PROFILE requires SIGN_IDENTITY (notarization needs a signed app)." >&2
    exit 1
  fi
  log "Submitting to notary service (profile: $NOTARY_PROFILE)…"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  log "Stapling ticket…"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

log "Done: $DMG_PATH"
