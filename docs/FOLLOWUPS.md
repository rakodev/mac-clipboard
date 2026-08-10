# MacClipboard Follow-Ups

Follow-ups are ideas worth revisiting later, but not committed backlog work yet. Promote an item to `BACKLOG.md` when it has a clear problem statement, priority, and acceptance criteria.

## Future Improvements

- [ ] Show the install location and signing identity in the Accessibility onboarding window, not just in Settings and the popover banner.
  - Why later: the launch alert and Settings > Installation already cover the failure cases; onboarding copy should be revisited as a whole rather than patched.

- [ ] Consider having the Homebrew cask refuse to install while a copy exists outside `/Applications`.
  - Why later: needs care not to break users who deliberately keep the app in `~/Applications`, and cask preflight behaviour should be tested against a real upgrade.

- [x] Evaluate configurable clipboard exclusion rules for apps or content patterns.
  - Promoted to `BACKLOG.md` task 5 on 2026-08-09, split in two: honouring `org.nspasteboard.ConcealedType`
    by not storing the clip at all (no false positives, so it can default on), and a user-managed
    excluded-apps list (a heuristic, so its limits are stated in the UI). Both shipped the same day;
    see `BACKLOG_ARCHIVE.md`.

- [ ] Revisit defaulting `skipConcealedClips` on.
  - It shipped off, at the requester's instruction, so a default install captures what it always
    captured. The backlog entry argued for on: the marker comes from the app that owns the secret, so
    honouring it is not a heuristic and has no false positives. While it is off, a default install
    still stores every password copied out of a password manager in plain text, which is the gap the
    entry was written about.
  - Why later: flipping it changes behaviour for existing installs without them asking, and it loses
    a clip rather than hiding it, so it needs a decision about how an upgrade tells users what
    changed (and possibly a one-time notice) rather than a silent default flip.

- [ ] Consider excluding by window or page rather than by app.
  - An excluded app is all-or-nothing: excluding a browser to cover one banking page also stops
    capture from every other tab. Per-site or per-window rules would be finer.
  - Why later: needs the Accessibility API to read a window title or URL on every capture, which is a
    much larger privacy and reliability surface than reading a bundle identifier, and title matching
    is a heuristic layered on the frontmost-app guess that is already a heuristic.

- [ ] Consider a quick way to exclude a running app, rather than only the file picker.
  - A menu of currently running apps would be a shorter path than choosing a bundle in `/Applications`,
    especially for helper apps that do not live there.
  - Why later: the picker covers the case the backlog asked for, and a running-apps list needs a rule
    for background and agent processes that never own a clip.

- [ ] Find a way to detect a global hotkey another app already owns.
  - `isGlobalHotkeyUnavailable`, the popover banner and the Settings warning are all driven by the
    `OSStatus` from `RegisterEventHotKey`, and that is not the signal it was assumed to be. Measured
    on macOS 26.5 on 2026-08-09 with a throwaway helper holding ⌃⌥N: a second process asking for the
    same combination got status 0, not `eventHotKeyExistsErr`. So the everyday collision, another app
    having got there first, still presents as a key that does nothing, and the banner only fires for
    a registration macOS actually refuses.
  - This predates the recorder shipped as backlog task 7 and is not caused by it. The recorder is the
    remedy either way, since a user who notices a dead key can now change it rather than being stuck,
    which is why the copy points at the recorder rather than at the toggle.
  - Why later: no public API answers "who owns this combination". `CGSGetSymbolicHotKeyValue` covers
    only the system's own hotkeys and is private, and inferring ownership by watching whether a
    press arrives would mean asking the user to press the key, which is a worse experience than the
    problem. Worth revisiting if a public API appears, or if it is worth reading
    `com.apple.symbolichotkeys` to at least catch collisions with macOS itself.

- [x] Consider storing the HTML flavour beside the RTF one.
  - Done on 2026-08-09, as part of backlog task 8 rather than after it. The entry had said "skip
    HTML in v1"; the first real Chrome copy tested against the shipped behaviour showed why that
    could not stand, since Chrome writes `public.html` and no `public.rtf` at all, so every browser
    copy stayed plain. See `BACKLOG_ARCHIVE.md`.

- [ ] Consider RTFD as a third flavour, for a copy with images inline.
  - The only remaining pasteboard type that carries formatting in practice. `ClipboardRichText` is
    shaped for another flavour now, so the code cost is small.
  - Why later: it is a flat attachment bundle, so it usually carries the images themselves and goes
    straight past the 1 MB cap, and a copy containing images is captured as an image item anyway.
    It would need its own size story rather than reusing the one text has.

- [ ] Decide whether the preview should render formatting rather than describe it.
  - Today a formatted item is marked in the row and reads "Formatted" in the preview, and the
    preview text itself is plain. The paid alternatives render it.
  - Why later: `ClipboardTextView` is one `NSTextView` in two modes, and `CLAUDE.md` records why the
    editor half must stay plain (a clip is data; a curly quote would change what gets pasted). Making
    the preview render while the editor does not means two views again, and the click-to-caret
    behaviour that connects them is exactly what a single view bought.

- [ ] Consider whether an exported favorite should keep its formatting.
  - `FavoritesExport` writes `favorites.json` plus `images/`, and a formatted favorite exports as
    plain text, so the export is now lossy in a way it was not before backlog task 8 (there was
    nothing to lose). The recovery story is unaffected: the words come back.
  - Why later: it is a format change to a file the export already promises to keep readable, and it
    would sit better alongside the import that `FOLLOWUPS.md` already says does not exist.

- [ ] Explore richer search ranking and tokenization.
  - Why later: current search is simple and understandable; improve only after measuring pain with larger histories.

- [ ] Consider optional per-item tags or groups beyond notes and favorites.
  - Why later: favorites, notes and search already cover most of what "organise my clips" means, and
    they cost no extra UI. Tags need a create/assign/filter surface in a popover that is already at
    its limit, plus a rule for what happens when a tagged item ages out under `persistenceDays`
    (silently deleting something the user filed away would be a worse bug than not having tags).
    Revisit only if users report favorites plus search failing at scale, and prefer widening the
    filter tabs over a new taxonomy.

- [ ] Investigate a command palette style keyboard workflow.
  - Why later: could make MacClipboard faster for power users, but should not compromise the compact current UI.

- [ ] Explore importing/exporting clipboard history with privacy safeguards.
  - Why later: useful for migration and backup, but needs strong filtering, warnings, and encryption decisions.
  - Where it stands: `FavoritesExport` already writes a zip of `favorites.json` plus `images/`, including
    hidden favorites flagged `"sensitive": true`, with the save panel saying so. So the format exists and
    the hard conversation (an export is a plaintext copy of things the app spent effort hiding) has been
    had once. Extending it to the whole history is mostly a scope change plus a stronger warning.
  - What is genuinely missing is **import**, which does not exist in any form: it needs a decision on
    duplicates against existing rows, on whether imported items keep their original timestamps (and so
    age out immediately under `persistenceDays`), and on trusting a JSON file enough to write its
    contents into the store. Do this after the backlog's product tasks, not instead of them.

- [ ] Consider a first-run guided setup that verifies permissions, shortcut behavior, and persistence.
  - Why later: onboarding exists for Accessibility, but a broader guided setup should be validated against keeping launch lightweight.

- [ ] Research a safer default for sensitive-content auto-detection.
  - Why later: enabling more protection by default is attractive, but false positives and user trust need testing.
  - Partly answered by `BACKLOG.md` task 5: the pasteboard-type half of the detection has no false
    positives, because the source app is declaring the clip confidential, so it can default on. This
    entry now covers only the regex and entropy halves (`matchesSensitivePattern`,
    `looksLikePassword`), where a false positive hides something the user wanted and a false negative
    stores a secret. Measure against a real history before changing their defaults.

- [ ] Sequential paste (a paste stack): select several items, then have each paste take the next one in order.
  - Why later: this is the only requested feature that needs a genuine mode. It has to show where you
    are in the stack while you are in another app (so a HUD or a menu bar count), define what happens
    when you copy something new mid-sequence, when the sequence runs out, and how you leave it early,
    and it has to survive the popover closing since the whole point is that you are typing into a form.
    That is a lot of new surface for a menu bar app.
  - What to do first: `BACKLOG.md` tasks 9 and 10 (merge selected items, split a clip into items) cover
    most of the same jobs at a fraction of the cost. Copying a list, splitting it, and pasting the
    pieces from the popover in order is the same workflow without a mode. Revisit only if users who
    have those two still ask for this.

- [ ] iCloud sync of clipboard history.
  - Why not now: it is the largest item requested by a wide margin, and it works against the app's main
    claim. Today the honest sentence is "everything you copy stays on this Mac"; with sync it becomes
    "everything you copy is in iCloud", which changes what a user is agreeing to when they install a
    tool that records their passwords, tokens and customer data by design.
  - The engineering is not small either: `NSPersistentCloudKitContainer` constrains the model (every
    relationship optional, no unique constraints), so the existing store needs a migration rather than a
    flag; images are external binary data and would sync as CloudKit assets, which is exactly the payload
    a user on a metered connection would not expect; a Developer ID build needs an iCloud container and a
    provisioning profile, which the current signing and notarisation flow in `build.sh` does not carry;
    and conflict resolution for a log that both machines append to constantly is its own design problem.
  - If it is ever done: text and favorites only, images never, anything flagged sensitive or concealed
    never, off by default, and with a plain statement of what leaves the machine.

- [ ] Decide whether an upgrade should still show the "downloaded from the Internet" dialog.
  - What happens: Homebrew quarantines cask apps, so `com.apple.quarantine` is on the installed
    bundle, and the cask's `postflight` launches it. macOS therefore asks the user to confirm
    opening it, once per upgrade, and the app does not start until they answer. Measured on the
    0.1.16 to 0.1.17 upgrade: process started 23:37:40, dialog answered 23:39:11
    (`syspolicyd: handle prompt response=Acknowledge`, then `Allowing code due to user approval`,
    then `updateQuarantineFlags flagsToSet=64`), app launched 23:39:12. So the 92 second gap was
    entirely the dialog waiting for a person; a relaunch afterwards took 0.086 seconds. The
    earlier guess that this was a slow notarisation check was wrong: XProtect finished in 30ms and
    Gatekeeper had already assessed the bundle as `Notarized Developer ID`.
  - The dialog is not new, but its timing is. The old `postflight` only re-activated the copy that
    was already running, so the prompt turned up at whatever launch came next, most likely at the
    next login, with no context. Now it appears immediately after `brew upgrade`, while the user is
    still looking at the terminal, which is arguably where it belongs.
  - Options if it should go away: `xattr -d com.apple.quarantine` in `postflight`, which drops the
    consent step for an app Homebrew has already checksum-verified and that is notarised and
    stapled, or leave it to users who set `HOMEBREW_CASK_OPTS=--no-quarantine`. Deliberately
    removing a Gatekeeper prompt on the user's behalf is a product and security call, not a
    cleanup, so it is parked here rather than done.
