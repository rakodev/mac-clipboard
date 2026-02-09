# Makefile for MacClipboard

.PHONY: all build dev clean install run release help

# Default target
all: build

# Build for release
build:
	@echo "🚀 Building MacClipboard for release..."
	@./build.sh

# Build for development (use ./run.sh for full dev workflow with signing)
dev:
	@echo "🔧 Building debug version..."
	@xcodebuild -project MacClipboard.xcodeproj -scheme MacClipboard -configuration Debug build
	@echo "✅ Debug build completed!"

# Clean build artifacts
clean:
	@echo "🧹 Cleaning build artifacts..."
	@rm -rf build/
	@rm -rf DerivedData/
	@echo "✅ Clean completed!"

# Build, sign, notarize, and create a GitHub release
release:
	@echo "📦 Building and releasing MacClipboard..."
	@./build.sh release

# Run the application (recommended for development)
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
	@echo "  dev      - Build debug version only"
	@echo "  run      - Build, sign, and run (recommended for development)"
	@echo "  release  - Build, sign, notarize, and create GitHub release"
	@echo "  clean    - Clean build artifacts"
	@echo "  install  - Check and install dependencies"
	@echo "  help     - Show this help message"
	@echo ""
	@echo "Development workflow:"
	@echo "  make run     # Build, sign with dev cert, and run"
	@echo "  ./run.sh     # Same as above"
	@echo ""
	@echo "First time setup:"
	@echo "  ./scripts/setup-dev-signing.sh"
