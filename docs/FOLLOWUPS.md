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

- [ ] Decide whether anything should be done about the slow first launch after a Homebrew upgrade.
  - Measured on the 0.1.16 to 0.1.17 upgrade: the app process started at 23:37:40 and reached
    `applicationDidFinishLaunching` at 23:39:12, so the menu bar icon was missing for 92 seconds.
    A plain relaunch of the same bundle a minute later checked in in 0.086 seconds, so this is
    the one-time Gatekeeper assessment of a freshly installed bundle, not our code: Homebrew
    quarantines cask apps (`com.apple.quarantine` is present on the installed app), and syspolicyd
    opens a TLS connection at exec time to check the notarisation ticket. XProtect itself finished
    in 30ms, so the time is in that check.
  - Why later: it is macOS behaviour on a security check, and the old cask hid it by accident
    rather than fixing it (its `open -a` just re-activated the still-running old copy, so the
    check happened at some later launch instead). Stripping `com.apple.quarantine` in `postflight`
    would remove the pause and the check with it, which is not a trade to make quietly. Worth
    measuring on another machine and a slower network first, since a user seeing no icon for a
    minute and a half may well quit and retry.
