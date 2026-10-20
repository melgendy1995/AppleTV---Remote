#!/usr/bin/env bash
#
# Build a Release .app and zip it for sharing.
# On this Mac, signs with an Apple Development certificate. Screen
# Recording grants do not stick for ad-hoc or self-signed apps. CI stays
# ad-hoc. Override with SIGN_IDENTITY=<hash-or-name>.
# Recipients still need to strip the macOS quarantine attribute — see
# INSTALL.md.
#
# Usage: ./ship.sh   (run from anywhere; cd's to the script's own directory)

set -euo pipefail

cd "$(dirname "$0")"

PROJECT=AppleTVRemote.xcodeproj
SCHEME=AppleTVRemote-macOS
CONFIG=Release
BUILD_DIR="$(pwd)/build"
DERIVED="$BUILD_DIR"
PRODUCT_DIR="$DERIVED/Build/Products/$CONFIG"
APP_NAME="Apple TV Remote.app"
APP_PATH="$PRODUCT_DIR/$APP_NAME"
DIST_DIR="$BUILD_DIR/dist"

echo "==> Cleaning previous build output"
rm -rf "$BUILD_DIR"
mkdir -p "$DIST_DIR"

# Screen Recording TCC only keeps a grant whose code requirement chains to
# Apple (a Team ID). Ad-hoc and self-signed roots are dropped on relaunch.
SIGN_ID="${SIGN_IDENTITY:-}"
if [[ -z "$SIGN_ID" && -z "${CI:-}" ]]; then
  idents="$(security find-identity -p codesigning -v 2>/dev/null || true)"
  SIGN_ID="$(printf '%s\n' "$idents" | grep 'Apple Development:' | grep -v REVOKED | grep -i 'mahmoud' | tail -1 | sed -n 's/^ *[0-9]*) \([0-9A-F]*\) .*/\1/p')"
  if [[ -z "$SIGN_ID" ]]; then
    SIGN_ID="$(printf '%s\n' "$idents" | grep 'Apple Development:' | grep -v REVOKED | tail -1 | sed -n 's/^ *[0-9]*) \([0-9A-F]*\) .*/\1/p')"
  fi
  if [[ -z "$SIGN_ID" ]] && printf '%s\n' "$idents" | grep -q '"AppleTVRemote-Dev"'; then
    SIGN_ID="AppleTVRemote-Dev"
  fi
fi
SIGN_ID="${SIGN_ID:--}"

echo "==> Building $SCHEME ($CONFIG) signed as: $SIGN_ID"
xcodebuild_args=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIG"
  -destination 'platform=macOS'
  -derivedDataPath "$DERIVED"
  CODE_SIGN_IDENTITY="$SIGN_ID"
  CODE_SIGN_STYLE=Manual
  DEVELOPMENT_TEAM=""
)
if [[ "$SIGN_ID" == "-" ]]; then
  xcodebuild_args+=(CODE_SIGNING_REQUIRED=NO)
fi
xcodebuild_args+=(build)
if [[ -n "${CI:-}" ]]; then
  xcodebuild "${xcodebuild_args[@]}"
else
  xcodebuild "${xcodebuild_args[@]}" >/dev/null
fi

[[ -d "$APP_PATH" ]] || { echo "build failed — $APP_PATH not found"; exit 1; }

echo "==> Verifying bundled backend resources"
RESOURCES="$APP_PATH/Contents/Resources"
for required in "Vendor/python/bin/python3" "Vendor/backend/app/main.py"; do
  if [[ ! -e "$RESOURCES/$required" ]]; then
    echo "missing $required inside the .app — did you run from the project root with Vendor/ populated?"
    exit 1
  fi
done

echo "==> Re-signing (deep) so embedded binaries match the app identity"
if [[ "$SIGN_ID" == "-" ]]; then
  codesign --force --deep --sign - "$APP_PATH" >/dev/null
else
  # Same identity on the main binary and the bundled Python runtime, so
  # Local Network / Screen Recording / Accessibility grants survive rebuilds.
  codesign --force --deep --sign "$SIGN_ID" \
    --entitlements Entitlements-macOS.plist \
    --options runtime \
    "$APP_PATH" >/dev/null
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
ZIP_NAME="AppleTVRemote-$VERSION.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"

echo "==> Zipping with ditto (preserves resource forks + Python symlinks)"
( cd "$PRODUCT_DIR" && ditto -c -k --sequesterRsrc --keepParent "$APP_NAME" "$ZIP_PATH" )

README_PATH="$DIST_DIR/INSTALL.md"
cp INSTALL.md "$README_PATH"

SIZE="$(du -h "$ZIP_PATH" | cut -f1)"
echo
echo "==> Done."
echo "    Artifact: $ZIP_PATH ($SIZE)"
echo "    Install:  $README_PATH"
echo "    Share both with whoever needs the app."
