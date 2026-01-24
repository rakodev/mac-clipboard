# MacClipboard Distribution Guide

This guide covers how to build and distribute MacClipboard as a signed and notarized macOS app.

## Prerequisites

- Apple Developer Program membership ($99/year)
- Developer ID Application certificate installed in Keychain

## Setup (One-Time)

### 1. Create Developer ID Application Certificate

If you haven't already:

1. Open **Xcode → Settings → Accounts**
2. Select your Apple ID → click your team
3. Click **Manage Certificates**
4. Click **+** → **Developer ID Application**

Verify it's installed:
```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

You should see:
```
"Developer ID Application: Ramazan KORKMAZ (K542B2Z65M)"
```

### 2. Create App-Specific Password for Notarization

1. Go to [appleid.apple.com](https://appleid.apple.com) → Sign In
2. Go to **Sign-In and Security** → **App-Specific Passwords**
3. Click **+** to generate a new password
4. Name it "notarytool" or similar
5. Copy the password (you'll only see it once)

### 3. Store Notarization Credentials in Keychain

> **Status: COMPLETE** - Credentials stored as `MacClipboard-Notarize`

If you ever need to re-create the credentials (new machine, revoked password, etc.):

```bash
xcrun notarytool store-credentials "MacClipboard-Notarize" \
  --apple-id "ramax@atalist.com" \
  --team-id "K542B2Z65M"
```

When prompted, enter an app-specific password from appleid.apple.com.

**Current configuration:**

| Setting | Value |
|---------|-------|
| Keychain Profile | `MacClipboard-Notarize` |
| Apple ID | `ramax@atalist.com` |
| Team ID | `K542B2Z65M` |

This is stored securely in your macOS Keychain, not in any file.

## Building for Distribution

### Quick Build (After Setup)

```bash
./build.sh
```

This will:
1. Build the app in Release configuration
2. Sign it with your Developer ID
3. Notarize it with Apple
4. Staple the notarization ticket
5. Create a ZIP and optional DMG for distribution

### Output Files

After a successful build, you'll find:
- `./build/export/MacClipboard.app` - The signed app bundle
- `./build/MacClipboard.zip` - ZIP archive for sharing
- `./build/MacClipboard-Installer.dmg` - DMG installer (if create-dmg is installed)

### Optional: Install create-dmg

For a nicer DMG installer with drag-to-Applications:

```bash
brew install create-dmg
```

## Distribution

### Distribution Methods

| Method | Audience | Install Command |
|--------|----------|-----------------|
| GitHub Releases | Developers, early adopters | Download from releases page |
| Homebrew Cask | Developers | `brew install --cask macclipboard` |
| Direct Download | Everyone | Download from website |

---

## GitHub Releases

The easiest way to distribute your app publicly.

### Creating a Release

1. **Build the app first:**

   ```bash
   ./build.sh
   ```

2. **Create a version tag:**

   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```

3. **Create the release with assets:**

   ```bash
   gh release create v1.0.0 \
     ./build/MacClipboard.zip \
     ./build/MacClipboard-Installer.dmg \
     --title "MacClipboard v1.0.0" \
     --notes "Initial release - clipboard history manager for macOS"
   ```

4. **Verify the release:**

   ```bash
   gh release view v1.0.0
   ```

### Updating a Release

For subsequent releases:

```bash
# Update version, build, tag, and release
git tag v1.1.0
git push origin v1.1.0
gh release create v1.1.0 \
  ./build/MacClipboard.zip \
  ./build/MacClipboard-Installer.dmg \
  --title "MacClipboard v1.1.0" \
  --notes "Bug fixes and improvements"
```

---

## Homebrew Cask

Homebrew Cask is the most popular way for developers to install Mac apps.

### Prerequisites

- A public GitHub release with your DMG or ZIP
- Get the SHA256 hash of your release file

### Step 1: Get the SHA256 Hash

After creating a GitHub release:

```bash
# For the DMG
shasum -a 256 ./build/MacClipboard-Installer.dmg

# Or for the ZIP
shasum -a 256 ./build/MacClipboard.zip
```

### Step 2: Create the Cask Formula

Fork [homebrew-cask](https://github.com/Homebrew/homebrew-cask) and create a new file:

**File:** `Casks/m/macclipboard.rb`

A pre-generated formula is available at `homebrew/macclipboard.rb` in this repo.

```ruby
cask "macclipboard" do
  version "0.0.1"
  sha256 "4f06931be780786736e3264edbad73ca75443fa2b6913dfa957bca83a2a2f7b2"

  url "https://github.com/rakodev/mac-clipboard/releases/download/v#{version}/MacClipboard-Installer.dmg"
  name "MacClipboard"
  desc "Clipboard history manager for macOS"
  homepage "https://github.com/rakodev/mac-clipboard"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :monterey"

  app "MacClipboard.app"

  zap trash: [
    "~/Library/Application Support/MacClipboard",
    "~/Library/Preferences/com.macclipboard.MacClipboard.plist",
    "~/Library/Caches/com.macclipboard.MacClipboard",
  ]
end
```

### Step 3: Test Locally

```bash
# Install from your local formula
brew install --cask ./Casks/m/macclipboard.rb

# Verify it works
open -a MacClipboard

# Uninstall to clean up
brew uninstall --cask macclipboard
```

### Step 4: Submit Pull Request

1. Commit your changes to your fork
2. Open a PR to [homebrew-cask](https://github.com/Homebrew/homebrew-cask)
3. Follow their [contribution guidelines](https://github.com/Homebrew/homebrew-cask/blob/master/CONTRIBUTING.md)

### Updating Homebrew Cask

When you release a new version:

1. Create a new GitHub release (see above)
2. Get the new SHA256 hash
3. Submit a PR updating the version and sha256 in the cask formula

Or use `brew bump-cask-pr`:

```bash
brew bump-cask-pr macclipboard --version 1.1.0
```

---

## What Users Experience

With proper signing and notarization:

- Users can open the app normally (double-click)
- No Gatekeeper warnings or "unidentified developer" messages
- macOS will show "Apple checked it for malicious software and none was detected"

### First Launch Permissions

Users will still need to grant:

- **Accessibility permissions** (System Settings → Privacy & Security → Accessibility)
  - Required for the global keyboard shortcut

## Troubleshooting

### Certificate Not Found

```bash
security find-identity -v -p codesigning
```

If your Developer ID certificate doesn't appear, try:
1. Open Keychain Access
2. Check both "login" and "System" keychains
3. Re-download the certificate from developer.apple.com

### Notarization Fails

Check the notarization log:
```bash
xcrun notarytool log <submission-id> --keychain-profile "MacClipboard-Notarize"
```

Common issues:
- Hardened Runtime not enabled
- Missing entitlements
- Unsigned embedded frameworks

### Verify Notarization Status

```bash
spctl -a -vvv -t install ./build/export/MacClipboard.app
```

Should show: `source=Notarized Developer ID`
