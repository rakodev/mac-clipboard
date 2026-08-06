#!/bin/bash

# Development run script for MacClipboard
# Builds, signs with dev certificate, and runs from a consistent location
# to preserve accessibility permissions across rebuilds.

set -e

CERT_NAME="MacClipboard Dev"
DEV_APP_PATH="$HOME/Applications/MacClipboard-Dev.app"
DEV_BUNDLE_ID="com.macclipboard.app.dev"
DEV_APP_NAME="MacClipboard Dev"
# The entitlements the app is built with. `codesign --force` replaces a signature wholesale, so
# the re-sign below has to pass them again or the dev build ends up with none at all, and then
# diverges from release on the Apple-events paste path. That is the 0.1.13 bug build.sh fixes.
ENTITLEMENTS_PATH="MacClipboard/MacClipboard.entitlements"

# Optional: reset this dev build's Accessibility grant. Run with:
#   ./run.sh --reset-permissions   (aliases: --reset-ax, -r)
# Use it when the permission state gets stale (e.g. after regenerating the dev
# cert, or the first time you switch to the separate dev bundle id). It is NOT run
# by default on purpose: resetting on every launch would force you to re-grant
# access each time, defeating the persistent dev identity we set up below.
RESET_PERMISSIONS=false
for arg in "$@"; do
    case "$arg" in
        --reset-permissions|--reset-ax|-r)
            RESET_PERMISSIONS=true
            ;;
    esac
done

# Stop the previous dev build only. A broad `pkill -f MacClipboard` also kills an installed
# release copy running from /Applications, which is not ours to stop: the two builds have
# separate bundle ids and separate hotkeys precisely so they can run side by side.
pkill -f "$DEV_APP_PATH/Contents/MacOS/MacClipboard" 2>/dev/null || true

# Wait for it to be gone. It handles SIGTERM to shut down cleanly, and the reset below must not
# race that: while the process lives, cfprefsd holds its UserDefaults and writes them back on
# quit, which puts the keys the reset just deleted straight back.
for _ in $(seq 1 25); do
    pgrep -f "$DEV_APP_PATH/Contents/MacOS/MacClipboard" >/dev/null 2>&1 || break
    sleep 0.2
done

if [ "$RESET_PERMISSIONS" = true ]; then
    echo "🧹 Resetting Accessibility permission for $DEV_BUNDLE_ID ..."
    tccutil reset Accessibility "$DEV_BUNDLE_ID" 2>/dev/null || true
    # The app fires the system prompt at most once ever, so without clearing that flag the reset
    # leaves it with no record and no way to ask for one, and the banner is the only way back.
    # Clearing "was granted" as well keeps the banner honest: with it still set, a fresh grant
    # that has not been made yet reads as a grant that stopped working.
    defaults delete "$DEV_BUNDLE_ID" hasRequestedAccessibilityPromptV1 2>/dev/null || true
    defaults delete "$DEV_BUNDLE_ID" accessibilityWasGrantedV1 2>/dev/null || true
    echo "   You will be asked to grant access once more on next launch."
fi

# Check if dev certificate exists
if ! security find-certificate -c "$CERT_NAME" "$HOME/Library/Keychains/login.keychain-db" &>/dev/null; then
    echo "⚠️  Development signing certificate not found."
    echo ""
    echo "Run the setup script first:"
    echo "  ./scripts/setup-dev-signing.sh"
    echo ""
    echo "This creates a certificate so accessibility permissions persist across rebuilds."
    exit 1
fi

# Build the app
make dev

# Get the correct build path (prefer Build over Index.noindex)
BUILD_PATH=""

# First try the Build directory (most reliable)
for dir in $(find ~/Library/Developer/Xcode/DerivedData -name "MacClipboard-*" -type d 2>/dev/null); do
    if [ -f "$dir/Build/Products/Debug/MacClipboard.app/Contents/MacOS/MacClipboard" ]; then
        BUILD_PATH="$dir/Build/Products/Debug/MacClipboard.app"
        break
    fi
done

# Fallback to any MacClipboard.app with valid executable
if [ -z "$BUILD_PATH" ]; then
    for app in $(find ~/Library/Developer/Xcode/DerivedData -name "MacClipboard.app" -type d 2>/dev/null); do
        if [ -f "$app/Contents/MacOS/MacClipboard" ]; then
            BUILD_PATH="$app"
            break
        fi
    done
fi

if [ -z "$BUILD_PATH" ]; then
    echo "❌ MacClipboard.app not found in DerivedData"
    echo "Please run 'make dev' first to build the app"
    exit 1
fi

echo "📦 Built app at: $BUILD_PATH"

# Create ~/Applications if it doesn't exist
mkdir -p "$HOME/Applications"

# Remove old dev app and copy new one
rm -rf "$DEV_APP_PATH"
cp -R "$BUILD_PATH" "$DEV_APP_PATH"

# Give the dev build its OWN identity so it never collides with a release/Homebrew
# install of MacClipboard in macOS's accessibility (TCC) database.
#
# TCC keys accessibility grants on (bundle id + code-signing identity). The Homebrew
# build and this dev build share the bundle id "com.macclipboard.app" but are signed
# with different certificates, so macOS treats them as the same app yet the signature
# never matches: the Accessibility toggle looks enabled (granted to the Homebrew copy)
# while the running dev copy stays untrusted and keeps re-prompting. Renaming the dev
# bundle id + display name gives it a separate "MacClipboard Dev" entry you grant once;
# because we re-sign with the persistent dev cert below, that grant survives rebuilds.
#
# This is also why the Debug configuration builds as com.macclipboard.app.debug and only this
# script promotes a copy to .dev: Xcode's own products are ad hoc signed, so a Run or a test
# run under the .dev bundle id makes tccd log "Failed to match existing code requirement" and
# the grant this copy holds becomes unusable. Only ever hand .dev to a bundle signed below.
PLIST="$DEV_APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DEV_BUNDLE_ID" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $DEV_BUNDLE_ID" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $DEV_APP_NAME" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $DEV_APP_NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DEV_APP_NAME" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $DEV_APP_NAME" "$PLIST"

# Re-sign with dev certificate for consistent identity (must run AFTER editing Info.plist)
echo "🔐 Signing with development certificate..."
# Use certificate hash to avoid ambiguity if multiple certs exist with same name
CERT_HASH=$(security find-identity -v -p codesigning | grep "$CERT_NAME" | head -1 | awk '{print $2}')
SIGN_IDENTITY="${CERT_HASH:-$CERT_NAME}"
if [ -z "$CERT_HASH" ]; then
    echo "⚠️  Could not find certificate hash, trying by name..."
fi
codesign --force --deep \
    --entitlements "$ENTITLEMENTS_PATH" \
    --sign "$SIGN_IDENTITY" "$DEV_APP_PATH"

# The dev build is only useful as a stand-in for the release build, so an entitlement that went
# missing has to stop the run rather than surface later as "auto-paste behaves differently in dev".
# Xcode's debug-only get-task-allow does not survive this re-sign, which is deliberate: it is not
# in the entitlements file, and a shipped build never has it either.
if ! codesign -d --entitlements - --xml "$DEV_APP_PATH" 2>/dev/null \
    | grep -q "com.apple.security.automation.apple-events"; then
    echo "❌ The signed dev app has no apple-events entitlement."
    echo "   Expected com.apple.security.automation.apple-events from $ENTITLEMENTS_PATH"
    exit 1
fi

# The build product in DerivedData has served its purpose now that a signed copy exists in
# ~/Applications. Leaving it there means macOS indexes it as yet another "MacClipboard", which is
# how a machine ends up with several identical looking entries in Spotlight, and it is ad hoc
# signed so it could never keep an Accessibility grant anyway. It carries the .debug bundle id,
# so it can no longer invalidate this copy's grant either. The next build recreates it.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$BUILD_PATH" 2>/dev/null || true
rm -rf "$BUILD_PATH"

echo "🚀 Starting MacClipboard from: $DEV_APP_PATH"

# Open the app from consistent location
open "$DEV_APP_PATH"

echo "✅ MacClipboard started! Look for the FILLED clipboard icon in the menu bar (dev build)."
echo "Use Cmd+Shift+Opt+V to open the clipboard history from anywhere."
echo "   (the release build keeps Cmd+Shift+V, so both can run at once - see GlobalHotkey in BuildInfo.swift)"
