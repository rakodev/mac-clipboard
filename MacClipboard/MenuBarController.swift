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
    
    @objc func showSettings() {
        // Close existing settings window if open
        settingsWindow?.close()
        
        // Hide popover if it's showing to avoid conflicts
        if popover?.isShown == true {
            popover?.close()
        }
        
        // Create settings view with window reference for proper dismissal
        let settingsView = SimpleSettingsView { [weak self] in
            self?.settingsWindow?.close()
            self?.settingsWindow = nil
        }
        
        // Create and configure window with better size
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
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
    
    init(onDismiss: @escaping () -> Void = {}) {
        self.onDismiss = onDismiss
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("MacClipboard Settings")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("Configure clipboard history and behavior")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                // Clipboard History Settings
                VStack(alignment: .leading, spacing: 12) {
                    Text("Clipboard History")
                        .font(.headline)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Maximum items:")
                                .frame(width: 120, alignment: .leading)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(
                                    value: Binding(
                                        get: { Double(preferences.maxClipboardItems) },
                                        set: { preferences.maxClipboardItems = Int($0) }
                                    ),
                                    in: Double(UserPreferencesManager.minClipboardItems)...Double(UserPreferencesManager.maxClipboardItems),
                                    step: 10
                                ) {
                                    Text("Max Items")
                                } minimumValueLabel: {
                                    Text("\(UserPreferencesManager.minClipboardItems)")
                                        .font(.caption)
                                } maximumValueLabel: {
                                    Text("\(UserPreferencesManager.maxClipboardItems)")
                                        .font(.caption)
                                }
                                
                                Text("\(preferences.maxClipboardItems) items")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Text("Older items will be automatically removed when the limit is reached.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 120)
                    }
                }
                
                Divider()
                
                // Persistence Settings
                VStack(alignment: .leading, spacing: 12) {
                    Text("Clipboard Persistence")
                        .font(.headline)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Save clipboard history", isOn: $preferences.persistenceEnabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        if preferences.persistenceEnabled {
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle("Save images to disk", isOn: $preferences.saveImages)
                                    .padding(.leading, 20)
                                
                                HStack {
                                    Text("Storage limit:")
                                        .frame(width: 100, alignment: .leading)
                                        .padding(.leading, 20)
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Slider(
                                            value: Binding(
                                                get: { Double(preferences.maxStorageSize) },
                                                set: { preferences.maxStorageSize = Int($0) }
                                            ),
                                            in: 10...1000,
                                            step: 10
                                        ) {
                                            Text("Storage Limit")
                                        } minimumValueLabel: {
                                            Text("10MB")
                                                .font(.caption)
                                        } maximumValueLabel: {
                                            Text("1GB")
                                                .font(.caption)
                                        }
                                        
                                        Text("\(preferences.maxStorageSize) MB")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                
                                HStack {
                                    Text("Keep items for:")
                                        .frame(width: 100, alignment: .leading)
                                        .padding(.leading, 20)
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Slider(
                                            value: Binding(
                                                get: { Double(preferences.persistenceDays) },
                                                set: { preferences.persistenceDays = Int($0) }
                                            ),
                                            in: 1...365,
                                            step: 1
                                        ) {
                                            Text("Persistence Days")
                                        } minimumValueLabel: {
                                            Text("1")
                                                .font(.caption)
                                        } maximumValueLabel: {
                                            Text("365")
                                                .font(.caption)
                                        }
                                        
                                        Text("\(preferences.persistenceDays) days")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                        
                        Text(preferences.persistenceEnabled 
                             ? "Clipboard items are saved to disk and restored when the app restarts."
                             : "Clipboard history will be cleared when the app quits.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Divider()
                
                // Additional Settings
                VStack(alignment: .leading, spacing: 12) {
                    Text("Global Hotkey")
                        .font(.headline)
                    
                    HStack {
                        Toggle("Enable global hotkey (⌘⇧V)", isOn: $preferences.hotKeyEnabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    if !preferences.hotKeyEnabled {
                        Text("Global hotkey is disabled. You can still access clipboard via menu bar.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer(minLength: 40)
                
                // Bottom buttons
                HStack {
                    Button("Reset to Defaults") {
                        preferences.resetToDefaults()
                    }
                    .buttonStyle(.borderless)
                    
                    Spacer()
                    
                    Button("Done") {
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 520, minHeight: 460)
        .background(Color(NSColor.windowBackgroundColor))
    }
}