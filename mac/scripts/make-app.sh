#!/bin/bash
#
# Builds MyRemoteAgent in release mode and wraps it into MyRemote.app.
#
#   mac/scripts/make-app.sh
#
# Environment:
#   MYREMOTE_CODESIGN_IDENTITY  Signing identity (name or SHA-1 as shown by
#                               `security find-identity -v -p codesigning`).
#                               Default "-" = ad-hoc signature.
#   MYREMOTE_APP_OUT            Output directory. Default: mac/dist
#   MYREMOTE_BUNDLE_ID          Default: dev.myremote.agent
#   MYREMOTE_VERSION            Default: 0.1.0
#
# Note on ad-hoc signing: macOS ties the Accessibility permission to the code
# signature. An ad-hoc signature changes with every build, so after rebuilding you
# have to remove MyRemote from System Settings > Privacy & Security > Accessibility
# and add it again. Signing with a stable identity avoids that.

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${MYREMOTE_APP_OUT:-$PACKAGE_DIR/dist}"
IDENTITY="${MYREMOTE_CODESIGN_IDENTITY:--}"
BUNDLE_ID="${MYREMOTE_BUNDLE_ID:-dev.myremote.agent}"
VERSION="${MYREMOTE_VERSION:-0.1.0}"
APP_NAME="MyRemote.app"
EXECUTABLE="MyRemoteAgent"

echo "==> Building $EXECUTABLE (release)"
swift build --package-path "$PACKAGE_DIR" -c release --product "$EXECUTABLE"
BIN_DIR="$(swift build --package-path "$PACKAGE_DIR" -c release --show-bin-path)"
BINARY="$BIN_DIR/$EXECUTABLE"
if [[ ! -x "$BINARY" ]]; then
    echo "error: $BINARY was not built" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
APP="$OUT_DIR/$APP_NAME"

# Assemble in a fresh staging directory next to the destination, then swap it in,
# so a failed run never leaves a half-built bundle behind.
STAGING="$(mktemp -d "$OUT_DIR/.make-app.XXXXXX")"
trap '[[ -n "${STAGING:-}" && -d "$STAGING" ]] && rm -rf "$STAGING"' EXIT
STAGED_APP="$STAGING/$APP_NAME"

echo "==> Assembling $APP_NAME"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BINARY" "$STAGED_APP/Contents/MacOS/$EXECUTABLE"
chmod 755 "$STAGED_APP/Contents/MacOS/$EXECUTABLE"

cat > "$STAGED_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>MyRemote</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MyRemote</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSBonjourServices</key>
    <array>
        <string>_myremote._tcp</string>
    </array>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>MyRemote lets your phone find this Mac on the local network and control media playback on it.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$STAGED_APP/Contents/PkgInfo"
plutil -lint "$STAGED_APP/Contents/Info.plist" > /dev/null

if [[ "$IDENTITY" == "-" ]]; then
    echo "==> Signing (ad-hoc)"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$STAGED_APP"
else
    echo "==> Signing with identity: $IDENTITY"
    codesign --force --options runtime --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$STAGED_APP"
fi
codesign --verify --strict --verbose=2 "$STAGED_APP"

# Replace a previous bundle. The path is fixed to "<out>/MyRemote.app" above.
if [[ -e "$APP" ]]; then
    rm -rf "$APP"
fi
mv "$STAGED_APP" "$APP"

echo "==> Done: $APP"
echo "    Run it:   open \"$APP\""
echo "    Headless: \"$APP/Contents/MacOS/$EXECUTABLE\" --headless --dry-run --loopback --port 0"
