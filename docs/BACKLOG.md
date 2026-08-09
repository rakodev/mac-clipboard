# MacClipboard Backlog

Goal: make MacClipboard the best clipboard manager app for macOS. Every task here should improve reliability, speed, privacy, usability, or maintainability.

Move completed items to `BACKLOG_ARCHIVE.md` with the completion date and a short note about what changed.

## Priority Tasks

Task 1 (the missing test seam for the store) was completed on 2026-08-09; see
`BACKLOG_ARCHIVE.md`. The numbers here are stable identifiers, as in the product section below, so
it leaves a gap rather than renumbering the entries under it.

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

Seen again on 2026-08-09 while verifying task 6: clearing a dev store of 348 items down to 3
favorites took the external files from 35 to 5, where 2 images survived. Object deletion removed the
30 it was responsible for, so the remainder is the pre-existing orphan set rather than a new leak.

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
meaning the task it meant. Task 5 (capture exclusions), task 4 (pausing capture) and task 6
(deleting the store persistence left behind) were all completed on 2026-08-09.

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

