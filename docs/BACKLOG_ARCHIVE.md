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

### 2026-08-05 - Make dev and release builds coexist, and make a stale Accessibility grant recoverable

- Source: Bug report (after `brew upgrade --cask macclipboard` from 0.1.12 to 0.1.13, two menu bar icons were running and the release build showed the "Accessibility permission required" banner while System Settings showed MacClipboard switched on).
- Summary: The reported failure was environmental, not a regression in 0.1.13. Before commit `9b31749`, `run.sh` copied the debug build to `~/Applications/MacClipboard-Dev.app` while keeping bundle id `com.macclipboard.app` and re-signing with the self-signed "MacClipboard Dev" certificate, so the TCC record for that bundle id ended up pinned to the dev certificate. macOS keys an Accessibility grant on bundle id *and* the code signing requirement recorded at grant time, so the row kept reading as enabled while tccd refused the Developer ID signed Homebrew build; the upgrade only made it visible by restarting that build. Verified the shipped app is otherwise healthy (`codesign --verify`, satisfies its DR, notarised and stapled, `spctl` accepted, DR unchanged from 0.1.12). Repaired locally with `tccutil reset Accessibility com.macclipboard.app`. Then closed the gaps that made it possible and hard to diagnose: added `BuildInfo` as the single Dev/Release check plus `GlobalHotkey` (dev builds use `Cmd+Shift+Opt+V`, since `RegisterEventHotKey` is first-come-first-served and the loser previously failed silently); surfaced a hotkey-conflict banner; badged the build channel in the Settings footer and the popover header, the menu bar icon (filled for dev) and its tooltip; added stale-grant detection (`accessibilityWasGrantedV1`) with a one-click Repair that runs `tccutil reset` for our own bundle id and re-arms the one-shot prompt; gave dev builds their own Core Data store, because `NSPersistentContainer.defaultDirectoryURL()` resolved to the same folder for both builds and both processes genuinely held write handles on one SQLite file (confirmed with `lsof`); routed `Logging.info` to the unified log at `notice` level so an installed build can be inspected after the fact, keeping `Logging.debug` on stdout only since it can reference clipboard content; handled SIGTERM through `NSApp.terminate` so the cask's `uninstall signal:` no longer kills the app before Core Data is flushed; asked older same-bundle-id instances to quit at launch; and fixed `build.sh`, whose pinning re-sign used `codesign --force` without `--entitlements` and had therefore been shipping every release with no entitlements at all, with a post-sign check that fails the build if entitlements are missing or debug-only `get-task-allow` is present. Also narrowed `run.sh`'s `pkill -f MacClipboard`, which killed the user's installed release copy too, and added `--version=`/`--notes=` to `build.sh` so a release can run non-interactively.
- Verification: `xcodebuild build` (Debug, succeeded); `xcodebuild test` (18 tests, TEST SUCCEEDED); `bash -n build.sh run.sh`; `./run.sh` then confirmed via `lsof` that the dev build holds 4 handles on `~/Library/Application Support/MacClipboard (Dev)/ClipboardData.sqlite` and 0 on the release store, and via `/usr/bin/log show --predicate 'subsystem == "com.macclipboard.app.dev"'` that it logged `[App] Launched Dev build ...` and `[AX][launch] trusted=true`.

### 2026-07-21 - Persist "most recently used at top" ordering across app restarts

- Source: Bug report (favorites ordered by latest used at top reverted to creation-date order after a Mac reboot; user expected reboot not to change ordering).
- Summary: The use-order was only ever kept in memory. `ClipboardMonitor.copyToClipboard` moves a pasted item to the front of the in-memory array, but nothing wrote that to disk, and `PersistenceManager.loadClipboardHistory` rebuilt the list sorted purely by `createdAt`, so every restart discarded the last-used order (not a regression, just first surfaced on reboot). Added an optional `lastUsedAt` Date attribute to `PersistedClipboardItem` (lightweight inferred migration, nil for legacy rows), seeded it with the creation time on save, added `PersistenceManager.markItemUsed(itemId:)` (sets `lastUsedAt = Date()` without touching `createdAt`/`updatedAt`, so "time ago" still reflects capture time), called it from `copyToClipboard` after the in-memory move, and changed the load sort to order by `lastUsedAt ?? createdAt` descending. Applies going forward; existing history has no historical use times so it falls back to `createdAt` until each item is next used.
- Verification: `make dev` (Debug build succeeded).

### 2026-07-13 - Stop the accessibility permission prompt from repeating endlessly

- Source: Bug report (native "would like to control this computer" dialog reappeared every time the user returned from System Settings, even though MacClipboard was already enabled there; user runs both a Homebrew build and a local ./run.sh build).
- Summary: `AXIsProcessTrustedWithOptions(prompt: true)` re-shows the system dialog on every call while the process is untrusted, so calling it on each launch (and in the paste path) spammed the user, made worse by detection failing when the granted entry belonged to a different-signature build. Gated the launch-time system prompt to fire at most once ever (UserDefaults `hasRequestedAccessibilityPromptV1`), removed the native prompt from `simulatePasteKeypress` (content is already on the clipboard for manual Cmd+V; the popover banner guides the user), and removed the now-unused `didAttemptAXPrompt`. Root environmental cause was the Homebrew and `./run.sh` builds sharing bundle id `com.macclipboard.app` with different code signatures, colliding in TCC; `run.sh` now rewrites the dev copy to bundle id `com.macclipboard.app.dev` / name "MacClipboard Dev" before signing so it gets its own persistent accessibility grant, and added an opt-in `./run.sh --reset-permissions` flag (`tccutil reset Accessibility com.macclipboard.app.dev`) for clearing a stale grant on demand (not run by default, to preserve persistence).
- Verification: `make dev` (Debug build succeeded); `bash -n run.sh` (syntax OK).

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
