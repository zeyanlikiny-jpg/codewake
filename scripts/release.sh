#!/bin/bash
# CodeWake local distribution pipeline:
# signed archive -> Developer ID export -> notarized app -> signed/notarized DMG.
#
# This script intentionally does not publish a GitHub release or generate an
# update feed. A future public release must configure a CodeWake-owned update
# channel separately.
#
# Required local setup:
#   LIDLESS_DEVELOPMENT_TEAM=<YOUR_TEAM_ID>
#   NOTARY_PROFILE=<notarytool keychain profile>
#   DMG_SIGNING_IDENTITY='Developer ID Application: Name (TEAMID)'
#   Developer ID Application certificate in the login keychain
#
# Usage:
#   LIDLESS_DEVELOPMENT_TEAM=ABCDE12345 NOTARY_PROFILE=lidless-ai-notary \
#     DMG_SIGNING_IDENTITY='Developer ID Application: Name (ABCDE12345)' \
#     ./scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${LIDLESS_DEVELOPMENT_TEAM:?Set LIDLESS_DEVELOPMENT_TEAM to your Apple Developer Team ID}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"
: "${DMG_SIGNING_IDENTITY:?Set DMG_SIGNING_IDENTITY to the exact Developer ID Application identity}"

command -v xcodegen >/dev/null || {
    echo "XcodeGen is required (brew install xcodegen)." >&2
    exit 1
}

APP_NAME="CodeWake"
SCHEME="CodeWake"
BUILD_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BUILD_ROOT="${BUILD_ROOT:-build/release-$BUILD_STAMP}"
ARCHIVE="$BUILD_ROOT/$APP_NAME.xcarchive"
EXPORT="$BUILD_ROOT/export"
STAGING="$BUILD_ROOT/dmg"

echo "[1/8] Generate project"
xcodegen generate

echo "[2/8] Archive with the locally supplied Developer Team"
xcodebuild archive \
    -project "CodeWake.xcodeproj" \
    -scheme "$SCHEME" \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    -configuration Release \
    LIDLESS_DEVELOPMENT_TEAM="$LIDLESS_DEVELOPMENT_TEAM"

echo "[3/8] Export and verify Developer ID application"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT" \
    -exportOptionsPlist ExportOptions.plist

APP="$EXPORT/$APP_NAME.app"
test -d "$APP" || {
    echo "Export did not produce $APP" >&2
    exit 1
}
codesign --verify --deep --strict --verbose=2 "$APP"

EXPECTED_VERSION="0.2.17"
EXPECTED_BUILD_NUMBER="22"
EXPECTED_ARCHITECTURES="arm64 x86_64"
APP_EXECUTABLE="$APP/Contents/MacOS/$APP_NAME"
HELPER="$APP/Contents/MacOS/LidlessHelper"
HOOK_BRIDGE="$APP/Contents/MacOS/LidlessAIHookBridge"
DISPLAY_WATCHDOG="$APP/Contents/MacOS/LidlessDisplayWatchdog"

for executable in "$APP_EXECUTABLE" "$HELPER" "$HOOK_BRIDGE" "$DISPLAY_WATCHDOG"; do
    test -x "$executable" || {
        echo "Release bundle is missing executable $executable" >&2
        exit 1
    }
done

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
[ "$VERSION" = "$EXPECTED_VERSION" ] || {
    echo "Unexpected app version $VERSION; expected $EXPECTED_VERSION" >&2
    exit 1
}
[ "$BUILD_NUMBER" = "$EXPECTED_BUILD_NUMBER" ] || {
    echo "Unexpected app build $BUILD_NUMBER; expected $EXPECTED_BUILD_NUMBER" >&2
    exit 1
}

canonical_architectures() {
    lipo -archs "$1" | tr ' ' '\n' | sort | paste -sd ' ' -
}

code_signing_value() {
    codesign -d --verbose=4 "$1" 2>&1 | sed -n "s/^$2=//p" | head -n 1
}

embedded_info_value() {
    local executable="$1"
    local architecture="$2"
    local key="$3"
    otool -X -V -s __TEXT __info_plist -arch "$architecture" "$executable" \
        | plutil -extract "$key" raw -o - -
}

APP_ARCHITECTURES="$(canonical_architectures "$APP_EXECUTABLE")"
APP_TEAM_ID="$(code_signing_value "$APP" TeamIdentifier)"
APP_IDENTIFIER="$(code_signing_value "$APP" Identifier)"
APP_AUTHORITY="$(code_signing_value "$APP" Authority)"
APP_TIMESTAMP="$(code_signing_value "$APP" Timestamp)"
[ "$APP_ARCHITECTURES" = "$EXPECTED_ARCHITECTURES" ] || {
    echo "App architectures '$APP_ARCHITECTURES' differ from required '$EXPECTED_ARCHITECTURES'" >&2
    exit 1
}
[ "$APP_TEAM_ID" = "$LIDLESS_DEVELOPMENT_TEAM" ] || {
    echo "App signing team $APP_TEAM_ID does not match $LIDLESS_DEVELOPMENT_TEAM" >&2
    exit 1
}
[ "$APP_IDENTIFIER" = "com.kenny.lidlessai" ] || {
    echo "Unexpected Release app identifier $APP_IDENTIFIER" >&2
    exit 1
}
[ "$APP_AUTHORITY" = "$DMG_SIGNING_IDENTITY" ] || {
    echo "App signing authority '$APP_AUTHORITY' is not '$DMG_SIGNING_IDENTITY'" >&2
    exit 1
}
[ -n "$APP_TIMESTAMP" ] || {
    echo "App Developer ID signature has no trusted timestamp" >&2
    exit 1
}

verify_embedded_executable() {
    local executable="$1"
    local expected_identifier="$2"
    local name="$3"
    local architectures identifier team_id authority timestamp architecture embedded_version embedded_build embedded_identifier

    codesign --verify --strict --verbose=2 "$executable"
    architectures="$(canonical_architectures "$executable")"
    [ "$architectures" = "$APP_ARCHITECTURES" ] || {
        echo "$name architectures '$architectures' differ from app '$APP_ARCHITECTURES'" >&2
        exit 1
    }

    identifier="$(code_signing_value "$executable" Identifier)"
    team_id="$(code_signing_value "$executable" TeamIdentifier)"
    authority="$(code_signing_value "$executable" Authority)"
    timestamp="$(code_signing_value "$executable" Timestamp)"
    [ "$identifier" = "$expected_identifier" ] || {
        echo "$name signing identifier $identifier differs from $expected_identifier" >&2
        exit 1
    }
    [ "$team_id" = "$APP_TEAM_ID" ] || {
        echo "$name signing team $team_id differs from app team $APP_TEAM_ID" >&2
        exit 1
    }
    [ "$authority" = "$APP_AUTHORITY" ] || {
        echo "$name signing authority '$authority' differs from app '$APP_AUTHORITY'" >&2
        exit 1
    }
    [ -n "$timestamp" ] || {
        echo "$name Developer ID signature has no trusted timestamp" >&2
        exit 1
    }

    for architecture in $(lipo -archs "$executable"); do
        embedded_version="$(embedded_info_value "$executable" "$architecture" CFBundleShortVersionString)"
        embedded_build="$(embedded_info_value "$executable" "$architecture" CFBundleVersion)"
        embedded_identifier="$(embedded_info_value "$executable" "$architecture" CFBundleIdentifier)"
        [ "$embedded_version" = "$VERSION" ] || {
            echo "$name $architecture version $embedded_version differs from app $VERSION" >&2
            exit 1
        }
        [ "$embedded_build" = "$BUILD_NUMBER" ] || {
            echo "$name $architecture build $embedded_build differs from app $BUILD_NUMBER" >&2
            exit 1
        }
        [ "$embedded_identifier" = "$expected_identifier" ] || {
            echo "$name $architecture embedded identifier $embedded_identifier differs from $expected_identifier" >&2
            exit 1
        }
    done
}

verify_embedded_executable "$HELPER" "com.kenny.lidlessai.helper" "LidlessHelper"
verify_embedded_executable "$HOOK_BRIDGE" "com.kenny.lidlessai.hookbridge" "LidlessAIHookBridge"
verify_embedded_executable "$DISPLAY_WATCHDOG" "com.kenny.lidless-ai.displaywatchdog" "LidlessDisplayWatchdog"

HELPER_ADVERTISEMENT="$VERSION+$BUILD_NUMBER;protocol=2"
strings "$HELPER" | grep -Fx "$HELPER_ADVERTISEMENT" >/dev/null || {
    echo "App build and Helper handshake differ; expected $HELPER_ADVERTISEMENT" >&2
    exit 1
}
DISPLAY_BLACKOUT_ADVERTISEMENT="$VERSION+$BUILD_NUMBER;protocol=1"
for executable in "$APP_EXECUTABLE" "$DISPLAY_WATCHDOG"; do
    strings "$executable" | grep -Fx "$DISPLAY_BLACKOUT_ADVERTISEMENT" >/dev/null || {
        echo "App and display Watchdog handshake differ; expected $DISPLAY_BLACKOUT_ADVERTISEMENT in $executable" >&2
        exit 1
    }
done
ZIP="$BUILD_ROOT/$APP_NAME.zip"
DMG="$BUILD_ROOT/$APP_NAME-$VERSION.dmg"

echo "[4/8] Submit app for notarization"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "[5/8] Staple app ticket and verify Gatekeeper"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "[6/8] Create and sign DMG"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -format UDZO "$DMG"
codesign --force --timestamp --sign "$DMG_SIGNING_IDENTITY" "$DMG"

echo "[7/8] Submit DMG for notarization"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "[8/8] Staple and verify DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo "Created signed and notarized artifact: $DMG"
