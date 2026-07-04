import SwiftUI
import ApplicationServices

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
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        logAccessibilityState(context: "launch")
        handleAccessibilityPermissions()

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
            self.menuBarController = MenuBarController(clipboardMonitor: ClipboardMonitor())
            self.showPersistenceRecoveryAlertIfNeeded()
        }
        if let window = NSApplication.shared.windows.first {
            window.close()
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        menuBarController?.cleanup()
    }

    @objc private func showPersistenceRecoveryAlertIfNeeded() {
        guard !didShowPersistenceRecoveryAlert,
              let message = PersistenceManager.shared.persistenceDiagnosticsMessage else { return }

        didShowPersistenceRecoveryAlert = true

        let alert = NSAlert()
        alert.messageText = "Clipboard History Storage Issue"
        alert.informativeText = "\(message)\n\nYou can continue using temporary storage, or reset saved history files and quit. Relaunching after reset creates a fresh history store."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset Saved History and Quit")
        alert.addButton(withTitle: "Continue")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            if PersistenceManager.shared.resetPersistentStoreFiles() {
                NSApp.terminate(nil)
            } else {
                let failureAlert = NSAlert()
                failureAlert.messageText = "Could Not Reset Clipboard History"
                failureAlert.informativeText = "MacClipboard could not remove the saved history files automatically. You can continue with temporary storage for this session."
                failureAlert.alertStyle = .critical
                failureAlert.addButton(withTitle: "OK")
                failureAlert.runModal()
            }
        }
    }
    
    private func handleAccessibilityPermissions() {
    let trusted = AXIsProcessTrusted()
        
        if trusted { return }

        // Always show prompt for permission when missing
        
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
    let promptResult = AXIsProcessTrustedWithOptions(options)
        
        if !promptResult {
            // Show onboarding window as backup
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
        window.title = "Enable Accessibility"
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
        Logging.debug("[AX][\(context)] trusted=\(trusted) bundleID=\(bundleID) path=\(bundlePath)")
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
