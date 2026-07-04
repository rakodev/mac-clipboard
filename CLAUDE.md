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
```

## Project Structure

```
MacClipboard/
├── MacClipboardApp.swift      # App entry point & AppDelegate
├── ClipboardMonitor.swift     # Clipboard polling (0.8s interval), history management
├── MenuBarController.swift    # Status bar item, popover, global hotkey registration
├── ContentView.swift          # Main UI: filter tabs, search, item list, preview
├── SettingsView.swift         # Settings panel UI
├── UserPreferences.swift      # UserPreferencesManager singleton (UserDefaults)
├── PersistenceManager.swift   # Core Data stack, save/load items, image storage
├── PermissionManager.swift    # Accessibility permission handling
├── Logging.swift              # Debug/release logging utility
└── ClipboardData.xcdatamodeld # Core Data model (PersistedClipboardItem entity)
```

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
- `isFavorite`, `isSensitive`: Boolean
- `note`: String (user-added)
- `createdAt`, `updatedAt`: Date

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+Shift+V` | Global: Open clipboard (from any app) |
| `Enter` | Paste selected item |
| `0-9` | Quick paste by position |
| `↑/↓` | Navigate items |
| `Cmd+F` | Cycle filter tabs |
| `Cmd+D` | Toggle favorite |
| `Cmd+H` | Toggle sensitive mode |
| `Cmd+V` | Reveal sensitive item |
| `Cmd+N` | Focus note field |
| `Cmd+Z` | Full-size image preview |
| `Cmd+Backspace` | Delete item(s) |
| `Escape` | Close popover |

## User Preferences

Settings stored in UserDefaults via `UserPreferencesManager`:
- `maxClipboardItems`: 10-1000 (default: 200)
- `persistenceEnabled`: Bool (default: true)
- `saveImages`: Bool (default: true)
- `maxStorageSize`: Bytes (default: 1GB)
- `persistenceDays`: 1-365 (default: 60)
- `hotKeyEnabled`: Bool (default: true)
- `shortcutsEnabled`: Bool (default: true)
- `autoStartEnabled`: Bool (default: true)

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
- [ ] Search filters by content and notes
- [ ] Sensitive mode hides/reveals correctly

When modifying UI:
- [ ] Filter tabs work correctly
- [ ] Keyboard navigation functions
- [ ] Multi-select deletion works
- [ ] Image preview opens with Cmd+Z

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

## Entitlements

The app requires:
- `com.apple.security.automation.apple-events` - For paste automation
- Accessibility permissions - For global hotkey (requested at runtime)

## Important Files for Common Tasks

| Task | Files to Modify |
|------|-----------------|
| Add keyboard shortcut | `ContentView.swift` (local), `MenuBarController.swift` (global) |
| Change clipboard polling | `ClipboardMonitor.swift` |
| Modify settings | `SettingsView.swift`, `UserPreferences.swift` |
| Update data model | `ClipboardData.xcdatamodeld`, `PersistenceManager.swift`, `ClipboardMonitor.swift` |
| Change UI layout | `ContentView.swift` |
| Modify menu bar behavior | `MenuBarController.swift` |
