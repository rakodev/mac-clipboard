#!/bin/bash

# Build script for MacClipboard
# This script builds, signs, notarizes, and optionally releases the app
#
# Usage:
#   ./build.sh                       # Build only (will prompt if you want to release)
#   ./build.sh release               # Build and create a GitHub release (interactive)
#   ./build.sh release --version=0.1.14 --notes="..."
#                                    # Same, without the fzf/read prompts

set -e

# Configuration
PROJECT_NAME="MacClipboard"
SCHEME_NAME="MacClipboard"
CONFIGURATION="Release"
ARCHIVE_PATH="./build/MacClipboard.xcarchive"
EXPORT_PATH="./build/export"
APP_PATH="./build/export/MacClipboard.app"
ENTITLEMENTS_PATH="./MacClipboard/MacClipboard.entitlements"
ZIP_PATH="./build/MacClipboard.zip"
DMG_PATH="./build/MacClipboard-Installer.dmg"

# Signing Configuration
DEVELOPER_ID="Developer ID Application: Ramazan KORKMAZ (K542B2Z65M)"
TEAM_ID="K542B2Z65M"
KEYCHAIN_PROFILE="MacClipboard-Notarize"

# Homebrew Tap Configuration
HOMEBREW_TAP_PATH="../homebrew-tap"
HOMEBREW_CASK_FILE="${HOMEBREW_TAP_PATH}/Casks/macclipboard.rb"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ============================================================================
# RELEASE WORKFLOW (runs first, before any build)
# ============================================================================

CREATE_RELEASE=false
NEW_VERSION=""
RELEASE_NOTES=""
KEEP_EXPORT=false
HAS_ARGS=false

# Parse arguments. `--version=` and `--notes=` pre-answer the two interactive prompts so a
# release can be driven non-interactively; everything else about the flow is unchanged.
for arg in "$@"; do
    HAS_ARGS=true
    case "$arg" in
        release)
            CREATE_RELEASE=true
            ;;
        --version=*)
            NEW_VERSION="${arg#*=}"
            ;;
        --notes=*)
            RELEASE_NOTES="${arg#*=}"
            ;;
        --keep-export)
            KEEP_EXPORT=true
            ;;
        *)
            echo -e "${RED}❌ Unknown argument: ${arg}${NC}"
            echo "Usage: ./build.sh [release] [--version=X.Y.Z] [--notes=\"...\"] [--keep-export]"
            exit 1
            ;;
    esac
done

if [ -n "$NEW_VERSION" ] && ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${RED}❌ --version must look like X.Y.Z (got: ${NEW_VERSION})${NC}"
    exit 1
fi

if [ "$HAS_ARGS" = false ]; then
    # Prompt user if they want to create a release
    echo -e "${CYAN}Do you want to create a release?${NC}"
    RELEASE_CHOICE=$(echo -e "No, just build\nYes, create release" | fzf --height=5 --reverse --prompt="Release? ")
    if [ "$RELEASE_CHOICE" = "Yes, create release" ]; then
        CREATE_RELEASE=true
    fi
fi

if [ "$CREATE_RELEASE" = true ]; then
    echo -e "${BLUE}📦 Release mode enabled${NC}"
    echo ""

    # Check for required tools
    if ! command -v fzf &> /dev/null; then
        echo -e "${RED}❌ Error: fzf is required for release mode${NC}"
        echo ""
        echo -e "${CYAN}To fix this, run:${NC}"
        echo -e "  ${YELLOW}brew install fzf${NC}"
        echo ""
        echo "Then re-run ./build.sh"
        exit 1
    fi

    if ! command -v gh &> /dev/null; then
        echo -e "${RED}❌ Error: GitHub CLI (gh) is required for release mode${NC}"
        echo ""
        echo -e "${CYAN}To fix this, run:${NC}"
        echo -e "  ${YELLOW}brew install gh${NC}"
        echo -e "  ${YELLOW}gh auth login${NC}"
        echo ""
        echo "Then re-run ./build.sh"
        exit 1
    fi

    # Check if gh is authenticated
    if ! gh auth status &> /dev/null; then
        echo -e "${RED}❌ Error: GitHub CLI is not authenticated${NC}"
        echo ""
        echo -e "${CYAN}To fix this, run:${NC}"
        echo -e "  ${YELLOW}gh auth login${NC}"
        echo ""
        echo "Follow the prompts to log in with your GitHub account."
        echo "Then re-run ./build.sh"
        exit 1
    fi

    # -------------------------------------------------------------------------
    # Handle uncommitted changes (all tracked paths, not just app sources, so
    # docs/ and build tooling edits cannot silently miss the release tag)
    # -------------------------------------------------------------------------
    REPO_CHANGES=$(git status --porcelain 2>/dev/null)
    if [ -n "$REPO_CHANGES" ]; then
        echo -e "${YELLOW}📝 You have uncommitted changes:${NC}"
        git status --short
        echo ""

        # Prompt for commit message
        echo -e "${CYAN}Enter commit message (or Ctrl+C to cancel):${NC}"
        read -r COMMIT_MESSAGE

        if [ -z "$COMMIT_MESSAGE" ]; then
            echo -e "${RED}❌ Commit message cannot be empty${NC}"
            exit 1
        fi

        # Stage and commit everything not covered by .gitignore
        git add -A
        git commit -m "$COMMIT_MESSAGE"
        echo -e "${GREEN}✅ Changes committed${NC}"
    fi

    # Push any unpushed commits
    UNPUSHED=$(git log origin/$(git branch --show-current)..HEAD --oneline 2>/dev/null || echo "")
    if [ -n "$UNPUSHED" ]; then
        echo -e "${YELLOW}📤 Pushing commits to remote...${NC}"
        git push
        echo -e "${GREEN}✅ Pushed to remote${NC}"
    fi

    # -------------------------------------------------------------------------
    # Version selection
    # -------------------------------------------------------------------------

    # Get latest version from git tags
    LATEST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
    LATEST_VERSION=${LATEST_TAG#v}  # Remove 'v' prefix

    # Parse version components
    IFS='.' read -r MAJOR MINOR PATCH <<< "$LATEST_VERSION"
    MAJOR=${MAJOR:-0}
    MINOR=${MINOR:-0}
    PATCH=${PATCH:-0}

    # Calculate next versions
    NEXT_PATCH="$MAJOR.$MINOR.$((PATCH + 1))"
    NEXT_MINOR="$MAJOR.$((MINOR + 1)).0"
    NEXT_MAJOR="$((MAJOR + 1)).0.0"

    echo ""
    echo -e "${CYAN}Current version: ${YELLOW}v${LATEST_VERSION}${NC}"

    if [ -n "$NEW_VERSION" ]; then
        echo -e "${CYAN}Version supplied on the command line${NC}"
    else
        echo -e "${CYAN}Select new version:${NC}"

        # Version selection with fzf
        VERSION_CHOICE=$(echo -e "patch → v${NEXT_PATCH}\nminor → v${NEXT_MINOR}\nmajor → v${NEXT_MAJOR}\ncustom" | fzf --height=7 --reverse --prompt="Version: ")

        case "$VERSION_CHOICE" in
            "patch"*) NEW_VERSION="$NEXT_PATCH" ;;
            "minor"*) NEW_VERSION="$NEXT_MINOR" ;;
            "major"*) NEW_VERSION="$NEXT_MAJOR" ;;
            "custom")
                echo -e "${CYAN}Enter custom version (without 'v' prefix):${NC}"
                read -r NEW_VERSION
                if [ -z "$NEW_VERSION" ]; then
                    echo -e "${RED}❌ Version cannot be empty${NC}"
                    exit 1
                fi
                ;;
            *)
                echo -e "${RED}❌ No version selected${NC}"
                exit 1
                ;;
        esac
    fi

    if git rev-parse "v${NEW_VERSION}" >/dev/null 2>&1; then
        echo -e "${RED}❌ Tag v${NEW_VERSION} already exists${NC}"
        exit 1
    fi

    echo -e "${GREEN}✅ New version: v${NEW_VERSION}${NC}"
    echo ""

    # -------------------------------------------------------------------------
    # Release notes (prompt now so no interaction needed at the end)
    # -------------------------------------------------------------------------
    if [ -z "$RELEASE_NOTES" ]; then
        echo -e "${CYAN}Enter release notes (press Enter for default, or type custom notes):${NC}"
        read -r RELEASE_NOTES
    fi

    if [ -z "$RELEASE_NOTES" ]; then
        RELEASE_NOTES="MacClipboard v${NEW_VERSION} - Clipboard history manager for macOS"
    fi
    echo -e "${GREEN}✅ Release notes saved${NC}"
    echo ""

    # -------------------------------------------------------------------------
    # Update version in Xcode project
    # -------------------------------------------------------------------------
    echo -e "${YELLOW}📝 Updating version in Xcode project...${NC}"

    # Update MARKETING_VERSION in project.pbxproj
    sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = ${NEW_VERSION};/g" "${PROJECT_NAME}.xcodeproj/project.pbxproj"

    # Increment build number
    CURRENT_BUILD=$(grep -m1 "CURRENT_PROJECT_VERSION" "${PROJECT_NAME}.xcodeproj/project.pbxproj" | sed 's/.*= \([0-9]*\);/\1/')
    NEW_BUILD=$((CURRENT_BUILD + 1))
    sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = ${NEW_BUILD};/g" "${PROJECT_NAME}.xcodeproj/project.pbxproj"

    echo -e "${GREEN}✅ Version updated to ${NEW_VERSION} (build ${NEW_BUILD})${NC}"

    # Commit version bump
    git add "${PROJECT_NAME}.xcodeproj/project.pbxproj"
    git commit -m "Bump version to ${NEW_VERSION}"
    git push
    echo -e "${GREEN}✅ Version bump committed and pushed${NC}"
    echo ""
fi

# ============================================================================
# BUILD WORKFLOW
# ============================================================================

echo -e "${GREEN}🚀 Building MacClipboard for distribution...${NC}"

# Check if Xcode is installed
if ! command -v xcodebuild &> /dev/null; then
    echo -e "${RED}❌ Error: Xcode command line tools not found${NC}"
    echo "Please install Xcode command line tools with: xcode-select --install"
    exit 1
fi

# Check if Developer ID certificate exists
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo -e "${RED}❌ Error: Developer ID Application certificate not found${NC}"
    echo "Please create one in Xcode: Settings → Accounts → Manage Certificates → + → Developer ID Application"
    exit 1
fi

# Check if notarization credentials are stored
if ! xcrun notarytool history --keychain-profile "${KEYCHAIN_PROFILE}" &> /dev/null; then
    echo -e "${YELLOW}⚠️  Notarization credentials not found. Skipping notarization.${NC}"
    echo "To enable notarization, run:"
    echo "  xcrun notarytool store-credentials \"${KEYCHAIN_PROFILE}\" --apple-id \"YOUR_EMAIL\" --team-id \"${TEAM_ID}\" --password \"APP_SPECIFIC_PASSWORD\""
    echo ""
    SKIP_NOTARIZATION=true
else
    SKIP_NOTARIZATION=false
fi

# Create build directory
mkdir -p build

# Clean previous builds
echo -e "${YELLOW}🧹 Cleaning previous builds...${NC}"
rm -rf build/*

# Build archive with Developer ID signing and Hardened Runtime
#
# -derivedDataPath keeps the intermediate build product inside build/, which this script wipes on
# every run. Without it the archive lands in the shared DerivedData as another bundle carrying the
# release bundle id, LaunchServices registers it, and the app then correctly reports a duplicate
# install to the user, for a copy that is only a leftover of building the release.
echo -e "${YELLOW}🔨 Building archive...${NC}"
xcodebuild archive \
    -project "${PROJECT_NAME}.xcodeproj" \
    -scheme "${SCHEME_NAME}" \
    -configuration "${CONFIGURATION}" \
    -archivePath "${ARCHIVE_PATH}" \
    -derivedDataPath "./build/DerivedDataRelease" \
    -destination "generic/platform=macOS" \
    CODE_SIGN_IDENTITY="${DEVELOPER_ID}" \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    CODE_SIGN_STYLE="Manual" \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES \
    ENABLE_HARDENED_RUNTIME=YES

# Create export options plist for Developer ID distribution
cat > build/ExportOptions.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
EOF

# Export archive
echo -e "${YELLOW}📦 Exporting app...${NC}"
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_PATH}" \
    -exportOptionsPlist build/ExportOptions.plist

# Re-sign with proper designated requirements
# This ensures macOS recognizes the app as the same app across updates,
# preserving Accessibility permissions. Without this, cdhash changes every build.
echo -e "${YELLOW}🔏 Re-signing with stable designated requirements...${NC}"

# Sign nested components first
find "${APP_PATH}" -type f \( -name "*.dylib" -o -name "*.framework" \) -exec \
    codesign --force --sign "${DEVELOPER_ID}" --options runtime {} \; 2>/dev/null || true

# Sign the main app with stable designated requirement
# Using identifier + team ID (not cdhash) so macOS recognizes app across updates
# This preserves Accessibility permissions after upgrades
#
# --entitlements is mandatory here: codesign --force replaces the signature wholesale, so
# omitting it silently ships an app with no entitlements at all (that is what 0.1.13 and
# every release before it did). The check below fails the build if that regresses.
codesign --force --sign "${DEVELOPER_ID}" \
    --options runtime \
    --entitlements "${ENTITLEMENTS_PATH}" \
    -r='designated => identifier "com.macclipboard.app" and anchor apple generic and certificate leaf[subject.OU] = "K542B2Z65M"' \
    "${APP_PATH}"

# Verify code signature (without --strict as it conflicts with custom designated requirements)
echo -e "${YELLOW}🔍 Verifying code signature...${NC}"
codesign --verify --deep --verbose=2 "${APP_PATH}"

# Show the designated requirement that was set
echo -e "${YELLOW}🔍 Checking designated requirements...${NC}"
codesign -d -r- "${APP_PATH}" 2>&1

# Confirm what actually shipped: the declared entitlements are present, and the debug-only
# get-task-allow is not (notarization rejects it).
echo -e "${YELLOW}🔍 Checking shipped entitlements...${NC}"
SHIPPED_ENTITLEMENTS=$(codesign -d --entitlements - --xml "${APP_PATH}" 2>/dev/null || true)

if ! grep -q "com.apple.security.automation.apple-events" <<< "${SHIPPED_ENTITLEMENTS}"; then
    echo -e "${RED}❌ Entitlements missing from the signed app${NC}"
    echo -e "${RED}   Expected com.apple.security.automation.apple-events from ${ENTITLEMENTS_PATH}${NC}"
    exit 1
fi

if grep -q "com.apple.security.get-task-allow" <<< "${SHIPPED_ENTITLEMENTS}"; then
    echo -e "${RED}❌ get-task-allow is present in the signed app; notarization will reject it${NC}"
    echo -e "${RED}   Remove it from ${ENTITLEMENTS_PATH}${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Entitlements verified${NC}"

echo -e "${GREEN}✅ Code signature verified${NC}"

# Notarization
if [ "$SKIP_NOTARIZATION" = false ]; then
    # Create ZIP for notarization
    echo -e "${YELLOW}🗜️  Creating ZIP for notarization...${NC}"
    ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

    # Submit for notarization
    echo -e "${YELLOW}📤 Submitting for notarization (this may take a few minutes)...${NC}"
    xcrun notarytool submit "${ZIP_PATH}" \
        --keychain-profile "${KEYCHAIN_PROFILE}" \
        --wait

    # Staple the notarization ticket
    echo -e "${YELLOW}📎 Stapling notarization ticket...${NC}"
    xcrun stapler staple "${APP_PATH}"

    # Verify notarization
    echo -e "${YELLOW}🔍 Verifying notarization...${NC}"
    spctl -a -vvv -t install "${APP_PATH}"
    echo -e "${GREEN}✅ Notarization verified${NC}"

    # Re-create ZIP with stapled app
    rm -f "${ZIP_PATH}"
    echo -e "${YELLOW}🗜️  Creating final ZIP archive...${NC}"
    cd build/export
    zip -r "../MacClipboard.zip" MacClipboard.app
    cd ../..
else
    # Create ZIP archive without notarization
    echo -e "${YELLOW}🗜️  Creating ZIP archive...${NC}"
    cd build/export
    zip -r "../MacClipboard.zip" MacClipboard.app
    cd ../..
fi

# Create DMG (if create-dmg is available)
if command -v create-dmg &> /dev/null; then
    echo -e "${YELLOW}💿 Creating DMG installer...${NC}"

    # Remove existing DMG if present (create-dmg won't overwrite)
    rm -f "${DMG_PATH}"

    # create-dmg returns non-zero even on success sometimes, so we check the output file instead
    create-dmg \
        --volname "MacClipboard" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "MacClipboard.app" 150 185 \
        --hide-extension "MacClipboard.app" \
        --app-drop-link 450 185 \
        --no-internet-enable \
        "${DMG_PATH}" \
        "${APP_PATH}" || true

    # Verify DMG was created
    if [ -f "${DMG_PATH}" ]; then
        echo -e "${GREEN}✅ DMG created successfully${NC}"

        # Notarize and staple DMG if notarization is enabled
        if [ "$SKIP_NOTARIZATION" = false ]; then
            echo -e "${YELLOW}📤 Notarizing DMG...${NC}"
            xcrun notarytool submit "${DMG_PATH}" \
                --keychain-profile "${KEYCHAIN_PROFILE}" \
                --wait
            xcrun stapler staple "${DMG_PATH}"
            echo -e "${GREEN}✅ DMG notarized${NC}"
        fi
    else
        echo -e "${RED}❌ DMG creation failed${NC}"
    fi
else
    echo -e "${RED}⚠️  create-dmg not found. DMG will not be created.${NC}"
    echo -e "${RED}   Install it with: brew install create-dmg${NC}"
fi

# ============================================================================
# CLEAN UP THE LOOSE EXPORTED APP
# ============================================================================
# The exported bundle is now inside the ZIP and the DMG, so the copy left in build/export is
# dead weight, and not a harmless one: LaunchServices registers every .app it sees, so that
# copy shows up as another "MacClipboard" in Spotlight and counts as a duplicate install. Two
# copies under one bundle id are exactly what breaks an Accessibility grant, and the app now
# warns the user when it finds them. Keeping the tree clean means those warnings only ever fire
# for real problems. Pass --keep-export when you need the bundle for inspection.
if [ "$KEEP_EXPORT" = false ] && [ -f "${ZIP_PATH}" ] && [ -d "${APP_PATH}" ]; then
    echo -e "${YELLOW}🧹 Removing the loose exported app (kept in the ZIP and DMG)...${NC}"
    # Unregister before deleting, so LaunchServices drops the entry rather than keeping a
    # record that points at a path which no longer exists.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -u "${APP_PATH}" 2>/dev/null || true
    rm -rf "${APP_PATH}"
    EXPORT_CLEANED=true
fi

# The archive's intermediate build product is another bundle with the release bundle id, and
# LaunchServices registers it wherever it sits, so it counts as a duplicate install exactly like
# the exported copy above. The archive keeps everything worth keeping (including the dSYMs), so
# this tree is pure cache.
if [ -d "./build/DerivedDataRelease" ]; then
    while IFS= read -r stale_app; do
        [ -n "$stale_app" ] || continue
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
            -u "$stale_app" 2>/dev/null || true
    done < <(find "./build/DerivedDataRelease" -name "MacClipboard.app" -type d 2>/dev/null)
    rm -rf "./build/DerivedDataRelease"
fi

# Finally, say something if this machine still has copies that would break a user's Accessibility
# grant. Report only: deciding which copy to keep is the user's call, and --fix does that.
if [ -x "./scripts/clean-dev-artifacts.sh" ]; then
    ./scripts/clean-dev-artifacts.sh || true
fi

echo ""
echo -e "${GREEN}✅ Build completed successfully!${NC}"
if [ "${EXPORT_CLEANED:-false}" = true ]; then
    echo -e "${GREEN}📁 App: packaged into the ZIP and DMG below (rerun with --keep-export to keep ${APP_PATH})${NC}"
else
    echo -e "${GREEN}📁 App location: ${APP_PATH}${NC}"
fi
echo -e "${GREEN}📁 ZIP archive: ${ZIP_PATH}${NC}"

if [ -f "${DMG_PATH}" ]; then
    echo -e "${GREEN}📁 DMG installer: ${DMG_PATH}${NC}"
fi

echo ""
if [ "$SKIP_NOTARIZATION" = false ]; then
    echo -e "${GREEN}🎉 MacClipboard is signed and notarized - ready for distribution!${NC}"
    echo -e "${GREEN}   Users can open the app without Gatekeeper warnings.${NC}"
else
    echo -e "${YELLOW}⚠️  App is signed but NOT notarized.${NC}"
    echo -e "${YELLOW}   Users will need to right-click → Open to bypass Gatekeeper.${NC}"
    echo -e "${YELLOW}   See DISTRIBUTION.md for notarization setup instructions.${NC}"
fi

# ============================================================================
# GITHUB RELEASE (if release mode is enabled)
# ============================================================================

if [ "$CREATE_RELEASE" = true ]; then
    echo ""
    echo -e "${BLUE}📦 Creating GitHub release...${NC}"

    # Create git tag
    TAG="v${NEW_VERSION}"
    git tag "$TAG"
    git push origin "$TAG"
    echo -e "${GREEN}✅ Tag ${TAG} created and pushed${NC}"

    # Prepare release assets
    RELEASE_ASSETS="${ZIP_PATH}"
    if [ -f "${DMG_PATH}" ]; then
        RELEASE_ASSETS="${RELEASE_ASSETS} ${DMG_PATH}"
    fi

    # Create GitHub release
    gh release create "$TAG" \
        $RELEASE_ASSETS \
        --title "MacClipboard ${TAG}" \
        --notes "$RELEASE_NOTES"

    echo ""
    echo -e "${GREEN}🎉 Release ${TAG} created successfully!${NC}"

    # Show SHA256 for Homebrew
    echo ""
    echo -e "${CYAN}SHA256 hashes (for Homebrew Cask):${NC}"
    echo -e "${YELLOW}ZIP:${NC} $(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"
    if [ -f "${DMG_PATH}" ]; then
        echo -e "${YELLOW}DMG:${NC} $(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"
    fi

    # Show release URL
    REPO_URL=$(gh repo view --json url -q .url)
    echo ""
    echo -e "${GREEN}🔗 Release URL: ${REPO_URL}/releases/tag/${TAG}${NC}"

    # =========================================================================
    # UPDATE HOMEBREW TAP
    # =========================================================================
    echo ""
    echo -e "${BLUE}🍺 Updating Homebrew tap...${NC}"

    if [ -f "${HOMEBREW_CASK_FILE}" ]; then
        # Get SHA256 of the DMG
        DMG_SHA256=$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')

        # Update version and SHA256 in cask file
        sed -i '' "s/version \"[^\"]*\"/version \"${NEW_VERSION}\"/" "${HOMEBREW_CASK_FILE}"
        sed -i '' "s/sha256 \"[^\"]*\"/sha256 \"${DMG_SHA256}\"/" "${HOMEBREW_CASK_FILE}"

        # Commit and push
        cd "${HOMEBREW_TAP_PATH}"
        git add Casks/macclipboard.rb
        git commit -m "Update macclipboard to v${NEW_VERSION}"
        git push
        cd - > /dev/null

        echo -e "${GREEN}✅ Homebrew tap updated to v${NEW_VERSION}${NC}"
        echo -e "${GREEN}   Users can now run: brew upgrade --cask macclipboard${NC}"
    else
        echo -e "${YELLOW}⚠️  Homebrew cask file not found at ${HOMEBREW_CASK_FILE}${NC}"
        echo -e "${YELLOW}   Skipping Homebrew tap update.${NC}"
    fi
fi

echo ""
echo -e "${YELLOW}📝 Note: Users will still need to grant Accessibility permissions${NC}"
echo -e "${YELLOW}   System Settings → Privacy & Security → Accessibility${NC}"
