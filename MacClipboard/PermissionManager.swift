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

    /// Why the permission is missing, which decides what the banner should tell the user to do.
    ///
    /// macOS keys an Accessibility grant on the bundle id *and* the code signing requirement
    /// captured when the grant was made, and it exposes none of that in the UI. So a grant can
    /// read as switched on in System Settings while tccd refuses the running binary, and
    /// "enable MacClipboard in System Settings" is then a dead end. The cases below need
    /// genuinely different fixes.
    enum Diagnosis: Equatable {
        /// No grant was ever made for this app. Switching it on is the correct advice.
        case notGranted

        /// A record exists that macOS will not honour for this binary, because a differently
        /// signed copy created it. The record has to be deleted and remade, so offer Repair.
        case staleRecord

        /// Another installed copy of the app owns the grant. Removing the extra copies is the
        /// fix; resetting the record would only hand the problem to the other copy.
        case conflictingCopies([AppInstallation.Copy])

        /// Our bundle was replaced on disk while we kept running, which is what an upgrade does.
        /// The grant is intact and belongs to the new binary; this process is the stale one, so
        /// the fix is to relaunch. Resetting the record here would throw away a working grant.
        case updatedInPlace
    }

    @Published private(set) var diagnosis: Diagnosis = .notGranted

    @Published private(set) var isRepairing: Bool = false
    @Published private(set) var repairFailureMessage: String?

    private var timer: Timer?

    /// Enumerating installed copies goes through LaunchServices and reads code signatures, which
    /// is far too much work for a 2 second poll, and the answer changes only when the user
    /// installs or removes something.
    private var cachedConflictingCopies: [AppInstallation.Copy] = []
    private var lastCopyScan: Date?
    private static let copyScanInterval: TimeInterval = 30

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

        let newDiagnosis: Diagnosis = actuallyWorking ? .notGranted : diagnose()

        // Only update on change to avoid unnecessary UI updates
        if actuallyWorking != isAccessibilityGranted || newDiagnosis != diagnosis {
            DispatchQueue.main.async {
                let statusChanged = actuallyWorking != self.isAccessibilityGranted
                self.isAccessibilityGranted = actuallyWorking
                self.diagnosis = newDiagnosis
                if actuallyWorking {
                    self.repairFailureMessage = nil
                }

                if statusChanged {
                    Logging.debug("[PermissionManager] Accessibility status changed: trusted=\(trusted), canCreateEvents=\(canCreateEvents), result=\(actuallyWorking)")

                    if trusted && !canCreateEvents {
                        Logging.debug("[PermissionManager] AXIsProcessTrusted=true but CGEvent creation failed")
                    }
                }

                switch newDiagnosis {
                case .notGranted:
                    break
                case .staleRecord:
                    Logging.info("[PermissionManager] Accessibility record exists but macOS refuses this binary; likely a stale TCC record")
                case .conflictingCopies(let copies):
                    Logging.info("[PermissionManager] Accessibility denied while other copies are installed: \(copies.map(\.displayPath).joined(separator: ", "))")
                case .updatedInPlace:
                    Logging.info("[PermissionManager] Accessibility refused because this bundle was replaced by an update; a relaunch restores it")
                }
            }
        }
    }

    /// Work out which of the failure modes we are in.
    private func diagnose() -> Diagnosis {
        // First, because it is the one case where the grant is fine and this process is the
        // problem. Every other answer here would send the user to fix something that is not
        // broken, and Repair would delete a record that works.
        if AppInstallation.wasReplacedInPlace() { return .updatedInPlace }

        let copies = conflictingCopies()
        if !copies.isEmpty { return .conflictingCopies(copies) }

        // Trusted at some point, refused now: the record no longer matches this binary.
        if UserDefaults.standard.bool(forKey: Self.wasGrantedBeforeKey) { return .staleRecord }

        // Never seen working, and this copy has no stable signing identity, so any record that
        // does exist was made by a different build and can never match. Dev builds are excluded:
        // `run.sh` gives them a persistent identity and their own bundle id.
        if !BuildInfo.isDevBuild && AppInstallation.isAdHocSigned { return .staleRecord }

        return .notGranted
    }

    private func conflictingCopies() -> [AppInstallation.Copy] {
        if let lastCopyScan, Date().timeIntervalSince(lastCopyScan) < Self.copyScanInterval {
            return cachedConflictingCopies
        }
        lastCopyScan = Date()
        cachedConflictingCopies = AppInstallation.duplicateCopies()
        return cachedConflictingCopies
    }

    /// Bring the extra copies to the user's attention in Finder.
    /// Restart into the copy that is now on disk. See `Diagnosis.updatedInPlace`.
    func relaunchAfterUpdate() {
        AppInstallation.relaunchAfterInPlaceUpdate()
    }

    func revealConflictingCopies() {
        guard case .conflictingCopies(let copies) = diagnosis else { return }
        AppInstallation.reveal(copies)
    }

    /// Force a permission refresh (useful after user has gone to System Settings)
    ///
    /// The user may have just removed a duplicate copy or moved the app, so the cached copy scan
    /// is discarded rather than reused here.
    func refreshPermission() {
        lastCopyScan = nil
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
                    self.diagnosis = .notGranted
                    self.lastCopyScan = nil
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
