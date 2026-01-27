import SwiftUI
import AppKit
import Carbon

class MenuBarController: NSObject, ObservableObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var clipboardMonitor: ClipboardMonitor
    private var hotKeyRef: EventHotKeyRef?
    private var previousApplication: NSRunningApplication?
    private var didAttemptAXPrompt = false
    private var clickOutsideMonitor: Any?
    private var settingsWindow: NSWindow?
    
    let permissionManager = PermissionManager()
    
    // Helper function to convert string to fourCharCode
    private func fourCharCode(_ string: String) -> OSType {
        guard string.count == 4 else { return 0 }
        let chars = Array(string.utf8)
        return OSType(chars[0]) << 24 | OSType(chars[1]) << 16 | OSType(chars[2]) << 8 | OSType(chars[3])
    }
    
    private lazy var hotKeyID: EventHotKeyID = EventHotKeyID(signature: fourCharCode("ClpM"), id: 1)
    
    init(clipboardMonitor: ClipboardMonitor) {
        self.clipboardMonitor = clipboardMonitor
    super.init()
        setupStatusItem()
        setupPopover()
        setupGlobalHotkey()
        
        // Listen for app activation to ensure button remains responsive
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        
        // Ensure button is properly setup after a short delay
        // This helps with timing issues on app launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.ensureButtonIsResponsive()
            self.verifyButtonSetup()
        }
    }
    
    private func setupStatusItem() {
        // Ensure we're on the main thread
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.setupStatusItem()
            }
            return
        }
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            // Try system symbol first, fallback to a simple text icon
            if let clipboardImage = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard Manager") {
                button.image = clipboardImage
            } else {
                // Fallback to a simple text-based icon
                button.title = "📋"
            }

            // Clear any existing target/action first
            button.target = nil
            button.action = nil
            
            // Set up the target and action
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            
            // Use standard mouse events for better compatibility
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            
            // Make sure the button is visible and enabled
            button.isEnabled = true
            button.isHidden = false
            
            // Force the button to recognize its target
            button.needsDisplay = true
        } else {
            
        }
    }
    
    private func setupPopover() {
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 400, height: 300) // Smaller initial size
        popover?.behavior = .semitransient  // Changed from .transient to .semitransient
        popover?.animates = true
        popover?.contentViewController = NSHostingController(
            rootView: ContentView(clipboardMonitor: clipboardMonitor, menuBarController: self)
        )
    }
    
    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseDown {
            showContextMenu()
        } else {
            togglePopover()
        }
    }
    
    @objc private func applicationDidBecomeActive() {
        // Ensure the menu bar button is responsive when app becomes active
        DispatchQueue.main.async {
            self.ensureButtonIsResponsive()
        }
    }
    
    private func ensureButtonIsResponsive() {
        guard let button = statusItem?.button else { return }

        // Check if target or action is lost and re-establish if needed
        if button.target !== self || button.action != #selector(statusItemClicked(_:)) {
            // Re-setup the button
            button.target = nil
            button.action = nil

            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])

            // Ensure button is enabled and visible
            button.isEnabled = true
            button.isHidden = false
            button.needsDisplay = true
        }
    }
    
    
    // Debug method to verify button setup
    private func verifyButtonSetup() {
        if let button = statusItem?.button {
            // If target or action is nil, reinitialize
            if button.target == nil || button.action == nil {
                button.target = self
                button.action = #selector(statusItemClicked(_:))
                button.sendAction(on: [NSEvent.EventTypeMask.leftMouseDown, NSEvent.EventTypeMask.rightMouseDown])
            }
        }
    }
    
    // Public method to force button reinitialization if needed
    func refreshMenuBarButton() {
        // Remove old status item
        if let oldStatusItem = statusItem {
            NSStatusBar.system.removeStatusItem(oldStatusItem)
        }

        // Create fresh status item
        setupStatusItem()

        // Verify it worked
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.verifyButtonSetup()
        }
    }
    
    private func showContextMenu() {
        let menu = NSMenu()
        
        let showClipboardItem = NSMenuItem(title: "Show Clipboard", action: #selector(showPopover), keyEquivalent: "")
        showClipboardItem.target = self
        menu.addItem(showClipboardItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let diagnoseItem = NSMenuItem(title: "Diagnose Paste", action: #selector(diagnosePaste), keyEquivalent: "")
        diagnoseItem.target = self
        menu.addItem(diagnoseItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let aboutItem = NSMenuItem(title: "About MacClipboard", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit Clipboard Manager", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func showAbout() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        options[.applicationName] = "MacClipboard"
        options[.applicationVersion] = "Version \(version) (Build \(build))"
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func checkForUpdates() {
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let repoURL = "https://api.github.com/repos/rakodev/mac-clipboard/releases/latest"

        guard let url = URL(string: repoURL) else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.showUpdateAlert(title: "Update Check Failed", message: "Could not check for updates: \(error.localizedDescription)")
                    return
                }

                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String else {
                    self.showUpdateAlert(title: "Update Check Failed", message: "Could not parse update information.")
                    return
                }

                let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

                if self.isVersion(latestVersion, newerThan: currentVersion) {
                    let alert = NSAlert()
                    alert.messageText = "Update Available"
                    alert.informativeText = "A new version (v\(latestVersion)) is available. You are currently running v\(currentVersion)."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "Download")
                    alert.addButton(withTitle: "Later")

                    NSApp.activate(ignoringOtherApps: true)
                    let response = alert.runModal()

                    if response == .alertFirstButtonReturn {
                        if let downloadURL = URL(string: "https://github.com/rakodev/mac-clipboard/releases/latest") {
                            NSWorkspace.shared.open(downloadURL)
                        }
                    }
                } else {
                    self.showUpdateAlert(title: "You're Up to Date", message: "MacClipboard v\(currentVersion) is the latest version.")
                }
            }
        }.resume()
    }

    private func showUpdateAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        let components1 = v1.split(separator: ".").compactMap { Int($0) }
        let components2 = v2.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(components1.count, components2.count) {
            let c1 = i < components1.count ? components1[i] : 0
            let c2 = i < components2.count ? components2[i] : 0
            if c1 > c2 { return true }
            if c1 < c2 { return false }
        }
        return false
    }

    @objc func showSettings() {
        // Close existing settings window if open
        settingsWindow?.close()
        
        // Hide popover if it's showing to avoid conflicts
        if popover?.isShown == true {
            popover?.close()
        }
        
        // Create settings view with window reference for proper dismissal
        let settingsView = SimpleSettingsView(
            onDismiss: { [weak self] in
                self?.settingsWindow?.close()
                self?.settingsWindow = nil
            },
            onCheckForUpdates: { [weak self] in
                self?.checkForUpdates()
            }
        )
        
        // Create and configure window with better size
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 380),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "MacClipboard Settings"
        window.contentView = NSHostingView(rootView: settingsView)
        window.center()
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 550, height: 500))
        
        // Ensure proper window ordering and focus
        window.level = .floating
        window.orderFront(nil)
        
        // Store reference and show
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        
        // Force to front and activate
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
    }
    
    @objc private func showPopover() {
        guard let button = statusItem?.button else { return }
        
        if popover?.isShown == true {
            stopClickOutsideMonitoring()
            popover?.close()
        } else {
            // Capture the frontmost application BEFORE we activate ourselves
            previousApplication = NSWorkspace.shared.frontmostApplication

            // Recreate the content view each time to force fresh state (resets selection/highlight)
            if let popover = popover {
                popover.contentViewController = NSHostingController(
                    rootView: ContentView(clipboardMonitor: clipboardMonitor, menuBarController: self)
                )
            }

            // Log current AX trust state every open for transparency (kept minimal)
            _ = AXIsProcessTrusted()
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            
            // Start monitoring for clicks outside
            startClickOutsideMonitoring()

            // Make it key shortly after appearing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.popover?.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    
    func togglePopover() {
        if popover?.isShown == true {
            hidePopover()
        } else {
            showPopover()
        }
    }
    
    @objc private func clearHistory() {
        clipboardMonitor.clearHistory()
    }
    
    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
    
    func hidePopover() {
        stopClickOutsideMonitoring()
        popover?.close()
    }
    
    func updatePopoverSize(to size: NSSize) {
        popover?.contentSize = size
    }
    
    func activatePreviousApplication() {
                    guard let previousApp = previousApplication else { return }
        previousApp.activate(options: [.activateIgnoringOtherApps])
    }
    
    func hidePopoverAndActivatePreviousApp() {
        hidePopover()
        
        // Small delay to let the popover close before activating the previous app
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.activatePreviousApplication()
        }
    }

    // MARK: - Paste Scheduling
    func schedulePasteAfterActivation() {
        // Poll until the previous application becomes active, or timeout
        let start = Date()
        let timeout: TimeInterval = 2.0
        let pollInterval: TimeInterval = 0.08
        

        func attempt() {
            // If we no longer have a previousApplication stored, just fire
            guard let previous = self.previousApplication else {
                
                self.simulatePasteKeypress()
                return
            }
            if previous.isActive {
                // App is active; send paste event
                self.simulatePasteKeypress()
                return
            }
            if Date().timeIntervalSince(start) > timeout {
                
                self.simulatePasteKeypress()
                return
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { attempt() }
        }

        // Give a short grace period after activation attempt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            attempt()
        }
    }

    private func simulatePasteKeypress() {
        permissionManager.checkPermission() // Refresh permission status
        
        if !permissionManager.isAccessibilityGranted {
            
            
            // Try prompting again (some cases require options variant to re-evaluate)
            if !didAttemptAXPrompt {
                didAttemptAXPrompt = true
                permissionManager.requestPermission()
                
                
                // Wait a moment and check again
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if self.permissionManager.isAccessibilityGranted {
                        self.simulatePasteKeypress() // Retry the paste
                    } else {
                    }
                }
                return
            } else {
                return
            }
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        guard let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) else { return }
        keyDownEvent.flags = .maskCommand
        guard let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else { return }
        keyUpEvent.flags = .maskCommand
        keyDownEvent.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) {
            keyUpEvent.post(tap: .cghidEventTap)
        }
    }

    @objc private func diagnosePaste() {
        permissionManager.checkPermission()
        simulatePasteKeypress()
    }
    
    private func setupGlobalHotkey() {
        // Register Cmd+Shift+V hotkey
        let hotKeyCode: UInt32 = 9 // 'V' key
        let modifierKeys: UInt32 = UInt32(cmdKey | shiftKey)
        
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        
        _ = InstallEventHandler(GetApplicationEventTarget(), { (_, event, userData) -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let menuBarController = Unmanaged<MenuBarController>.fromOpaque(userData).takeUnretainedValue()
            
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, OSType(kEventParamDirectObject), OSType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            
            if hotKeyID.id == menuBarController.hotKeyID.id {
                DispatchQueue.main.async {
                    menuBarController.togglePopover()
                }
            }
            
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)
        
        let registerResult = RegisterEventHotKey(hotKeyCode, modifierKeys, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        
        _ = registerResult
    }
    
    // MARK: - Click Outside Monitoring
    private func startClickOutsideMonitoring() {
        stopClickOutsideMonitoring() // Ensure we don't have multiple monitors
        
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self,
                  let popover = self.popover,
                  popover.isShown,
                  let popoverWindow = popover.contentViewController?.view.window else {
                return
            }
            
            // Convert the event location to screen coordinates
            let eventLocation = event.locationInWindow
            let screenLocation = event.window?.convertPoint(toScreen: eventLocation) ?? eventLocation
            
            // Check if the click is outside the popover bounds
            if !popoverWindow.frame.contains(screenLocation) {
                DispatchQueue.main.async {
                    self.hidePopoverAndActivatePreviousApp()
                }
            }
        }
        
    }
    
    private func stopClickOutsideMonitoring() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
    
    func cleanup() {
        stopClickOutsideMonitoring()
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        NotificationCenter.default.removeObserver(self)
        statusItem = nil
        popover = nil
    }
    
    deinit {
        cleanup()
    }
}

private func fourCharCodeFrom(_ string: String) -> FourCharCode {
    let utf8 = string.utf8
    var result: FourCharCode = 0
    for (i, byte) in utf8.enumerated() {
        guard i < 4 else { break }
        result = result << 8 + FourCharCode(byte)
    }
    return result
}

// Simple inline settings view until we can add SettingsView.swift to the project
struct SimpleSettingsView: View {
    @ObservedObject private var preferences = UserPreferencesManager.shared
    let onDismiss: () -> Void
    let onCheckForUpdates: () -> Void

    init(onDismiss: @escaping () -> Void = {}, onCheckForUpdates: @escaping () -> Void = {}) {
        self.onDismiss = onDismiss
        self.onCheckForUpdates = onCheckForUpdates
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Clipboard History
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Clipboard History")
                            .font(.headline)

                        HStack {
                            Text("Max items:")
                                .frame(width: 80, alignment: .leading)
                            Slider(
                                value: Binding(
                                    get: { Double(preferences.maxClipboardItems) },
                                    set: { preferences.maxClipboardItems = Int($0) }
                                ),
                                in: Double(UserPreferencesManager.minClipboardItems)...Double(UserPreferencesManager.maxClipboardItems),
                                step: 10
                            )
                            Text("\(preferences.maxClipboardItems)")
                                .frame(width: 45, alignment: .trailing)
                                .foregroundColor(.secondary)
                        }
                    }

                    Divider()

                    // Persistence
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Persistence")
                            .font(.headline)

                        Toggle("Save clipboard history", isOn: $preferences.persistenceEnabled)

                        if preferences.persistenceEnabled {
                            Toggle("Save images to disk", isOn: $preferences.saveImages)

                            HStack {
                                Text("Storage:")
                                    .frame(width: 80, alignment: .leading)
                                Slider(
                                    value: Binding(
                                        get: { Double(preferences.maxStorageSize) },
                                        set: { preferences.maxStorageSize = Int($0) }
                                    ),
                                    in: 10...10000,
                                    step: 50
                                )
                                Text(preferences.maxStorageSize >= 1000 ? String(format: "%.1fGB", Double(preferences.maxStorageSize) / 1000.0) : "\(preferences.maxStorageSize)MB")
                                    .frame(width: 50, alignment: .trailing)
                                    .foregroundColor(.secondary)
                            }

                            HStack {
                                Text("Keep for:")
                                    .frame(width: 80, alignment: .leading)
                                Slider(
                                    value: Binding(
                                        get: { Double(preferences.persistenceDays) },
                                        set: { preferences.persistenceDays = Int($0) }
                                    ),
                                    in: 1...365,
                                    step: 1
                                )
                                Text("\(preferences.persistenceDays) days")
                                    .frame(width: 60, alignment: .trailing)
                                    .foregroundColor(.secondary)
                            }

                            Text("Favorites are kept indefinitely.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Divider()

                    // Hotkey & Shortcuts
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Shortcuts")
                            .font(.headline)

                        Toggle("Global hotkey (⌘ ⇧ V)", isOn: $preferences.hotKeyEnabled)
                        Toggle("In-app shortcuts", isOn: $preferences.shortcutsEnabled)

                        if preferences.shortcutsEnabled {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 12) {
                                    ForEach([("⌘ D", "Favorite"), ("⌘ F", "Filter"), ("⌘ Z", "Preview")], id: \.0) { shortcut in
                                        HStack(spacing: 4) {
                                            Text(shortcut.0)
                                                .font(.system(.caption2, design: .monospaced))
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 2)
                                                .background(Color.secondary.opacity(0.2))
                                                .cornerRadius(3)
                                            Text(shortcut.1)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                HStack(spacing: 4) {
                                    Text("⌘+Click")
                                        .font(.system(.caption2, design: .monospaced))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.2))
                                        .cornerRadius(3)
                                    Text("Multi-select for deletion")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.leading, 16)
                        }
                    }
                }
            }

            Divider()

            // Footer with version and links
            HStack {
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

                Text("MacClipboard v\(version) (\(build))")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("·")
                    .foregroundColor(.secondary)

                Button("GitHub") {
                    if let url = URL(string: "https://github.com/rakodev/mac-clipboard") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)

                Text("·")
                    .foregroundColor(.secondary)

                Button("Check for Updates") {
                    onCheckForUpdates()
                }
                .buttonStyle(.link)
                .font(.caption)

                Spacer()

                Button("Reset") {
                    preferences.resetToDefaults()
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Button("Done") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 400, minHeight: 360)
        .background(Color(NSColor.windowBackgroundColor))
    }
}