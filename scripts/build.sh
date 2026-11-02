#!/bin/zsh
# Builds RoboDust.app next to this project. Ad-hoc signed, never touches anything else.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${ROBODUST_VERSION:-0.1}"
if [ -n "${ROBODUST_UNIVERSAL:-}" ]; then
  swift build -c release --arch arm64 --arch x86_64 2>&1 | grep -E "error|Build complete" | tail -30
  BIN=.build/apple/Products/Release/RoboDust
else
  swift build -c release 2>&1 | grep -E "error|Build complete" | tail -30
  BIN=.build/release/RoboDust
fi
APP=build/RoboDust.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RoboDust"
cp Resources/Shaders.metal "$APP/Contents/Resources/Shaders.metal"
mkdir -p "$APP/Contents/Frameworks"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/RoboDust" 2>/dev/null || true
PUBLIC_KEY=$(tr -d '[:space:]' < scripts/sparkle-public-key.txt)
[ -f Resources/RoboDust.icns ] && cp Resources/RoboDust.icns "$APP/Contents/Resources/RoboDust.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>RoboDust</string>
<key>CFBundleDisplayName</key><string>RoboDust</string>
<key>CFBundleIdentifier</key><string>com.muhraufan.robodust</string>
<key>CFBundleExecutable</key><string>RoboDust</string>
<key>CFBundleIconFile</key><string>RoboDust</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>NSHumanReadableCopyright</key><string>© 2026 Muhammad Raufan Yusup</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>SUFeedURL</key><string>https://robodust.muhraufan.com/appcast.xml</string>
<key>SUPublicEDKey</key><string>$PUBLIC_KEY</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUAutomaticallyUpdate</key><true/>
<key>SUAllowsAutomaticUpdates</key><true/>
<key>NSAppleEventsUsageDescription</key><string>RoboDust asks Finder where your desktop icons are so it can draw them in exactly the same places. When you run a clean, Finder also carries out the Trash and Tidy up actions.</string>
<key>NSDesktopFolderUsageDescription</key><string>RoboDust reads your desktop's file names, sizes and thumbnails to draw them, and removes files only when you run Trash or Delete.</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
echo "built $APP"
