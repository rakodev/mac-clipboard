#!/usr/bin/env swift

import Foundation
import ApplicationServices

print("=== MacClipboard Permission Diagnostics ===")
print("Date: \(Date())")
print()

// Check basic accessibility trust
let basicTrust = AXIsProcessTrusted()
print("1. AXIsProcessTrusted(): \(basicTrust)")

// Check with options (this is what apps usually call)
let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false]
let optionsTrust = AXIsProcessTrustedWithOptions(options)
print("2. AXIsProcessTrustedWithOptions (no prompt): \(optionsTrust)")

// Get current executable path
let executablePath = ProcessInfo.processInfo.arguments[0]
print("3. Current executable path: \(executablePath)")

// Get bundle information
if let bundle = Bundle.main.bundleIdentifier {
    print("4. Bundle identifier: \(bundle)")
} else {
    print("4. Bundle identifier: (none - running as script)")
}

print("5. Bundle path: \(Bundle.main.bundlePath)")

// Try to create a CGEvent (this should fail if no accessibility)
if let event = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true) {
    print("6. CGEvent creation: ✅ SUCCESS (accessibility is working)")
} else {
    print("6. CGEvent creation: ❌ FAILED (no accessibility access)")
}

print()
print("=== Recommendations ===")
if !basicTrust {
    print("• AXIsProcessTrusted() returned false")
    print("• This means macOS doesn't recognize this binary as having accessibility access")
    print("• Solution: Ensure the same binary that's granted permission is the one running")
    print("• Try: Remove MacClipboard from Accessibility list, restart app to re-prompt")
} else {
    print("• ✅ Accessibility seems to be working correctly")
    print("• If auto-paste still fails, the issue might be elsewhere")
}