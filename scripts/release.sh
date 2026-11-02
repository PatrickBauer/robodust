#!/bin/zsh
# Builds a universal, Developer ID signed .app and .dmg in dist/, and notarizes when credentials exist.
#   ROBODUST_VERSION=1.0 scripts/release.sh
# Then scripts/publish.sh makes it live for everyone who has the app.
# One-time setup for notarizing:
#   xcrun notarytool store-credentials robodust-notary --key <AuthKey.p8> --key-id <id> --issuer <id>
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${ROBODUST_VERSION:-0.1}"
PROFILE="${NOTARY_PROFILE:-robodust-notary}"
IDENTITY=$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')
[ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate found"; exit 1; }

ROBODUST_UNIVERSAL=1 ROBODUST_VERSION="$VERSION" scripts/build.sh
rm -rf dist; mkdir -p dist
cp -R build/RoboDust.app dist/RoboDust.app
# Inside out, the way Sparkle documents it: never --deep for a release.
F=dist/RoboDust.app/Contents/Frameworks/Sparkle.framework/Versions/B
SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
"${SIGN[@]}" "$F/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$F/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$F/Autoupdate"
"${SIGN[@]}" "$F/Updater.app"
"${SIGN[@]}" dist/RoboDust.app/Contents/Frameworks/Sparkle.framework
"${SIGN[@]}" --entitlements scripts/RoboDust.entitlements dist/RoboDust.app
codesign --verify --strict --deep dist/RoboDust.app
echo "signed: $(lipo -archs dist/RoboDust.app/Contents/MacOS/RoboDust)"

HAVE_NOTARY=0
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 && HAVE_NOTARY=1

# The app gets its own ticket first, so it still opens offline after leaving the disk image.
if [ $HAVE_NOTARY = 1 ]; then
  ZIP=$(mktemp -d)/RoboDust.zip
  ditto -c -k --keepParent dist/RoboDust.app "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait | grep -E "status:"
  xcrun stapler staple dist/RoboDust.app
fi

DMG="dist/RoboDust-$VERSION.dmg"
scripts/make-dmg.sh "$PWD/$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ $HAVE_NOTARY = 1 ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait | grep -E "status:"
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
  echo "notarized: $DMG"
  # The update feed entry, signed with the private key in this Mac's keychain.
  ATTRS=$(.build/artifacts/sparkle/Sparkle/bin/sign_update "$DMG")
  NOTES="${RELEASE_NOTES:-Improvements and fixes.}"
  cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>RoboDust</title>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>$NOTES</p>]]></description>
      <enclosure url="https://robodust.muhraufan.com/releases/RoboDust-$VERSION.dmg" type="application/octet-stream" $ATTRS />
    </item>
  </channel>
</rss>
XML
  echo "feed entry: dist/appcast.xml"
else
  echo "signed but NOT notarized: no '$PROFILE' credentials yet. $DMG"
fi
