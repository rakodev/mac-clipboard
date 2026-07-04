# MacClipboard Backlog

Goal: make MacClipboard the best clipboard manager app for macOS. Every task here should improve reliability, speed, privacy, usability, or maintainability.

Move completed items to `BACKLOG_ARCHIVE.md` with the completion date and a short note about what changed.

## Priority Tasks

### P1 - Product Quality

- [ ] Improve accessibility and localization readiness for user-facing strings.
  - Evidence: menu items, alerts, buttons, onboarding, and empty states are hardcoded throughout SwiftUI/AppKit views.
  - Acceptance: user-facing strings are centralized or localized with `LocalizedStringKey`/string resources, and key icon-only buttons have accessibility labels.

- [ ] Split `ContentView` into smaller focused views and action handlers.
  - Evidence: `ContentView` owns filtering, keyboard handling, row/list rendering, preview, deletion confirmation, shortcut help, note editing, and image loading state.
  - Acceptance: filtering/search state, preview, list rows, shortcuts, and destructive actions are separated enough to test and maintain independently.

### P2 - Maintainability and Polish

- [ ] Normalize formatting and indentation in app startup and menu-bar code.
  - Evidence: several blocks in `MacClipboardApp`, `MenuBarController`, and `PermissionManager` have inconsistent indentation or empty branches.
  - Acceptance: SwiftFormat or the repo's chosen formatter produces a clean no-op diff after formatting.

