import SwiftUI
import ApplicationServices

enum L10n {
    static func string(_ key: String, comment: String) -> String {
        NSLocalizedString(key, comment: comment)
    }
}

@main
struct MacClipboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var onboardingWindow: NSWindow?
    private var didShowPersistenceRecoveryAlert = false
    private var terminationSignalSource: DispatchSourceSignal?
    private var updateWatchTimer: Timer?
    private var didRelaunchAfterUpdate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installTerminationSignalHandler()
        terminateOtherInstances()
        Logging.info("[App] Launched \(BuildInfo.channelName) build \(BuildInfo.versionString) (\(BuildInfo.bundleIdentifier))")
        logAccessibilityState(context: "launch")
        handleAccessibilityPermissions()
        checkInstallationHygiene()
        startWatchingForInPlaceUpdate()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showPersistenceRecoveryAlertIfNeeded),
            name: .persistenceStoreDidRecoverTemporarily,
            object: nil
        )

        // Sync login item state with user preference (runs async to avoid blocking startup)
        UserPreferencesManager.shared.syncLoginItemState()
        // Defer creating the MenuBarController slightly to avoid race conditions with
        // accessibility enabling and the app activation policy. Some macOS versions
        // can cause status item event handling to be lost if created too early.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            // A test host is this same app, so a run of `xcodebuild test` would otherwise poll the
            // pasteboard, load the developer's own history and run maintenance against it for the
            // length of the run, alongside whatever the tests are doing. `PersistenceManager
            // .shared` now traps under a test host, so this would be fatal rather than untidy.
            guard !BuildInfo.isHostingTests else {
                Logging.info("[App] Hosting an XCTest bundle; not starting the menu bar or the clipboard monitor")
                return
            }

            self.menuBarController = MenuBarController(clipboardMonitor: ClipboardMonitor())
            self.showPersistenceRecoveryAlertIfNeeded()
        }
        if let window = NSApplication.shared.windows.first {
            window.close()
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        updateWatchTimer?.invalidate()
        updateWatchTimer = nil
        menuBarController?.cleanup()
    }

    /// Turn SIGTERM into an orderly AppKit shutdown.
    ///
    /// The Homebrew cask stops the app with `uninstall signal: ["TERM", ...]` before it
    /// replaces the bundle. The default disposition for SIGTERM kills the process outright,
    /// so `applicationWillTerminate` never runs and anything not yet flushed to Core Data is
    /// lost on every upgrade. Ignoring the default and handling it ourselves fixes that.
    private func installTerminationSignalHandler() {
        signal(SIGTERM, SIG_IGN)

        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            Logging.info("[App] Received SIGTERM, shutting down cleanly")
            NSApp.terminate(nil)
        }
        source.resume()
        terminationSignalSource = source
    }

    /// Ask any older copy of *this same* app to quit.
    ///
    /// A second instance normally cannot start, but it can when two bundles share one
    /// identifier (an upgrade that replaced the bundle under a running process, for
    /// instance). Two instances mean two menu bar icons, two clipboard pollers and a fight
    /// over the global hotkey. The newest binary wins; asking the old one to quit rather
    /// than exiting ourselves means an upgrade can never leave the user with nothing running.
    ///
    /// A dev build has its own bundle id, so it is never affected by this.
    private func terminateOtherInstances() {
        guard !BuildInfo.isHostingTests else {
            Logging.info("[App] Hosting an XCTest bundle; leaving other instances alone")
            return
        }

        let duplicates = olderRunningInstances()
        guard !duplicates.isEmpty else { return }

        Logging.info("[App] Found \(duplicates.count) older instance(s) of \(BuildInfo.bundleIdentifier); asking them to quit")
        for duplicate in duplicates {
            duplicate.terminate()
        }

        // `terminate()` posts a quit Apple event, which macOS can drop silently: sending events
        // to another app is itself a permission-gated operation, and an app that is busy or
        // paused under a debugger may never act on it. Two live instances then fight over the
        // hotkey and both write to one Core Data store, so escalate rather than assume it
        // worked. SIGTERM is handled cleanly by `installTerminationSignalHandler`, and only a
        // process that ignores that too gets forced.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let survivors = self?.olderRunningInstances(), !survivors.isEmpty else { return }
            Logging.info("[App] \(survivors.count) older instance(s) ignored the quit request; sending SIGTERM")
            for survivor in survivors {
                kill(survivor.processIdentifier, SIGTERM)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let stubborn = self?.olderRunningInstances(), !stubborn.isEmpty else { return }
                Logging.info("[App] Force terminating \(stubborn.count) older instance(s)")
                for instance in stubborn {
                    instance.forceTerminate()
                }
            }
        }
    }

    /// Running copies that share our bundle id and started before we did.
    ///
    /// Only older instances are ever asked to quit. If two copies somehow start at the same
    /// moment, a symmetric rule would have each kill the other and leave nothing running.
    private func olderRunningInstances() -> [NSRunningApplication] {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let ownLaunchDate = NSRunningApplication.current.launchDate ?? Date()

        return NSWorkspace.shared.runningApplications.filter { app in
            guard app.bundleIdentifier == BuildInfo.bundleIdentifier,
                  app.processIdentifier != ownProcessIdentifier,
                  !app.isTerminated else { return false }
            guard let launchDate = app.launchDate else { return true }
            return launchDate < ownLaunchDate
        }
    }

    // MARK: - Installation Hygiene

    /// Keys the last set of duplicate paths we warned about, so the alert appears when the
    /// situation changes rather than on every single launch.
    private static let duplicateCopiesWarnedKey = "duplicateCopiesWarnedPathsV1"
    /// Set when the user answers "Don't Ask Again" to the move-to-Applications offer.
    private static let relocationOfferDeclinedKey = "relocationOfferDeclinedV1"

    /// Tell the user when this copy cannot keep its permissions, or when more than one copy is
    /// installed.
    ///
    /// Both states look to the user like MacClipboard being broken for no reason: the
    /// Accessibility switch is on, auto-paste does nothing, and Spotlight shows several
    /// identical apps. macOS gives no hint about which copy a grant belongs to, so the app has
    /// to say it.
    /// Notice when an installer replaces our bundle underneath us, and relaunch.
    ///
    /// `brew upgrade --cask` moves the old bundle aside and the new one into its place while the
    /// app keeps running. macOS then refuses this process's Accessibility grant (its recorded code
    /// identity no longer matches the binary at our path), so auto-paste and the global hotkey
    /// stop working while System Settings still shows MacClipboard as enabled: from the user's
    /// side the upgrade broke the app and nothing in System Settings fixes it. Homebrew is meant
    /// to quit the app first, but it decides whether we are running via AppleScript and
    /// `launchctl list`, neither of which is reliable for a menu bar app started as a login item,
    /// so it silently skips it. Watching for it here fixes the upgrade for every install method,
    /// including a plain drag from a DMG.
    ///
    /// Polling costs one `stat` and only reads the signature once the file has actually changed.
    private func startWatchingForInPlaceUpdate() {
        guard !BuildInfo.isDevBuild, !BuildInfo.isHostingTests else { return }

        // Read the running binary's identity now, while it is still ours. `launchFingerprint` is
        // lazy, and a first read taken after an upgrade would describe the *new* bundle, leaving
        // nothing to compare against and no replacement ever detected.
        let launch = AppInstallation.launchFingerprint
        Logging.debug("[Install] Launched from inode \(launch.inode), build \(launch.version ?? "unknown")")

        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self, !self.didRelaunchAfterUpdate else { return }
            guard AppInstallation.wasReplacedInPlace() else { return }

            // Once only: if the replacement cannot start, one failed attempt is enough.
            self.didRelaunchAfterUpdate = true
            self.updateWatchTimer?.invalidate()
            self.updateWatchTimer = nil
            AppInstallation.relaunchAfterInPlaceUpdate()
        }
        RunLoop.main.add(timer, forMode: .common)
        updateWatchTimer = timer
    }

    private func checkInstallationHygiene() {
        Logging.info("[Install] \(AppInstallation.diagnosticLine)")
        guard !BuildInfo.isDevBuild, !BuildInfo.isHostingTests else { return }

        // Wait for the menu bar item so an alert never appears before there is any app to see.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }

            if let problem = AppInstallation.locationProblem {
                // A loose copy is also a duplicate of whatever is already installed, and moving
                // it resolves both, so only one alert is shown.
                self.presentRelocationAlert(for: problem)
            } else {
                self.presentDuplicateCopiesAlertIfNeeded()
            }
        }
    }

    private func presentRelocationAlert(for problem: AppInstallation.LocationProblem) {
        // The randomised and read-only cases are always raised: permissions genuinely cannot be
        // saved, so staying quiet would leave the user with an app that never works. A copy in
        // an ordinary folder does work, it just loses its grant when moved, so that offer can
        // be declined for good.
        if problem == .notInApplicationsFolder,
           UserDefaults.standard.bool(forKey: Self.relocationOfferDeclinedKey) {
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning

        switch problem {
        case .translocated:
            alert.messageText = L10n.string("MacClipboard is running from a temporary copy",
                                            comment: "Relocation alert title, translocated app")
            alert.informativeText = L10n.string("macOS runs apps opened straight from a download or a disk image out of a temporary location that changes every time, so Accessibility permission can never be saved. Installing MacClipboard in your Applications folder fixes this permanently.",
                                                comment: "Relocation alert message, translocated app")
        case .readOnlyVolume:
            alert.messageText = L10n.string("MacClipboard is running from a disk image",
                                            comment: "Relocation alert title, read-only volume")
            alert.informativeText = L10n.string("Permissions and clipboard history cannot be kept for an app running from a disk image, and it stops working as soon as the image is ejected. Install MacClipboard in your Applications folder instead.",
                                                comment: "Relocation alert message, read-only volume")
        case .notInApplicationsFolder:
            alert.messageText = L10n.string("MacClipboard is not in your Applications folder",
                                            comment: "Relocation alert title, loose copy")
            alert.informativeText = L10n.string("macOS ties Accessibility permission to the exact copy of the app you granted it to. Keeping MacClipboard in Applications means the permission survives moves, restarts and updates.",
                                                comment: "Relocation alert message, loose copy")
        }

        alert.addButton(withTitle: L10n.string("Move to Applications", comment: "Relocation alert confirm button"))
        alert.addButton(withTitle: L10n.string("Not Now", comment: "Relocation alert defer button"))
        if problem == .notInApplicationsFolder {
            alert.addButton(withTitle: L10n.string("Don't Ask Again", comment: "Relocation alert suppress button"))
        }

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            relocateToApplications()
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(true, forKey: Self.relocationOfferDeclinedKey)
        default:
            break
        }
    }

    private func relocateToApplications() {
        AppInstallation.relocateToApplicationsAndRelaunch { result in
            switch result {
            case .success:
                // The freshly installed copy is already starting up. Leaving this one running
                // would give the user two menu bar icons.
                NSApp.terminate(nil)

            case .failure(let error):
                let failure = NSAlert()
                failure.alertStyle = .critical
                failure.messageText = L10n.string("Could Not Move MacClipboard",
                                                  comment: "Relocation failure alert title")
                let format = L10n.string("%@\n\nDrag MacClipboard to your Applications folder in Finder, then open it from there.",
                                         comment: "Relocation failure alert message")
                failure.informativeText = String(format: format, error.localizedDescription)
                failure.addButton(withTitle: L10n.string("OK", comment: "Standard confirmation button title"))
                failure.runModal()
            }
        }
    }

    private func presentDuplicateCopiesAlertIfNeeded() {
        let duplicates = AppInstallation.duplicateCopies()
        guard !duplicates.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.duplicateCopiesWarnedKey)
            return
        }

        Logging.info("[Install] \(duplicates.count) duplicate copy/copies registered: \(duplicates.map(\.displayPath).joined(separator: ", "))")

        let signature = duplicates.map(\.url.path).sorted().joined(separator: "\n")
        guard UserDefaults.standard.string(forKey: Self.duplicateCopiesWarnedKey) != signature else { return }
        UserDefaults.standard.set(signature, forKey: Self.duplicateCopiesWarnedKey)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("More than one copy of MacClipboard is installed",
                                        comment: "Duplicate copies alert title")

        let listed = duplicates
            .map { "• \($0.displayPath) (\($0.displayVersion))" }
            .joined(separator: "\n")
        let format = L10n.string("macOS ties Accessibility permission to one specific copy, so extra copies make auto-paste stop working even though the switch stays on in System Settings. They also show up as duplicates in Spotlight.\n\nThis copy is running from:\n• %@ (%@)\n\nOther copies found:\n%@",
                                 comment: "Duplicate copies alert message")
        var message = String(format: format,
                             (AppInstallation.bundleURL.path as NSString).abbreviatingWithTildeInPath,
                             BuildInfo.shortVersion,
                             listed)

        // If one of the others is the better copy, say so: launching the wrong one is how people
        // end up here, and "which of these do I keep" is the question they are left with.
        if let better = AppInstallation.betterCopyThanThisOne() {
            let recommendation = L10n.string("\n\nThe copy at %@ is the one to keep. Quit this one and open that instead.",
                                             comment: "Duplicate copies alert recommendation")
            message += String(format: recommendation, better.displayPath)
        }
        alert.informativeText = message

        alert.addButton(withTitle: L10n.string("Show in Finder", comment: "Duplicate copies alert reveal button"))
        alert.addButton(withTitle: L10n.string("Move Others to Trash", comment: "Duplicate copies alert cleanup button"))
        alert.addButton(withTitle: L10n.string("Not Now", comment: "Duplicate copies alert defer button"))
        alert.buttons[1].hasDestructiveAction = true

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            AppInstallation.reveal(duplicates)
        case .alertSecondButtonReturn:
            trashDuplicates(duplicates)
        default:
            break
        }
    }

    private func trashDuplicates(_ duplicates: [AppInstallation.Copy]) {
        let failures = AppInstallation.moveToTrash(duplicates)
        guard !failures.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("Some Copies Could Not Be Removed",
                                        comment: "Duplicate cleanup failure alert title")
        let format = L10n.string("MacClipboard could not move these to the Trash:\n%@\n\nRemove them in Finder, then reopen MacClipboard.",
                                 comment: "Duplicate cleanup failure alert message")
        alert.informativeText = String(format: format,
                                       failures.map { "• \($0.displayPath)" }.joined(separator: "\n"))
        alert.addButton(withTitle: L10n.string("OK", comment: "Standard confirmation button title"))
        alert.runModal()
    }

    @objc private func showPersistenceRecoveryAlertIfNeeded() {
        // Reached by notification as well as directly, and a test's own store falling back to
        // temporary storage posts the same notification. Touching `shared` here would trap.
        guard !BuildInfo.isHostingTests else { return }

        guard !didShowPersistenceRecoveryAlert,
              let message = PersistenceManager.shared.persistenceDiagnosticsMessage else { return }

        didShowPersistenceRecoveryAlert = true

        let alert = NSAlert()
        alert.messageText = L10n.string("Clipboard History Storage Issue", comment: "Persistence recovery alert title")
        let recoveryFormat = L10n.string("%@\n\nYou can continue using temporary storage, or reset saved history files and quit. Relaunching after reset creates a fresh history store.", comment: "Persistence recovery alert message")
        alert.informativeText = String(format: recoveryFormat, message)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("Reset Saved History and Quit", comment: "Persistence recovery destructive button title"))
        alert.addButton(withTitle: L10n.string("Continue", comment: "Persistence recovery continue button title"))

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            if PersistenceManager.shared.resetPersistentStoreFiles() {
                NSApp.terminate(nil)
            } else {
                let failureAlert = NSAlert()
                failureAlert.messageText = L10n.string("Could Not Reset Clipboard History", comment: "Persistence reset failure alert title")
                failureAlert.informativeText = L10n.string("MacClipboard could not remove the saved history files automatically. You can continue with temporary storage for this session.", comment: "Persistence reset failure alert message")
                failureAlert.alertStyle = .critical
                failureAlert.addButton(withTitle: L10n.string("OK", comment: "Standard confirmation button title"))
                failureAlert.runModal()
            }
        }
    }
    
    private func handleAccessibilityPermissions() {
        if AXIsProcessTrusted() { return }

        // An ad hoc signed build can never keep a grant: macOS pins it to one binary hash and the
        // next build changes it. Prompting there teaches the developer to dismiss the system
        // dialog, and it used to be how the dev copy's own grant got claimed by a throwaway
        // binary. A test host is the same case with a dialog nobody is watching.
        if BuildInfo.isHostingTests || (BuildInfo.isDevBuild && AppInstallation.isAdHocSigned) {
            Logging.debug("[AX] This build cannot keep a grant (ad hoc signed or hosting tests); not prompting")
            return
        }

        // IMPORTANT: AXIsProcessTrustedWithOptions(prompt: true) re-shows the system
        // "would like to control this computer" dialog on EVERY call while the process
        // is untrusted, with no rate limiting. Calling it on each launch (or whenever
        // detection fails, e.g. a stale TCC grant from a different-signature build)
        // makes the popup reappear endlessly. So we fire the system prompt at most once,
        // ever, purely to register the app in the Accessibility list. After that we rely
        // on the in-popover banner and the onboarding window for guidance, and detect the
        // grant by polling AXIsProcessTrusted(). The banner's "Force Reset" button remains
        // a manual escape hatch to re-trigger the system prompt on demand.
        let defaults = UserDefaults.standard
        let hasPromptedKey = PermissionManager.hasRequestedPromptKey
        guard !defaults.bool(forKey: hasPromptedKey) else {
            Logging.debug("[AX] System prompt already shown once; not re-prompting automatically")
            return
        }
        defaults.set(true, forKey: hasPromptedKey)

        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        if !AXIsProcessTrustedWithOptions(options) {
            // Show onboarding window as backup (it polls for the grant and opens Settings).
            showOnboardingWindow()
        }
    }

    private func showOnboardingWindow() {
        // Show minimal onboarding floating panel with explanation + button
        let contentView = OnboardingView(onGrant: { [weak self] in
            self?.openAccessibilitySettings()
        }, onDismiss: { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        })

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.center()
        window.title = L10n.string("Enable Accessibility", comment: "Accessibility onboarding window title")
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    private func openAccessibilitySettings() {
        // Prefer modern System Settings URL (macOS 13+)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        } else if let legacyURL = URL(fileURLWithPath: "/System/Library/PreferencePanes/Security.prefPane") as URL? {
            NSWorkspace.shared.open(legacyURL)
        }
    }

    private func logAccessibilityState(context: String) {
        let trusted = AXIsProcessTrusted()
        let bundlePath = Bundle.main.bundlePath
        let bundleID = Bundle.main.bundleIdentifier ?? "(nil)"
        // Recorded at info level: when a user reports that auto-paste does nothing, this is
        // the single most useful line to read back out of the unified log.
        Logging.info("[AX][\(context)] trusted=\(trusted) bundleID=\(bundleID) path=\(bundlePath)")
    }
}

// MARK: - Onboarding View
struct OnboardingView: View {
    let onGrant: () -> Void
    let onDismiss: () -> Void

    @State private var isGranted: Bool = AXIsProcessTrusted()
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 32))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Accessibility Permission Needed")
                        .font(.headline)
                    Text("To let MacClipboard auto-paste into other apps, grant Accessibility access. You can still copy without it.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            if isGranted {
                Label("Permission Granted", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Text("1. Click 'Open Settings'\n2. Enable MacClipboard in Accessibility list" )
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Button(isGranted ? "Close" : "Open Settings") {
                    if isGranted {
                        onDismiss()
                    } else {
                        onGrant()
                        startPolling()
                    }
                }
                .keyboardShortcut(.defaultAction)

                Button("Later") {
                    onDismiss()
                }
                .disabled(isGranted)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startPolling() }
        .onDisappear { pollTimer?.invalidate() }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            let granted = AXIsProcessTrusted()
            if granted != isGranted {
                isGranted = granted
                if granted {
                    // Close after short delay so user sees success
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        onDismiss()
                    }
                }
            }
        }
    }
}
