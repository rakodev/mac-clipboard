#!/bin/bash

# Development build script for MacClipboard
# This creates a signed development build that retains accessibility permissions

set -e

# Configuration
PROJECT_NAME="MacClipboard"
SCHEME_NAME="MacClipboard"
CONFIGURATION="Debug"
EXPORT_PATH="./build/dev-export"
APP_PATH="./build/dev-export/MacClipboard.app"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}🚀 Building MacClipboard (Development)...${NC}"

# Check if Xcode is installed
if ! command -v xcodebuild &> /dev/null; then
    echo -e "${RED}❌ Error: Xcode command line tools not found${NC}"
    echo "Please install Xcode command line tools with: xcode-select --install"
    exit 1
fi

# Create build directory
mkdir -p build

# Clean previous dev builds
echo -e "${YELLOW}🧹 Cleaning previous dev builds...${NC}"
rm -rf build/dev-export

# Build directly to export path (no archive needed for dev builds)
echo -e "${YELLOW}🔨 Building development version...${NC}"
xcodebuild build \
    -project "${PROJECT_NAME}.xcodeproj" \
    -scheme "${SCHEME_NAME}" \
    -configuration "${CONFIGURATION}" \
    -derivedDataPath ./build/DerivedData \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES

# Copy the built app to export location
echo -e "${YELLOW}📦 Copying app to export location...${NC}"
mkdir -p "${EXPORT_PATH}"
cp -R "./build/DerivedData/Build/Products/${CONFIGURATION}/MacClipboard.app" "${APP_PATH}"

# Create ZIP archive
echo -e "${YELLOW}🗜️  Creating ZIP archive...${NC}"
cd build/dev-export
zip -r "../MacClipboard-dev.zip" MacClipboard.app
cd ../..

echo -e "${GREEN}✅ Development build completed successfully!${NC}"
echo -e "${GREEN}📁 App location: ${APP_PATH}${NC}"
echo -e "${GREEN}📁 ZIP archive: ./build/MacClipboard-dev.zip${NC}"

echo ""
echo -e "${GREEN}🎉 MacClipboard development build is ready!${NC}"
echo -e "${YELLOW}💡 This version should retain accessibility permissions${NC}"