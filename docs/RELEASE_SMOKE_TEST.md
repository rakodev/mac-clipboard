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

## Signing

- [ ] `codesign -d --entitlements - --xml /Applications/MacClipboard.app` lists
      `com.apple.security.automation.apple-events` and does not list `get-task-allow`.
- [ ] `codesign -d -r- /Applications/MacClipboard.app` still prints the pinned designated
      requirement (`identifier "com.macclipboard.app" and anchor apple generic and
      certificate leaf[subject.OU] = K542B2Z65M`). Changing it invalidates every user's
      Accessibility grant.
- [ ] `spctl -a -vvv /Applications/MacClipboard.app` reports `source=Notarized Developer ID`.

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
