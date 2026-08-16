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

### Finish Every Change With `./run.sh`

`xcodebuild build` and `xcodebuild test` prove the code compiles and the logic holds, and they
change nothing about the app anyone is actually using: the product goes into DerivedData, while the
dev copy in `~/Applications/MacClipboard-Dev.app` keeps running whatever binary was last installed
there. So a feature can be finished, built and tested, and still be invisible in the popover the
person reviewing it has open, which reads as the work not having been done.

`./run.sh` is what closes that gap. It quits the running dev copy, builds, re-signs with the
persistent dev certificate, installs, and relaunches. Run it after implementing anything, before
reporting the work as done, and say that the running dev build now carries the change. Only the dev
copy is touched: an installed release build has its own bundle id and keeps running.

## Project Structure

```
MacClipboard/
├── MacClipboardApp.swift      # App entry point & AppDelegate
├── Appearance.swift           # AppearancePreference: System/Light/Dark, and the one NSApp.appearance
├── BuildInfo.swift            # Build channel (Dev/Release), bundle id, version
├── GlobalHotkey.swift         # GlobalHotkeyShortcut: key code + modifiers, validation, labels
├── ClipboardMonitor.swift     # Clipboard polling (`ClipboardPolling.interval`), history management
├── MenuBarController.swift    # Status bar item, popover, global hotkey registration
├── ContentView.swift          # Main UI: filter tabs, search, item list, preview
├── SettingsView.swift         # Settings panel UI
├── UserPreferences.swift      # UserPreferencesManager singleton (UserDefaults)
├── PersistenceManager.swift   # Core Data stack, save/load items, image storage
├── PermissionManager.swift    # Accessibility permission handling
├── UpdateService.swift        # Release check, ReleaseVersion, UpdateChecker (schedule + state)
├── ImageTextRecognition.swift # On-device OCR: the plan, the line ordering, the Vision request
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
| Global hotkey default | `Cmd+Shift+V` | `Cmd+Shift+Opt+V` |
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

## An Update Is Announced, Never Imposed

`UpdateService` performs a check; `UpdateChecker` decides when to run one and remembers the answer.
Everything the user sees is a reader of one published property, `UpdateChecker.availableUpdate`, so
the three surfaces cannot disagree: the menu bar icon badge (a template dot, visible from any app),
the popover banner (version, action, and Skip), and the Settings footer row.

Four rules, and each one is a thing that was explicitly asked for:

- **A background check never opens a window.** A modal `NSAlert` appears only when the user pressed
  "Check for Updates" themselves, because then they are owed an answer including "you are up to
  date". `check(userInitiated:completion:)` takes the flag but shows nothing itself; the caller
  decides. Never add an alert to the automatic path.
- **The automatic check is switchable off, and says what it sends.** It is the only thing the app
  does over the network unasked, in an app that sells itself on the clipboard staying local, so
  `automaticUpdateChecksEnabled` and the Settings copy next to it are load-bearing rather than
  polite. Dev builds never check automatically; `run.sh` is how they update.
- **Nothing is downloaded or installed automatically.** A check sets state; the user acts. A
  Homebrew install is handed `brew upgrade --cask macclipboard` instead of a DMG, because a manual
  download over a cask-managed copy makes the next `brew upgrade` walk the app backwards.
- **The badge comes from disk before it comes from the network.** `start()` restores
  `lastSeenLatestVersion` first, so the dot is right at launch rather than ten seconds into it.

Version comparison goes through `ReleaseVersion`, which understands prereleases: the old
`compactMap { Int($0) }` read `0.1.25-beta.1` as `[0, 1]` and called it older than `0.1.24`. Design
notes, including the scheduling and skip rules, are in `docs/DEVELOPMENT.md`.

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

### A Multi-Selection Grows From an Anchor, Not From the Set

⌘ or ⇧ on ↑/↓ extends the selection (`ClipboardSelectionExtension`). `selectedItemIds` is free-form,
so it cannot say which rows a previous press took and reversing direction could not give them back.
An extend is therefore a range between an anchor and the cursor, recomputed each press, unioned with
whatever was selected when the run began. Three rules:

- **The anchor is an id, not an index.** A capture arriving while the popover is open shifts every
  index below it.
- **`endSelectionRun()` ends a run without clearing the selection**; `clearMultiSelection()` clears
  both. A plain arrow or a ⌘-click uses the first, so a user can pick a block, step past a row, and
  pick another. Everything that changes what the list means uses the second.
- **⌥↑ jumps to the top**, moved off ⌘↑ when ⌘ became an extend modifier.

### Copy Merged Follows the Same Model

`Cmd+M`, and the row's context menu, join a multi-selection into one new clip
(`ClipboardMonitor.copyMerged` → `ClipboardMergedCopy`). Same rules as the editor: sources untouched,
new item, masking only gained, nothing trimmed. Three things that are its own:

- **The order is the list's order**, so `plan(forSelectionIn:selectedIds:)` takes `filteredItems`
  rather than the `Set<UUID>`, which has none. The action's title says "Top to Bottom" before it runs.
- **Non-text items are skipped, never dropped silently.** The count appears in the menu title and
  again in the status banner afterwards.
- **It writes the pasteboard**, unlike `saveEditedText`, which deliberately does not. The action is
  called Copy. A merged clip carries no RTF or HTML: splicing several documents would produce a
  flavour claiming to be what the user copied.

### Split Is the Same Model Run Backwards

`Cmd+Shift+M`, and the row's context menu, turn the selected multi-line text item into one new item
per line (`ClipboardMonitor.splitIntoItems` → `ClipboardTextSplit`). Same rules again: source
untouched, new items, masking only gained, nothing trimmed. Four things that are its own:

- **The pieces are inserted last line first**, because every insert goes in at position 0. That, and
  timestamps descending a millisecond a piece, are what make the list read in the source's order
  both now and after a relaunch.
- **The policy runs per piece**, not once over the clip, so a password on line 4 masks only the item
  it becomes. A masked source still masks every piece.
- **It does not write the pasteboard**, unlike `copyMerged`. A split has no single result, and the
  point is to paste the pieces one at a time afterwards.
- **Above 100 pieces the user is asked first.** It is the one action that multiplies rows.

Blank and whitespace-only lines are dropped; surviving lines keep their own whitespace. The plan
comes from the cursor's item rather than the right-clicked row, so both context menu entries describe
the selection, and `splitPlan` stands down for a multi-selection, which is Copy Merged's.

Design notes are in `docs/DEVELOPMENT.md`.

## The Text in an Image Is Read On Request, Never on Capture

`Cmd+R`, and the button in the preview toolbar, read the text in the selected image with Vision and
save it as a new text item (`ClipboardImageTextRecognition`, `ClipboardMonitor.recognizeText`). The
same model as the editor, Copy Merged and Split: the image row is untouched, the text lands as an
ordinary item, masking can only be gained, nothing is trimmed, and the pasteboard is not written.
Four rules of its own:

- **Only when asked, one image at a time.** Recognising on capture would spend CPU and battery on
  screenshots that are pasted once and forgotten. There is no preference and no queue.
- **The result is an item, not a field on the image.** Putting it in `associatedText` would make it
  unsearchable as a clip and unable to be edited or deleted on its own, and the image row would stop
  meaning "what was on the pasteboard".
- **A masked image is refused until it is revealed**, as the editor is: reading one would write out
  text the user never saw. Text read from a hidden image is hidden too.
- **Reading order is rebuilt from the boxes, not taken from Vision.** Its result order is not
  documented as reading order, and here the order *is* the output. Boxes that overlap vertically are
  one line joined with a space; measured on a two-column image, Vision returns those as separate
  observations. `text(from:)` holds the rule and the tests pin it.

`isRecognizedText` marks the item in the row and the preview. It is an attribute rather than a note
because the note field is the user's, and rather than a display-time derivation because provenance is
not content. The recognition is on device with no entitlement and no network; the update check
remains the app's only unprompted network call. Design notes are in `docs/DEVELOPMENT.md`.

## A Clip Records Which App It Came From, and That Is a Guess

`sourceBundleIdentifier` is the app that was in front when the change was noticed. The pasteboard
carries no author, so `NSWorkspace.shared.frontmostApplication` at detection time is the only answer
there is, and with polling it is a good guess rather than a fact. `ClipboardSource` holds the
rule, the row shows the app's icon and the preview its name. Five things it depends on:

- **One read answers both questions.** `captureRead(for:)` samples the frontmost app once and hands
  the same value to `ClipboardCapturePolicy` and to the item, so the guard that may drop the clip and
  the source recorded on it can never name different apps. The retry path carries it in
  `pendingSourceBundleIdentifier` rather than re-reading, for the reason the excluded-app check is
  not repeated there: by then the user may have switched apps.
- **The identifier only is stored.** Name and icon are resolved at display time by
  `ClipboardSourceAppCatalog`, as `ExcludedAppRow` already does, so a renamed app reads correctly, an
  uninstalled one reads as its identifier instead of dropping off, and no icon bytes reach the store.
  The catalog caches hits *and* misses, because the search predicate runs over the whole history on
  every keystroke; `NSWorkspace.didLaunchApplicationNotification` clears it so an app installed while
  MacClipboard runs stops reading as its own identifier.
- **A row either names its source or says nothing.** nil for every clip captured before the attribute
  existed, for a process with no bundle identifier, and for an item the user made themselves (an
  edit, a merge, a split), which were copied out of nothing. Never an "Unknown app".
- **It is not inherited on a re-copy**, exactly like the text flavours: the source is a property of
  the copy, not a decision the user made about the clip, so `ClipboardHistoryMerger`'s "already at
  position 0, nothing to write" short-circuit compares it too. `copyToClipboard` adopts the
  pasteboard's change count, so the app's own writes never come back through capture and cannot make
  an item claim it came from MacClipboard.
- **The filter is exact; the search is a find.** `sourceFilter` (a bundle identifier) narrows the
  list to one app, set from a menu in the search bar and from the preview's source button, both
  through `setSourceFilter`. Search also matches the name the row shows, but never the bundle
  identifier of an installed app: "com.google.Chrome" would make a search for "google" return every
  clip from Chrome. So typing "Mail" finds the clips that say the word as well as the ones from
  Mail, and the menu finds only the ones from Mail.
- **The menu offers only the apps that have something in the list**, read off the current tab
  before the source filter and the search are applied, so picking an app cannot empty the menu that
  picked it, and it is not drawn at all until something has a source. `sourceFilter` is `@State`
  and dies with the popover: a source filter that outlived the session would hide clips behind a
  setting nobody remembers turning on. `revealWrittenItem` clears it, and it is the filter every
  write there trips, since an edit, a merge, a split and text read from an image all have no source.

Do not sharpen the guess with `NSWorkspace.didActivateApplicationNotification` history; that is a
heuristic on a heuristic. The only honest way to narrow the window is a shorter tick, and
`ClipboardPolling.interval` is that tick, named in one place and measured (see below). Design notes
are in `docs/DEVELOPMENT.md`.

## A Clip That Is a Colour Shows the Colour

`ClipboardColorSwatch` parses a text clip that is **exactly** a colour (`#RGB`, `#RGBA`, `#RRGGBB`,
`#RRGGBBAA`, `rgb()`, `rgba()`) and the row and the preview draw a swatch of it. Derived at display
time and stored nowhere, so there is no attribute and no migration. Three rules:

- **The whole trimmed clip, never a match inside it.** `color: #FF5733;` gets nothing. Matching
  anywhere would put a swatch on most CSS and most code, and a marker that is on everything says
  nothing.
- **A near miss gets no swatch.** Hex is 3, 4, 6 or 8 ASCII hex digits and nothing between them, so
  `#1234567`, `#GGHHII` and a ticket reference all refuse. Out-of-range `rgb()` components are the
  one exception and are clamped, as a browser does.
- **It is behind the mask, and bounded.** A hidden clip shows the lock until it is revealed, because
  the colour is content. `maxLength` is checked with `prefix` before anything is allocated, and the
  list is a `LazyVStack`, so a history of megabyte clips pays 41 characters of counting per visible
  row. Design notes are in `docs/DEVELOPMENT.md`.

## No Key That Could Be a Search Term May Be Lost

Typing anywhere in the popover starts a search; there is no mode to enter. `ClipboardSearchTyping`
holds the rule, `SearchTypingTests` pins it, and it is a decision of its own because the same
mistake was made twice and both times looked like the app dropping keystrokes:

- **The typing check runs before the shortcut table, not in its `default` arm.**
  `KeyEventView.performKeyEquivalent` sees every key in the window whoever holds first responder, so
  a case that matches on key code and then fails its ⌘ test consumes the key and passes it to
  nobody. Over the list that lost `f`, `d`, `z`, `e`, `h`, `v` and `n` entirely.
- **Focus is read as the fact of holding the keyboard, never as the intention.** `@FocusState` flips
  on assignment while AppKit follows a pass or two later, and keys in that gap reached neither the
  list nor a field that was not listening yet: "pickup" typed at speed arrived as "pckup". The search
  field is an `NSTextField` of the app's own (`ClipboardSearchField`) so it can report when it truly
  has the keyboard, and take focus with the caret at the end rather than selecting its contents,
  which is what let the whole handoff become synchronous. Until it reports in, `handleKeyEvent` keeps
  claiming keys and appending them itself, and `unfocusSearch()` moves both flags together for the
  same reason in the other direction.

`0`-`9` used to jump the selection. Removing that is what lets a digit be searched for, and what
gives the ten newest rows the same icon or thumbnail as every other row. Design notes are in
`docs/DEVELOPMENT.md`.

## A Text Clip Keeps Its Formatting, and the Plain Text Stays Its Content

`ClipboardRichText` holds the whole rule. A text clip stores the pasteboard's RTF *and* HTML beside
its plain text (`rtfData` and `htmlData`, inline Binary attributes), and every flavour it has is
written back on paste, unless the user asks for plain text with ⇧⏎. Both are needed because apps
split down the middle: Word, Notes, Pages, Mail and TextEdit write RTF, while Chrome, Slack, VS Code
and everything else built on a web view write HTML and no RTF at all. Measured on a Chrome copy:
`public.html` at 12,993 bytes, plain text at 674, no `public.rtf`. Storing one flavour would leave
half of what a user copies arriving plain.

Which flavour a paste *uses* is not decided here. `NSPasteboard.availableType(from:)` answers with
the first type in the **receiving** app's own order of preference, so a rich text editor takes the
RTF and a web view takes the HTML off the same pasteboard. Writing one would be choosing for both.

The plain text stays the item's *content*, so `contentEquals`, search, the preview and the editor
all keep working over it and formatting never becomes a second thing to keep in step. Four rules
any change here has to keep:

- **Formatting is not identity, except at the top of the history.** `contentEquals` compares plain
  text alone, so the same sentence copied from Word and then from Terminal is one entry. That makes
  the flavours the only part of a text clip that can differ while the two still compare equal, so
  `ClipboardHistoryMerger`'s "already at position 0, nothing to write" short-circuit compares both
  of them too. Without that, an item keeps pasting with formatting the user has since replaced.
- **Neither flavour is inherited on a re-copy**, unlike favorite, note and the sensitivity flags:
  those are decisions the user made about the clip, formatting is a property of the copy itself.
- **Only bytes shaped like the flavour they claim are stored, and the check runs again on load.**
  RTF is a signature; HTML has none, so `looksLikeHTML` scans for a `<` that starts a tag. The row
  promises the item keeps its formatting, and a pasteboard can carry anything under any type.
- **Refusing formatting never loses the clip, and the cap is per flavour.** Over 1 MB, or the wrong
  shape, means that flavour is dropped, not the clip, and oversized HTML does not take the RTF with
  it.

Both are inline rather than external binary storage: they are capped, and external files are what
leave the orphans in `docs/BACKLOG.md`. The preview and the editor stay plain text (see above), so
an edit saves a plain-text item, and `FavoritesExport` writes plain text only. Design notes,
including why RTFD is not a third flavour, are in `docs/DEVELOPMENT.md`.

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
- `rtfData`, `htmlData`: Binary, inline (the source app's formatting for a text item; see below)
- `isFavorite`, `isSensitive`: Boolean
- `note`: String (user-added)
- `isRecognizedText`: Boolean (this text was read out of an image; see below)
- `sourceBundleIdentifier`: String (the app that was in front when the clip was noticed; see below)
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

All four automatic paths are covered by `FavoriteProtectionTests`, over a store of the test's own.
See below for why that store has to be its own.

## A Test Cannot Reach the User's History

`PersistenceManager` is built over a `StoreLocation`, and only `shared` holds the
`.applicationSupport` case. Everything else names a directory (`PersistenceManager(storeLocation:
.directory(url))`), which is what `StoreBackedTestCase` hands each test in `/tmp`. Without that
split there was no way to test the favorite guarantees above, because every path that could delete
a favorite ran against the developer's own clips.

Two things enforce it, and both are needed:

- **`PersistenceManager.shared` traps under a test host.** `ClipboardMonitor.init` defaults to it,
  so forgetting to inject a store would otherwise be silent, and the failure would be the user's
  history quietly losing rows rather than a red test. `BuildInfo.isHostingTests` is the check, and
  `StoreLocationTests` asserts it still recognises a test run: if Xcode ever changes those
  environment variables, the whole protection lapses with nothing to say so.
- **The test host does not start the app.** `xcodebuild test` launches MacClipboard itself as the
  host, so `applicationDidFinishLaunching` runs during every test pass, and it used to build a
  `MenuBarController(clipboardMonitor: ClipboardMonitor())` 0.25 s in. That polled the pasteboard,
  loaded the dev history and ran hourly maintenance against it for the length of the run. It is now
  guarded, alongside the instance takeover and the installation alerts that already were.

`UserPreferencesManager` takes a `UserDefaults` for the same reason. Preferences decide whether
persistence runs at all, so a machine with it switched off would fail an unrelated test, and
`imageStorageCompacted` is *written* during ordinary use: a test sharing the standard domain would
change what the developer's own copy does at its next launch.

## Switching Saving Off Deletes Nothing, So the App Has to Offer

`persistenceEnabled` guards `saveItemToPersistence` and `loadPersistedHistory` only. Switching it
off stops new writes and stops loading at launch; every clip from before that moment stays on disk,
invisible in the popover, which is the opposite of what the toggle reads as. So Settings offers to
delete it at the moment the toggle goes off (`SettingsView.offerToDeleteSavedHistory`), and
`clearHistoryOnQuit` answers the separate question, "keep history while I work, keep nothing
afterwards".

Four things hold it together:

- **The quit clear is synchronous.** `ClipboardMonitor.clearHistoryOnQuitIfRequested` calls
  `clearAllData()` on the caller's thread, not `clearHistory()`, which hops to a utility queue.
  The process is exiting, so a dispatched delete would be abandoned halfway and the preference
  would quietly do nothing. `performOnContext` is `performAndWait`, so the rows and the external
  image files are gone before it returns. `AppDelegate.applicationWillTerminate` is the only
  caller, via `MenuBarController`, and it runs *before* `cleanup()`; SIGTERM reaches it because
  `installTerminationSignalHandler` turns that into `NSApp.terminate`. Never move this into
  `cleanup()`, which `deinit` also calls: a controller being deallocated is not a quit.
- **Both paths go through `clearAllData`**, so favorites are spared by the one `AND` in
  `bulkDeleteNonFavorites` rather than by a second rule that could drift from it.
- **The offer is an offer, and it is skipped when there is nothing to take.**
  `PersistenceManager.savedHistorySummary()` counts the clearable rows and the favorites with
  `count(for:)` and reads the store size; `clearableCount == 0` means no alert, because a store of
  only favorites has no question worth asking. Someone may also be switching saving off for an
  afternoon and want their history back afterwards.
- **The copy states the two things it cannot do.** The size is described as what the history uses,
  never as what a delete frees: SQLite keeps its allocated pages and only the external image files
  come back at once. And the quit clear covers an orderly quit only, so the toggle's help text says
  a force quit or a power cut leaves the history on disk.

`clearHistoryOnQuit` is deliberately *not* disabled while saving is off: a store the user declined
to purge is exactly the case where it still has work to do.

## Skipping a Clip and Masking a Clip Are Different Decisions

Two policies, deliberately not merged, both in `ClipboardMonitor.swift`:

- `ClipboardCapturePolicy` decides whether a pasteboard change is **recorded at all**. A skip means
  the clip never reaches memory or disk, so there is nothing to reveal with Cmd+V and nothing to
  delete. Driven by `skipConcealedClips` and `excludedBundleIdentifiers`.
- `ClipboardSensitivityPolicy` decides how an item that **was** recorded is displayed. Driven by
  `autoDetectSensitiveData` and `autoHidePasswordLikeStrings`.

Both default to off, which is the state to keep in mind when reading the capture path: on a default
install nothing is skipped and nothing is masked. A user can pick any combination of the four.

The guard runs in `checkClipboard`, before the pasteboard is read, and its result is never queued
for a retry. Three things it depends on:

- **`changeCount` has already moved when a skip is decided**, so a skip is final rather than
  reconsidered on the next tick.
- **`attemptPendingCapture` re-checks the concealed type but not the app.** The retry path exists
  because some apps write a clip in stages, so the concealed type can appear after the change count
  moved. The frontmost app cannot be re-read the same way: by then the user may have switched apps,
  which answers a different question. The app verdict is made once, when the change is noticed.
- **The frontmost app is a guess, and the Settings copy says so.** One tick of
  `ClipboardPolling.interval` after the copy at worst,
  `NSWorkspace.shared.frontmostApplication` at detection time is a good guess at the source of a
  clip, not a fact. Do not try to improve it with heuristics over
  `NSWorkspace.didActivateApplicationNotification` history; the honest sentence is "clips copied
  from these apps are not saved", with the concealed-type rule as the exact mechanism, since there
  the source app marks the clip itself.

`excludedBundleIdentifiers` stores identifiers only. Names and icons are resolved at display time in
`ExcludedAppRow`, so an app the user has since uninstalled still reads as excluded (marked "not
installed") instead of dropping off the list.

## Pausing Capture Has to Be Visible, and Has to Forget What It Missed

The third reason a clip is not recorded, and the only one that is not a judgement about the clip:
while capture is paused nothing is read from the pasteboard at all, so neither policy above ever
runs. `ClipboardMonitor.setCapturePaused` is the single writer of `UserPreferencesManager
.capturePaused`, on the main thread, and the state is stored so a pause survives a relaunch: someone
who paused before a screen share and then rebooted has not silently started recording again.

Three things it depends on:

- **Resuming adopts the pasteboard's current change count, before the timer restarts**
  (`ClipboardCapturePause.changeCountOnResume`). `changeCount` still holds the last clip that was
  captured, so without this the first tick after resuming sees a different count and records the
  very clip the user paused in order not to record, which is the whole feature undone a quarter of a
  second later. The pending-capture retry is dropped on both edges for the same reason.
- **The state is readable from outside the popover.** The menu bar icon becomes a clipboard with a
  line struck through it, composed in `MenuBarController.slashed(_:)` because SF Symbols has no
  slashed clipboard; swapping to a generic `pause` glyph would cost the user the one thing that
  icon is for, which is knowing which icon is MacClipboard. `MenuBarController` observes
  `$isCapturePaused` so the icon can never lag behind the state, and the tooltip and the
  accessibility label say "capture paused" because the glyph alone cannot.
- **The popover says it is paused rather than looking like an empty history.** A banner
  (`capturePausedBanner`) carries a Resume button, and with no history at all the empty state says
  "Capture is paused" instead of telling the user to copy something, which would do nothing.

`resetToDefaults()` deliberately leaves `capturePaused` alone, for the same reason it leaves
`excludedBundleIdentifiers` alone: Reset is not where anyone looks to start recording again, and
resuming is one click on an icon that is showing the pause the whole time.

## The Global Hotkey Is Stored, Not Hardcoded

`Cmd+Shift+V` is only the default. `GlobalHotkeyShortcut` (`GlobalHotkey.swift`) holds the pair
Carbon takes, a virtual key code and a modifier mask, `MenuBarController` re-registers on every
change, and Settings records a new one. Two rules that constrain any change here:

- **The recorder needs the hotkey out of the way while it listens**
  (`MenuBarController.setGlobalHotkeyRecording(_:)`), and every exit from recording must switch it
  back on. Carbon takes a registered hotkey before the event reaches the app, so the combination
  already set is otherwise the one combination that cannot be recorded.
- **A combination with no ⌘/⌃/⌥, or ⌘ plus one key, is refused**, on the way in from the recorder
  *and* on the way in from disk. A global hotkey is taken from every app, so a bad one is a broken
  Mac rather than a MacClipboard problem.

Dev and release need no rule of their own: different bundle ids mean different preference domains,
and `defaultForCurrentBuild` keeps the defaults apart. Design notes, including why labels come from
the keyboard layout, are in `docs/DEVELOPMENT.md`.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+Shift+V` | Global: Open clipboard (from any app). Default; rebindable in Settings |
| `Enter` | Paste selected item |
| `Shift+Enter` | Paste selected item without its formatting |
| `Cmd+E` | Edit a copy of a text item |
| Any letter or digit | Start searching, over the list or from any row |
| `↑/↓` | Navigate items |
| `Cmd+F` | Cycle filter tabs |
| `Cmd+D` | Toggle favorite |
| `Cmd+H` | Toggle sensitive mode |
| `Cmd+V` | Reveal sensitive item |
| `Cmd+N` | Focus note field |
| `Cmd+R` | Read the text in an image, on this Mac, into a new item |
| `Cmd+Z` | Full-size image preview |
| `Cmd+Click` | Add an item to the selection |
| `Cmd+↑` / `Cmd+↓` | Extend the selection (`Shift+↑` / `Shift+↓` do the same) |
| `Option+↑` | Jump to the top of the list (was `Cmd+↑` until 0.1.24) |
| `Cmd+M` | Copy the selection merged, top to bottom |
| `Cmd+Shift+M` | Split the selected item into one item per line |
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
- `globalHotkey`: key code plus Carbon modifiers (default: `Cmd+Shift+V`, `Cmd+Shift+Opt+V` on a dev
  build), recorded in Settings; an unusable stored value falls back to the default
- `shortcutsEnabled`: Bool (default: true)
- `autoStartEnabled`: Bool (default: true)
- `appearance`: `system` / `light` / `dark` (default: `system`), stored as the raw string and applied
  as one `NSApp.appearance` by `AppDelegate`. `.system` assigns `nil`, which is how AppKit says
  "follow the Mac". The menu bar icon is untouched: AppKit pins the status bar's window to the menu
  bar's appearance, so a forced dark app cannot put a white glyph on a light menu bar
- `autoDetectSensitiveData`: Bool (default: false), masks recognisable secrets
- `autoHidePasswordLikeStrings`: Bool (default: false), masks high-entropy strings
- `skipConcealedClips`: Bool (default: false), drops clips the source app marked confidential
- `excludedBundleIdentifiers`: [String] (default: empty), apps whose clips are never recorded
- `capturePaused`: Bool (default: false), capture switched off by the user until they switch it
  back on; written only by `ClipboardMonitor.setCapturePaused`
- `clearHistoryOnQuit`: Bool (default: false), the saved history is deleted on an orderly quit
- `automaticUpdateChecksEnabled`: Bool (default: true), asks GitHub for the latest release tag once
  a day; the only unprompted network call, and the reason it is switchable
- `lastUpdateCheckDate`, `lastSeenLatestVersion`, `skippedUpdateVersion`: not toggles, the update
  check's own state. The version is cached so the badge is right at launch; the skip hides one
  version and nothing newer

`resetToDefaults()` covers every preference except `excludedBundleIdentifiers`, `capturePaused` and
`clearHistoryOnQuit`. It clears `skippedUpdateVersion` (all that does is bring a banner back, in
front of the user, with Skip still on it) and leaves `lastUpdateCheckDate` and
`lastSeenLatestVersion` alone, because those are a cache of what the server said, not preferences. Emptying that list starts recording clips from whatever the user excluded with
nothing on screen to show it changed, and the entries are removable individually in front of them;
resuming capture from Reset is the same trap, and the pause is one click away from being lifted
deliberately; and turning the quit clear off would leave a history the user expected to be gone
sitting on disk after the next quit. Every preference Reset *does* touch has the safe direction as
its default.

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
- [ ] Text copied from Word, Notes, Pages, Mail or TextEdit (RTF) pastes back with its formatting,
      and the row shows the text-format marker
- [ ] Text copied from Chrome, Slack or another web view (HTML, no RTF) does the same, and pasting
      it into a rich text editor as well as back into a browser both keep the styling
- [ ] ⇧⏎, and the Plain button in the preview, paste the same item as plain text, and the item still
      pastes formatted the next time
- [ ] Text copied from Terminal or a code editor shows no marker and pastes as it always did
- [ ] Re-copying a formatted clip as plain text (from another app) stops it pasting formatted, the
      reverse starts it again, and copying the same words from a browser after an RTF app swaps
      which flavour is kept, none of it adding a second row
- [ ] Search filters by content and notes
- [ ] Sensitive mode hides/reveals correctly
- [ ] With both privacy guards off (the default), a password copied from a password manager is
      captured exactly as before
- [ ] With "Never save clips marked confidential" on, that copy adds no row to history and no row to
      the store, and the next ordinary copy is still captured
- [ ] With an app excluded, copying while it is in front adds nothing; copying from another app still
      works, and removing the exclusion restores capture without a relaunch
- [ ] Pausing changes the menu bar icon to the slashed clipboard, and copying adds nothing
- [ ] The clip copied while paused is *not* captured on resume; the next copy after that is
- [ ] A pause survives quitting and relaunching, and the icon and popover still say so
- [ ] Switching "Save clipboard history" off offers to delete what is saved, with the right count,
      and declining keeps every item
- [ ] Accepting removes the non-favorites and leaves the favorites, in the popover and on disk
- [ ] Switching it off with nothing but favorites saved asks nothing
- [ ] With "Clear history when MacClipboard quits" on, quitting and relaunching comes back with
      favorites only, and with it off the history is still there

When modifying the polling interval (`ClipboardPolling`), run from Xcode so `Logging.debug` reaches a
console:
- [ ] An ordinary copy is captured and prints no ⏱️ line, at launch as well as later: the launch tick
      compares against nothing and must not report the machine's whole change count as lost clips
- [ ] Two writes inside one tick (`printf 'a' | pbcopy; printf 'b' | pbcopy`) leave the second in
      history and print one ⏱️ line saying one clip could not be recovered
- [ ] Pausing, copying, then resuming captures nothing and prints no ⏱️ line, because the resume
      adopted the pasteboard's count
- [ ] Pasting from MacClipboard prints no ⏱️ line: the app's own write is adopted, not counted
- [ ] Copying and immediately switching apps still names the app the clip was copied from, more often
      than it did at the previous interval
- [ ] The Settings copy under Never save clips from these apps names the new interval, since it
      interpolates it

When modifying the update check:
- [ ] With a newer version cached, the menu bar icon shows a dot, the popover shows a banner naming
      the version, and the Settings footer says "Update to vX.Y.Z"
- [ ] None of the three interrupts anything: no alert appears at launch or while working
- [ ] Skip clears all three at once, and a newer version brings them back
- [ ] "Check for Updates" while already current says so in an alert, which is the one modal allowed
- [ ] With automatic checks off, no request is made and the manual check still works
- [ ] A paused capture plus an available update shows both the slash and the dot, and the
      accessibility label names both
- [ ] On a Homebrew install the action copies `brew upgrade --cask macclipboard` instead of opening
      the release page

When modifying the global hotkey: the checklist is in `docs/DEVELOPMENT.md`.

When modifying search or the popover's key handling:
- [ ] Typing a word over the list as fast as you can type gives that word, every letter of it, with
      the popover freshly opened and again with a long history loaded
- [ ] The same for a word starting with f, d, z, e, h, v, n or m, which are the ⌘-shortcut letters
- [ ] Digits reach the search: a clip found by a year or a house number is findable by typing it
- [ ] Backspace during that first burst takes back the letter it should
- [ ] Tab focuses and unfocuses the field; Escape hands the keyboard back to the list, and the arrows
      work immediately afterwards
- [ ] Clicking into the field, typing, then pressing Enter still pastes the selected item
- [ ] ⌘F, ⌘D, ⌘E, ⌘H, ⌘V, ⌘N, ⌘M, ⌘⇧M and ⌘⌫ all still act rather than typing their letter
- [ ] With shortcuts switched off in Settings, those combinations do nothing rather than typing
      their letter, and the bare letters still search

When modifying the appearance override:
- [ ] With the Mac set to light, picking Dark turns the popover, Settings, the right-click menu and
      an alert dark straight away, without reopening anything, and the reverse on a dark Mac
- [ ] The menu bar icon stays readable in both, and still shows the pause slash and the update dot
- [ ] The choice survives a relaunch, and Reset puts it back to System
- [ ] On System, switching the Mac between light and dark still carries the app with it

When modifying UI:
- [ ] Filter tabs work correctly
- [ ] Keyboard navigation functions
- [ ] Multi-select deletion works
- [ ] Image preview opens with Cmd+Z
- [ ] Cmd+↓ three times from the top selects four rows; Cmd+↑ hands them back one at a time
- [ ] Shift+↑ and Shift+↓ do exactly the same
- [ ] Cmd+↑ on the first row and Cmd+↓ on the last change nothing
- [ ] Cmd-click a row, then Cmd+↓ from elsewhere: the clicked row stays selected
- [ ] A plain ↑ or ↓ keeps the selection but starts the next extend from the new cursor
- [ ] Option+↑ jumps to the top, and the floating button's tooltip says so

When modifying Copy Merged:
- [ ] Cmd-click three text items, press Cmd+M: one new item at the top holds all three joined with
      newlines, in the order they were shown, and the three originals are unchanged
- [ ] Pasting straight into another app gives the same joined text
- [ ] Right-clicking any row offers the same action, with the count in its title, and with nothing
      selected the entry is greyed and says how to make a selection
- [ ] Selecting an image alongside two text items merges the two and reports 1 skipped
- [ ] Selecting one text item and one image offers nothing to merge
- [ ] A merge that includes a hidden item is hidden, and the popover switches to All to show it
- [ ] Merging text that is already the top item moves it rather than adding a second copy, and the
      pasteboard still gets it

When modifying Split:
- [ ] Select a clip of three lines, press Cmd+Shift+M: three new items at the top, reading top to
      bottom in the source's order, and the source unchanged further down
- [ ] The pasteboard is untouched: what was copied before the split still pastes elsewhere
- [ ] Blank lines and lines of only spaces or tabs produce no items; an indented line keeps its tab
- [ ] The action is unavailable on images, files and single-line text, and the context menu entry
      says what would make it available
- [ ] With two or more rows Cmd-clicked, Split is greyed and Copy Merged is the one offered
- [ ] Splitting a hidden item gives hidden items, and the popover switches to All to show them
- [ ] A clip with a repeated line produces one item for it, and the banner says how many moved
- [ ] Over 100 lines asks first, names the count, and cancelling adds nothing
- [ ] Relaunching keeps the pieces in the same order they were left in

When modifying text recognition:
- [ ] With a screenshot of text selected, ⌘R and the preview's text button both add one new item at
      the top holding the text, reading top to bottom, with the image left where it was
- [ ] The new row and its preview both carry the read-from-an-image marker, and it is still there
      after a relaunch
- [ ] The pasteboard is untouched: what was copied before ⌘R still pastes elsewhere. ⏎ on the new
      row pastes the text
- [ ] A screenshot of two columns keeps each row on one line rather than one column then the other
- [ ] While it runs the button becomes a spinner and a second ⌘R does nothing; closing the popover
      mid-read still leaves the new item in history when it is reopened
- [ ] A photo with no text says so and adds nothing
- [ ] The action is unavailable on text and file items, and greyed on a masked image until ⌘V reveals
      it; text read from a revealed hidden image is hidden, and the popover switches to All to show it
- [ ] Reading the same image twice does not add a second row, and the banner says the text was
      already in the history
- [ ] Running it on an old image that is no longer in memory loads the image first and still works
- [ ] With shortcuts switched off in Settings, ⌘R does nothing and the button still works

When modifying the recorded source app:
- [ ] Copying from Slack, then from a browser, then from Terminal gives each row that app's icon
      beside the time and its name in the preview, and the tooltip says it is the app that was in
      front rather than a certainty
- [ ] Clips captured before this shipped show no icon and no name at all, not "Unknown app", and the
      rows are otherwise unchanged
- [ ] An edit (⌘E), a merge (⌘M), a split (⌘⇧M) and text read from an image (⌘R) all produce rows
      with no source
- [ ] Copying the same sentence out of one app and then out of another leaves one row, and it names
      the second app; re-copying it from the same app again changes nothing
- [ ] The menu in the search bar lists exactly the apps that have something in the list, with their
      icons, and is absent entirely on a history where nothing has a source
- [ ] Picking one narrows the list to that app and the menu button shows its icon; All Apps widens
      it again, and the menu still lists every app while one is picked
- [ ] Switching tabs while an app is picked keeps the app picked, and the menu then lists only the
      apps with something in that tab
- [ ] Clicking the app name in the preview picks that app in the menu, and gives the same list
- [ ] Searching for a word that is also an app name finds both the clips containing that word and
      the clips from that app, while the menu finds only the clips from that app
- [ ] With an app picked, an edit, a merge, a split or ⌘R widens the list back out rather than
      writing a row into a list that cannot show it
- [ ] A clip from an app that has since been uninstalled shows the placeholder glyph and its bundle
      identifier, and is still findable by searching that identifier
- [ ] With an app excluded from capture, nothing is recorded for it at all, source included
- [ ] A masked clip still shows its source: where a clip came from is not its content

When modifying the colour swatch:
- [ ] Copying `#FF5733`, `#f53`, `#FF573380` and `rgb(255, 87, 51)` each gives the row a swatch of
      that colour, and the preview one beside the character count
- [ ] The preview prints `#FF5733` beside the swatch for the `rgb()` and `#f53` clips, and prints
      nothing beside the swatch for the clip that already reads `#FF5733`
- [ ] `color: #FF5733;`, `#GGHHII`, `#1234567` and a copied stylesheet all show the ordinary text
      icon, not a swatch
- [ ] `#FFFFFF` in light mode and `#000000` in dark are both visible as a bordered square rather
      than disappearing into the row
- [ ] `#FF573380` shows the checkerboard behind it; `#FF5733` does not
- [ ] Marking a colour clip sensitive replaces the swatch with the lock in the row and takes it out
      of the preview; revealing it brings both back

When modifying the editor:
- [ ] Clicking the preview text opens it with the caret where the click landed
- [ ] Dragging over the preview text selects it and does not open the editor; Cmd+C copies it
- [ ] Cmd+E and the pencil open it; all three are unavailable on images, files, and masked items
- [ ] Enter adds a line, Cmd+S saves, Cmd+Enter saves and pastes, Escape cancels (with a confirm
      once the text has changed)
- [ ] Cmd+A, Cmd+C, Cmd+V, Cmd+X, Cmd+Z and Cmd+Backspace behave as text editing, not as the
      popover's shortcuts
- [ ] Saving adds a new item at the top, selects it, and leaves the original as it was
- [ ] The saved item shows a relative time, not "unknown" (`cacheTimeAgoForNewItems` covers every
      item that appears while the popover is open, captures included)
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
  - This rule is what makes `appearance` (System / Light / Dark, above) a preference rather than a
    project: forcing dark on a light Mac works only because no colour here is written down

## Entitlements

The app requires:
- `com.apple.security.automation.apple-events` - For paste automation
- Accessibility permissions - For global hotkey (requested at runtime)

`build.sh` re-signs the exported app to pin the designated requirement, and that re-sign MUST
pass `--entitlements`: `codesign --force` replaces the signature wholesale, so omitting it ships
an app with no entitlements at all. Releases up to 0.1.13 did exactly that. The build now fails
if the entitlements are missing, or if debug-only `get-task-allow` is present.

The DMG is a second thing to sign, and its own three steps run in one order only: **sign, notarize,
staple**. `codesign` rewrites the image, so signing an image that has already been stapled drops the
ticket, with nothing to say so beyond `stapler validate` starting to fail. Releases up to 0.1.22
shipped a container with a ticket and no signature at all, which Gatekeeper rejected as "no usable
signature" while the app inside assessed correctly. `spctl -a -t open --context
context:primary-signature` on the finished image is the guard, and it fails the build, because it is
the only check that needs both the signature and the ticket to be there.

## Important Files for Common Tasks

| Task | Files to Modify |
|------|-----------------|
| Add keyboard shortcut | `ContentView.swift` (local), `MenuBarController.swift` (global) |
| Change the global hotkey model | `GlobalHotkey.swift`, `UserPreferences.swift`, `SettingsView.swift` (`GlobalHotkeyRecorder`) |
| Change clipboard polling | `ClipboardMonitor.swift` |
| Change what a clip keeps beside its text | `ClipboardMonitor.swift` (`ClipboardRichText`), `ClipboardData.xcdatamodeld`, `PersistenceManager.swift` |
| Modify settings | `SettingsView.swift`, `UserPreferences.swift` |
| Change the light/dark override | `Appearance.swift`, `MacClipboardApp.swift` (`startFollowingAppearancePreference`), `SettingsView.swift` |
| Update data model | `ClipboardData.xcdatamodeld`, `PersistenceManager.swift`, `ClipboardMonitor.swift` |
| Change UI layout | `ContentView.swift` |
| Change the copy editor | `ContentView.swift` (`ClipboardTextEditorView`), `ClipboardMonitor.swift` (`ClipboardTextEdit`), `MenuBarController.swift` (`ClipboardEditDraftStore`) |
| Change Copy Merged | `ClipboardMonitor.swift` (`ClipboardMergedCopy`, `copyMerged`), `ContentView.swift` (`ClipboardMergedCopyContent`, `copyMergedSelection`) |
| Change Split | `ClipboardMonitor.swift` (`ClipboardTextSplit`, `splitIntoItems`), `ContentView.swift` (`ClipboardTextSplitContent`, `splitSelectedItem`) |
| Change the colour swatch | `ContentView.swift` (`ClipboardColorSwatch`, `ClipboardColorSwatchView`) |
| Change text recognition | `ImageTextRecognition.swift`, `ClipboardMonitor.swift` (`recognizeText`), `ContentView.swift` (`recognizeSelectedItemText`, `recognizeTextButton`) |
| Change the recorded source app | `ClipboardSource.swift`, `ClipboardMonitor.swift` (`captureRead`), `ContentView.swift` (`ClipboardSourceAppIcon`, `sourceApp`, `searchForSourceApp`) |
| Modify menu bar behavior | `MenuBarController.swift` |
| Change the app icon | `scripts/make-app-icon.swift`, then re-run it; the PNGs it writes into `Assets.xcassets/AppIcon.appiconset` are checked in, and no SF Symbol may be used in an app icon |
| Change the update check or how it is announced | `UpdateService.swift` (`UpdateChecker`), `MenuBarController.swift` (badge, menu item, alert), `ContentView.swift` (`updateAvailableBanner`), `SettingsView.swift` (`updateStatusControl`) |
