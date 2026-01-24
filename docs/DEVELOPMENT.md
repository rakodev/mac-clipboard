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
make run
```

## Build Commands

```bash
make build     # Release build with DMG/ZIP
make dev       # Fast debug build
make run       # Build and run
make clean     # Clean build artifacts
```

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
* **Images**: `NSImage` pasteboard objects
* **Files**: `NSURL` pasteboard objects

### Global Hotkey

Implemented using Carbon framework's `RegisterEventHotKey` for system-wide `Cmd+Shift+V` support.

```swift
// Carbon event handler for global hotkey
var hotKeyRef: EventHotKeyRef?
let hotKeyID = EventHotKeyID(signature: OSType("MCLP"), id: 1)
RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | shiftKey), hotKeyID, ...)
```

### Data Storage

Clipboard history persisted to `~/Library/Application Support/MacClipboard` using Core Data.

* Regular items: Subject to retention settings (default 60 days)
* Favorites: Kept indefinitely
* Images: Optionally stored to disk for faster loading

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
- [ ] Global hotkey `Cmd+Shift+V` works from any app
- [ ] Favorites persist after app restart
- [ ] Settings are saved correctly
- [ ] Multi-select deletion works
- [ ] Search filters items correctly
- [ ] Image preview opens with `Cmd+Z`

### Permissions Testing

1. Revoke accessibility permissions
2. Launch app
3. Verify permission prompt appears
4. Grant permission
5. Verify hotkey works

## Debugging

### Logs

View logs in Console.app or:

```bash
log stream --predicate 'subsystem == "com.macclipboard.MacClipboard"' --level debug
```

### Common Issues

**Hotkey not registering:**
* Check accessibility permissions
* Verify no other app is using `Cmd+Shift+V`

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
