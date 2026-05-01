#!/usr/bin/env bash
#
# Cuts a SipClient release: bumps the version, builds, code-signs,
# notarizes, EdDSA-signs the zip, updates appcast.xml, and prints the
# `gh release create` command needed to publish.
#
# See ReleaseProcess.md for one-time setup (Developer ID cert, notary
# credentials, Sparkle key pair).
#
# Usage:
#   ./bin/make_release.sh <short-version> [<release-notes-html>]
#
# Examples:
#   ./bin/make_release.sh 0.1.0-b8
#   ./bin/make_release.sh 0.1.0-b8 "<ul><li>Fix RTP jitter</li></ul>"
#
# Required environment (read from ~/.config/sipclient-release.env if present):
#   APPLE_ID                     - Apple ID email
#   APPLE_TEAM_ID                - 10-char Developer team ID
#   APPLE_APP_SPECIFIC_PASSWORD  - App-specific password for notarytool
#   SPARKLE_PRIVATE_KEY_PATH     - File holding the EdDSA private key
#   SIGNING_IDENTITY             - Codesign identity, e.g.
#                                  "Developer ID Application: Foo (TEAMID)"

set -euo pipefail

SHORT_VERSION="${1:-}"
RELEASE_NOTES_HTML="${2:-<p>Release ${SHORT_VERSION}.</p>}"
if [ -z "$SHORT_VERSION" ]; then
    echo "usage: $0 <short-version> [<release-notes-html>]" >&2
    exit 64
fi

ENV_FILE="${HOME}/.config/sipclient-release.env"
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

require() {
    local name="$1"
    if [ -z "${!name:-}" ]; then
        echo "error: $name must be set (see $ENV_FILE or ReleaseProcess.md)" >&2
        exit 65
    fi
}
require APPLE_ID
require APPLE_TEAM_ID
require APPLE_APP_SPECIFIC_PASSWORD
require SPARKLE_PRIVATE_KEY_PATH
require SIGNING_IDENTITY

if [ ! -f "$SPARKLE_PRIVATE_KEY_PATH" ]; then
    echo "error: SPARKLE_PRIVATE_KEY_PATH=$SPARKLE_PRIVATE_KEY_PATH not found" >&2
    exit 66
fi

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INFO_PLIST="$PROJECT_ROOT/Sources/Info.plist"
APPCAST="$PROJECT_ROOT/appcast.xml"
TAG="release_${SHORT_VERSION//[.-]/_}"
ASSET_NAME="SipClient-${SHORT_VERSION}.zip"
RELEASE_URL="https://github.com/yepher/SipClient/releases/download/${TAG}/${ASSET_NAME}"

BUILD_DIR="$PROJECT_ROOT/build/release/${SHORT_VERSION}"
DERIVED="$BUILD_DIR/dd"
APP_SRC="$DERIVED/Build/Products/Release/SipClient.app"

# Build number = total commit count → monotonic across releases.
BUILD_NUMBER=$(git -C "$PROJECT_ROOT" rev-list --count HEAD)

mkdir -p "$BUILD_DIR"

echo "==> Bumping version to ${SHORT_VERSION} (build ${BUILD_NUMBER})"
plutil -replace CFBundleShortVersionString -string "$SHORT_VERSION" "$INFO_PLIST"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$INFO_PLIST"

echo "==> Building Release configuration"
xcodebuild \
    -project "$PROJECT_ROOT/SipClient.xcodeproj" \
    -scheme SipClient \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
    clean build >/dev/null

if [ ! -d "$APP_SRC" ]; then
    echo "error: build did not produce $APP_SRC" >&2
    exit 70
fi

# Re-sign Sparkle's nested helpers + re-sign the outer app.
#
# Sparkle ships its framework pre-signed by the Sparkle project; those
# signatures have neither our Developer ID nor a secure timestamp, so
# notarization rejects them. Xcode's auto-embed for SPM binary products
# doesn't apply `Code Sign On Copy`, so we walk the framework and resign
# everything inside out.
#
# Resigning the outer SipClient.app last with the project's
# `SipClient.entitlements` strips the `get-task-allow` entitlement that
# the build system silently injects when the pbxproj's
# `CODE_SIGN_IDENTITY[sdk=macosx*]` is `Apple Development`.
echo "==> Re-signing Sparkle helpers + outer app for distribution"

SIGN_ARGS=(--force --options=runtime --timestamp --sign "$SIGNING_IDENTITY")
SPARKLE_FW="$APP_SRC/Contents/Frameworks/Sparkle.framework"
ENTITLEMENTS="$PROJECT_ROOT/Sources/SipClient.entitlements"

# Order matters: deepest binaries first, then their containing bundles,
# then the framework, then the app.
codesign "${SIGN_ARGS[@]}" \
    "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
codesign "${SIGN_ARGS[@]}" \
    "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
codesign "${SIGN_ARGS[@]}" \
    "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
codesign "${SIGN_ARGS[@]}" \
    "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
codesign "${SIGN_ARGS[@]}" \
    "$SPARKLE_FW/Versions/B/Updater.app/Contents/MacOS/Updater"
codesign "${SIGN_ARGS[@]}" \
    "$SPARKLE_FW/Versions/B/Updater.app"
codesign "${SIGN_ARGS[@]}" \
    "$SPARKLE_FW/Versions/B/Autoupdate"
codesign "${SIGN_ARGS[@]}" \
    "$SPARKLE_FW"

codesign "${SIGN_ARGS[@]}" \
    --entitlements "$ENTITLEMENTS" \
    "$APP_SRC"

echo "==> Verifying signature"
codesign -dvv --strict --deep "$APP_SRC"
codesign -d --entitlements - "$APP_SRC" 2>&1 | grep -i task-allow \
    && { echo "error: get-task-allow still present in entitlements" >&2; exit 72; } \
    || echo "    get-task-allow correctly stripped"
spctl -a -t exec -vvv "$APP_SRC" || true

echo "==> Submitting to Apple notary service"
NOTARY_ZIP="$BUILD_DIR/notarize.zip"
ditto -c -k --keepParent "$APP_SRC" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP_SRC"
xcrun stapler validate "$APP_SRC"

echo "==> Packaging final release zip"
DIST_ZIP="$BUILD_DIR/${ASSET_NAME}"
rm -f "$DIST_ZIP"
ditto -c -k --keepParent "$APP_SRC" "$DIST_ZIP"

# `sign_update` is bundled with the Sparkle SPM artifact under DerivedData.
# Locate it once the project has been built at least once.
SIGN_UPDATE=$(find ~/Library/Developer/Xcode/DerivedData \
    -path '*/Sparkle*/sign_update' -type f 2>/dev/null | head -1)
if [ -z "$SIGN_UPDATE" ]; then
    echo "error: sign_update binary not found. Build the app once in Xcode after" >&2
    echo "       adding the Sparkle SPM package, then re-run this script." >&2
    exit 71
fi

echo "==> Signing zip with EdDSA"
SIGN_OUTPUT="$("$SIGN_UPDATE" -f "$SPARKLE_PRIVATE_KEY_PATH" "$DIST_ZIP")"
echo "    $SIGN_OUTPUT"

echo "==> Inserting entry into appcast.xml"
"$PROJECT_ROOT/bin/update_appcast.py" \
    --appcast "$APPCAST" \
    --short-version "$SHORT_VERSION" \
    --build "$BUILD_NUMBER" \
    --enclosure-url "$RELEASE_URL" \
    --asset "$DIST_ZIP" \
    --sign-output "$SIGN_OUTPUT" \
    --notes-html "$RELEASE_NOTES_HTML"

echo ""
echo "Release artifact ready:  $DIST_ZIP"
echo ""
echo "Next steps:"
echo "  git diff Sources/Info.plist appcast.xml          # review"
echo "  git add Sources/Info.plist appcast.xml"
echo "  git commit -m \"Release ${SHORT_VERSION}\""
echo "  git tag ${TAG} && git push --tags && git push"
echo "  gh release create ${TAG} \"$DIST_ZIP\" \\"
echo "      --title \"SipClient ${SHORT_VERSION}\" \\"
echo "      --notes \"${RELEASE_NOTES_HTML}\""
echo ""
echo "Sparkle clients pull the appcast from the URL configured in"
echo "Info.plist (SUFeedURL); pushing the appcast.xml change to main"
echo "is what makes the update visible."
