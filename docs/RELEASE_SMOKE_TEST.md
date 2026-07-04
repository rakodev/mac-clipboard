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

## Clipboard and Persistence

- [ ] Copy text, an image, and one or more files; confirm each appears with the expected preview.
- [ ] Add a favorite and a note, quit the app, relaunch, and confirm both persisted.
- [ ] Mark an item as sensitive, close and reopen the popover, and confirm it stays hidden until revealed.
- [ ] Lower the history limit and confirm older non-favorite items are trimmed.

## Update and Distribution

- [ ] Use Settings or the context menu to run "Check for Updates" and confirm the alert is understandable.
- [ ] Confirm README privacy language still matches the app's network behavior.
- [ ] If shipping Homebrew, install or upgrade via the cask and confirm the app launches from the expected path.
