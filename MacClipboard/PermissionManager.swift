import Foundation
import ApplicationServices
import AppKit

/// Manages accessibility permission state and provides reactive updates
class PermissionManager: ObservableObject {
    /// Tracks the once-ever system prompt. Shared with `AppDelegate` so a repair can
    /// re-arm the prompt.
    static let hasRequestedPromptKey = "hasRequestedAccessibilityPromptV1"

    /// Set the first time we observe a working grant. Lets us tell "never granted" apart
    /// from "was granted and stopped working", which need different advice.
    private static let wasGrantedBeforeKey = "accessibilityWasGrantedV1"

    @Published var isAccessibilityGranted: Bool = false

    /// True when this app was trusted at some point but is not any more.
    ///
    /// The usual cause is a stale TCC row: macOS keys an Accessibility grant on the bundle
    /// id *and* the code signing requirement captured when the grant was made. If a
    /// differently signed build ever used this bundle id (a locally built copy, say), the
    /// row survives and keeps showing as switched on in System Settings while tccd denies
    /// the running binary. Telling the user to "enable MacClipboard" is a dead end in that
    /// state, so the banner offers a repair instead.
    @Published private(set) var permissionLooksStale: Bool = false

    @Published private(set) var isRepairing: Bool = false
    @Published private(set) var repairFailureMessage: String?

    private var timer: Timer?

    init() {
        checkPermission()
        startPeriodicCheck()
    }

    deinit {
        timer?.invalidate()
    }

    /// Check the current accessibility permission status
    func checkPermission() {
        let trusted = AXIsProcessTrusted()

        // Also check if we can actually create CGEvents (more reliable test)
        let canCreateEvents = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true) != nil

        // Use the more restrictive check - both must be true
        let actuallyWorking = trusted && canCreateEvents

        let defaults = UserDefaults.standard
        if actuallyWorking && !defaults.bool(forKey: Self.wasGrantedBeforeKey) {
            defaults.set(true, forKey: Self.wasGrantedBeforeKey)
        }
        let looksStale = !actuallyWorking && defaults.bool(forKey: Self.wasGrantedBeforeKey)

        // Only update on change to avoid unnecessary UI updates
        if actuallyWorking != isAccessibilityGranted || looksStale != permissionLooksStale {
            DispatchQueue.main.async {
                let statusChanged = actuallyWorking != self.isAccessibilityGranted
                self.isAccessibilityGranted = actuallyWorking
                self.permissionLooksStale = looksStale
                if actuallyWorking {
                    self.repairFailureMessage = nil
                }

                if statusChanged {
                    Logging.debug("[PermissionManager] Accessibility status changed: trusted=\(trusted), canCreateEvents=\(canCreateEvents), result=\(actuallyWorking)")

                    if trusted && !canCreateEvents {
                        Logging.debug("[PermissionManager] AXIsProcessTrusted=true but CGEvent creation failed")
                    }
                    if looksStale {
                        Logging.info("[PermissionManager] Accessibility grant lost after previously working; likely a stale TCC record")
                    }
                }
            }
        }
    }

    /// Force a permission refresh (useful after user has gone to System Settings)
    func refreshPermission() {
        checkPermission()
    }

    /// Request accessibility permission with prompt
    func requestPermission() {
        Logging.debug("[PermissionManager] Requesting accessibility permission")
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        let result = AXIsProcessTrustedWithOptions(options)

        // Check again after prompt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.checkPermission()
        }

        Logging.debug("[PermissionManager] Permission request result: \(result)")
    }

    /// Force a complete permission reset - shows system prompt
    func forcePermissionPrompt() {
        Logging.debug("[PermissionManager] Forcing accessibility permission prompt")

        // First check current status
        let currentTrusted = AXIsProcessTrusted()
        Logging.debug("[PermissionManager] Current AXIsProcessTrusted: \(currentTrusted)")

        // Always show the prompt to ensure this specific binary gets permission
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        let promptResult = AXIsProcessTrustedWithOptions(options)
        Logging.debug("[PermissionManager] Force prompt result: \(promptResult)")

        // Check again after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.checkPermission()
            Logging.debug("[PermissionManager] Post-prompt check completed")
        }
    }

    // MARK: - Stale Grant Repair

    /// Delete this app's Accessibility record and ask for it again.
    ///
    /// Deleting the row is the only way out of a stale grant: while it exists, macOS shows
    /// the app as enabled and refuses it at the same time, and the toggle in System Settings
    /// cannot rewrite the recorded code requirement. `tccutil` is the supported way to
    /// remove it, and it only ever touches our own bundle id.
    func repairPermission() {
        guard !isRepairing else { return }

        isRepairing = true
        repairFailureMessage = nil
        let bundleIdentifier = BuildInfo.bundleIdentifier

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.resetAccessibilityRecord(for: bundleIdentifier)

            DispatchQueue.main.async {
                self.isRepairing = false

                switch result {
                case .success:
                    Logging.info("[PermissionManager] Reset the Accessibility record for \(bundleIdentifier)")
                    // The record is gone, so this is a first grant again: re-arm the
                    // one-shot system prompt and forget that we were ever trusted.
                    let defaults = UserDefaults.standard
                    defaults.removeObject(forKey: Self.hasRequestedPromptKey)
                    defaults.set(false, forKey: Self.wasGrantedBeforeKey)
                    self.isAccessibilityGranted = false
                    self.permissionLooksStale = false
                    self.forcePermissionPrompt()

                case .failure(let message):
                    Logging.info("[PermissionManager] Accessibility reset failed: \(message)")
                    self.repairFailureMessage = message
                }
            }
        }
    }

    private enum RepairOutcome {
        case success
        case failure(String)
    }

    private static func resetAccessibilityRecord(for bundleIdentifier: String) -> RepairOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleIdentifier]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .failure(error.localizedDescription)
        }

        // Drain stderr before waiting so a chatty tccutil cannot fill the pipe and hang.
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .failure(stderrText.isEmpty
                            ? "tccutil exited with status \(process.terminationStatus)"
                            : stderrText)
        }

        return .success
    }

    /// Open System Settings to Accessibility page
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Start periodic checking (useful for detecting when user enables permission in System Settings)
    private func startPeriodicCheck() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            self.checkPermission()
        }
    }
}
