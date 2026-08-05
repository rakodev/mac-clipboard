#!/bin/bash

# Find and clean up stray copies of MacClipboard on this machine.
#
# Why this exists: macOS registers every .app it sees, so leftover build products (an exported
# bundle, an old DerivedData build, a copy dragged somewhere by hand) show up as extra
# "MacClipboard" entries in Spotlight and count as duplicate installs. An Accessibility grant
# belongs to one specific copy, identified by bundle id *and* the code signing requirement
# recorded when the grant was made, so duplicates are the usual reason auto-paste stops working
# while the switch in System Settings stays on.
#
# Usage:
#   ./scripts/clean-dev-artifacts.sh            # report only
#   ./scripts/clean-dev-artifacts.sh --fix      # remove stray copies and stale DerivedData

set -e

RELEASE_BUNDLE_ID="com.macclipboard.app"
DEV_BUNDLE_ID="com.macclipboard.app.dev"
DEV_APP_PATH="$HOME/Applications/MacClipboard-Dev.app"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

FIX=false
for arg in "$@"; do
    case "$arg" in
        --fix) FIX=true ;;
        *) echo "Usage: $0 [--fix]"; exit 1 ;;
    esac
done

lsregister() {
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister "$@"
}

version_of() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist" 2>/dev/null || echo "?"
}

# Ad hoc signatures pin a grant to one exact binary hash, so such a copy loses Accessibility on
# every rebuild and can never match a record made by a signed release.
is_adhoc() {
    codesign -dv "$1" 2>&1 | grep -q "^Signature=adhoc"
}

describe() {
    local app="$1" identity
    if is_adhoc "$app"; then
        identity="ad hoc, cannot keep permissions"
    else
        identity=$(codesign -dv "$app" 2>&1 | grep "^TeamIdentifier=" | cut -d= -f2)
        [ -z "$identity" ] || [ "$identity" = "not set" ] && identity="local certificate"
    fi
    echo "v$(version_of "$app"), ${identity}"
}

# Spotlight is asked the same question the user's search bar asks, so the report matches what
# they actually see.
copies_of() {
    mdfind "kMDItemCFBundleIdentifier == '$1'" 2>/dev/null | while IFS= read -r app; do
        [ -d "$app" ] && echo "$app"
    done
}

# The release copy worth keeping: properly signed beats ad hoc, /Applications beats anywhere
# else, and a higher version breaks the remaining ties.
score_release_copy() {
    local app="$1" score=0
    is_adhoc "$app" || score=$((score + 4))
    case "$app" in
        /Applications/MacClipboard.app) score=$((score + 2)) ;;
        "$HOME/Applications/MacClipboard.app") score=$((score + 1)) ;;
    esac
    echo "$score"
}

echo -e "${CYAN}Copies of MacClipboard macOS knows about${NC}"
echo ""

RELEASE_COPIES=()
while IFS= read -r app; do
    [ -n "$app" ] && RELEASE_COPIES+=("$app")
done < <(copies_of "$RELEASE_BUNDLE_ID")

KEEPER=""
KEEPER_RANK=-1
for app in "${RELEASE_COPIES[@]}"; do
    rank=$(score_release_copy "$app")
    if [ "$rank" -gt "$KEEPER_RANK" ]; then
        KEEPER="$app"
        KEEPER_RANK="$rank"
    elif [ "$rank" -eq "$KEEPER_RANK" ] && \
         [ "$(printf '%s\n%s\n' "$(version_of "$KEEPER")" "$(version_of "$app")" | sort -V | tail -1)" = "$(version_of "$app")" ]; then
        KEEPER="$app"
    fi
done

STRAYS=()
for app in "${RELEASE_COPIES[@]}"; do
    if [ "$app" = "$KEEPER" ]; then
        echo -e "  ${GREEN}keep${NC}  $app  ($(describe "$app"))"
    else
        echo -e "  ${YELLOW}stray${NC} $app  ($(describe "$app"))"
        STRAYS+=("$app")
    fi
done

DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
REPO_BUILD_DIR="$(cd "$(dirname "$0")/.." && pwd)/build"
while IFS= read -r app; do
    [ -z "$app" ] && continue
    case "$app" in
        "$DEV_APP_PATH")
            echo -e "  ${GREEN}keep${NC}  $app  ($(describe "$app"), dev build)"
            ;;
        "$DERIVED_DATA"/* | "$REPO_BUILD_DIR"/*)
            # Every `make dev` leaves one of these behind, and a build given an explicit
            # -derivedDataPath leaves one under the repo's own build/. Both carry the dev bundle
            # id, so they can only ever contend with the dev copy, and deleting them just slows
            # the next build. Report them so the count is honest, but do not call them strays.
            echo -e "  ${CYAN}build${NC} $app  ($(describe "$app"), normal build output)"
            ;;
        *)
            echo -e "  ${YELLOW}stray${NC} $app  ($(describe "$app"), dev build in an unexpected place)"
            STRAYS+=("$app")
            ;;
    esac
done < <(copies_of "$DEV_BUNDLE_ID")

echo ""

# DerivedData folders from an earlier project name keep old bundles registered long after that
# project stopped existing.
STALE_DERIVED=()
while IFS= read -r dir; do
    [ -n "$dir" ] && STALE_DERIVED+=("$dir")
done < <(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 1 -type d -name "ClipboardManager-*" 2>/dev/null)

if [ ${#STALE_DERIVED[@]} -gt 0 ]; then
    echo -e "${CYAN}DerivedData from the old ClipboardManager project name${NC}"
    for dir in "${STALE_DERIVED[@]}"; do
        echo -e "  ${YELLOW}stale${NC} $dir"
    done
    echo ""
fi

if [ ${#STRAYS[@]} -eq 0 ] && [ ${#STALE_DERIVED[@]} -eq 0 ]; then
    echo -e "${GREEN}✅ Nothing to clean up. One release copy, one dev copy.${NC}"
    exit 0
fi

if [ "$FIX" = false ]; then
    echo -e "${YELLOW}Report only. Rerun with --fix to remove the entries marked stray or stale.${NC}"
    echo -e "${YELLOW}Build products are recreated by the next build; nothing here is source.${NC}"
    exit 0
fi

# App bundles go to the Trash rather than being deleted outright: one of them may be a copy the
# user installed on purpose, and this script decides which copy wins by heuristic.
for app in "${STRAYS[@]}"; do
    echo -e "${YELLOW}🧹 Moving to Trash: $app${NC}"
    pkill -f "$app/Contents/MacOS/" 2>/dev/null || true
    lsregister -u "$app" 2>/dev/null || true
    # Every stray has the same file name, so keep counting up until a free one is found. A
    # timestamp is not enough: several moves land in the same second.
    target="$HOME/.Trash/$(basename "$app")"
    suffix=1
    while [ -e "$target" ]; do
        target="$HOME/.Trash/$(basename "$app" .app)-${suffix}.app"
        suffix=$((suffix + 1))
    done
    mv "$app" "$target"
done

# DerivedData is pure build cache, so it is deleted rather than filling the Trash.
for dir in "${STALE_DERIVED[@]}"; do
    echo -e "${YELLOW}🧹 Deleting build cache: $dir${NC}"
    rm -rf "$dir"
done

echo ""
echo -e "${GREEN}✅ Cleanup done. Kept: ${KEEPER:-none}${NC}"
echo -e "${CYAN}If Accessibility was granted to a copy that is now gone, open MacClipboard and use${NC}"
echo -e "${CYAN}the banner's Repair button, or run:${NC}"
echo -e "${CYAN}  tccutil reset Accessibility ${RELEASE_BUNDLE_ID}${NC}"
