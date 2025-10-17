# MacClipboard Build Guide

## Build Scripts Overview

### Development Builds

**`run.sh`** - Quick development build and run
- Uses development code signing
- Retains debugging symbols
- Automatically launches after build
- Best for: Daily development and testing

**`build-dev.sh`** - Signed development build for export
- Uses development code signing with proper entitlements
- Creates exportable .app bundle
- Retains accessibility permissions across builds
- Best for: Testing exported versions during development

### Distribution Builds

**`build.sh`** - Production build for distribution
- Uses "Sign to Run Locally" identity
- Optimized release configuration
- Creates ZIP archive for distribution
- Best for: Final releases and distribution

## Accessibility Permissions & Code Signing

### The Issue
macOS tracks accessibility permissions by app signature. Different signatures = different permission grants needed.

### Build Signature Differences:
- **`run.sh`**: Development signing (keeps permissions)
- **`build-dev.sh`**: Development signing (keeps permissions) 
- **`build.sh`**: Local distribution signing (requires new permissions)

### Recommendation:
1. **During development**: Use `run.sh` for daily work
2. **Testing exports**: Use `build-dev.sh` to test exported apps without losing permissions
3. **Final distribution**: Use `build.sh` and inform users about permission requirements

## Permission Requirements Notice

When distributing the app built with `build.sh`, include this notice:

> **Important**: This app requires accessibility permissions to paste clipboard items automatically. 
> 
> If you previously used a development version, you'll need to re-grant permissions:
> 1. Go to System Settings > Privacy & Security > Accessibility
> 2. Remove MacClipboard if it appears in the list
> 3. Launch MacClipboard again and grant permissions when prompted

## Quick Commands

```bash
# Development work
./run.sh

# Test export build (keeps permissions)
./build-dev.sh

# Final distribution build
./build.sh
```

## Troubleshooting

**Q: My exported app doesn't have accessibility permissions**
A: If you used `build.sh`, the signature is different. Re-grant permissions in System Settings.

**Q: I want to test exports without losing permissions**
A: Use `build-dev.sh` instead of `build.sh` for testing.

**Q: The app won't launch**
A: Make sure the script is executable: `chmod +x build.sh`