# Release Smoke-Test Checklist

Run this before creating a distribution build or publishing a Homebrew cask update.

## Build and Install

- [ ] Build the release artifact with `./build.sh release` or the documented release command.
- [ ] Install the generated DMG or ZIP into `/Applications` on a clean or secondary macOS account.
- [ ] Launch from `/Applications` and confirm the menu bar icon appears.

## Permissions and Shortcuts

- [ ] Grant Accessibility permission when prompted.
- [ ] Confirm `Cmd+Shift+V` opens the popover from another app.
- [ ] Disable and re-enable the global hotkey in Settings and confirm the shortcut responds immediately.
- [ ] Confirm paste returns focus to the previous app.
- [ ] Confirm the Settings footer reads `Release` (a shipped build must never say `Dev`).
- [ ] Run `tccutil reset Accessibility com.macclipboard.app` while the app is running, wait for
      the banner to change to "Accessibility permission stopped working", press Repair, and
      confirm the system prompt appears and the grant works afterwards.

## Installation Hygiene

These paths move and trash app bundles, so exercise them by hand on a secondary account before
shipping. Build with `./build.sh --keep-export` so a loose bundle is available to copy around.

- [ ] Copy the exported app to `~/Downloads` and open it from there. Confirm the alert says
      MacClipboard is not in your Applications folder, press **Move to Applications**, and check
      that it relaunches from `/Applications`, the `~/Downloads` copy is in the Trash, and the
      Accessibility grant still holds.
- [ ] Open the DMG and launch the app from the mounted image. Confirm the alert names the disk
      image and that **Not Now** leaves the app running.
- [ ] With a good copy in `/Applications`, put a second copy in `~/Applications` and launch the
      `/Applications` one. Confirm the duplicate alert lists the other copy and names the copy to
      keep, that **Show in Finder** reveals it, and that **Move Others to Trash** removes it.
- [ ] Confirm the same information appears under Settings > Installation while a duplicate exists,
      and that the section disappears once the copy is gone.
- [ ] Confirm the popover banner reads "More than one copy of MacClipboard is installed" when a
      duplicate holds the grant, rather than the plain "enable it in System Settings" text.
- [ ] `log show --predicate 'subsystem == "com.macclipboard.app"' --last 10m | grep Install`
      prints one `[Install]` line per launch with the path, identity and any duplicates.

## Signing

- [ ] `codesign -d --entitlements - --xml /Applications/MacClipboard.app` lists
      `com.apple.security.automation.apple-events` and does not list `get-task-allow`.
- [ ] `codesign -d -r- /Applications/MacClipboard.app` still prints the pinned designated
      requirement (`identifier "com.macclipboard.app" and anchor apple generic and
      certificate leaf[subject.OU] = K542B2Z65M`). Changing it invalidates every user's
      Accessibility grant.
- [ ] `spctl -a -vvv /Applications/MacClipboard.app` reports `source=Notarized Developer ID`.
- [ ] `codesign -dvvv build/MacClipboard-Installer.dmg` names the Developer ID authority and prints
      a `Timestamp`. The disk image carries a signature of its own, not only the app inside it.
- [ ] `spctl -a -t open --context context:primary-signature -vv build/MacClipboard-Installer.dmg`
      reports `accepted` with `source=Notarized Developer ID`. This is what Gatekeeper does when
      the user opens the download. `build.sh` fails the build on a rejection, so a passing build is
      already evidence; run it by hand on the published artifact after downloading it.
- [ ] `xcrun stapler validate build/MacClipboard-Installer.dmg` still says the validate action
      worked. Signing an image drops a ticket already stapled to it, so this is what catches the
      sign and staple steps being reordered.

## Clipboard and Persistence

- [ ] Copy text, an image, and one or more files; confirm each appears with the expected preview.
- [ ] Add a favorite and a note, quit the app, relaunch, and confirm both persisted.
- [ ] Copy something, then `kill -TERM` the app: it must exit cleanly and still have that item
      after relaunching (the Homebrew cask stops the app this way on every upgrade).
- [ ] Mark an item as sensitive, close and reopen the popover, and confirm it stays hidden until revealed.
- [ ] Lower the history limit and confirm older non-favorite items are trimmed.

## Update and Distribution

- [ ] Use Settings or the context menu to run "Check for Updates" and confirm the alert is understandable.
- [ ] Confirm README privacy language still matches the app's network behavior.
- [ ] If shipping Homebrew, install or upgrade via the cask and confirm the app launches from the expected path.
