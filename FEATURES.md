# MacClipboard Features

## ✅ Implemented Features

### Core Functionality
- **Clipboard History Tracking**: Automatically monitors and stores clipboard changes
- **Menu Bar Integration**: Native macOS menu bar icon for easy access
- **Global Hotkey**: Press `Cmd+Shift+V` from anywhere to open clipboard history
- **Search Functionality**: Filter clipboard items with real-time search
- **Preview Mode**: Hover over items to see expanded preview
- **One-Click Paste**: Select any item to paste it immediately

### Technical Features
- **Native macOS App**: Built with SwiftUI and AppKit for native performance
- **Universal Binary**: Supports both Apple Silicon (ARM64) and Intel (x86_64)
- **Configurable History**: Adjustable maximum clipboard items (default: 50)
- **Multiple Content Types**: 
  - Plain text
  - Rich text (RTF)
  - Images
  - URLs
- **Persistent Storage**: Clipboard history survives app restarts
- **Memory Efficient**: Automatic cleanup of old items

### User Interface
- **Clean SwiftUI Design**: Modern, native macOS appearance
- **Responsive Layout**: Adapts to different screen sizes
- **Keyboard Navigation**: Full keyboard support for accessibility
- **Visual Feedback**: Clear selection and hover states
- **Compact Popover**: Non-intrusive interface that appears on demand

## 🚀 Usage

1. **Launch the App**: The MacClipboard icon appears in your menu bar
2. **Copy Items**: Normal copy operations (Cmd+C) are automatically tracked
3. **Access History**: 
   - Click the menu bar icon, OR
   - Press `Cmd+Shift+V` from anywhere
4. **Search**: Type in the search box to filter items
5. **Select & Paste**: Click any item to paste it to the active application

## 🛠️ Build & Run

```bash
# Build and run
make run

# Just build
make build

# Development build (faster)
make dev-build

# Clean build artifacts
make clean
```

## 📁 Project Structure

```
MacClipboard/
├── MacClipboardApp.swift    # App entry point
├── ClipboardMonitor.swift       # Core clipboard monitoring
├── MenuBarController.swift      # Menu bar integration & hotkeys
├── ContentView.swift           # SwiftUI interface
├── UserPreferences.swift       # Settings management
└── Assets.xcassets/           # App icons & resources
```

## 🎯 Key Benefits

- **No Manual Management**: Automatically captures all clipboard activity
- **Instant Access**: Global hotkey for immediate access from any app
- **Native Performance**: Built with Apple's frameworks for optimal speed
- **Privacy Focused**: All data stored locally on your Mac
- **Lightweight**: Minimal resource usage and memory footprint
- **Professional Grade**: Follows macOS design guidelines and best practices

## 🔧 Customization

The app supports customization through `UserPreferences`:
- Maximum clipboard items to retain
- Hotkey combinations (currently Cmd+Shift+V)
- Display preferences