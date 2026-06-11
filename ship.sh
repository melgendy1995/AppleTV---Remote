#!/usr/bin/env bash
#
# Build a Release .app, re-sign ad-hoc, zip it for sharing.
# Recipients still need to strip the macOS quarantine attribute — the
# generated INSTALL.md explains how.
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

echo "==> Building $SCHEME ($CONFIG)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  build >/dev/null

[[ -d "$APP_PATH" ]] || { echo "build failed — $APP_PATH not found"; exit 1; }

echo "==> Verifying bundled backend resources"
RESOURCES="$APP_PATH/Contents/Resources"
for required in "Vendor/python/bin/python3" "Vendor/backend/app/main.py"; do
  if [[ ! -e "$RESOURCES/$required" ]]; then
    echo "missing $required inside the .app — did you run from the project root with Vendor/ populated?"
    exit 1
  fi
done

echo "==> Re-signing ad-hoc (deep) so embedded binaries pass signature-integrity checks"
codesign --force --deep --sign - "$APP_PATH" >/dev/null

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
ZIP_NAME="AppleTVRemote-$VERSION.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"

echo "==> Zipping with ditto (preserves resource forks + Python symlinks)"
( cd "$PRODUCT_DIR" && ditto -c -k --sequesterRsrc --keepParent "$APP_NAME" "$ZIP_PATH" )

README_PATH="$DIST_DIR/INSTALL.md"
cat > "$README_PATH" <<'EOF'
# Apple TV Remote — install

This `.app` is unsigned (no Apple Developer Program), so macOS Gatekeeper
will refuse to launch it normally. Run the steps below once and it'll work.

## 1. Unzip and move

Unzip `AppleTVRemote-*.zip`, then drag `Apple TV Remote.app` into
`~/Applications` (or `/Applications` if you prefer — `~/Applications` doesn't
need admin).

## 2. Remove the quarantine flag

macOS marks downloaded apps as quarantined. For an unsigned app this shows up
as "Apple TV Remote.app is damaged and can't be opened." Strip the flag with:

```bash
xattr -dr com.apple.quarantine ~/Applications/"Apple TV Remote.app"
```

(Adjust the path if you put it elsewhere.)

## 3. First launch

```bash
open ~/Applications/"Apple TV Remote.app"
```

If macOS still complains, right-click the app → **Open** → **Open** in the
confirmation dialog. After that it launches normally from the Dock.

## What it does on first run

- Starts a small Python backend bundled inside the app (no install needed).
- Scans your Wi-Fi for Apple TVs.
- Pair each Apple TV once (PIN flow), then connect and control it.

Backend logs and pairing credentials live in `~/.appletv-remote/`.
EOF

SIZE="$(du -h "$ZIP_PATH" | cut -f1)"
echo
echo "==> Done."
echo "    Artifact: $ZIP_PATH ($SIZE)"
echo "    Install:  $README_PATH"
echo "    Share both with whoever needs the app."
