# Makefile f# Build for development
dev:
	@echo "�️ Building debug version..."
	@xcodebuild -project MacClipboard.xcodeproj -scheme MacClipboard -configuration Debug build
	@echo "🔑 Code signing for accessibility stability..."
	@codesign --force --deep --sign - ~/Library/Developer/Xcode/DerivedData/MacClipboard-*/Build/Products/Debug/MacClipboard.app 2>/dev/null || echo "⚠️ Code signing skipped"
	@echo "✅ Debug build completed!"lipboard (renamed project/target)

.PHONY: all build dev clean install run help

# Default target
all: build

# Build for release
build:
	@echo "🚀 Building MacClipboard for release..."
	@./build.sh

# Build for development
dev:
	@echo "�️ Building debug version..."
	@xcodebuild -project MacClipboard.xcodeproj -scheme MacClipboard -configuration Debug build
	@echo "🔑 Code signing for accessibility stability..."
	@codesign --force --deep --sign - build/Debug/MacClipboard.app 2>/dev/null || echo "⚠️ Code signing skipped"
	@echo "✅ Debug build completed!"

# Clean build artifacts
clean:
	@echo "🧹 Cleaning build artifacts..."
	@rm -rf build/
	@rm -rf DerivedData/
	@echo "✅ Clean completed!"

# Run the application
run:
	@echo "🚀 Running MacClipboard..."
	@./run.sh

# Install dependencies (if needed)
install:
	@echo "📦 Checking dependencies..."
	@if ! command -v xcodebuild &> /dev/null; then \
		echo "❌ Xcode command line tools not found"; \
		echo "Please install with: xcode-select --install"; \
		exit 1; \
	fi
	@if ! command -v create-dmg &> /dev/null; then \
		echo "⚠️  create-dmg not found (optional for DMG creation)"; \
		echo "Install with: brew install create-dmg"; \
	fi
	@echo "✅ Dependencies check completed!"

# Show help
help:
	@echo "MacClipboard Build System"
	@echo ""
	@echo "Available targets:"
	@echo "  build    - Build for release distribution"
	@echo "  dev      - Build for development"
	@echo "  run      - Run the application (builds if needed)"
	@echo "  clean    - Clean build artifacts"
	@echo "  install  - Check and install dependencies"
	@echo "  help     - Show this help message"
	@echo ""
	@echo "Usage examples:"
	@echo "  make build   # Build release version"
	@echo "  make dev     # Build development version"
	@echo "  make clean   # Clean all build files"