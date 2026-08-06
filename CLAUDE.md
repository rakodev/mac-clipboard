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
| Bundle id | `com.macclipboard.app` (Release config) | `com.macclipboard.app.dev`, set by `run.sh`; the Debug config builds `.debug` |
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

### Three Bundle Ids, and Why `.dev` Is Handed Out By One Script Only

Only the Release configuration may ever use `com.macclipboard.app`. The other two exist because
TCC keys a grant on bundle id *and* the code signing identity recorded with it:

- `com.macclipboard.app.debug` is what the Debug configuration builds, so Xcode's Run button and
  the test host have an id of their own.
- `com.macclipboard.app.dev` is handed out by `run.sh` alone, with `PlistBuddy` and a re-sign with
  the persistent dev certificate, to the copy it installs in `~/Applications`.

Until 0.1.17 the Debug configuration itself carried `.dev`, so every Run and every test pass put an
ad hoc signed binary behind that id. tccd then logged `Failed to match existing code requirement
for subject com.macclipboard.app.dev` and the grant held by the properly signed dev copy became
unusable, which surfaced as the popover's "Accessibility permission stopped working" banner in the
middle of ordinary work. Never give a bundle id to a build that is not signed with a stable
identity, and keep `PRODUCT_NAME` at `MacClipboard` so the test target's `TEST_HOST` resolves.

`run.sh`'s re-sign passes `--entitlements`, for the same reason `build.sh` must: `codesign --force`
replaces a signature wholesale, so without it the dev build runs with no entitlements at all and
silently differs from release on the Apple-events paste path. The script fails if the
apple-events entitlement is missing afterwards. Xcode's debug-only `get-task-allow` does not
survive that re-sign, which is intended: it is not in the entitlements file, and no shipped build
has it.

A build that cannot hold a grant says so rather than sending the developer to System Settings:
`PermissionManager.cannotHoldGrant` (dev build plus ad hoc signature) drives its own banner text,
and `handleAccessibilityPermissions` skips the one-shot system prompt for those builds and for a
test host.

## One Copy, In Applications

An Accessibility grant belongs to a single copy of the app, keyed on bundle id *and* the code
signing requirement recorded when the grant was made. So a second copy under the same bundle id
is refused while System Settings keeps showing the app as enabled, and extra copies also clutter
Spotlight, poll the pasteboard twice and fight over the global hotkey. `AppInstallation` detects
this and the app offers the fix (move into Applications, or trash the extra copies) at launch and
under Settings > Installation.

Rules that follow from it:

- Never run a bare `xcodebuild -configuration Release build`. With no signing identity it ad hoc
  signs the *release* bundle id into the shared DerivedData, which LaunchServices registers, so the
  app then reports a duplicate install to you for a copy that is only a build leftover. Use
  `./build.sh`, which archives into `build/DerivedDataRelease`, removes it afterwards, and finishes
  by running `clean-dev-artifacts.sh` in report mode.
- Never leave a built `.app` lying around in an indexed folder. `build.sh` deletes and unregisters
  `build/export/MacClipboard.app` after packaging it (`--keep-export` opts out), and `run.sh`
  deletes the DerivedData build product once it has copied and re-signed it into
  `~/Applications/MacClipboard-Dev.app`. Running the tests or hitting Run in Xcode brings that
  product back until the next `./run.sh`. It carries the `.debug` bundle id, so it cannot take the
  dev copy's Accessibility grant away; while it carried `.dev`, it did exactly that.
- `./scripts/clean-dev-artifacts.sh` reports stray copies; `--fix` removes them.
- When diagnosing a permission report, read `[Install]` in the unified log first:
  `log show --predicate 'subsystem == "com.macclipboard.app"' --last 1h | grep Install`.
  It gives the path, the signing identity, and every duplicate that was found.

## An Upgrade Replaces the Bundle Under the Running App

`brew upgrade --cask` moves the old bundle aside and moves the new one into the same path without
quitting the app. macOS then refuses that still-running process for Accessibility, because the
code identity it recorded no longer matches the binary now at its path, so auto-paste and the
global hotkey stop working while System Settings still shows MacClipboard as enabled. Pinning the
designated requirement does not help here: that keeps the grant valid for the *new* copy, not for
a process whose bundle was swapped. Only a relaunch fixes it.

Do not rely on Homebrew to quit the app first. It decides whether the app is running with a JXA
`Application(id).running()` call (which needs Automation consent for whichever terminal ran
`brew`) and with `launchctl list` labels, and neither reports a menu bar app started as a login
item, so it skips quitting silently. `open -a` does not help either: with the old process alive,
macOS activates that one instead of launching the new bundle.

So the app handles it itself, and the cask backs it up:

- `AppInstallation.wasReplacedInPlace()` compares the running executable's inode *and* code
  directory hash against `launchFingerprint`. Both must differ, so an identical build copied into
  place again does not count, and an unreadable signature mid-upgrade reads as "not yet".
- A 5 second poll in `AppDelegate.startWatchingForInPlaceUpdate` calls
  `relaunchAfterInPlaceUpdate()`, which starts the new copy and quits this one *only* once the
  replacement is up. Dev builds are excluded: `run.sh` replaces them on every build and restarts
  them itself.
- `PermissionManager.Diagnosis.updatedInPlace` is checked before every other case. Never let this
  case fall through to `.staleRecord`: Repair runs `tccutil reset` and would delete a grant that
  works perfectly for the new copy.
- The cask's `uninstall quit:` runs before `signal:`, and its `postflight` ends the old process by
  its executable path and waits for it to exit before `open`. `postflight` comes from the *new*
  cask, so a cask fix reaches users who are still on the old app.

## Editing a Copy Never Touches the Original

Clicking the preview text, `Cmd+E`, or the pencil in the preview toolbar opens a text item in an
editor that takes over the whole popover. Saving writes a *new* item
(`ClipboardMonitor.saveEditedText` → `ClipboardTextEdit`), so history stays a log of what was on the
pasteboard plus copies the user made deliberately. Five things this depends on:

- **Preview and editor are both `NSTextView`s** (`ClipboardTextView`, one representable in two
  modes). A click in the preview has to become a caret at the same character in the editor, and
  neither `Text` nor `TextEditor` can report or set a caret. Two consequences worth keeping:
  automatic quote, dash, replacement and spelling substitutions are all switched off, because a clip
  is data and a curly quote would change what gets pasted; and the callbacks are wired in
  `makeNSView` as well as `updateNSView`, because a click can land before SwiftUI's first update.
  A click only opens the editor when it leaves the selection empty
  (`ClipboardPreviewClick.opensEditor`), so dragging, double clicking and modified clicks still
  select text in the preview. Escape there hands the keyboard back to the list rather than editing.

- **The draft lives on `MenuBarController`, not in `ContentView`.** `showPopover` rebuilds the
  content view controller on every open, and any click outside closes the popover, so SwiftUI state
  would lose an edit the moment the user checked something in another app.
  `ClipboardEditDraftStore` keeps it, `ContentView.restoreEditDraftIfNeeded` picks it up on the next
  open, and while a draft is dirty the click-outside monitor and `togglePopover` refuse to dismiss
  the popover. Nothing is ever saved to history implicitly: the draft either gets saved by the user
  or restored for them.
- **The global key handler must stay out of the way.** `handleKeyEvent` returns straight into
  `handleEditorKeyEvent` while editing. `performKeyEquivalent` reaches `KeyEventView` whatever holds
  first responder, so without that, `Cmd+Backspace` would offer to clear the history instead of
  deleting to the start of a line, a digit would jump the selection, and `Cmd+V` would toggle a
  reveal instead of pasting. Escape arrives via `.onExitCommand` on the editor, because the key
  handler sits in a sibling branch of the view tree and only sees key equivalents.
- **First responder has to be handed back.** `KeyEventHandler.focusToken` is bumped when the editor
  closes; nothing else gives the responder back, and arrows and Enter stay dead until it is.
- **Masking can only be gained.** The edited text is re-run through
  `ClipboardSensitivityPolicy.flags` and or-ed with the source's own `isSensitive`, and a masked
  item cannot be edited at all until it is revealed. Content is never trimmed (whitespace in a clip
  is content, unlike in a note), and favorite and note are not inherited.

## Managed Objects Never Leave Their Context

`PersistenceManager.performOnContext` runs on the background context's queue, and what it returns
must be value types only. Handing a `PersistedClipboardItem` back and reading a property on the
caller's thread faults the row in from the wrong thread, corrupts the context's object graph, and
crashes the *context* queue later inside `-[NSManagedObjectContext _processRecentChanges:]`, with
a backtrace pointing nowhere near the cause. That shipped in 0.1.16: `loadClipboardHistory` and
`loadImageData` both did it, and `compactImageStorage`'s `refreshAllObjects()` between batches
made it fatal on the first launch after upgrading, which is the one launch that migration runs.

Convert to `ClipboardItem` (a struct), or read the bytes, inside the block. The shared scheme
passes `-com.apple.CoreData.ConcurrencyDebug 1`, so a violation now traps in Debug at the point of
access; keep that argument.

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
| `Cmd+E` | Edit a copy of a text item |
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

While the editor is open: `Cmd+S` saves as a new item, `Cmd+Enter` saves and pastes, `Enter` adds a
line, `Escape` cancels. Nothing else in the table applies (see below).

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

When modifying the editor:
- [ ] Clicking the preview text opens it with the caret where the click landed
- [ ] Dragging over the preview text selects it and does not open the editor; Cmd+C copies it
- [ ] Cmd+E and the pencil open it; all three are unavailable on images, files, and masked items
- [ ] Enter adds a line, Cmd+S saves, Cmd+Enter saves and pastes, Escape cancels (with a confirm
      once the text has changed)
- [ ] Cmd+A, Cmd+C, Cmd+V, Cmd+X, Cmd+Z and Cmd+Backspace behave as text editing, not as the
      popover's shortcuts
- [ ] Saving adds a new item at the top, selects it, and leaves the original as it was
- [ ] Saving an edit that matches an existing item says so instead of adding a duplicate
- [ ] Type, close the popover with the X or the hotkey, reopen: the edit comes back
- [ ] Type, then click another app: the popover stays open
- [ ] Arrows and Enter still work in the list after cancelling or saving an edit
- [ ] An edit of a hidden item is hidden too

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
| Change the copy editor | `ContentView.swift` (`ClipboardTextEditorView`), `ClipboardMonitor.swift` (`ClipboardTextEdit`), `MenuBarController.swift` (`ClipboardEditDraftStore`) |
| Modify menu bar behavior | `MenuBarController.swift` |
