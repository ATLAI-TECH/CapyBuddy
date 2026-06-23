#!/usr/bin/env bash
# Build, sign, notarize, staple, zip CapyBuddy, and regenerate appcast.xml.
#
# Prereqs (one-time):
#   1. Developer ID Application certificate installed in login keychain.
#   2. App-specific password stored in keychain under profile "CAPYBUDDY_NOTARY":
#        xcrun notarytool store-credentials CAPYBUDDY_NOTARY \
#          --apple-id "you@example.com" \
#          --team-id 9A6Q68R555 \
#          --password "xxxx-xxxx-xxxx-xxxx"
#   3. Sparkle's `generate_keys` run once; public key already pasted into
#      CapyBuddyPro-Info.plist under SUPublicEDKey. Private key stays in keychain.
#   4. Sparkle helper binaries available at ./bin/{sign_update,generate_appcast}.
#      The repo ships symlinks pointing into DerivedData; if those break,
#      re-resolve packages in Xcode or recreate the symlinks.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

SCHEME="CapyBuddy"
PROJECT="CapyBuddy.xcodeproj"
BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/CapyBuddy.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="scripts/ExportOptions.plist"
NOTARY_PROFILE="CAPYBUDDY_NOTARY"
APP_NAME="CapyBuddy.app"
RELEASES_DIR="releases"
APPCAST_PATH="$RELEASES_DIR/appcast.xml"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "CapyBuddy/App/CapyBuddyPro-Info.plist")
ZIP_NAME="CapyBuddy-${VERSION}.zip"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$RELEASES_DIR"

echo "==> [1/6] Archiving (scheme: $SCHEME, version: $VERSION)"
xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    archive

echo "==> [2/6] Exporting Developer ID-signed .app"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_DIR"

APP_PATH="$EXPORT_DIR/$APP_NAME"
if [ ! -d "$APP_PATH" ]; then
    echo "Export did not produce $APP_PATH" >&2
    exit 1
fi

echo "==> [3/6] Submitting to Apple notary service"
ZIP_FOR_NOTARY="$BUILD_DIR/notary-submission.zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_FOR_NOTARY"
xcrun notarytool submit "$ZIP_FOR_NOTARY" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "==> [4/6] Stapling notary ticket"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "==> [5/6] Packaging $ZIP_NAME into $RELEASES_DIR/"
DIST_ZIP="$RELEASES_DIR/$ZIP_NAME"
# Sparkle expects a flat zip of the .app at the root, which `ditto -c -k
# --keepParent` produces.
ditto -c -k --keepParent "$APP_PATH" "$DIST_ZIP"

echo "==> [6/6] Regenerating $APPCAST_PATH (signs every zip in $RELEASES_DIR/)"
# generate_appcast scans the directory, signs each .zip with the keychain
# private key, and writes appcast.xml. Older versions stay in the feed so
# users on a tier behind can still upgrade incrementally.
./bin/generate_appcast "$RELEASES_DIR"

echo ""
echo "Done."
echo "  Notarized + stapled app: $APP_PATH"
echo "  Distribution zip:        $DIST_ZIP"
echo "  Appcast:                 $APPCAST_PATH"
echo ""
echo "Next: upload the contents of $RELEASES_DIR/ to your CDN bucket"
echo "(R2/B2/S3) so SUFeedURL in CapyBuddyPro-Info.plist can fetch them."
