# MacClipboard Backlog Archive

Completed backlog tasks move here from `BACKLOG.md`. Keep newest completions at the top.

## Archive Format

Use this format for each completed item:

```markdown
### YYYY-MM-DD - Task title

- Source: P0/P1/P2 from `BACKLOG.md`
- Summary: What changed and why.
- Verification: Build, test, or manual check used.
```

## Completed Tasks

### 2026-07-13 - Fix stale/mismatched row labels and note field in clipboard list

- Source: Bug report (masked item showed another item's note label, e.g. "GDL Almere PWD" instead of "Google Keystore Pwd"; self-corrected after switching items several times).
- Summary: Root cause was `ForEach(0..<filteredItems.count, id: \.self)` in `ContentView.clipboardListView`, which identifies rows by index over a dynamic array. Inside `LazyVStack` this let SwiftUI reuse recycled rows with stale `item.note` (masked rows render the note as a hint), so a credential label from one item leaked onto another. Switched to `ForEach(Array(filteredItems.enumerated()), id: \.element.id)` for stable UUID identity, simplified the row `.id()` and `scrollTo` targets to the item UUID, made `ClipboardFilter.filteredItems` sort stable (explicit original-index tiebreaker so equal-score items no longer reshuffle on each recompute), and gave the compact preview `.id(selectedItem.id)` so `editingNote` re-initializes reliably per item.
- Verification: `make dev` (Debug build succeeded). Manual: labels now stay pinned to the correct item across rapid selection switches.

- Source: P1 from `BACKLOG.md`
- Summary: Extracted compact preview rendering into `ClipboardCompactPreviewView`, moved deletion confirmation alerts into a dedicated view modifier, and added unit coverage for deletion confirmation copy/state.
- Verification: `xcodebuild test -project MacClipboard.xcodeproj -scheme MacClipboard -configuration Debug -destination 'platform=macOS'`

### 2026-07-04 - Improve accessibility and localization readiness for user-facing strings

- Source: P1 from `BACKLOG.md`
- Summary: Added a shared `L10n` wrapper for AppKit menus, alerts, window titles, update messages, and update errors; kept SwiftUI filter/empty-state text on localized keys; added accessibility labels for key icon-only clipboard controls and the menu bar button.
- Verification: `xcodebuild test -project MacClipboard.xcodeproj -scheme MacClipboard -configuration Debug -destination 'platform=macOS'`

### 2026-07-04 - Normalize formatting and indentation in app startup and menu-bar code

- Source: P2 from `BACKLOG.md`
- Summary: Fixed inconsistent indentation in startup/accessibility permission code and removed an empty status-item branch in menu-bar setup.
- Verification: `xcodebuild test -project MacClipboard.xcodeproj -scheme MacClipboard -configuration Debug -destination 'platform=macOS'`

### 2026-07-04 - Replace ad-hoc update checking with a privacy-conscious update service abstraction

- Source: P1 from `BACKLOG.md`
- Summary: Moved GitHub release checking into `UpdateService`, added cancellation, rate-limit handling, release URL parsing, and XCTest coverage with a stubbed URL protocol.
- Verification: `xcodebuild test -project MacClipboard.xcodeproj -scheme MacClipboard -configuration Debug -destination 'platform=macOS'`

### 2026-07-04 - Respect the hotKeyEnabled preference at runtime

- Source: P1 from `BACKLOG.md`
- Summary: `MenuBarController` now observes `UserPreferencesManager.hotKeyEnabled`, registers the global hotkey only when enabled, unregisters it immediately when disabled, and cleans up the Carbon event handler.
- Verification: `xcodebuild build -project MacClipboard.xcodeproj -scheme MacClipboard -configuration Debug -destination 'platform=macOS'`

### 2026-07-04 - Fix Settings links and preference range mismatches

- Source: P1 from `BACKLOG.md`
- Summary: Settings now opens the MacClipboard repository URL and uses the same 10MB-10GB storage bounds as `UserPreferencesManager`.
- Verification: `xcodebuild build -project MacClipboard.xcodeproj -scheme MacClipboard -configuration Debug -destination 'platform=macOS'`

### 2026-07-04 - Reset selection focus when switching clipboard filter tabs

- Source: P1 from `BACKLOG.md`
- Summary: Filter tab changes now reset stale selection and force the list identity to refresh so the next list opens from the top instead of preserving an off-screen item.
- Verification: `xcodebuild build -project MacClipboard.xcodeproj -scheme MacClipboard -configuration Debug -destination 'platform=macOS'`

### 2026-07-04 - Standardize logging and remove direct print calls from production paths

- Source: P1 from `BACKLOG.md`
- Summary: Removed the remaining direct debug `print` call from `ContentView`; runtime diagnostics now route through `Logging`.
- Verification: `xcodebuild build -project MacClipboard.xcodeproj -scheme MacClipboard -configuration Debug -destination 'platform=macOS'`

### 2026-07-04 - Remove dead or duplicate helper code

- Source: P2 from `BACKLOG.md`
- Summary: Removed the unused duplicate four-character-code helper and deleted unreferenced legacy placeholder source files.
- Verification: `xcodebuild build -project MacClipboard.xcodeproj -scheme MacClipboard -configuration Debug -destination 'platform=macOS'`

### 2026-07-04 - Add a lightweight manual release smoke-test checklist

- Source: P2 from `BACKLOG.md`
- Summary: Added `docs/RELEASE_SMOKE_TEST.md` and linked it from the development guide before distribution builds.
- Verification: Documentation review and `xcodebuild test -project MacClipboard.xcodeproj -scheme MacClipboard -configuration Debug -destination 'platform=macOS'`

### 2026-07-04 - Document privacy boundaries for clipboard data and update checks

- Source: P2 from `BACKLOG.md`
- Summary: Updated README and developer docs to clarify local-only clipboard storage and the explicit GitHub update-check network call.
- Verification: Documentation review and `xcodebuild test -project MacClipboard.xcodeproj -scheme MacClipboard -configuration Debug -destination 'platform=macOS'`

### 2026-07-04 - Add automated coverage for sensitive-content detection

- Source: P0 from `BACKLOG.md`
- Summary: Added XCTest coverage for API keys, password-like strings, common false positives, large-text pattern limits, and preference-policy interactions.
- Verification: `xcodebuild test -project MacClipboard.xcodeproj -scheme MacClipboard -configuration Debug -destination 'platform=macOS'`

### 2026-07-04 - Add automated coverage for clipboard history metadata preservation

- Source: P0 from `BACKLOG.md`
- Summary: Extracted duplicate-history insertion into a pure helper and added tests for duplicate text, image, and file captures preserving metadata and moving to the top only when appropriate.
- Verification: `xcodebuild test -project MacClipboard.xcodeproj -scheme MacClipboard -configuration Debug -destination 'platform=macOS'`

### 2026-07-04 - Move persistence work onto a dedicated Core Data background context

- Source: P0 from `BACKLOG.md`
- Summary: Moved persistence operations off the main view context and onto a dedicated private-queue Core Data context; startup history loading now fetches away from the main thread.
- Verification: `xcodebuild test -project MacClipboard.xcodeproj -scheme MacClipboard -configuration Debug -destination 'platform=macOS'`

### 2026-07-04 - Replace Core Data fatalError with graceful recovery

- Source: P0 from `BACKLOG.md`
- Summary: Replaced persistent-store load termination with temporary in-memory storage, diagnostics, and a user-visible reset-and-quit recovery path.
- Verification: `xcodebuild test -project MacClipboard.xcodeproj -scheme MacClipboard -configuration Debug -destination 'platform=macOS'`
