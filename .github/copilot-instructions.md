# Copilot Context Guide: MacClipboard

Purpose: A native macOS clipboard manager that tracks clipboard history with menu bar access and global hotkey support for quick clipboard item retrieval and pasting.

## Core Goals
- Always-available clipboard history accessible via menu bar and global hotkey (Cmd+Shift+V)
- Support multiple content types: text, images, files
- Fast, responsive interface with search and preview capabilities
- Lightweight, privacy-focused design (no persistence, no network)
- Native macOS integration with minimal resource usage

## Non-Goals
- No cloud sync or backup functionality  
- No persistent storage (privacy by design)
- No advanced text editing or manipulation
- No cross-platform support
- No complex configuration or plugins

## Architecture Overview
- `MacClipboardApp.swift`: App entry point with NSApplicationDelegate for menu bar-only mode
- `ClipboardMonitor.swift`: Core clipboard tracking via NSPasteboard polling, history management
- `MenuBarController.swift`: NSStatusItem management, popover UI, global hotkey registration (Carbon)
- `ContentView.swift`: SwiftUI interface with clipboard list, search, preview, and selection
- `UserPreferences.swift`: Settings persistence via UserDefaults (max items, hotkey preferences)

## Key Data Types
- `ClipboardItem`: Core data structure with content (Any), type enum, timestamp, preview text
- `ClipboardContentType` enum: `.text`, `.image`, `.file` for different pasteboard content
- `ClipboardMonitor`: ObservableObject that publishes clipboard history changes

## Clipboard Monitoring Strategy
1. Timer-based polling every 0.5 seconds checking NSPasteboard.general.changeCount
2. Content extraction priorities: text → image → file URLs
3. Deduplication by content comparison before adding to history
4. Maximum items limit (default 50) with FIFO removal
5. Move-to-top behavior when pasting existing items

## UI/UX Design Principles
- Menu bar icon: clipboard symbol, left-click for popover, right-click for context menu
- Global hotkey: Cmd+Shift+V opens popover from any app (requires accessibility permission)
- List view: one line per item with icon, preview text, and timestamp
- Selection model: single-click to preview, double-click to paste
- Search: real-time filtering across item content and preview text
- Preview pane: expandable view showing full content for selected items

## Content Type Handling
- **Text**: Direct string content, truncated preview (100 chars, first line)
- **Images**: NSImage objects, shows thumbnail with "📷 Image" label
- **Files**: URL arrays, shows file count and paths with "📁 N file(s)" label
- **Deduplication**: Content-aware comparison (string equality, image presence, URL list equality)

## Global Hotkey Implementation
- Carbon framework RegisterEventHotKey for system-wide Cmd+Shift+V
- Event handler toggles popover visibility
- Requires accessibility permission in System Preferences
- Graceful degradation if permission denied

## Privacy & Security Considerations
- No network access or external communication
- No persistent storage - history cleared on app quit
- Minimal clipboard access pattern - only on detected changes
- Accessibility permission only for hotkey functionality
- In-memory history only, no disk writes

## Performance Guidelines
- Polling interval: 0.5s balance between responsiveness and efficiency
- Content size limits: truncate large text, reasonable image sizes
- Memory management: FIFO history limit, avoid content duplication
- UI updates: main thread for ObservableObject changes
- Efficient search: string contains matching without complex regex

## Extension Points (If Needed Later)
- Configurable hotkey combinations (beyond Cmd+Shift+V)
- Additional content type support (RTF, HTML, custom formats)
- Optional persistence toggle in preferences
- Blacklist for sensitive apps (password managers, etc.)
- Export/import of clipboard history

## Integration Patterns
- NSPasteboard.general for system clipboard access
- NSStatusItem for menu bar presence
- NSPopover with NSHostingController for SwiftUI embedding
- Carbon event handling for global hotkeys
- UserDefaults for preference persistence

## Common Pitfalls
- Clipboard change detection: rely on changeCount, not content polling
- Memory leaks: proper cleanup of Carbon event handlers and timers
- UI thread safety: ensure ObservableObject updates on main queue
- Permission handling: graceful degradation when accessibility denied
- Content lifecycle: avoid retaining large clipboard content unnecessarily

## Testing Strategies (Manual)
- Copy various content types and verify capture
- Test global hotkey from different applications
- Verify search filtering across content types
- Check memory usage with large clipboard history
- Test permission flows and error states

## Suggested Copilot Behaviors
- When asked for new features: consider privacy and performance impact
- Encourage minimal, focused changes that maintain simplicity
- Prefer native macOS patterns over custom implementations
- Consider accessibility and permissions when suggesting UI changes
- Maintain focus on clipboard management core functionality

## Code Style Guidelines
- SwiftUI-first for UI components
- ObservableObject pattern for data models
- Clear separation between clipboard monitoring and UI
- Explicit error handling for system API calls
- Consistent naming: ClipboardXxx for main types

## License
MIT – contributions should preserve lightweight, privacy-focused design.