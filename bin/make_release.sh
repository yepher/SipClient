#!/usr/bin/env bash
#
# Cuts a SipClient release: bumps the version, builds, code-signs,
# notarizes, EdDSA-signs the zip, updates appcast.xml, and prints the
# `gh release create` command needed to publish.
#
# The script is **phase-aware and resumable**. Each phase records a
# marker in $BUILD_DIR/.state/, and on re-run the script skips phases
# whose marker already exists. So if e.g. notarization fails because of
# a transient TLS hiccup, you can just re-run with the same version and
# only the failed phase (plus any later phases) will execute.
#
# To force a clean rebuild for a version, set REBUILD=1:
#   REBUILD=1 ./bin/make_release.sh 0.1.0-b8 "..."
#
# See ReleaseProcess.md for one-time setup (Developer ID cert, notary
# credentials, Sparkle key pair).
#
# Usage:
#   ./bin/make_release.sh <short-version> [<release-notes>]
#
# <release-notes> can be either an HTML string OR a path to an HTML
# file (auto-detected — if the argument names an existing file, its
# contents are used; otherwise the argument itself is treated as
# literal HTML).
#
# Examples:
#   ./bin/make_release.sh 0.1.0-b8
#   ./bin/make_release.sh 0.1.0-b8 "<ul><li>Fix RTP jitter</li></ul>"
#   ./bin/make_release.sh 0.1.0-b8 release_notes/0.1.0-b8.html
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
RELEASE_NOTES_INPUT="${2:-<p>Release ${SHORT_VERSION}.</p>}"
if [ -z "$SHORT_VERSION" ]; then
    echo "usage: $0 <short-version> [<release-notes-or-path-to-html>]" >&2
    echo "" >&2
    echo "  <release-notes> can be either an inline HTML string or a path" >&2
    echo "  to an existing HTML file (auto-detected)." >&2
    echo "  Set REBUILD=1 to wipe per-version state and re-run from scratch." >&2
    exit 64
fi

# Resolve release notes — file path or inline HTML.
if [ -f "$RELEASE_NOTES_INPUT" ]; then
    echo "==> Using release notes from file: $RELEASE_NOTES_INPUT"
    RELEASE_NOTES_HTML="$(cat "$RELEASE_NOTES_INPUT")"
else
    RELEASE_NOTES_HTML="$RELEASE_NOTES_INPUT"
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
STATE_DIR="$BUILD_DIR/.state"
BUILD_NUM_FILE="$STATE_DIR/build_number.txt"
NOTARY_ID_FILE="$STATE_DIR/notary_id.txt"
NOTARY_OUT_FILE="$STATE_DIR/notary_output.txt"
ED_SIG_FILE="$STATE_DIR/eddsa_signature.txt"

if [ "${REBUILD:-0}" = "1" ]; then
    echo "==> REBUILD=1: wiping $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR" "$STATE_DIR"

phase_done() { [ -f "$STATE_DIR/$1.done" ]; }
mark_phase() { touch "$STATE_DIR/$1.done"; }

# Pin BUILD_NUMBER on first run for this version; reuse it across
# resumes so the Info.plist value we notarize matches the one Sparkle
# clients see in the appcast — even if HEAD has moved between attempts.
if [ -f "$BUILD_NUM_FILE" ]; then
    BUILD_NUMBER=$(cat "$BUILD_NUM_FILE")
else
    BUILD_NUMBER=$(git -C "$PROJECT_ROOT" rev-list --count HEAD)
    echo "$BUILD_NUMBER" > "$BUILD_NUM_FILE"
fi

# Bumping the Info.plist is idempotent — always do it. (Versions live
# in source control; a partial run shouldn't leave plist edits behind.)
echo "==> Bumping version to ${SHORT_VERSION} (build ${BUILD_NUMBER})"
plutil -replace CFBundleShortVersionString -string "$SHORT_VERSION" "$INFO_PLIST"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$INFO_PLIST"

# ---------------------------------------------------------------- build
if phase_done build && [ -d "$APP_SRC" ]; then
    echo "==> Skipping build (cached; REBUILD=1 to force)"
else
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
    mark_phase build
fi

# ---------------------------------------------------------------- sign
# Re-sign Sparkle's nested helpers + the outer app.
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
if phase_done sign; then
    echo "==> Skipping re-sign (cached)"
else
    echo "==> Re-signing Sparkle helpers + outer app for distribution"
    SIGN_ARGS=(--force --options=runtime --timestamp --sign "$SIGNING_IDENTITY")
    SPARKLE_FW="$APP_SRC/Contents/Frameworks/Sparkle.framework"
    ENTITLEMENTS="$PROJECT_ROOT/Sources/SipClient.entitlements"

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
    if codesign -d --entitlements - "$APP_SRC" 2>&1 | grep -qi task-allow; then
        echo "error: get-task-allow still present in entitlements" >&2
        exit 72
    fi
    echo "    get-task-allow correctly stripped"
    spctl -a -t exec -vvv "$APP_SRC" || true
    mark_phase sign
fi

# ---------------------------------------------------------------- notarize
if phase_done notarize; then
    echo "==> Skipping notarization (cached, id=$(cat "$NOTARY_ID_FILE"))"
else
    echo "==> Submitting to Apple notary service"
    NOTARY_ZIP="$BUILD_DIR/notarize.zip"
    rm -f "$NOTARY_ZIP"
    ditto -c -k --keepParent "$APP_SRC" "$NOTARY_ZIP"
    set +e
    xcrun notarytool submit "$NOTARY_ZIP" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --wait | tee "$NOTARY_OUT_FILE"
    set -e
    if ! grep -q "status: Accepted" "$NOTARY_OUT_FILE"; then
        echo "" >&2
        echo "error: notarization did not return 'Accepted'." >&2
        SUB_ID=$(awk '/^[[:space:]]*id:/ {print $2; exit}' "$NOTARY_OUT_FILE" || true)
        if [ -n "$SUB_ID" ]; then
            echo "       Submission id: $SUB_ID" >&2
            echo "       Inspect with:" >&2
            echo "         xcrun notarytool log $SUB_ID --apple-id \"\$APPLE_ID\" \\" >&2
            echo "             --team-id \"\$APPLE_TEAM_ID\" --password \"\$APPLE_APP_SPECIFIC_PASSWORD\"" >&2
        fi
        exit 74
    fi
    awk '/^[[:space:]]*id:/ {print $2; exit}' "$NOTARY_OUT_FILE" > "$NOTARY_ID_FILE"
    mark_phase notarize
fi

# ---------------------------------------------------------------- staple
if phase_done staple; then
    echo "==> Skipping staple (cached)"
else
    echo "==> Stapling notarization ticket"
    xcrun stapler staple "$APP_SRC"
    xcrun stapler validate "$APP_SRC"
    mark_phase staple
fi

# ---------------------------------------------------------------- package
DIST_ZIP="$BUILD_DIR/${ASSET_NAME}"
if phase_done package && [ -f "$DIST_ZIP" ]; then
    echo "==> Skipping packaging (zip exists)"
else
    echo "==> Packaging final release zip"
    rm -f "$DIST_ZIP"
    ditto -c -k --keepParent "$APP_SRC" "$DIST_ZIP"
    mark_phase package
fi

# ---------------------------------------------------------------- ed-sign
# `sign_update` is bundled with the Sparkle SPM artifact under DerivedData.
SIGN_UPDATE=$(find ~/Library/Developer/Xcode/DerivedData \
    -path '*/Sparkle*/sign_update' -type f 2>/dev/null | head -1)
if [ -z "$SIGN_UPDATE" ]; then
    echo "error: sign_update binary not found. Build the app once in Xcode after" >&2
    echo "       adding the Sparkle SPM package, then re-run this script." >&2
    exit 71
fi

if phase_done ed-signed && [ -f "$ED_SIG_FILE" ]; then
    SIGN_OUTPUT=$(cat "$ED_SIG_FILE")
    echo "==> Skipping EdDSA sign (cached)"
    echo "    $SIGN_OUTPUT"
else
    echo "==> Signing zip with EdDSA"
    SIGN_OUTPUT="$("$SIGN_UPDATE" -f "$SPARKLE_PRIVATE_KEY_PATH" "$DIST_ZIP")"
    echo "$SIGN_OUTPUT" > "$ED_SIG_FILE"
    echo "    $SIGN_OUTPUT"
    mark_phase ed-signed
fi

# ---------------------------------------------------------------- appcast
# Always run — `update_appcast.py` removes any existing entry with a
# matching <sparkle:version> before inserting, so this is safe to re-run.
echo "==> Inserting/updating entry in appcast.xml"
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
if [ -f "$RELEASE_NOTES_INPUT" ]; then
    echo "  gh release create ${TAG} \"$DIST_ZIP\" \\"
    echo "      --title \"SipClient ${SHORT_VERSION}\" \\"
    echo "      --notes-file \"${RELEASE_NOTES_INPUT}\""
else
    echo "  gh release create ${TAG} \"$DIST_ZIP\" \\"
    echo "      --title \"SipClient ${SHORT_VERSION}\" \\"
    echo "      --notes \"${RELEASE_NOTES_HTML}\""
fi
echo ""
echo "Sparkle clients pull the appcast from the URL configured in"
echo "Info.plist (SUFeedURL); pushing the appcast.xml change to main"
echo "is what makes the update visible."
