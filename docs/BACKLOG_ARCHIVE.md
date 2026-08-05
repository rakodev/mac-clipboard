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

### 2026-08-05 - Upgrading broke Accessibility for every user, and the 0.1.16 migration could crash on launch

- Source: Bug report ("still permission issue after upgrade", after `brew upgrade --cask macclipboard` 0.1.15 to 0.1.16). The reporter's concern was other users hitting the same thing, which they do: both faults below are on the upgrade path, not specific to a development machine.
- Summary: Two separate defects, found from the reporting machine's own unified log. **First, the upgrade breaks Accessibility for the instance that is running.** The log is unambiguous: PID 57425 launched from `/Applications` at 19:46 as 0.1.15 with `trusted=true duplicates=[]`, and at 22:49, with no user action but the upgrade in between, the same PID reported Accessibility denied; a fresh process from the same path then logged `trusted=true` immediately, with no TCC change at all. `brew upgrade --cask` moves the old bundle aside and moves the new one into the same path without quitting the app, and macOS stops honouring the running process because the code identity it recorded no longer matches the binary now at its path. Pinning the designated requirement (which the release does) does not help: it keeps the grant valid for the *new* copy, not for a process whose bundle has been swapped. Homebrew is supposed to quit the app first and did not, and cannot be relied on to: `Cask::Artifact::AbstractUninstall` decides whether the app is running via a JXA `Application(id).running()` call, which needs Automation consent for the calling terminal, and via `launchctl list` labels, and neither reports a menu bar app started as a login item, so it silently skipped both the cask's `signal:` directive and its own upgrade-quit. The user's upgrade output shows no `Quitting application` and no `Signalling 'TERM'` line. Worse, the cask's `postflight` then ran `open -a`, which with the old process still alive just activates that process, so the user is left on the copy macOS refuses, and the banner blamed a stale TCC record and offered Repair, i.e. `tccutil reset` of a grant that was working. Fixed on both sides. In the app: `AppInstallation.BinaryFingerprint` records the running executable's inode and code directory hash at launch, `wasReplacedInPlace()` reports when a *different* build has taken our path (inode change alone is not enough, so re-copying an identical build does not trigger it, and an unreadable signature mid-upgrade reads as "not yet"), a 5 second poll in `AppDelegate` watches for it, and `relaunchAfterInPlaceUpdate()` starts the new copy and quits this one only once the replacement is actually up, so a bundle that cannot launch leaves the user with a working app rather than nothing. This works for every install method, including a drag from the DMG. `PermissionManager.Diagnosis` gained `.updatedInPlace`, checked before every other case, so the banner says "MacClipboard was updated and needs to restart" with a Restart button instead of offering to delete a good grant. In the cask: `uninstall quit:` is restored ahead of `signal:` (it was removed in tap commit 6214210 over a cosmetic warning that modern Homebrew no longer prints, since it checks `running?` first), and `postflight` now ends the old process by its executable path and waits for it to actually exit before `open`. That part fixes the upgrade for users already on 0.1.16, because `postflight` comes from the new cask. **Second, `compactImageStorage` could crash the app seconds after launch.** A crash report from 22:59:14 (0.1.16, five seconds after launch, `EXC_BAD_ACCESS` at `0x7370616e5344435f`, which is the ASCII of a `_CDSnapshot` name) sits inside `-[NSManagedObjectContext _processRecentChanges:]` on the background context's own queue. The cause: `loadClipboardHistory` and `loadImageData(for:)` both returned `PersistedClipboardItem` objects out of `performOnContext` and then read their properties on the caller's thread. The one-time 0.1.16 image re-encoding made that reliably fatal, because it calls `refreshAllObjects()` between batches, dropping the snapshot behind a row the UI is still reading, and it runs exactly once per install: on the first launch after upgrading. Both now convert to `ClipboardItem` (a struct) or read the bytes inside the block, `performOnContext` documents the invariant, and the shared scheme passes `-com.apple.CoreData.ConcurrencyDebug 1` so any future off-queue access traps where it happens instead of corrupting the graph and crashing elsewhere. Also cleaned up the noise that made this report harder to read: `build.sh` now archives into `build/DerivedDataRelease` and removes it afterwards, so a release build no longer leaves a bundle carrying the release id in the shared DerivedData for LaunchServices to register as a duplicate install, and it finishes by running `clean-dev-artifacts.sh` in report mode. That script no longer calls a dev-id build product under the repo's own `build/` a stray.
- Verification: `xcodebuild build` (Debug, BUILD SUCCEEDED); `xcodebuild test` (36 tests, 0 failures, TEST SUCCEEDED), including seven new `InPlaceUpdateDetectionTests` covering the decision table (different file and identity is a replacement; untouched bundle, identical build recopied, unreadable signature, and missing file are not) and that a real signed bundle yields a usable fingerprint with a code hash; `bash -n build.sh scripts/clean-dev-artifacts.sh`; `ruby -c` plus `brew style --cask` on the cask in a real tap (only the pre-existing `desc` platform offence remains, and the tapped checkout was restored clean). The mechanism itself was established from the machine's own evidence rather than inferred: replicating brew's replacement with a byte-identical bundle under the running app deliberately did *not* break trust, which is what confirms the trigger is a change of code identity at our path and not the replacement itself. Machine state was also repaired: the ad hoc 0.1.15 Release build product in the shared DerivedData and a verification copy left in a scratch directory were unregistered and deleted, the copy in the Trash was unregistered, and the app now logs `trusted=true ... duplicates=[]` from `/Applications`.
- Verified end to end on the real upgrade, after releasing 0.1.17: with 0.1.16 running as PID 99451, `brew upgrade --cask macclipboard` logged `[App] Received SIGTERM, shutting down cleanly` for that PID (the new cask's postflight, since the old 0.1.16 cask had no `quit:` and Homebrew's own quit again said nothing), and the replacement came up as `[App] Launched Release build 0.1.17 (29)` with `[AX][launch] trusted=true` and `duplicates=[]`. That is the exact sequence that was broken. One observation worth keeping: the replacement took 92 seconds to reach `applicationDidFinishLaunching`, so the menu bar icon was missing for that long. A plain relaunch of the same bundle immediately afterwards checked in in 0.086 seconds, and the log shows syspolicyd opening a TLS connection at exec time while XProtect finished in 30ms, so it is the one-time Gatekeeper notarisation check on a bundle Homebrew has quarantined, not our code. Tracked in `FOLLOWUPS.md`.
- Note on reach: the app-side watcher only protects upgrades made *from* 0.1.17 onward, since the process that has to notice the replacement is the old one. The cask fix is what covers everyone still on 0.1.16 or earlier, because `postflight` comes from the new cask.

### 2026-08-05 - Store images compressed, and give them their own retention window

- Source: P1 from `BACKLOG.md` (the storage limit silently capping history), plus the question of whether images should be managed differently from text.
- Summary: Measured a real 1859-item store first: 1683 text clips came to 717 KB, while 176 images came to 1.2 GB. The cause was not retention at all. `saveClipboardItem` stored `image.tiffRepresentation`, and AppKit writes TIFF uncompressed (`compression=none`, `bps=9`), averaging 7 MB per screenshot. Re-encoding 13 sampled stored images as PNG took 120 MB to 3.0 MB, about 40x smaller, losslessly. So: images are now stored as PNG (`NSImage.clipboardStorageData`, falling back to TIFF if re-encoding fails, since keeping the image beats keeping it small), and `compactImageStorage` re-encodes an existing history once per install, in batches of five with a refresh between so peak memory stays a few images, guarded by `imageStorageCompacted` and only replacing a blob when the PNG decodes and is smaller. Retention is now split: `persistenceDays` for everything and a new, shorter `imagePersistenceDays` (default 30) for images alone, via `cleanupOldItems(olderThan:scope:)`. File items deliberately follow the text window, because a file clip stores only its paths and so costs about a line of text. The broken storage-limit behaviour is gone: instead of halving the retention window once (which could never reach the limit, and just kept history at half the requested age every hour, for ever), `evictImagesUntilWithin(byteLimit:)` drops oldest non-favorite images until the store actually fits, and `getStorageSize` now stats the store directory rather than faulting every external image in to add up its length, which was moving over a gigabyte per hourly pass. Bulk deletes switched from `NSBatchDeleteRequest` to batched object deletion, because a batch delete runs straight against the store and never tells Core Data to remove the external image files: that store still held 8 orphaned files (49 MB) from rows deleted months earlier, so deleting images to reclaim space could reclaim nothing. Favorites stay exempt from every automatic path.
- Verification: `xcodebuild test`, 30 tests, TEST SUCCEEDED. New tests assert stored bytes carry the PNG signature and are smaller than the TIFF for the same pixels while still decoding, that PNG re-encoding is idempotent and rejects non-image bytes, and that image cleanup's predicate cannot reach text or file items. The 40x figure and the 717 KB / 1.2 GB split are measurements from the reporting machine's own store, not estimates.

### 2026-08-05 - Detect duplicate installs and bad install locations, which is what actually breaks Accessibility

- Source: Bug report (the permission banner appeared on a fresh launch while System Settings showed MacClipboard enabled; Spotlight listed six entries called MacClipboard).
- Summary: The reported machine had four copies registered under `com.macclipboard.app`: the notarised release in `/Applications` (0.1.14, Developer ID K542B2Z65M), an ad hoc signed 1.0 build from October in `~/Applications`, the Xcode Debug build, and the exported bundle left in `build/export`. tccd logged `Failed to match existing code requirement`, since the TCC record pins the Developer ID requirement while the copy being launched was ad hoc, so it was refused with the switch still showing as on. Three copies were also running at once. Fixes: new `AppInstallation` reports this copy's path, signing identity (ad hoc detected through `SecCodeCopySigningInformation`), Gatekeeper translocation, read-only volume, whether it is in an Applications folder, and every other registered copy through LaunchServices, ignoring translocated paths, Trash and read-only volumes; at launch the app offers to move itself into Applications when it is translocated, on a disk image or loose, and otherwise raises duplicate copies once per distinct set of paths with Show in Finder and Move Others to Trash; the same state is shown persistently under Settings > Installation for anyone who dismissed the alert. `PermissionManager` now distinguishes not-granted from a stale record from another copy owning the grant (`Diagnosis`), so the banner stops giving the dead-end "enable it in System Settings" advice, and treats an ad hoc signature as a stale record rather than waiting to have seen a working grant first; the copy scan is cached for 30s because it walks LaunchServices and reads signatures. `terminateOtherInstances` escalates from the quit Apple event (which macOS had silently dropped, leaving two instances live) to SIGTERM, then `forceTerminate`. The Debug configuration now builds with bundle id `com.macclipboard.app.dev` and display name "MacClipboard Dev", so running from Xcode can no longer contend for the release TCC record and dev artifacts are tellable apart in Spotlight; `run.sh` still rewrites the id for its own copy. `PRODUCT_NAME` deliberately stays `MacClipboard` so the test target's `TEST_HOST` keeps resolving. Because the test host shares the Debug bundle id, `applicationDidFinishLaunching` now detects an XCTest host (`XCTestConfigurationFilePath` and friends) and skips both the instance takeover and the installation alerts, which otherwise made `xcodebuild test` quit the dev build a developer was using. `build.sh` deletes and unregisters the loose `build/export/MacClipboard.app` after packaging it into the ZIP and DMG, since that copy was itself a registered duplicate (`--keep-export` opts out). Added `scripts/clean-dev-artifacts.sh` to report or remove stray copies and DerivedData from the old ClipboardManager project name.
- Verification: `xcodebuild build` Debug and Release (both succeeded); `xcodebuild test` (18 tests, TEST SUCCEEDED); `bash -n build.sh scripts/clean-dev-artifacts.sh`; ran the app from a temporary bundle id and confirmed `[Install] path=... identity=adhoc inApplications=false translocated=false readOnlyVolume=false duplicates=[]` in the unified log, so the launch hook runs and logs; drove the real detection code from a harness over the machine's own copies, which listed all four with correct versions and identities (`adhoc=true team=-` for the two local builds, `team=K542B2Z65M` for the notarised ones) and chose `/Applications/MacClipboard.app` as the copy to keep; `./scripts/clean-dev-artifacts.sh` flagged exactly the three strays plus the stale `ClipboardManager-*` DerivedData folder, and after `--fix` reported one release copy and one dev copy. Opening the notarised `/Applications` copy then logged `[AX][launch] trusted=true` with no TCC changes at all, confirming duplicates were the whole problem. Finally launched the dev build and ran `xcodebuild test` again: 18 tests passed, the dev build was still running afterwards, and the log shows `[App] Hosting an XCTest bundle; leaving other instances alone`.

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
