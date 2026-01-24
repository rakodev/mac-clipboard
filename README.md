# MacClipboard 📋

Lightweight macOS menu bar clipboard manager that keeps track of your clipboard history with quick access and global hotkey support. Built to be fast, unobtrusive, and native to macOS.

## Why

Managing clipboard history shouldn't be complicated. MacClipboard gives you instant access to your recent copies with a clean interface and global hotkey support.

## Key Features

* 📋 **Automatic clipboard tracking** - Captures text, images, and files as you copy them
* ⌨️ **Global hotkey** - Press `Cmd+Shift+V` to open clipboard history from anywhere
* ⭐ **Favorites** - Save important items that persist indefinitely
* 🔍 **Live search** - Find clipboard items quickly with real-time filtering
* 👀 **Smart preview** - Click any item to see full content before pasting
* 🖼️ **Image preview** - Full-size image preview with `Cmd+Z`
* 🎯 **Quick paste** - Click, press Enter, or use number keys (0-9) to paste
* 💾 **Persistent storage** - History saved to disk, survives app restarts
* 📁 **Multiple content types** - Supports text, images, and file paths
* 🗑️ **Bulk delete** - Select multiple items with `Cmd+Click` for deletion
* ⚡ **Minimal footprint** - Native SwiftUI app with low memory usage
* 🔧 **Highly configurable** - Adjust history size, storage limits, retention days

## Installation

### Homebrew (Recommended)

```bash
brew tap rakodev/tap
brew install --cask macclipboard
```

Or in one command:

```bash
brew install --cask rakodev/tap/macclipboard
```

### Direct Download

Download the latest release from [GitHub Releases](https://github.com/rakodev/mac-clipboard/releases):

1. Download `MacClipboard-Installer.dmg` (or `MacClipboard.zip`)
2. Open the DMG and drag MacClipboard to Applications
3. Launch from Applications or Spotlight
4. Grant accessibility permissions when prompted

### Build from Source

```bash
git clone https://github.com/rakodev/mac-clipboard.git
cd mac-clipboard
make build
```

## Quick Start

After installation, the menu bar icon appears. Press `Cmd+Shift+V` or click it to open clipboard history.

## Usage

### Opening Clipboard History

* **Menu bar icon**: Left-click the clipboard icon in your menu bar
* **Global hotkey**: Press `Cmd+Shift+V` from any application
* **Right-click menu**: Right-click the icon for quick actions

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+Shift+V` | Open clipboard history (global) |
| `Cmd+F` | Switch between All / Favorites view |
| `Cmd+D` | Toggle favorite on selected item |
| `Cmd+Z` | Open image preview (when image selected) |
| `Cmd+Click` | Select multiple items for deletion |
| `0-9` | Quick paste item by number |
| `Enter` | Paste selected item |
| `↑` `↓` | Navigate between items |
| `Escape` | Close clipboard window |

### Using Clipboard Items

* **Preview**: Click any item to see full content in the preview panel
* **Paste**: Click, press Enter, or use number keys (0-9) for quick paste
* **Favorite**: Click the star icon or press `Cmd+D` to save important items
* **Search**: Start typing to filter items instantly
* **Multi-select**: Hold `Cmd` and click to select multiple items for deletion
* **Image zoom**: Press `Cmd+Z` on an image to see full-size preview

### Content Types Supported

* **Text**: Code snippets, URLs, notes, messages
* **Images**: Screenshots, copied images from web/apps
* **Files**: File paths and multiple file selections

## Permissions

MacClipboard automatically requests:

* **Accessibility**: Required for automatic paste functionality and global hotkey (`Cmd+Shift+V`)
- **Clipboard access**: Automatically granted for clipboard monitoring

## Settings

Access settings via the gear icon or right-click menu.

### Clipboard History

* **Maximum items**: 10 - 1,000 items (default: 500)
* Older items automatically removed when limit is reached

### Clipboard Persistence

* **Save clipboard history**: Enable/disable persistent storage
* **Save images to disk**: Store images for faster loading
* **Storage limit**: 10MB - 1GB (default: 1GB)
* **Keep items for**: 1 - 365 days (default: 60 days)
* **Favorites**: Kept indefinitely, regardless of retention settings

### Global Hotkey

* Enable/disable `Cmd+Shift+V` global shortcut

### Keyboard Shortcuts

* Enable/disable in-app keyboard shortcuts (`Cmd+D`, `Cmd+F`, `Cmd+Z`, etc.)

## Requirements
 
macOS 13.0+, Xcode 15+ (to build from source).

## Development

```bash
make build     # release build with DMG/ZIP
make dev       # fast debug build
make run       # build and run
make clean     # clean build artifacts
```

Or open in Xcode:

```bash
open MacClipboard.xcodeproj
# Press ⌘+R to build and run
```

## Uninstall

If installed via Homebrew:

```bash
brew uninstall --cask macclipboard
```

If installed manually, quit the app and run:

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

**Data Storage**: Clipboard history persisted to `~/Library/Application Support/MacClipboard` using Core Data. Favorites are kept indefinitely.

**UI Framework**: Native SwiftUI with `NSHostingController` embedded in `NSPopover` for modern, responsive interface.

## Privacy & Security

* **No network access**: All data stays on your Mac
* **Local storage only**: History stored in `~/Library/Application Support/MacClipboard`
* **Configurable retention**: Set how long items are kept (or disable persistence entirely)
* **Secure by design**: Only accesses clipboard when content changes
* **Minimal permissions**: Only needs accessibility for hotkey and auto-paste

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

**Menu bar icon click not working?**

* Left-click the icon to open clipboard history
* Right-click the icon for settings and other options
* If clicks aren't responding, try restarting the app

**Persistence not working?**

* Right-click the menu bar icon and select "Settings..."
* Ensure "Enable Persistence" is toggled on (enabled by default)
* Check available storage space if items aren't being saved
* Persistence is disabled if storage limit is exceeded

**Focus not returning after using clipboard?**

* When you close the clipboard (Escape or click outside), focus automatically returns to your previous application
* If focus doesn't restore properly, ensure the clipboard app has accessibility permissions
* This works for both keyboard shortcuts and clicking outside the popover

## License

MIT. See [LICENSE](LICENSE).

---

Built with ❤️ for better clipboard management on macOS.
