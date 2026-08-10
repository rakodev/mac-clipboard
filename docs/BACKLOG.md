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
selection into one clip), task 10 (splitting one clip into a line per item), task 11 (a swatch on a
clip that is a colour), task 12 (reading the text in a copied image) and task 13 (a light and dark
override) were completed on 2026-08-10.

### 14. A clip does not record which app it came from

Raised in external feedback on the backlog post, 2026-08-10, alongside task 15. The pasteboard
carries no author: `NSPasteboard` has no metadata saying which process wrote a clip, so the only
way to know is to sample `NSWorkspace.shared.frontmostApplication` at the moment the change is
noticed. `checkClipboard` already does exactly that, once, inside `captureDecision(for:)`, and
throws the answer away as soon as the exclusion check has run. `PersistedClipboardItem` has no
attribute for it.

The value is that a history list is scanned by source before it is read: an icon and an app name
say "that is the thing I copied out of Slack" faster than the first line of text does, and it gives
a filter worth having on a long history.

Two scoping calls. Store the **bundle identifier only**, as `excludedBundleIdentifiers` does, and
resolve the name and the icon at display time the way `ExcludedAppRow` already does, so an app the
user has since uninstalled still reads correctly and no icon bytes reach the store. And capture it
on the **same read** that feeds the capture decision rather than a second call, so the guard and the
recorded source can never disagree about which app was in front.

The known limit carries over unchanged: with 0.8 s polling the frontmost app is a good guess, not a
fact, and the rule in `CLAUDE.md` stands, so do not layer `didActivateApplicationNotification`
history on it to sharpen the guess. Task 15 is the honest way to narrow the window. A row showing
the wrong app is the new failure this task introduces, which is why the two belong together.

Done means: an optional attribute on `PersistedClipboardItem` with a lightweight migration; the
identifier captured on the existing read; name and icon resolved at display time; a way to filter or
search by source app; nothing shown at all for clips captured before this change, for a process with
no bundle identifier, and for items the user made themselves (an edit, a merge, a split), since
those have no source; and tests covering the no-frontmost-app case.

### 15. The polling interval is a literal, and a second copy inside one tick is lost

Raised in the same feedback as task 14. `startMonitoring` builds `Timer(timeInterval: 0.8,
repeats: true)`. `changeCount` moves once per write, so two copies inside the same 800 ms window
leave it higher by more than one while the pasteboard holds only the later clip. The earlier one is
unrecoverable, and nothing anywhere says it happened, so the loss is invisible in use and
unmeasured in development.

Two parts, and the first is worth having on its own. **Make the drop observable**: compare the delta
against the last seen count and log when it is greater than one, so how often this really happens
becomes a measurement rather than an argument. **Then pick the interval on evidence**, either a
shorter fixed tick or one that runs fast while the user is active and backs off when they are not.

The scoping call: this is not a preference. A slider asks the user to trade responsiveness against
battery on numbers they cannot see, and a menu bar app pays for every pixel of UI. Whatever is
chosen should live in one named place instead of a literal inside `startMonitoring`.

What makes a shorter tick affordable is that reading `changeCount` is cheap while reading the
pasteboard's contents is not, and the current shape already only reads contents once the count has
moved. A Universal Clipboard item can make that read slow, so keep the fast path fast and leave the
work where it is.

Done means: the interval named in one place; a debug log when `changeCount` jumps by more than one;
an idle cost measurement at the chosen interval, recorded in `docs/DEVELOPMENT.md`, rather than a
number picked by feel; the pause path still adopting the pasteboard's count before the timer
restarts (`ClipboardCapturePause.changeCountOnResume`, which is what stops a resume capturing the
clip the user paused to avoid); and the pending-capture retry unchanged.

