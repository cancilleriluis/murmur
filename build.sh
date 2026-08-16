#!/bin/bash
# Builds Murmur.app — a self-contained menu-bar app bundle.
#
#   ./build.sh            build into ./build/Murmur.app
#   ./build.sh --install  also copy to /Applications and relaunch
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Murmur"
BUNDLE_ID="com.murmur.dictation"
VERSION="1.0.0"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

echo "==> Compiling (release)…"
swift build -c release --disable-sandbox

BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
  echo "!! Build produced no binary at $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling bundle…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>            <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>                  <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>           <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundleVersion</key>               <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>        <string>13.0</string>

    <!-- Menu-bar only: no Dock icon, no main window. -->
    <key>LSUIElement</key>                   <true/>

    <key>NSMicrophoneUsageDescription</key>
    <string>Murmur records your voice while you hold the push-to-talk key so it can transcribe it into text.</string>

    <key>NSHumanReadableCopyright</key>      <string>Local dictation. No accounts, no telemetry.</string>
</dict>
</plist>
PLIST

cat > "$APP_DIR/Contents/PkgInfo" <<< "APPL????"

# Prefer the stable identity from ./setup-signing.sh; permissions granted to a
# stably-signed app survive rebuilds. Fall back to ad-hoc if it isn't set up.
SIGN_ID="-"
SIGN_LABEL="ad-hoc — permissions reset on every rebuild"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Murmur Self-Signed"; then
  SIGN_ID="Murmur Self-Signed"
  SIGN_LABEL="Murmur Self-Signed — permissions persist"
fi

echo "==> Signing ($SIGN_LABEL)…"
# Ad-hoc signature. Entitlements keep the TCC prompts well-formed.
ENTITLEMENTS="$(mktemp -t murmur-entitlements).plist"
cat > "$ENTITLEMENTS" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>   <true/>
    <key>com.apple.security.automation.apple-events</key> <true/>
</dict>
</plist>
ENT

codesign --force --deep --sign "$SIGN_ID" \
         --entitlements "$ENTITLEMENTS" \
         --options runtime \
         "$APP_DIR" 2>/dev/null || \
codesign --force --deep --sign "$SIGN_ID" --entitlements "$ENTITLEMENTS" "$APP_DIR"

rm -f "$ENTITLEMENTS"

echo "==> Built $APP_DIR"

if [[ "${1:-}" == "--install" ]]; then
  echo "==> Installing to /Applications…"
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP_DIR" "/Applications/$APP_NAME.app"
  echo "==> Launching…"
  open "/Applications/$APP_NAME.app"
  echo
  echo "If this is the first run, grant permissions in:"
  echo "  System Settings ▸ Privacy & Security ▸ Microphone"
  echo "  System Settings ▸ Privacy & Security ▸ Accessibility"
  echo "  System Settings ▸ Privacy & Security ▸ Input Monitoring"
  echo "Then quit and reopen Murmur."
fi
