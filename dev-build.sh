#!/bin/bash

# Quick build script for development
# This script builds and runs the app for testing

set -e

PROJECT_NAME="MacClipboard"
SCHEME_NAME="MacClipboard"
CONFIGURATION="Debug"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}🔧 Quick building MacClipboard for development...${NC}"

# Build and run
echo -e "${YELLOW}🏗️  Building and running...${NC}"
xcodebuild build \
    -project "${PROJECT_NAME}.xcodeproj" \
    -scheme "${SCHEME_NAME}" \
    -configuration "${CONFIGURATION}" \
    -destination "generic/platform=macOS"

echo -e "${GREEN}✅ Build completed! You can now run the app from Xcode.${NC}"