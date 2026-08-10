# Development Guide

This guide covers how to build, develop, and contribute to MacClipboard.

## Prerequisites

* macOS 13.0+
* Xcode 15+
* Command line tools: `xcode-select --install`

## Quick Start

```bash
git clone https://github.com/rakodev/mac-clipboard.git
cd mac-clipboard

# One-time setup: Create dev signing certificate (preserves accessibility permissions)
./scripts/setup-dev-signing.sh

# Build and run
./run.sh
```

## Build Commands

```bash
make build     # Release build with DMG/ZIP
make dev       # Fast debug build only
make run       # Build, sign with dev cert, and run (recommended)
make release   # Build, sign, notarize, and create GitHub release
make clean     # Clean build artifacts
```

Before creating a distribution build, run the [release smoke-test checklist](RELEASE_SMOKE_TEST.md).

## Development Signing Setup

macOS requires accessibility permissions for the global hotkey and auto-paste features. During development, each rebuild normally creates a new code signature, which invalidates the permission and forces you to re-grant it.

To avoid this, we use a self-signed certificate that provides a consistent signature across builds.

### First-Time Setup (One-Time)

```bash
./scripts/setup-dev-signing.sh
```

This creates a "MacClipboard Dev" certificate in your login keychain. You may be prompted for your password.

### Running the App

```bash
./run.sh
```

This script:
1. Builds the app with `make dev`
2. Copies it to `~/Applications/MacClipboard-Dev.app` (consistent location)
3. Signs it with your dev certificate (consistent signature)
4. Launches the app

The first time you run, grant accessibility permission to "MacClipboard-Dev". This permission will persist across all future rebuilds.

### Troubleshooting Signing

**Certificate not found error:**
```bash
./scripts/setup-dev-signing.sh  # Re-run setup
```

**Permission still being requested after rebuild:**
1. Open Keychain Access
2. Find "MacClipboard Dev" certificate
3. Double-click → Trust → Code Signing: "Always Trust"
4. Delete old "MacClipboard-Dev" from Accessibility settings
5. Run `./run.sh` and re-grant permission

**Recreate certificate:**
1. Open Keychain Access
2. Delete "MacClipboard Dev" certificate and private key
3. Run `./scripts/setup-dev-signing.sh` again

## Development in Xcode

```bash
open MacClipboard.xcodeproj
# Press ⌘+R to build and run
```

## Project Structure

```
MacClipboard/
├── MacClipboardApp.swift      # App entry point & delegate
├── ClipboardMonitor.swift     # Clipboard tracking & history management
├── MenuBarController.swift    # Status item, popover, global hotkey
├── ContentView.swift          # Main SwiftUI UI components
├── SettingsView.swift         # Settings panel UI
├── UserPreferences.swift      # Settings persistence (UserDefaults)
├── PersistenceManager.swift   # Core Data clipboard storage
├── PermissionManager.swift    # Accessibility permission handling
├── Logging.swift              # Logging utilities
├── Assets.xcassets/           # Icons & image assets
└── ClipboardData.xcdatamodeld # Core Data model
```

## Technical Details

### Clipboard Monitoring

Uses `NSPasteboard.general` with change count polling every 0.5 seconds for reliable clipboard tracking.

```swift
// Polling loop checks for clipboard changes
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    let currentCount = NSPasteboard.general.changeCount
    if currentCount != lastChangeCount {
        // Process new clipboard content
    }
}
```

### Content Support

* **Text**: `NSPasteboard.string(forType: .string)`
* **Formatted text**: `NSPasteboard.data(forType: .rtf)` and `.html`, stored beside the plain text
* **Images**: `NSImage` pasteboard objects
* **Files**: `NSURL` pasteboard objects

### Rich Text

`ClipboardRichText` (in `ClipboardMonitor.swift`) is the whole policy, deliberately as value-level
code: `NSPasteboard` is shared machine state, so a test that wrote to it would put its fixtures on
the developer's own clipboard and race the running dev build's polling. The pasteboard-facing half
is a checklist item in `CLAUDE.md` instead.

Decisions worth keeping, and why:

* **Two flavours, RTF and HTML, because apps split down the middle.** Word, Notes, Pages, Mail and
  TextEdit write RTF; Chrome, Slack, VS Code and everything else on a web view write HTML and no
  RTF at all. Measured on a real Chrome copy: `public.html` 12,993 bytes, `public.utf8-plain-text`
  674 bytes, no `public.rtf`. Shipping RTF alone left browser copies pasting plain, which is where
  most people copy formatted text from.
* **The receiving app picks, not us.** Every stored flavour is written on paste.
  `NSPasteboard.availableType(from:)` returns the first type in the *receiver's* preference order,
  so a rich text editor takes the RTF and a web view takes the HTML from the same pasteboard.
  Choosing one at write time would be answering a question that is not ours.
* **The cap is per flavour.** 1 MB each, matching the plain-text cap because a clip is held in
  memory for the session. A page with enormous HTML still keeps the RTF that came with it, and the
  clip is captured either way.
* **A shape check, not a parse.** `{\rtf` at the front for RTF. HTML has no signature, since what a
  browser writes is a fragment that may begin `<meta`, `<!DOCTYPE`, `<html>` or a bare `<span>`, so
  `looksLikeHTML` scans the first 4 KB for a `<` that starts a tag name, tolerating the zero bytes
  of UTF-16 and rejecting prose like `a < b`. Both are byte scans: parsing would cost an
  `NSAttributedString` round trip on every copy, and the bytes are handed back raw on paste anyway.
* **Inline Binary, not external binary storage.** Both are capped, and external files are what leave
  the orphans described in `docs/BACKLOG.md`. The consequence to weigh if the cap is ever raised:
  they live in the SQLite file, so they count towards `getStorageSize()` but are not reachable by
  `evictImagesUntilWithin`, which only drops images.
* **RTFD is not a third flavour.** It is the only other pasteboard type that carries formatting in
  practice, and it is not a cheap addition like HTML was: it is a flat attachment bundle, so it
  usually carries the images inline and blows past the cap, and a copy that has images in it is
  captured as an image item anyway. The two flavours above cover formatting without attachments,
  which is what "keep the formatting" means for text.
* **⇧⏎ for the plain-text paste.** It sits next to ⏎ because it is the same action with one thing
  taken away, and it is a property of that paste rather than of the item, so the RTF stays stored
  and the next paste can keep it. ⌘⇧V, the usual "paste and match style", is the app's own default
  global hotkey and could not be taken for this.
* **The marker is shown on masked items too.** Whether a clip carries formatting says nothing about
  what it contains, so hiding the marker would cost information for no privacy.

Testing it by hand needs a source app for each half: Word, Notes, Pages, Mail or TextEdit for RTF,
and Chrome, Slack or VS Code for HTML. To drive it without one, write the flavours from a script:

```swift
let attributed = NSAttributedString(string: "styled", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
let rtf = attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:])!
let pasteboard = NSPasteboard.general
pasteboard.clearContents()
pasteboard.setData(rtf, forType: .rtf)                                    // an RTF app
pasteboard.setData(Data("<p><b>styled</b></p>".utf8), forType: .html)     // or a browser: HTML alone
pasteboard.setString(attributed.string, forType: .string)
```

Then read `NSPasteboard.general.types` after a paste from the popover: the flavours the clip carries
are present after ⏎ and absent after ⇧⏎. Do both halves separately, since writing HTML *without*
RTF is exactly the case that RTF-only support got wrong.

### Extending a Selection From the Keyboard

⌘ or ⇧ held on ↑/↓ grows the multi-selection instead of moving the cursor alone.
`ClipboardSelectionExtension.extending(from:by:in:selectedIds:anchor:)` is the whole of it, and it is
pure, so the model is tested without a popover.

**Why an anchor rather than adding to the set.** The obvious implementation adds the row you step
onto and removes the row you step off, which needs no new state and is wrong the moment you reverse
past where you started: stepping back over the first row would remove it instead of extending the
other way. Every list on the Mac anchors, and so does this. The anchor is set on the first press of
a run, and the selection is recomputed as the range between it and the cursor on every press after.

**Why the anchor is an id.** Indices move. A capture arriving while the popover is open goes in at
position 0 and shifts everything below it, and `selectedIndex` is already re-synced by id in the
`onChange(of: computedFilteredItems)` handler for that reason. An index-based anchor would have
silently pointed one row off after any copy made while the popover was open.

**Why a run ends without clearing the selection.** `endSelectionRun()` drops only the anchor;
`clearMultiSelection()` drops the selection too. A plain arrow and a ⌘-click use the first, so the
next extend grows from where the cursor now is while keeping what is already picked. That is what
makes "select a block, skip a row, select another block" work from the keyboard alone. Filter
changes, a plain click, a delete and a merge all use the second: they change what the list means, so
a selection carried across them would be a selection of something the user never saw.

**Why both ⌘ and ⇧.** ⇧+arrow is the platform standard. ⌘+arrow is not, but ⌘-click is this app's
own multi-select gesture, so ⌘ is the modifier already under the hand of anyone who has learned it
here. Neither is gated on `shortcutsEnabled`, for the same reason the bare arrows are not.

**What it cost.** ⌘↑ meant "scroll to top" and moved to ⌥↑, because ⌘↑ and ⌘↓ have to mean the same
thing as each other or neither is learnable. Three sites: the key handler, the floating button's
tooltip, and the ⌘/ reference.

### Copy Merged

`Cmd+M`, or the context menu on any row, joins the multi-selection into one new text item and puts
it on the pasteboard. `ClipboardMergedCopy` holds the whole decision as a pure value
(`plan(forSelectionIn:selectedIds:)` → `Plan` → `mergedItem(from:sensitivity:)`), so the join, the
counts and the action's own title are all testable without a pasteboard or a store. Notes on the
calls that are not obvious from the code:

**Why the plan takes the list and not just the selection.** `selectedItemIds` is a `Set<UUID>` and
has no order, so joining from it would give whatever order hashing happened to produce, differing
between runs of the same selection. Passing `filteredItems` makes the order the one on screen, which
is the only order the user can predict. It also drops ids that are no longer in the list, which is
what happens when the filter changes or a selected row is deleted while the selection survives.

**Why non-text items are skipped rather than disabling the action.** The alternative considered was
refusing the whole merge if the selection holds an image. It loses: a user ⌘-clicking down a list is
selecting the things they want joined, and an image caught along the way is a slip, not a change of
intent. Refusing would also have to explain itself somewhere, and a greyed menu entry has no room.
So the skip is silent in the mechanism and loud in the copy: the count appears in the menu title
before the merge and in the status banner after it.

**Why the separator is not configurable.** A separator preference is invisible until after a merge,
which is the worst moment to discover it is wrong, and the two obvious wants (a blank line between
pieces, a comma) are each one edit away in the editor afterwards. `ClipboardMergedCopy.separator` is
a newline and stays one.

**Why the merged clip carries no formatting.** RTF and HTML are whole documents with headers,
font tables and a body. Concatenating several would produce bytes that pass `isRTF` or `looksLikeHTML`
while being something this app assembled, and the row's formatting marker promises "the formatting
this was copied with". Plain text is the honest answer; see the rich text section above.

**Why it writes the pasteboard when `saveEditedText` does not.** Saving an edit is a change to
history and must not silently replace what the user has copied. Copy Merged is a copy, named as one
in the menu and reached with ⌘M: the point is to paste it next. It goes through `copyToClipboard`,
which pauses capture and adopts the change count, so the poll does not add the clip a second time.

**What happens when the join already exists.** `insertIntoHistory` returns nil when the same text is
already the top item, and `copyMerged` still calls `copyToClipboard` on that row. Skipping it would
leave the user with an action that appeared to do nothing, having asked for a copy.

Manual checks are in the CLAUDE.md testing checklist; `MacClipboardTests/MergedCopyTests.swift`
covers the order, the skips, the whitespace, the masking and the titles.

### Split

`Cmd+Shift+M`, or the context menu on any row, turns the selected multi-line text item into one new
item per line. `ClipboardTextSplit` holds the whole decision as a pure value (`plan(for:)` → `Plan` →
`items(from:sensitivity:timestamp:)`), so the pieces, the counts, the masking and the titles are all
testable without a store. It reuses Copy Merged's model wholesale: sources untouched, pieces land as
ordinary new items through `insertIntoHistory`, masking can only be gained, nothing is trimmed.
Notes on the calls that are not obvious from the code:

**Why the pieces are inserted in reverse.** Every insert goes in at position 0, so inserting last
line first is what leaves the list reading in the source's own order, which is the order they will
be pasted in. The timestamps descend by a millisecond a piece for the same reason: the array order
decides what the popover shows now, the timestamps decide what comes back after a relaunch, and the
two have to agree that the first line is the newest item.

**Why a whitespace-only line is dropped.** The backlog entry said empty lines; a line of tabs
between two blocks is one in every way that matters, and a clip of three spaces arrives as a row
showing nothing that cannot be told from an empty one. Lines that survive are never trimmed, which
is the rule that actually protects a leading tab: dropping and trimming are separate decisions and
only the first one is made here.

**Why the plan is computed from the cursor's item, not the clicked row.** A right click does not
move the selection, so the row under the pointer and the row the action takes are not always the
same one, and the title says which. The alternative, a per-row plan, means scanning the text of
every visible clip on every list rebuild, and a clip can be megabytes. Both context menu entries now
describe what is selected rather than what was clicked, which is at least one consistent rule.

**Why ⌘⇧M, sharing a key with ⌘M.** They are the same idea in opposite directions and the two can
never both apply: `splitPlan` stands down when two or more rows are ⌘-clicked, which is exactly when
`mergePlan` exists. Matching the modifiers in the `case 46` pattern keeps a bare m reaching the
search field.

**Why it does not write the pasteboard, when Copy Merged does.** A split has no single result to
copy, and the point of it is to paste the pieces one at a time afterwards. Replacing what the user
has copied in order to do that would be taking something away; the action is called Split, not Copy.

**Why the cap is a confirmation and not a refusal.** This is the one action in the popover that
multiplies rows, and a stray copy of a log file is one keystroke from thousands of them. Above 100
pieces the alert names the count, and names the history limit as well when the split would reach it,
because that is the part the user cannot see coming. Nothing is capped after they confirm:
`trimHistoryToLimitPreservingFavorites` is the existing answer to a history with too much in it, and
it keeps the newest, which after a reverse insert is the first lines of the source.

**Why the menu shows ⌘M and ⌘⇧M without owning them.** Both entries carry a `.keyboardShortcut`,
which SwiftUI maps to the NSMenuItem key equivalent, so macOS draws the glyphs right-aligned the way
it does in any menu. A key equivalent on a *contextual* menu is only live while that menu is open,
which is why `handleKeyEvent`'s `case 46` is still what makes the keys work over the list. The two
cannot fight: the menu is closed whenever the list has the keyboard. If a SwiftUI release ever did
register these window-wide, both actions are already safe against firing twice, because each clears
what it consumed (`clearMultiSelection`, and a split leaves a one-line item selected), so the second
call finds no plan.

**What happens to a repeated line.** The merger dedupes by content, so a list with the same name
twice produces one row for it, not two. `ClipboardTextSplitOutcome` counts those separately and the
status banner says how many moved, because otherwise 12 lines becoming 11 rows reads as dropped
text.

Manual checks are in the CLAUDE.md testing checklist; `MacClipboardTests/TextSplitTests.swift`
covers the line rules, the ordering, the masking, the cap and the titles.

### Sensitive Content Detection

The app can auto-detect sensitive content using two methods:

**1. Pasteboard Type Detection** - Instant detection via special pasteboard types set by password managers:
* `org.nspasteboard.ConcealedType`
* `org.nspasteboard.TransientType`

**2. Pattern Matching** - Regex patterns for known secret formats:
* API keys (OpenAI, Stripe, AWS, Google, GitHub, Slack, Heroku)
* JWT tokens
* Private keys (PEM format)
* Database connection strings with credentials
* Generic secrets with `password=`, `api_key=`, etc.

**3. Password-like String Detection** - Heuristic detection for strings that look like passwords:
* 8-64 characters, no spaces/newlines
* Contains all 4 character types (uppercase, lowercase, digit, special)

The password detection excludes common false positives:

| Pattern | Examples |
|---------|----------|
| URLs | `https://example.com/path` |
| Emails | `user@example.com` |
| File paths | `/Users/username/file.txt`, `C:\Users\` |
| UUIDs | `550e8400-e29b-41d4-a716-446655440000` |
| IP addresses | `192.168.1.1:8080`, `fe80::1` |
| MAC addresses | `00:1A:2B:3C:4D:5E` |
| ISO dates | `2024-01-15T10:30:00` |
| Versions | `v1.2.3-beta` |
| Domains | `sub.example.com` |
| Phone numbers | `+1-555-123-4567` |

See `SensitiveContentDetector` in `ClipboardMonitor.swift` for implementation details.

### Global Hotkey

Implemented using Carbon framework's `RegisterEventHotKey` for system-wide support.

The combination is a stored preference, `globalHotkey`, held as the pair Carbon takes: a virtual key
code and a modifier mask (`GlobalHotkeyShortcut` in `GlobalHotkey.swift`). `Cmd+Shift+V` is the
default, and a dev build defaults to `Cmd+Shift+Opt+V`: `RegisterEventHotKey` is
first-come-first-served system wide, so a dev build and an installed release build otherwise fight
over one combination and whichever launched second loses it without any visible sign. The two builds
have different bundle identifiers and so different preference domains, which is what keeps a
recorded shortcut on one from reaching the other. When registration fails, the popover and Settings
both say so rather than leaving a dead key.

```swift
// Carbon event handler for global hotkey
var hotKeyRef: EventHotKeyRef?
let hotKeyID = EventHotKeyID(signature: OSType("MCLP"), id: 1)
RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID, ...)
```

`MenuBarController` unregisters and re-registers whenever the preference changes, and
`setGlobalHotkeyRecording(_:)` lets go of the hotkey entirely while the Settings recorder is
listening. Without that, the one combination the recorder could never capture would be the one
already registered: Carbon takes it before the key event reaches the app, so pressing it would open
the popover instead of being written down.

#### Recording One

`GlobalHotkeyRecorder` (`SettingsView.swift`) is a local `NSEvent` monitor rather than a first
responder view. The combinations worth recording are exactly the ones that are already key
equivalents somewhere (⌘⇧V is Paste and Match Style, ⌥⌘C is Copy Style), and a local monitor runs
before `performKeyEquivalent`, so pressing one records it instead of performing it. Returning nil
from the monitor is what stops the settings window's own Done button from firing on a recorded
Return. Every exit from recording has to call `setGlobalHotkeyRecording(false)`, including Escape,
Cancel, the window losing key, and the hotkey toggle being switched off underneath the recorder: a
stranded monitor swallows the next key press anywhere in the app.

Two combinations are refused, and both refusals are about other apps rather than about MacClipboard:

* **No ⌘, ⌃ or ⌥** would fire the hotkey while the user types. Function keys are the exception, since
  F13 on its own is a legitimate hotkey.
* **⌘ plus one key** is how apps spell their menu items, so taking one globally removes Paste, Save
  or Quit from everything the user runs.

The same check runs on the value read back from disk, so a combination this build would refuse to
record cannot arrive from an older one either. `GlobalHotkeyShortcut.init` also masks off the
modifier bits Carbon does not take (caps lock, keypad, fn), which `NSEvent.modifierFlags` reports
and which would otherwise make two identical shortcuts compare unequal.

Key labels come from the current keyboard layout through `UCKeyTranslate`, not from a table of key
codes to letters: key code 6 is Z on a US keyboard and W on a French one, and a recorder that named
the wrong key would be describing a keyboard the user is not looking at. Keys the layout cannot
label (Return, Escape, the arrows, F1 to F20) are named in `GlobalHotkeyKey`, and
`GlobalHotkeyKey.label(for:)` never returns an empty string, since a shortcut nobody can see is
worse than an ugly label.

**Known limit: a collision is usually silent.** `isGlobalHotkeyUnavailable`, the popover banner and
the Settings warning are all driven by the `OSStatus` from `RegisterEventHotKey`, and on macOS 26.5
that call returns `noErr` for a combination another *process* already holds. Measured with a
throwaway helper holding ⌃⌥N: a second process asking for the same combination got status 0. So the
banner catches a refused registration when macOS reports one, and the everyday case, another app
having got there first, still presents as a key that does nothing. Recording a different shortcut is
the remedy either way, which is why the copy points at the recorder.

#### Manual Checks

- [ ] Recording a new combination takes effect without a relaunch, and the old one stops working
- [ ] The combination currently registered can itself be recorded: pressing it while recording
      writes it down instead of opening the popover
- [ ] Escape leaves the shortcut as it was; Cancel and clicking another app both end recording, and
      the hotkey works again afterwards
- [ ] A key with no ⌘/⌃/⌥, and ⌘ plus one key, are both refused with a reason, and recording
      continues rather than closing on the refusal
- [ ] A function key on its own is accepted
- [ ] The recorded shortcut survives a relaunch, and Reset restores the default for this build
- [ ] The popover banner, the shortcut reference (⌘/) and Settings all name the current combination

### Launch at Login

Uses `SMAppService` from the ServiceManagement framework (macOS 13+) to register as a login item.

```swift
// Register/unregister login item
try SMAppService.mainApp.register()   // Enable launch at login
try SMAppService.mainApp.unregister() // Disable launch at login
```

### Data Storage

Clipboard history persisted to `~/Library/Application Support/MacClipboard` using Core Data.

* Regular items: Subject to retention settings (default 60 days)
* Favorites: Kept indefinitely
* Images: Optionally stored to disk for faster loading

### Privacy and Network Boundaries

Clipboard content is local-only. The app does not upload clipboard history, notes, images, or file paths. Persistent clipboard data lives in the app support directory and follows the user's retention settings.

The only network path is the update check, and it is a GET of the latest release tag from the GitHub Releases API. No clipboard data, no identifier and no version telemetry is included: the request carries an `Accept` header and nothing else, and the running version is compared locally against the tag that comes back.

From 0.1.25 that check also runs on its own, once a day, which makes it the one thing the app does over the network without being asked. Three things keep that honest, and none of them is optional:

* `automaticUpdateChecksEnabled` (Settings > General, default on) switches it off, and the Settings copy states exactly what the request contains. An app whose pitch is that your clipboard never leaves the machine does not get to make an unprompted request with no way to stop it.
* Nothing is ever downloaded or installed automatically. A check only sets `UpdateChecker.availableUpdate`, which three passive surfaces read; the user chooses whether to act.
* Dev builds never check automatically. They are routinely ahead of the latest release, so a nag would be wrong as often as it was right.

Switching the preference off leaves the manual check working, in Settings and in the menu, so no build ever loses the ability to answer "am I current".

### Telling the User About a Release Without Getting in the Way

`UpdateService` performs a check; `UpdateChecker` decides when to run one and remembers the answer. That split is what lets the notification be passive: the checker publishes `availableUpdate`, and every surface is a reader of it, so the badge, the banner and the Settings row cannot disagree about whether there is an update.

The three surfaces are deliberately unequal in how much they say, because they are seen in different places:

| Surface | Where | Says |
|---------|-------|------|
| Menu bar icon badge | Visible from any app | Only "there is something", as a template dot that takes the menu bar tint |
| Popover banner | Where the user already is | The version, the running version, and the action, with Skip |
| Settings footer row | Somewhere you go on purpose | The version, or when the app last looked |

A modal `NSAlert` appears in exactly one case: the user pressed "Check for Updates" themselves and is owed an answer, including "you are up to date". A check that ran on its own never opens one. That is the whole design constraint, and it is the reason `UpdateChecker.check(userInitiated:completion:)` takes the flag but does not itself show anything.

Details worth keeping:

* **The badge is restored from disk before the network is touched.** `start()` calls `refreshFromStoredState()` first, so the dot is correct at launch rather than ten seconds into it. `lastSeenLatestVersion` exists for that and nothing else.
* **Only a completed check writes `lastUpdateCheckDate`.** A failure leaving it alone is what makes the next hourly poll retry, which is what anyone offline or behind a rate limit wants.
* **The poll is hourly and asks `UpdateCheckSchedule.isDue`, rather than being a single 24 hour timer.** A Mac sleeps; a day-long timer measures uptime, not elapsed time. A stored date in the future (a clock moved backwards) counts as due, so a bad clock cannot wedge checks until the date comes round again.
* **Skip means "not this one".** `UpdateAvailabilityPolicy` hides a skipped version and anything older, and surfaces anything newer. "Stop telling me" is the preference, and it is a different question.
* **`ReleaseVersion` parses prereleases.** The naive `split(".").compactMap { Int($0) }` read `0.1.25-beta.1` as `[0, 1]`, i.e. *older* than `0.1.24`, so a beta would have suppressed the update instead of offering it. Nothing has shipped through that hole, because `/releases/latest` excludes prereleases; the parse is what stops it opening the first time someone tags one.
* **A Homebrew install is offered the command, not the download.** `UpdateChecker.isHomebrewManaged` looks for a Caskroom receipt under both `/opt/homebrew` and `/usr/local`. Downloading a DMG over a cask-managed copy leaves `brew` believing the old version is installed, and the next `brew upgrade` walks the app backwards. The command goes on the pasteboard, where `ClipboardMonitor` captures it like any other copy, which is correct: the user did copy it.

### UI Framework

Native SwiftUI with `NSHostingController` embedded in `NSPopover` for modern, responsive interface.

```swift
let contentView = ContentView()
let hostingController = NSHostingController(rootView: contentView)
popover.contentViewController = hostingController
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    MenuBarController                     │
│  - NSStatusItem (menu bar icon)                         │
│  - NSPopover (clipboard UI)                             │
│  - Global hotkey registration                           │
└─────────────────────┬───────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────┐
│                    ClipboardMonitor                      │
│  - NSPasteboard polling                                 │
│  - Content type detection                               │
│  - History management                                   │
└─────────────────────┬───────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────┐
│                  PersistenceManager                      │
│  - Core Data stack                                      │
│  - Save/load clipboard items                            │
│  - Image file storage                                   │
│  - Retention policy enforcement                         │
└─────────────────────────────────────────────────────────┘
```

## Building for Distribution

See [DISTRIBUTION.md](../DISTRIBUTION.md) for:

* Code signing with Developer ID
* Notarization with Apple
* Creating DMG installers
* GitHub releases
* Homebrew Cask submission

## Contributing

PRs welcome for:

* Bug fixes and stability improvements
* Performance optimizations
* UI/UX enhancements (keeping simplicity in mind)
* Additional content type support

### Guidelines

1. **Keep it simple**: MacClipboard is intentionally minimal
2. **Test thoroughly**: Especially clipboard monitoring and hotkey functionality
3. **Follow conventions**: Match existing code style
4. **Update docs**: If adding features, update relevant documentation

### What We're NOT Looking For

* Cloud sync features
* Cross-platform support
* Heavy dependencies
* Overly complex UI changes

## Testing

### Manual Testing Checklist

- [ ] Clipboard monitoring captures text, images, files
- [ ] Global hotkey `Cmd+Shift+V` works from any app, and a recorded replacement works immediately
- [ ] Favorites persist after app restart
- [ ] Notes persist after app restart
- [ ] Notes are searchable
- [ ] Settings are saved correctly
- [ ] Multi-select deletion works
- [ ] Search filters items correctly (content and notes)
- [ ] Image preview opens with `Cmd+Z`
- [ ] `Cmd+N` focuses note field
- [ ] `Cmd+Backspace` shows delete confirmation
- [ ] `Cmd+H` toggles sensitive mode on items
- [ ] `Cmd+V` temporarily reveals sensitive content
- [ ] Sensitive reveal auto-hides when switching items or closing popover

### Permissions Testing

1. Revoke accessibility permissions
2. Launch app
3. Verify permission prompt appears
4. Grant permission
5. Verify hotkey works

## Debugging

### Logs

`Logging.info` goes to the unified log at `notice` level, so an installed release build can be
inspected after the fact. `Logging.debug` stays on stdout in Debug builds only, because verbose
messages can reference clipboard content and must not persist anywhere.

```bash
# Installed release build
log show --predicate 'subsystem == "com.macclipboard.app"' --last 1h

# Dev build
log show --predicate 'subsystem == "com.macclipboard.app.dev"' --last 1h

# Live
log stream --predicate 'subsystem BEGINSWITH "com.macclipboard"'
```

If `log` prints "too many arguments", a shell alias is shadowing it. Use `/usr/bin/log`.

### Common Issues

**Hotkey not registering:**
* Check accessibility permissions
* Verify no other app is using the combination (by default `Cmd+Shift+V` for release builds,
  `Cmd+Shift+Opt+V` for dev builds). The popover and Settings both say so when registration is
  refused; recording a different shortcut is the fix.

**Accessibility shows as enabled but the app says permission is missing:**

macOS records an Accessibility grant against the bundle id *and* the code signing requirement
captured when the grant was made. If a differently signed build ever used the same bundle id,
for example a locally built copy signed with the dev certificate, the record survives and keeps
showing as switched on while tccd refuses the running binary. Toggling the switch does not
rewrite the recorded requirement, so the only fix is to delete the record:

```bash
tccutil reset Accessibility com.macclipboard.app      # or .dev for a dev build
defaults delete com.macclipboard.app hasRequestedAccessibilityPromptV1
open -a /Applications/MacClipboard.app                # then approve the prompt
```

The app detects this state itself (it knows it was trusted before) and offers a Repair button in
the popover banner that runs the same reset. `run.sh --reset-permissions` does it for dev builds.

This is why `run.sh` renames the dev bundle to `com.macclipboard.app.dev`: without that, every
`./run.sh` overwrites the shared record and breaks the installed release copy.

**The dev build loses permission after a build from Xcode:**

Fixed in 0.1.17, and worth knowing if you see it on an older checkout. The Debug configuration used
to build with the `.dev` bundle id, so hitting Run or Cmd+U put an ad hoc signed binary behind the
id the signed dev copy holds its grant under. tccd logs the mismatch:

```bash
/usr/bin/log show --predicate 'process == "tccd"' --last 1h | grep macclipboard
# Failed to match existing code requirement for subject com.macclipboard.app.dev
```

The Debug configuration now builds `com.macclipboard.app.debug`, and only `run.sh` promotes a copy
to `.dev`. An ad hoc copy also stops asking for Accessibility it can never keep, and says so in the
popover banner instead.

**Clipboard not updating:**
* Check `NSPasteboard.general.changeCount` is incrementing
* Verify clipboard content type is supported

**Persistence not working:**
* Check Core Data store location
* Verify storage limit not exceeded

## Release Process

1. Update version in Xcode project
2. Run `./build.sh release`
3. Follow prompts for version bump
4. Script handles: build, sign, notarize, tag, GitHub release

See [DISTRIBUTION.md](../DISTRIBUTION.md) for full details.
