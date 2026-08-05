# MacClipboard Follow-Ups

Follow-ups are ideas worth revisiting later, but not committed backlog work yet. Promote an item to `BACKLOG.md` when it has a clear problem statement, priority, and acceptance criteria.

## Future Improvements

- [ ] Show the install location and signing identity in the Accessibility onboarding window, not just in Settings and the popover banner.
  - Why later: the launch alert and Settings > Installation already cover the failure cases; onboarding copy should be revisited as a whole rather than patched.

- [ ] Consider having the Homebrew cask refuse to install while a copy exists outside `/Applications`.
  - Why later: needs care not to break users who deliberately keep the app in `~/Applications`, and cask preflight behaviour should be tested against a real upgrade.

- [ ] Evaluate configurable clipboard exclusion rules for apps or content patterns.
  - Why later: valuable for privacy, but needs careful UX so users do not accidentally miss expected captures.

- [ ] Explore richer search ranking and tokenization.
  - Why later: current search is simple and understandable; improve only after measuring pain with larger histories.

- [ ] Consider optional per-item tags beyond notes and favorites.
  - Why later: can improve organization, but may add UI complexity to a lightweight menu bar app.

- [ ] Investigate a command palette style keyboard workflow.
  - Why later: could make MacClipboard faster for power users, but should not compromise the compact current UI.

- [ ] Explore importing/exporting clipboard history with privacy safeguards.
  - Why later: useful for migration and backup, but needs strong filtering, warnings, and encryption decisions.

- [ ] Consider a first-run guided setup that verifies permissions, shortcut behavior, and persistence.
  - Why later: onboarding exists for Accessibility, but a broader guided setup should be validated against keeping launch lightweight.

- [ ] Research a safer default for sensitive-content auto-detection.
  - Why later: enabling more protection by default is attractive, but false positives and user trust need testing.

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
