import SwiftUI
import AppKit
import Carbon
import Combine

class MenuBarController: NSObject, ObservableObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var clipboardMonitor: ClipboardMonitor
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyEventHandlerRef: EventHandlerRef?
    private var hotKeyPreferenceCancellable: AnyCancellable?
    private let updateService: UpdateService
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
    
    init(clipboardMonitor: ClipboardMonitor, updateService: UpdateService = .shared) {
        self.clipboardMonitor = clipboardMonitor
        self.updateService = updateService
    super.init()
        setupStatusItem()
        setupPopover()
        setupGlobalHotkeyPreferenceObserver()
        updateGlobalHotkeyRegistration()
        
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

    private func makeStatusBarImage() -> NSImage? {
        let symbolNames = ["doc.on.clipboard", "clipboard", "doc.on.doc"]

        for symbolName in symbolNames {
            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "MacClipboard") {
                image.isTemplate = true
                image.size = NSSize(width: 17, height: 17)
                return image
            }
        }

        return nil
    }

    private func configureStatusButton(_ button: NSStatusBarButton) {
        if let image = makeStatusBarImage() {
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "📋"
        }

        button.imagePosition = .imageOnly
        button.appearsDisabled = false
        button.target = nil
        button.action = nil
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        button.isEnabled = true
        button.isHidden = false
        button.needsDisplay = true
    }
    
    private func setupStatusItem() {
        // Ensure we're on the main thread
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.setupStatusItem()
            }
            return
        }
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.isVisible = true

        if let button = statusItem?.button {
            configureStatusButton(button)
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
            configureStatusButton(button)
        }
    }
    
    
    // Debug method to verify button setup
    private func verifyButtonSetup() {
        if let button = statusItem?.button {
            // If target or action is nil, reinitialize
            if button.target == nil || button.action == nil {
                configureStatusButton(button)
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

        updateService.checkForUpdates(currentVersion: currentVersion) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }

                switch result {
                case .success(.updateAvailable(let currentVersion, let latestVersion, let downloadURL)):
                    let alert = NSAlert()
                    alert.messageText = "Update Available"
                    alert.informativeText = "A new version (v\(latestVersion)) is available. You are currently running v\(currentVersion)."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "Download")
                    alert.addButton(withTitle: "Later")

                    NSApp.activate(ignoringOtherApps: true)
                    let response = alert.runModal()

                    if response == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(downloadURL)
                    }

                case .success(.upToDate(let currentVersion)):
                    self.showUpdateAlert(title: "You're Up to Date", message: "MacClipboard v\(currentVersion) is the latest version.")

                case .failure(.cancelled):
                    return

                case .failure(let error):
                    self.showUpdateAlert(title: "Update Check Failed", message: error.localizedDescription)
                }
            }
        }
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

    @objc func showSettings() {
        // Close existing settings window if open
        settingsWindow?.close()
        
        // Hide popover if it's showing to avoid conflicts
        if popover?.isShown == true {
            popover?.close()
        }
        
        // Create settings view with window reference for proper dismissal
        let settingsView = SettingsView(
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
            clipboardMonitor.refreshClipboardNow()

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

    private func setupGlobalHotkeyPreferenceObserver() {
        hotKeyPreferenceCancellable = UserPreferencesManager.shared.$hotKeyEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateGlobalHotkeyRegistration()
            }
    }

    private func updateGlobalHotkeyRegistration() {
        if UserPreferencesManager.shared.hotKeyEnabled {
            registerGlobalHotkeyIfNeeded()
        } else {
            unregisterGlobalHotkey()
        }
    }

    private func installGlobalHotkeyHandlerIfNeeded() {
        guard hotKeyEventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        var handlerRef: EventHandlerRef?

        let installResult = InstallEventHandler(GetApplicationEventTarget(), { (_, event, userData) -> OSStatus in
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
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        if installResult == noErr {
            hotKeyEventHandlerRef = handlerRef
        } else {
            Logging.info("Failed to install global hotkey handler: \(installResult)")
        }
    }

    private func registerGlobalHotkeyIfNeeded() {
        guard hotKeyRef == nil else { return }

        // Register Cmd+Shift+V hotkey
        let hotKeyCode: UInt32 = 9 // 'V' key
        let modifierKeys: UInt32 = UInt32(cmdKey | shiftKey)

        installGlobalHotkeyHandlerIfNeeded()
        guard hotKeyEventHandlerRef != nil else { return }

        let registerResult = RegisterEventHotKey(hotKeyCode, modifierKeys, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

        if registerResult != noErr {
            hotKeyRef = nil
            Logging.info("Failed to register global hotkey: \(registerResult)")
        }
    }

    private func unregisterGlobalHotkey() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
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
        unregisterGlobalHotkey()
        if let hotKeyEventHandlerRef {
            RemoveEventHandler(hotKeyEventHandlerRef)
            self.hotKeyEventHandlerRef = nil
        }
        updateService.cancel()
        hotKeyPreferenceCancellable = nil
        NotificationCenter.default.removeObserver(self)
        statusItem = nil
        popover = nil
    }
    
    deinit {
        cleanup()
    }
}

