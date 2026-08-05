# MacClipboard Backlog

Goal: make MacClipboard the best clipboard manager app for macOS. Every task here should improve reliability, speed, privacy, usability, or maintainability.

Move completed items to `BACKLOG_ARCHIVE.md` with the completion date and a short note about what changed.

## Priority Tasks

### 1. No test seam for the store, so favorite protection cannot be regression tested

`PersistenceManager` is a singleton bound to the real store path and `ClipboardMonitor.init` loads
from it, so a test that constructs either one reads and writes the user's actual history. That is
why the favorite-protection guarantees added alongside this entry are covered only indirectly, by
`FavoritesExportTests`, and why the bulk-delete predicate is enforced structurally
(`bulkDeleteNonFavorites`) rather than by a test.

Done means: an injectable persistence type backed by an in-memory store in tests, plus tests that
assert favorites survive `cleanupOldItems`, `clearAllData`, and storage-pressure eviction, and
that `addToHistory` never leaves a re-copied item with no row on disk. Any test touching
persistence must be unable to reach the real store.

### 2. The DMG is notarized and stapled but never code signed

`build.sh` hands the disk image straight from `create-dmg` to `notarytool` and `stapler`, with no
`codesign` step, so the container carries a valid notarization ticket and no signature of its own:

```
xcrun stapler validate build/MacClipboard-Installer.dmg   # The validate action worked!
spctl -a -t open --context context:primary-signature -vv  # rejected: no usable signature
```

Pre-existing, not a regression: v0.1.15's DMG behaves the same. The app inside is correct
(`accepted`, `source=Notarized Developer ID`, hardened runtime, ticket stapled), which is what
users actually run, and the stapled ticket is what Gatekeeper checks when the image is opened. So
this is a gap against Apple's guidance rather than a broken download.

Done means: `codesign --sign "$DEVELOPER_ID"` on the DMG before submitting it, and the `spctl`
assessment above passing, added to the release pre-flight so it cannot regress silently.

### 3. Orphaned external image files from before object deletion

Deletes now go through the context so Core Data removes the external file behind `imageData`, but
stores written before that change can still hold orphans. One measured store had 8 files totalling
49 MB with no row referencing them, from rows deleted months earlier.

A sweep is awkward with public API: Core Data keeps the external file name inside the `imageData`
blob, and reading that attribute faults the file in rather than revealing the name, so identifying
which files are referenced means parsing a private format. Not worth the risk of deleting a live
image, and after PNG storage an orphan costs a fortieth of what it used to.

Done means: either an approach that identifies referenced files without depending on Core Data
internals, or a decision to leave orphans alone and remove this entry.

