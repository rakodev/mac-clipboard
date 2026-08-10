# MacClipboard Backlog

Goal: make MacClipboard the best clipboard manager app for macOS. Every task here should improve reliability, speed, privacy, usability, or maintainability.

Move completed items to `BACKLOG_ARCHIVE.md` with the completion date and a short note about what changed.

## Priority Tasks

Task 1 (the missing test seam for the store) and task 2 (the unsigned DMG) were both completed on
2026-08-09; see `BACKLOG_ARCHIVE.md`. The numbers here are stable identifiers, as in the product
section below, so a completed task leaves a gap rather than renumbering the entries under it.

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
meaning the task it meant. Task 5 (capture exclusions), task 4 (pausing capture), task 6
(deleting the store persistence left behind), task 7 (a configurable global hotkey) and task 8
(keeping the formatting a clip was copied with) were all completed on 2026-08-09. Task 9 (merging a
selection into one clip) and task 10 (splitting one clip into a line per item) were completed on
2026-08-10.

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

