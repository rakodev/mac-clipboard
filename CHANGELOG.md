# Changelog

All notable changes to MacClipboard will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial release of MacClipboard
- Automatic clipboard tracking for text, images, and files
- Global hotkey support (Cmd+Shift+V)
- Menu bar icon with popover interface
- Real-time search and filtering
- Content preview with full-text view
- Support for multiple clipboard content types
- Configurable history size (default: 50 items)
- Native SwiftUI interface
- Right-click context menu
- Privacy-focused design (no persistence)

### Features

- **Core Functionality**
  - Clipboard history tracking with automatic capture
  - Support for text, images, and file content types
  - Intelligent deduplication of identical content
  - Move-to-top behavior for recently used items

 
- **User Interface**
  - Clean SwiftUI-based popover interface
  - Menu bar icon with system clipboard symbol
  - Real-time search across clipboard history
  - Content preview with expandable details
  - Visual indicators for different content types

 
- **System Integration**
  - Global hotkey (Cmd+Shift+V) using Carbon framework
  - Native macOS menu bar integration
  - Proper accessibility permission handling
  - Right-click context menu for quick actions

 
- **Privacy & Performance**
  - In-memory storage only (no disk persistence)
  - Efficient polling-based clipboard monitoring
  - Minimal resource usage and memory footprint
  - No network access or external dependencies

## [1.0.0] - Initial Release

### Release Summary

- Complete clipboard manager functionality
- Native macOS app with menu bar integration
- Global hotkey support for quick access
- Multi-format clipboard content support
- Search and preview capabilities
- Privacy-focused, memory-only design
