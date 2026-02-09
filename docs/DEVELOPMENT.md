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
* **Images**: `NSImage` pasteboard objects
* **Files**: `NSURL` pasteboard objects

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
* Contains 3+ character types (uppercase, lowercase, digit, special)

The password detection excludes common false positives:

| Pattern | Examples |
|---------|----------|
| URLs | `https://example.com/path` |
| Emails | `user@example.com` |
| File paths | `/Users/max/file.txt`, `C:\Users\` |
| UUIDs | `550e8400-e29b-41d4-a716-446655440000` |
| IP addresses | `192.168.1.1:8080`, `fe80::1` |
| MAC addresses | `00:1A:2B:3C:4D:5E` |
| ISO dates | `2024-01-15T10:30:00` |
| Versions | `v1.2.3-beta` |
| Domains | `sub.example.com` |
| Phone numbers | `+1-555-123-4567` |

See `SensitiveContentDetector` in `ClipboardMonitor.swift` for implementation details.

### Global Hotkey

Implemented using Carbon framework's `RegisterEventHotKey` for system-wide `Cmd+Shift+V` support.

```swift
// Carbon event handler for global hotkey
var hotKeyRef: EventHotKeyRef?
let hotKeyID = EventHotKeyID(signature: OSType("MCLP"), id: 1)
RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | shiftKey), hotKeyID, ...)
```

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
