# CLAUDE.md - MacClipboard Project Guide

## Project Overview

MacClipboard is a native macOS menu bar clipboard manager built with Swift and SwiftUI. It automatically tracks clipboard history and provides quick access via a global hotkey (Cmd+Shift+V).

**Product Goal**: Build and maintain the best clipboard manager app for macOS. Prioritize improvements that make MacClipboard more reliable, faster, more private, easier to use, and easier to maintain. When you see a concrete issue or opportunity, either fix it or track it in the docs backlog so it is not lost.

**Tech Stack**: Swift 5.0, SwiftUI, AppKit, Core Data
**Target**: macOS 13.0+ (Ventura)
**Bundle ID**: com.macclipboard.app

## Task Tracking

Use the docs folder to track product and engineering work:

- `docs/BACKLOG.md` - Committed todo tasks with priority, evidence, and acceptance criteria.
- `docs/FOLLOWUPS.md` - Ideas or possible future improvements that are not ready for the backlog yet.
- `docs/BACKLOG_ARCHIVE.md` - Completed backlog tasks, including date, summary, and verification.

Workflow:
1. Add actionable issues found during code review to `docs/BACKLOG.md`.
2. Add lower-confidence ideas or later enhancements to `docs/FOLLOWUPS.md`.
3. When a backlog item is completed, move it to `docs/BACKLOG_ARCHIVE.md` and include the verification used.
4. Keep backlog items concrete: include the affected file or behavior, why it matters, and what “done” means.

## Quick Commands

```bash
# Development (recommended)
./run.sh              # Build, sign with dev cert, and run

# Alternative commands
make run              # Same as ./run.sh
make dev              # Debug build only (no run)
make clean            # Clean build artifacts

# Release build (requires Developer ID certificate)
./build.sh release    # Full release: build, sign, notarize, create DMG/ZIP

# Housekeeping
./scripts/clean-dev-artifacts.sh          # Report stray copies of the app on this machine
./scripts/clean-dev-artifacts.sh --fix    # Remove them
```

## Project Structure

```
MacClipboard/
├── MacClipboardApp.swift      # App entry point & AppDelegate
├── BuildInfo.swift            # Build channel (Dev/Release) + GlobalHotkey definition
├── ClipboardMonitor.swift     # Clipboard polling (0.8s interval), history management
├── MenuBarController.swift    # Status bar item, popover, global hotkey registration
├── ContentView.swift          # Main UI: filter tabs, search, item list, preview
├── SettingsView.swift         # Settings panel UI
├── UserPreferences.swift      # UserPreferencesManager singleton (UserDefaults)
├── PersistenceManager.swift   # Core Data stack, save/load items, image storage
├── PermissionManager.swift    # Accessibility permission handling
├── AppInstallation.swift      # Install location, duplicate copies, signing identity
├── Logging.swift              # Debug/release logging utility
└── ClipboardData.xcdatamodeld # Core Data model (PersistedClipboardItem entity)
```

## Dev and Release Builds Side by Side

`run.sh` builds a dev copy that is meant to run alongside an installed release copy, so the two
must never collide. `BuildInfo.isDevBuild` is the single check; everything derived from it:

| Concern | Release | Dev |
|---------|---------|-----|
| Bundle id | `com.macclipboard.app` (Release config) | `com.macclipboard.app.dev` (Debug config, and re-set by `run.sh`) |
| Global hotkey | `Cmd+Shift+V` | `Cmd+Shift+Opt+V` |
| Menu bar icon | outlined clipboard | filled clipboard |
| Core Data store | `~/Library/Application Support/MacClipboard` | `.../MacClipboard (Dev)` |
| Settings footer | `Release` badge | `Dev` badge |
| Display name | MacClipboard | MacClipboard Dev |
| Install checks | on | skipped (a dev build runs from wherever it was built) |

An app process hosting an XCTest bundle skips the instance takeover and the install alerts, so
running the tests never disturbs a dev build you have open.

Never change the release-side values: the bundle id and the pinned designated requirement in
`build.sh` are what keep every user's Accessibility grant valid across upgrades, and the store
path is where their history lives.

The Debug configuration carries the `.dev` bundle id so that building and running straight from
Xcode cannot contend for the release Accessibility record either. Only the Release configuration
may ever use `com.macclipboard.app`.

## One Copy, In Applications

An Accessibility grant belongs to a single copy of the app, keyed on bundle id *and* the code
signing requirement recorded when the grant was made. So a second copy under the same bundle id
is refused while System Settings keeps showing the app as enabled, and extra copies also clutter
Spotlight, poll the pasteboard twice and fight over the global hotkey. `AppInstallation` detects
this and the app offers the fix (move into Applications, or trash the extra copies) at launch and
under Settings > Installation.

Rules that follow from it:

- Never leave a built `.app` lying around in an indexed folder. `build.sh` deletes and unregisters
  `build/export/MacClipboard.app` after packaging it (`--keep-export` opts out), and `run.sh`
  deletes the DerivedData build product once it has copied and re-signed it into
  `~/Applications/MacClipboard-Dev.app`. Running the tests or hitting Run in Xcode brings that
  product back until the next `./run.sh`, which is harmless: it carries the dev bundle id.
- `./scripts/clean-dev-artifacts.sh` reports stray copies; `--fix` removes them.
- When diagnosing a permission report, read `[Install]` in the unified log first:
  `log show --predicate 'subsystem == "com.macclipboard.app"' --last 1h | grep Install`.
  It gives the path, the signing identity, and every duplicate that was found.

## Architecture

**Pattern**: MVVM-inspired with SwiftUI
**Data Flow**: MenuBarController → ContentView → ClipboardMonitor → NSPasteboard

Key singletons:
- `UserPreferencesManager.shared` - App settings
- `PersistenceManager.shared` - Core Data operations

## Core Data Model

**Entity: PersistedClipboardItem**
- `id`: UUID
- `contentType`: Int16 (0=text, 1=image, 2=files)
- `textContent`: String (full text)
- `displayText`: String (preview)
- `imageData`: Binary (external storage)
- `fileURLs`: Transformable (secure-archived array)
- `isFavorite`, `isSensitive`: Boolean
- `note`: String (user-added)
- `createdAt`, `updatedAt`: Date

## Images Are the Storage Cost, Not Text

Measured on a real 1859-item history: 1683 text clips came to 717 KB, 176 images to 1.2 GB. Text is
a rounding error. Two things follow, and both are load-bearing:

- **Store images as PNG**, via `NSImage.clipboardStorageData`. Never go back to
  `tiffRepresentation`: AppKit writes TIFF uncompressed, which measured about 40 times larger for
  the same pixels. `compactImageStorage()` re-encodes a pre-existing history once per install,
  guarded by `UserPreferencesManager.imageStorageCompacted`.
- **Images have their own retention window**, `imagePersistenceDays` (default 30), separate from
  `persistenceDays`. File items follow the text window on purpose: a file clip stores only its
  paths, so it costs about as much as a line of text.

Under storage pressure, `evictImagesUntilWithin(byteLimit:)` drops oldest non-favorite images
rather than shortening the retention window. The previous behaviour halved `persistenceDays` once
per pass, which could never reach the limit and so silently kept history at half the age the user
asked for. `getStorageSize()` stats the store directory: do not go back to summing `imageData`
lengths, which faults every external image file into memory once an hour.

Bulk deletes use batched object deletion, not `NSBatchDeleteRequest`. A batch delete runs directly
against the store, so Core Data never removes the external file behind `imageData`, and those files
are the whole cost. See `docs/BACKLOG.md` for the orphans left by the old behaviour.

## Favorites Are Permanent

The empty state tells users favorites are never auto-deleted, so the code has to make that true
rather than remember to be careful:

- Every bulk delete goes through `PersistenceManager.bulkDeleteNonFavorites`, which always ands in
  `isFavorite == NO`. Add new cleanup paths through that method, never a bare
  `NSBatchDeleteRequest`. Age cleanup and storage pressure both run through it.
- A favorite leaves the store only via `deleteItems(withIds:)`, which is a request for those
  specific items, i.e. the user deleting something directly.
- `clearAllData` (Clear History, and the popover trash button) keeps favorites, and
  `ClipboardMonitor.clearHistory` keeps the same rows in memory so the two stay in step.
- `addToHistory` saves the replacement row *before* deleting the row it supersedes, both on one
  queue. The reverse order committed the delete synchronously while the save was async, so a quit
  in between lost the item entirely. Re-copying is what happens to a favorite snippet constantly,
  so favorites were the most exposed. Do not reintroduce a delete-then-save ordering.
- `Settings > Persistence > Export Favorites` writes a zip (`favorites.json` plus `images/`) via
  `FavoritesExport`, so a favorite can be recovered from outside the app. Hidden favorites are
  included and flagged `"sensitive": true`; the save panel says so before writing.

`docs/BACKLOG.md` tracks the missing test seam: nothing may construct `PersistenceManager` or
`ClipboardMonitor` in a test, because both reach the user's real store.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+Shift+V` | Global: Open clipboard (from any app) |
| `Enter` | Paste selected item |
| `0-9` | Quick paste by position |
| `↑/↓` | Navigate items |
| `Cmd+F` | Cycle filter tabs |
| `Cmd+D` | Toggle favorite |
| `Cmd+H` | Toggle sensitive mode |
| `Cmd+V` | Reveal sensitive item |
| `Cmd+N` | Focus note field |
| `Cmd+Z` | Full-size image preview |
| `Cmd+Backspace` | Delete item(s) |
| `Escape` | Close popover |

## User Preferences

Settings stored in UserDefaults via `UserPreferencesManager`:
- `maxClipboardItems`: 10-1000 (default: 200)
- `persistenceEnabled`: Bool (default: true)
- `saveImages`: Bool (default: true)
- `maxStorageSize`: MB (default: 1000), enforced by evicting oldest non-favorite images
- `persistenceDays`: 1-365 (default: 60), applies to every kind of item
- `imagePersistenceDays`: 1-365 (default: 30), images only, shorter because they are the space
- `hotKeyEnabled`: Bool (default: true)
- `shortcutsEnabled`: Bool (default: true)
- `autoStartEnabled`: Bool (default: true)

## Filter Tabs

ContentView has four filter modes:
1. **All** - All non-hidden clipboard items
2. **Favorites** - Items marked as favorite
3. **Images** - Image content type only
4. **Hidden** - Sensitive/hidden items

## Development Setup

1. First time: `./scripts/setup-dev-signing.sh` (creates persistent dev certificate)
2. Build and run: `./run.sh`

The dev certificate ensures accessibility permissions persist across rebuilds.

## Testing Checklist

When modifying clipboard functionality:
- [ ] Text, images, and files are captured correctly
- [ ] Global hotkey works from any app
- [ ] Favorites and notes persist after restart
- [ ] Re-copying a favorite, then quitting immediately, keeps it starred after relaunch
- [ ] Clear History leaves favorites in place
- [ ] Export Favorites produces a zip whose JSON and images open
- [ ] Copied images are stored as PNG (check bytes in `_EXTERNAL_DATA` start with the PNG header)
- [ ] Images age out on `imagePersistenceDays` while older text survives on `persistenceDays`
- [ ] Search filters by content and notes
- [ ] Sensitive mode hides/reveals correctly

When modifying UI:
- [ ] Filter tabs work correctly
- [ ] Keyboard navigation functions
- [ ] Multi-select deletion works
- [ ] Image preview opens with Cmd+Z

## Code Conventions

- Use `@Published` properties in ObservableObject for reactive updates
- Background work: `DispatchQueue.global(qos: .utility)`
- UI updates: `DispatchQueue.main.async`
- Use `MARK:` comments to organize code sections
- Logging: Use `Logger.log()` from Logging.swift (silent in Release builds)
- **Colors**: Always use semantic colors for automatic dark/light mode support:
  - `Color(NSColor.windowBackgroundColor)` for window backgrounds
  - `Color(NSColor.controlBackgroundColor)` for control backgrounds
  - `Color(NSColor.textBackgroundColor)` for text field backgrounds
  - `.foregroundColor(.primary)` for main text
  - `.foregroundColor(.secondary)` for secondary text
  - `Color.accentColor` for highlights
  - Never use hardcoded `Color.white`, `Color.black`, or hex colors for backgrounds/text

## Entitlements

The app requires:
- `com.apple.security.automation.apple-events` - For paste automation
- Accessibility permissions - For global hotkey (requested at runtime)

`build.sh` re-signs the exported app to pin the designated requirement, and that re-sign MUST
pass `--entitlements`: `codesign --force` replaces the signature wholesale, so omitting it ships
an app with no entitlements at all. Releases up to 0.1.13 did exactly that. The build now fails
if the entitlements are missing, or if debug-only `get-task-allow` is present.

## Important Files for Common Tasks

| Task | Files to Modify |
|------|-----------------|
| Add keyboard shortcut | `ContentView.swift` (local), `MenuBarController.swift` (global) |
| Change clipboard polling | `ClipboardMonitor.swift` |
| Modify settings | `SettingsView.swift`, `UserPreferences.swift` |
| Update data model | `ClipboardData.xcdatamodeld`, `PersistenceManager.swift`, `ClipboardMonitor.swift` |
| Change UI layout | `ContentView.swift` |
| Modify menu bar behavior | `MenuBarController.swift` |
