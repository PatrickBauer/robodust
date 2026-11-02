#!/bin/zsh
# Builds the install disk image from dist/RoboDust.app: scripts/make-dmg.sh out.dmg
# Finder applies the layout itself, so a Finder window opens for a few seconds during a build.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$1"
if mount | grep -q "/Volumes/RoboDust"; then echo "Eject every RoboDust disk first, then run this again."; exit 1; fi

STAGE=$(mktemp -d); RW=$(mktemp -d)/rw.dmg
ditto dist/RoboDust.app "$STAGE/RoboDust.app"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp Resources/dmg-background.tiff "$STAGE/.background/background.tiff"
hdiutil create -quiet -volname RoboDust -srcfolder "$STAGE" -fs HFS+ -format UDRW -size 60m "$RW"
rm -rf "$STAGE"
hdiutil attach -quiet -noverify -noautoopen "$RW"
xcrun SetFile -a V /Volumes/RoboDust/.background
sleep 1
osascript <<'APPLESCRIPT'
tell application "Finder"
    tell disk "RoboDust"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {240, 180, 900, 628}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "RoboDust.app" of container window to {170, 214}
        set position of item "Applications" of container window to {490, 214}
        update without registering applications
        delay 2
        close
        open
        delay 2
        close
    end tell
end tell
APPLESCRIPT
# Applied last, because the Finder step above loses it.
cp Resources/RoboDust.icns /Volumes/RoboDust/.VolumeIcon.icns
xcrun SetFile -a C /Volumes/RoboDust
rm -rf /Volumes/RoboDust/.fseventsd
sync; sleep 2
hdiutil detach -quiet /Volumes/RoboDust
rm -f "$OUT"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT"
rm -f "$RW"
