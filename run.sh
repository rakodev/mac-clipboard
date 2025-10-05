#!/bin/bash

# Kill any existing MacClipboard processes
pkill -f MacClipboard 2>/dev/null || true

# Build the app if needed
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

echo "🚀 Starting MacClipboard from: $BUILD_PATH"

# Open the app
open "$BUILD_PATH"

echo "✅ MacClipboard started! Check your menu bar for the clipboard icon."
echo "Use Cmd+Shift+V to open the clipboard history from anywhere."