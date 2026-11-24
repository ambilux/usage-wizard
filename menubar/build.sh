#!/bin/zsh
# Builds Usage Wizard.app (menu bar app) without Xcode, using only the Command Line Tools.
set -e
cd "$(dirname "$0")"
APP="build/Usage Wizard.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14 \
  Sources/*.swift -o "$APP/Contents/MacOS/UsageWizard"
# Build number = build time: macOS caches app icons (e.g. in notifications) per version,
# so a new build with a new icon gets picked up instead of the cached old one
BUILD=$(date +%Y%m%d%H%M)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Usage Wizard</string>
  <key>CFBundleIdentifier</key><string>local.usagewizard</string>
  <key>CFBundleExecutable</key><string>UsageWizard</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
mkdir -p "$APP/Contents/Resources"
# App icon and menu bar icons are drawn from code (original pixel art, see icon/make_wizard.swift)
swift icon/make_wizard.swift "$APP/Contents/Resources"
# Ad-hoc signing is enough: the app needs no Accessibility permission (no auto-paste), so nothing
# is tied to the code signature and no certificate is required.
codesign --force --options runtime -s - "$APP"   # hardened runtime: blocks code injection into the app

# Install to /Applications (where the autostart points; shows up under "Applications" like any app) and relaunch
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
DEST="/Applications/Usage Wizard.app"
pkill -x UsageWizard 2>/dev/null || true
rm -rf "$DEST"
cp -R "$APP" /Applications/
# Re-register so Finder and notifications pick up the current AppIcon
$LSREG -f "$DEST"
$LSREG -u "$PWD/$APP" 2>/dev/null || true   # only the installed copy should be registered
open "$DEST"
echo "Done: $DEST"
