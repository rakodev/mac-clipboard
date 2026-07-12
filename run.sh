#!/bin/bash

# Development run script for MacClipboard
# Builds, signs with dev certificate, and runs from a consistent location
# to preserve accessibility permissions across rebuilds.

set -e

CERT_NAME="MacClipboard Dev"
DEV_APP_PATH="$HOME/Applications/MacClipboard-Dev.app"
DEV_BUNDLE_ID="com.macclipboard.app.dev"
DEV_APP_NAME="MacClipboard Dev"

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

if [ "$RESET_PERMISSIONS" = true ]; then
    echo "🧹 Resetting Accessibility permission for $DEV_BUNDLE_ID ..."
    tccutil reset Accessibility "$DEV_BUNDLE_ID" 2>/dev/null || true
    echo "   You will be asked to grant access once more on next launch."
fi

# Kill any existing MacClipboard processes
pkill -f "MacClipboard" 2>/dev/null || true

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
if [ -n "$CERT_HASH" ]; then
    codesign --force --deep --sign "$CERT_HASH" "$DEV_APP_PATH"
else
    echo "⚠️  Could not find certificate hash, trying by name..."
    codesign --force --deep --sign "$CERT_NAME" "$DEV_APP_PATH"
fi

echo "🚀 Starting MacClipboard from: $DEV_APP_PATH"

# Open the app from consistent location
open "$DEV_APP_PATH"

echo "✅ MacClipboard started! Check your menu bar for the clipboard icon."
echo "Use Cmd+Shift+V to open the clipboard history from anywhere."
