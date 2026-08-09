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

## Product Tasks

A batch of feature requests was triaged on 2026-08-09. The ordering below is by value per unit of
risk, not by how often each one was asked for. Two principles decided most of the calls:

- **Privacy is the product.** MacClipboard's claim is that a history of everything you copy stays
  on your own Mac. Anything that weakens that (sync, broad exports) has to earn its place; anything
  that strengthens it (exclusions, honouring concealed clips, not writing to disk) goes near the
  front even when it is small.
- **A menu bar app pays for every pixel of UI.** Features that need a new mode, a new pane, or a
  new mental model were either cut down to a single action on an item the user already has selected
  or moved to `FOLLOWUPS.md`.

What was declined for now, with reasons, is in `FOLLOWUPS.md`: iCloud sync, sequential paste
(the paste stack), per-item tags or groups, and full history import/export.

The numbers are stable identifiers, not positions: a completed task leaves a gap rather than
renumbering the ones below it, so a reference written in `BACKLOG_ARCHIVE.md` or `FOLLOWUPS.md` keeps
meaning the task it meant. Task 5 (capture exclusions) was completed on 2026-08-09.

### 4. No way to pause capture without quitting the app

`ClipboardMonitor.isPausing` exists but is private and only suppresses capture for 0.5 s around an
auto-paste. There is no user-facing control, so the only way to stop recording before typing a
password into a field, screen sharing, or working in a customer's account is to quit the app, which
also gives up the global hotkey and the history that is in memory.

Design notes that matter more than the toggle itself:

- On resume, set `changeCount = NSPasteboard.general.changeCount` before restarting the timer.
  Without it, the first tick after resuming sees a changed count and captures the clip the user
  copied while paused, which defeats the whole feature.
- The paused state must be obvious from outside the popover, so the menu bar icon changes (a
  slashed clipboard), not just a checkmark buried in a menu.
- Persist the state across relaunch, and pair that with the icon above and a line in the popover's
  empty state. A pause that silently lifts at the next login is worse than one the user can see.

Done means: a toggle in the menu bar menu and the popover, a distinct icon while paused, capture
stopped at the top of `checkClipboard`, `changeCount` resynced on resume, the state surviving a
relaunch, and the popover saying it is paused rather than looking like an empty history.

### 6. Turning persistence off leaves the old store on disk, and there is no clear-on-quit option

`persistenceEnabled` guards `saveItemToPersistence` and `loadPersistedHistory`, so switching it off
stops new writes and stops loading at launch. It deletes nothing. A user who turns it off to stop
storing their clipboard still has every clip from before that moment on disk, invisible in the UI,
which is the opposite of what the setting promises. There is also no way to say "keep history while
I work, keep nothing afterwards".

Done means: turning persistence off offers to purge the existing store (confirmed, and honest about
what it removes); a separate "Clear history when MacClipboard quits" preference that runs the same
path the trash button uses, from `applicationWillTerminate` and from the existing SIGTERM handler;
favourites spared, consistent with the guarantee in `CLAUDE.md`, and the toggle's help text saying
so; and the copy admitting that a force quit or a power loss cannot be covered.

### 7. The global hotkey and the in-popover keys are not configurable

`GlobalHotkey` is a hardcoded enum (`keyCode 9`, cmd + shift) registered through Carbon's
`RegisterEventHotKey` in `MenuBarController`, and every in-popover key is hardcoded in
`ContentView` behind one `shortcutsEnabled` on/off switch. Cmd+Shift+V collides with "Paste and
Match Style" in a lot of apps and with other clipboard managers, and a user who hits that collision
has nothing to change.

Scope this to the **global hotkey only**. Rebinding the in-popover keys multiplies the conflict
surface (the editor, the digit shortcuts, the arrow navigation, the reveal key) for a fraction of
the benefit, and `CLAUDE.md`'s editor section shows how carefully that key handling is balanced.

Done means: a shortcut recorder in Settings storing key code plus modifiers; re-registration on
change with the failure from `RegisterEventHotKey` surfaced as "that shortcut is already taken by
another app" rather than a silently dead key; a reset to default; and the dev build keeping a
separate binding so the two copies still cannot fight over one combination.

### 8. Formatting is lost: only plain text is captured and pasted

`getClipboardContent` reads `pasteboard.string(forType: .string)` and `copyToClipboard` writes
`.string` back. Copy a styled paragraph out of a browser, Word or Notes, paste it from MacClipboard,
and it arrives as plain text. For anyone whose clipboard is mostly prose rather than code this is
the most visible difference between MacClipboard and the paid alternatives.

Keep it to one extra flavour: store the pasteboard's RTF representation beside the plain text, and
write both back on paste. Skip HTML in v1; it doubles the storage and the failure modes for a
smaller share of real copies. Bound it the same way text is bounded (skip over 1 MB), and keep
`contentEquals` comparing the plain-text form so deduplication and the merger keep working.

Not in scope: rendering rich text in the preview or the editor. `ClipboardTextView` is an
`NSTextView` deliberately configured as plain text, and `CLAUDE.md` explains why a clip must not
pick up smart quotes or substitutions. Editing a rich item saves a plain-text copy, which is
consistent with editing already producing a new item rather than mutating the original.

Done means: an RTF attribute on `PersistedClipboardItem` with a lightweight migration; both flavours
written on copy; a "Paste as plain text" action with its own key; a marker in the row so a user can
see which items carry formatting; and the size cap and dedupe behaviour covered by tests.

### 9. Multiple selected items cannot be pasted together

`ContentView` already supports multi-select (Cmd+Backspace deletes a selection), so the missing
piece is one action rather than a feature: join the selected text items and put the result on the
pasteboard as a new clip. This is the cheap answer to the "copy several things, paste them into one
place" request, and it lands without a new mode, a new indicator or a new state machine, which is
what the sequential paste stack in `FOLLOWUPS.md` would need.

Done means: a "Copy merged" action with a key and a context menu entry; joining in the order shown
in the list, top to bottom, stated in the UI so it is predictable; a separator that is a newline;
non-text items in the selection either skipped with a count shown or the action disabled, decided
once and applied consistently; and the merged clip entering history as an ordinary new item.

### 10. A multi-line clip cannot be split into separate items

The mirror of task 9, and the same shape: one action on one selected item, no mode. Copy a column of
names out of a spreadsheet, split, then paste them one at a time.

Follow the editor's model exactly: the source item is untouched and the pieces are new items, so
history stays a log of what was on the pasteboard plus copies the user made deliberately. Split on
line endings only, and do not trim the lines. Whitespace inside a clip is content, as
`CLAUDE.md` notes for the editor, and a leading tab is often exactly what the user wants pasted.
Drop empty lines, and refuse or confirm above a sane count (100 lines) so a stray paste of a log file
cannot fill the history in one action.

Done means: the action available only on multi-line text items; the source item unchanged; the
pieces inserted newest-first in reading order so pasting them in order works naturally; the count cap
with a confirmation; and each piece re-run through `ClipboardSensitivityPolicy` so a masked source
cannot produce unmasked pieces.

### 11. A hex colour clip shows no colour

Small and self-contained: when a text clip is exactly a colour (`#RGB`, `#RRGGBB`, `#RRGGBBAA`,
optionally `rgb()`), show a swatch in the row and in the preview. Nothing is stored; it is derived at
display time, so there is no migration and no cost to a history that has none.

The scoping call that keeps this from becoming noise: match only when the whole trimmed clip is a
colour. Matching anywhere in the text would put a swatch on most CSS and most code snippets.

Done means: the pattern and the parse covered by tests (including rejecting near misses like
`#GGHHII` and a 7-character string), a swatch that stays legible in light and dark against the
semantic backgrounds, and no measurable cost per row on a full history.

### 12. Text in a copied image cannot be extracted

Vision's `VNRecognizeTextRequest` runs on device with no network and no extra entitlement, and the
app already targets macOS 13, so this is a much smaller feature than it sounds.

Run it **only when the user asks**, from an action on a selected image, never on capture. OCR on
every screenshot would spend CPU and battery on images that are mostly pasted once and forgotten,
and the storage note in `CLAUDE.md` shows how many images a real history holds.

The result should become a new text item rather than being stuffed into `associatedText`, so it is
searchable, persistable and deletable like anything else, and so the image row keeps meaning "what
was on the pasteboard".

Done means: an action and a key on image items; a progress and failure state for images with no
readable text; the resulting item marked in its note or display so it is clearly derived; UI copy
stating the recognition is on device; and the request kept off the main thread.

### 13. Light and dark follow the system with no way to override

Low value, near-zero cost, listed so it is not mistaken for a larger piece of work. The colour rules
in `CLAUDE.md` mean light and dark already work; the only gap is a user who wants the popover to stay
dark while the system is light. That is a three-way preference driving `NSApp.appearance`.

Not in scope: a theme system, custom accent colours, or anything that would justify hardcoding a
colour and breaking the semantic-colour rule.

Done means: a System / Light / Dark control in Settings, applied at launch and on change, covering
the popover, the settings window and the onboarding window.

