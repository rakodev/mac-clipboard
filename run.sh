#!/bin/bash

# Development run script for MacClipboard
# Builds, signs with dev certificate, and runs from a consistent location
# to preserve accessibility permissions across rebuilds.

set -e

CERT_NAME="MacClipboard Dev"
DEV_APP_PATH="$HOME/Applications/MacClipboard-Dev.app"

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

# Re-sign with dev certificate for consistent identity
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
