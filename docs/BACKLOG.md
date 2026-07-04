# MacClipboard Backlog

Goal: make MacClipboard the best clipboard manager app for macOS. Every task here should improve reliability, speed, privacy, usability, or maintainability.

Move completed items to `BACKLOG_ARCHIVE.md` with the completion date and a short note about what changed.

## Priority Tasks

### P1 - Product Quality

- [ ] Respect the `hotKeyEnabled` preference at runtime.
  - Evidence: `MenuBarController` registers the global hotkey during setup, but preference changes are not visibly unregistering or re-registering it.
  - Acceptance: toggling the setting immediately enables/disables `Cmd+Shift+V` without app restart.

- [ ] Replace ad-hoc update checking with a privacy-conscious update service abstraction.
  - Evidence: `MenuBarController.checkForUpdates()` performs a direct GitHub API request from UI/controller code.
  - Acceptance: update checking is isolated, cancelable/testable, handles rate limits, and documents that it is the app's only network call if retained.

- [ ] Standardize logging and remove direct `print` calls from production paths.
  - Evidence: `PersistenceManager` still prints save/load/delete errors while `Logging` exists for controlled output.
  - Acceptance: all runtime diagnostics go through `Logging` or a structured logger; release builds stay quiet except for actionable failures.

- [ ] Improve accessibility and localization readiness for user-facing strings.
  - Evidence: menu items, alerts, buttons, onboarding, and empty states are hardcoded throughout SwiftUI/AppKit views.
  - Acceptance: user-facing strings are centralized or localized with `LocalizedStringKey`/string resources, and key icon-only buttons have accessibility labels.

- [ ] Fix Settings links and preference range mismatches.
  - Evidence: `SettingsView` opens the generic `https://github.com` URL, and its storage slider uses 100MB-5GB while `UserPreferencesManager` accepts 10MB-10GB.
  - Acceptance: Settings links point to the MacClipboard repository, and UI controls use the same bounds as the underlying preference validation.

- [ ] Reset selection focus appropriately when switching clipboard filter tabs.
  - Evidence: switching from Favorites back to All can keep focus on a favorite item from much earlier in history, causing the All list to scroll far down unexpectedly.
  - Acceptance: changing filter tabs leaves the list positioned predictably near the top or on the first relevant item, without preserving a stale off-screen selection from the previous tab.

- [ ] Split `ContentView` into smaller focused views and action handlers.
  - Evidence: `ContentView` owns filtering, keyboard handling, row/list rendering, preview, deletion confirmation, shortcut help, note editing, and image loading state.
  - Acceptance: filtering/search state, preview, list rows, shortcuts, and destructive actions are separated enough to test and maintain independently.

### P2 - Maintainability and Polish

- [ ] Remove dead or duplicate helper code.
  - Evidence: `MenuBarController` contains a private `fourCharCode(_:)` method and a file-level `fourCharCodeFrom(_:)` helper with overlapping purpose; `Logger.swift` is empty; `ClipboardManagerApp.swift` is an inert legacy placeholder.
  - Acceptance: only needed source files and helpers remain, covered by their active usage paths.

- [ ] Normalize formatting and indentation in app startup and menu-bar code.
  - Evidence: several blocks in `MacClipboardApp`, `MenuBarController`, and `PermissionManager` have inconsistent indentation or empty branches.
  - Acceptance: SwiftFormat or the repo's chosen formatter produces a clean no-op diff after formatting.

- [ ] Add a lightweight manual release smoke-test checklist.
  - Evidence: `CLAUDE.md` has feature checklists, but no release-focused pass for persistence migration, permissions, update check, install path, and Homebrew cask behavior.
  - Acceptance: release checklist exists and is referenced before distribution builds.

- [ ] Document privacy boundaries for clipboard data and update checks in developer docs.
  - Evidence: README says no network access, while update checking currently reaches GitHub when the user triggers it.
  - Acceptance: README and developer docs accurately explain local-only clipboard storage and any explicit network behavior.
