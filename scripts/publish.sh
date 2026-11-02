#!/bin/zsh
# Publishes the release in dist/ to robodust.muhraufan.com. Installed copies pick it up from the feed.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f dist/appcast.xml ] || { echo "No dist/appcast.xml: run scripts/release.sh first"; exit 1; }
DMG=$(ls dist/RoboDust-*.dmg | head -1)
VERSION=$(basename "$DMG" .dmg | sed 's/RoboDust-//')
xcrun stapler validate "$DMG" >/dev/null
mkdir -p site/releases
cp "$DMG" site/releases/
cp dist/appcast.xml site/appcast.xml
git -C site add appcast.xml "releases/$(basename "$DMG")"
git -C site commit -q -m "Release RoboDust $VERSION

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git -C site push -q origin gh-pages
echo "published $VERSION"
