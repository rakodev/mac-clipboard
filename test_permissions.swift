#!/usr/bin/env swift

import Foundation
import ApplicationServices

print("🔍 MacClipboard Accessibility Diagnostics")
print("==========================================")

let trusted = AXIsProcessTrusted()
print("✓ AXIsProcessTrusted(): \(trusted)")

if let bundleID = Bundle.main.bundleIdentifier {
    print("✓ Bundle ID: \(bundleID)")
} else {
    print("⚠️  Bundle ID: (none)")
}

print("✓ Bundle Path: \(Bundle.main.bundlePath)")

// Check if we can create CGEvents (this will fail without accessibility)
let event = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)
if event != nil {
    print("✓ CGEvent creation: Success")
} else {
    print("❌ CGEvent creation: Failed (likely no accessibility)")
}

print("\n🔧 If trusted=false:")
print("1. Open System Settings > Privacy & Security > Accessibility")
print("2. Look for 'MacClipboard' in the list")
print("3. Enable the toggle if it exists")
print("4. If not in list, the app needs to trigger permission request")