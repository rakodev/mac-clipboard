# MacClipboard 📋

Lightweight macOS menu bar clipboard manager that keeps track of your clipboard history with quick access and global hotkey support. Built to be fast, unobtrusive, and native to macOS.

![MacClipboard Demo](assets/demo.gif)

## Why
Managing clipboard history shouldn't be complicated. MacClipboard gives you instant access to your recent copies with a clean interface and global hotkey support.

## Key Features

* 📋 **Automatic clipboard tracking** - Captures text, images, and files as you copy them
* ⌨️ **Global hotkey** - Press `Cmd+Shift+V` to open clipboard history from anywhere
* 🔍 **Live search** - Find clipboard items quickly with real-time filtering
* 👀 **Smart preview** - Click any item to see full content before pasting
* 🎯 **One-click paste** - Click or press Enter to paste any item automatically
* 🔒 **Smart permissions** - Automatically requests accessibility permissions for paste functionality
* 📁 **Multiple content types** - Supports text, images, and file paths
* ⚡ **Minimal footprint** - Native SwiftUI app with low memory usage
* 🔧 **Configurable** - Adjust history size and preferences

## Quick Start

```bash
git clone https://github.com/yourusername/macclipboard.git
cd mac-clipboard
make run
```

Menu bar icon appears; press `Cmd+Shift+V` or click it to open history.

## Install (Binary)
 
1. Download the latest release (DMG or ZIP)
2. Move `MacClipboard.app` to Applications
3. Launch (Spotlight or Applications)
4. Grant accessibility permissions when prompted for automatic paste functionality

## Usage

### Opening Clipboard History

* **Menu bar icon**: Left-click the clipboard icon in your menu bar
* **Global hotkey**: Press `Cmd+Shift+V` from any application
* **Right-click menu**: Right-click the icon for quick actions

### Using Clipboard Items

* **Preview**: Click once on any item to see a larger preview
* **Paste**: Click any item or press Enter to automatically paste it
* **Search**: Type in the search bar to filter items
* **Navigation**: Use arrow keys to navigate between items
* **Clear**: Use the trash icon or right-click menu to clear history

### Content Types Supported

* **Text**: Code snippets, URLs, notes, messages
* **Images**: Screenshots, copied images from web/apps
* **Files**: File paths and multiple file selections

## Permissions

MacClipboard automatically requests:

* **Accessibility**: Required for automatic paste functionality and global hotkey (`Cmd+Shift+V`)
- **Clipboard access**: Automatically granted for clipboard monitoring

## Settings Persist
 
Settings are automatically saved including:
- Maximum clipboard items (default: 50)
- Hotkey enabled/disabled
- Window preferences

## Requirements
 
macOS 13.0+, Xcode 15+ (to build from source).

## Build From Source

```bash
make build     # release build with DMG/ZIP
make dev       # fast debug build
make run       # build and run
make clean     # clean build artifacts
```

For development in Xcode:
```bash
open MacClipboard.xcodeproj
# Press ⌘+R to build and run
```

## Uninstall

Quit the app, then remove:

```bash
rm -rf /Applications/MacClipboard.app
defaults delete com.macclipboard.app 2>/dev/null || true
```

## Project Structure

```text
MacClipboard/
  MacClipboardApp.swift     App entry point & delegate
  ClipboardMonitor.swift    Clipboard tracking & history
  MenuBarController.swift   Status item, popover, hotkey
  ContentView.swift         SwiftUI UI components
  UserPreferences.swift     Settings persistence
  Assets.xcassets/          Icons & assets
```

## Technical Details

**Clipboard Monitoring**: Uses `NSPasteboard.general` with change count polling every 0.5 seconds for reliable clipboard tracking.

**Content Support**:

* Text via `NSPasteboard.string(forType: .string)`
* Images via `NSImage` pasteboard objects
* Files via `NSURL` pasteboard objects

**Global Hotkey**: Implemented using Carbon framework's `RegisterEventHotKey` for system-wide `Cmd+Shift+V` support.

**Data Storage**: Clipboard history stored in memory only (not persisted between app launches for privacy).

**UI Framework**: Native SwiftUI with `NSHostingController` embedded in `NSPopover` for modern, responsive interface.

## Privacy & Security

* **No network access**: All data stays on your Mac
* **No persistent storage**: History cleared when app quits
* **Secure by design**: Only accesses clipboard when content changes
* **Minimal permissions**: Only needs accessibility for hotkey

## Goals

* Fast, responsive clipboard access
* Native macOS look and feel
* Minimal resource usage
* Privacy-focused design
* Simple but powerful interface

## Non-Goals

* Cloud sync or backup
* Advanced text editing
* Clipboard encryption
* Cross-platform support

## Contributing

PRs welcome for:

* Bug fixes and stability improvements
* Performance optimizations
* UI/UX enhancements (keeping simplicity in mind)
* Additional content type support

Please keep changes focused and maintain the lightweight philosophy.

## Troubleshooting

**Global hotkey not working?**

* Check System Settings > Privacy & Security > Accessibility
* Ensure MacClipboard is allowed

**App not capturing clipboard?**

* Try quitting and restarting the app
* Check if another clipboard manager is running

**Can't see menu bar icon?**

* The icon appears as a clipboard symbol in your menu bar
* Try adjusting menu bar item spacing in System Settings

## License

MIT. See [LICENSE](LICENSE).

---
Built with ❤️ for better clipboard management on macOS.
