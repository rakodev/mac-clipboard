import SwiftUI
import AppKit
import Carbon

class MenuBarController: ObservableObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var clipboardMonitor: ClipboardMonitor
    private var hotKeyRef: EventHotKeyRef?
    private var previousApplication: NSRunningApplication?
    private var didAttemptAXPrompt = false
    private var clickOutsideMonitor: Any?
    
    let permissionManager = PermissionManager()
    
    // Helper function to convert string to fourCharCode
    private func fourCharCode(_ string: String) -> OSType {
        guard string.count == 4 else { return 0 }
        let chars = Array(string.utf8)
        return OSType(chars[0]) << 24 | OSType(chars[1]) << 16 | OSType(chars[2]) << 8 | OSType(chars[3])
    }
    
    private lazy var hotKeyID: EventHotKeyID = EventHotKeyID(signature: fourCharCode("ClpM"), id: 1)
    
    init() {
        self.clipboardMonitor = ClipboardMonitor()
        setupStatusItem()
        setupGlobalHotkey()
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            // Try system symbol first, fallback to a simple text icon
            if let clipboardImage = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard Manager") {
                button.image = clipboardImage
            } else {
                // Fallback to a simple text-based icon
                button.title = "📋"
            }
            
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            
            // Make sure the button is visible
            button.isEnabled = true
            
            print("✅ Menu bar item created successfully")
        } else {
            print("❌ Failed to create menu bar button")
        }
        
        setupPopover()
    }
    
    private func setupPopover() {
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 400, height: 500)
        popover?.behavior = .semitransient  // Changed from .transient to .semitransient
        popover?.animates = true
        popover?.contentViewController = NSHostingController(
            rootView: ContentView(clipboardMonitor: clipboardMonitor, menuBarController: self)
        )
        
        print("✅ Popover setup completed")
    }
    
    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }
    
    private func showContextMenu() {
        let menu = NSMenu()
        
        menu.addItem(NSMenuItem(title: "Show Clipboard", action: #selector(showPopover), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Diagnose Paste", action: #selector(diagnosePaste), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let aboutItem = NSMenuItem(title: "About MacClipboard", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(aboutItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Clipboard Manager", action: #selector(quit), keyEquivalent: "q"))
        
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
    
    @objc private func showPopover() {
        guard let button = statusItem?.button else { 
            print("❌ No status item button available")
            return 
        }
        
        if popover?.isShown == true {
            print("🔄 Closing popover")
            stopClickOutsideMonitoring()
            popover?.close()
        } else {
            // Capture the frontmost application BEFORE we activate ourselves
            previousApplication = NSWorkspace.shared.frontmostApplication
            print("📱 (showPopover) Stored previous app: \(previousApplication?.localizedName ?? "unknown")")

            // Recreate the content view each time to force fresh state (resets selection/highlight)
            if let popover = popover {
                popover.contentViewController = NSHostingController(
                    rootView: ContentView(clipboardMonitor: clipboardMonitor, menuBarController: self)
                )
            }

            // Log current AX trust state every open for transparency
            Logging.debug("[AX][popover-open] trusted=\(AXIsProcessTrusted())")

            print("🔄 Opening popover")
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
        showPopover()
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
    
    func activatePreviousApplication() {
        guard let previousApp = previousApplication else {
            print("⚠️ No previous application stored")
            return
        }
        
        print("🔄 Activating previous app: \(previousApp.localizedName ?? "unknown")")
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
        Logging.debug("[Paste] Scheduling paste; timeout=\(timeout)s poll=\(pollInterval)s previous=\(previousApplication?.localizedName ?? "nil")")

        func attempt() {
            // If we no longer have a previousApplication stored, just fire
            guard let previous = self.previousApplication else {
                Logging.debug("[Paste] No previous app stored; firing paste now")
                self.simulatePasteKeypress()
                return
            }
            if previous.isActive {
                Logging.debug("[Paste] Previous app active (\(previous.localizedName ?? "unknown")); sending paste event")
                // App is active; send paste event
                self.simulatePasteKeypress()
                return
            }
            if Date().timeIntervalSince(start) > timeout {
                Logging.debug("[Paste] Timeout waiting for activation; firing paste anyway")
                self.simulatePasteKeypress()
                return
            }
            Logging.debug("[Paste] Previous app not yet active; retrying in \(pollInterval)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { attempt() }
        }

        // Give a short grace period after activation attempt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            Logging.debug("[Paste] Starting activation polling")
            attempt()
        }
    }

    private func simulatePasteKeypress() {
        permissionManager.checkPermission() // Refresh permission status
        
        if !permissionManager.isAccessibilityGranted {
            Logging.debug("[Paste][Diag] Permission not granted according to PermissionManager")
            Logging.debug("[Paste][Diag] AXIsProcessTrusted() raw check: \(AXIsProcessTrusted())")
            
            // Try prompting again (some cases require options variant to re-evaluate)
            if !didAttemptAXPrompt {
                didAttemptAXPrompt = true
                permissionManager.requestPermission()
                Logging.debug("[Paste][Diag] Requested permission via PermissionManager")
                
                // Wait a moment and check again
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if self.permissionManager.isAccessibilityGranted {
                        self.simulatePasteKeypress() // Retry the paste
                    } else {
                        Logging.debug("[Paste][Diag] Still not granted after prompt; aborting paste simulation")
                    }
                }
                return
            } else {
                Logging.debug("[Paste][Diag] Permission not available; aborting paste simulation")
                return
            }
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        guard let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) else { return }
        keyDownEvent.flags = .maskCommand
        guard let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else { return }
        keyUpEvent.flags = .maskCommand
        Logging.debug("[Paste] Posting Cmd+V keyDown")
        keyDownEvent.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) {
            Logging.debug("[Paste] Posting Cmd+V keyUp")
            keyUpEvent.post(tap: .cghidEventTap)
        }
    }

    @objc private func diagnosePaste() {
        permissionManager.checkPermission()
        let trusted = AXIsProcessTrusted()
        Logging.debug("[Diag] PermissionManager.isAccessibilityGranted: \(permissionManager.isAccessibilityGranted)")
        Logging.debug("[Diag] AXIsProcessTrusted() raw: \(trusted)")
        if let prev = previousApplication {
            Logging.debug("[Diag] Previous app stored: bundle=\(prev.bundleIdentifier ?? "nil") name=\(prev.localizedName ?? "nil") active=\(prev.isActive)")
        } else {
            Logging.debug("[Diag] No previous application stored")
        }
        let front = NSWorkspace.shared.frontmostApplication
        Logging.debug("[Diag] Frontmost now: bundle=\(front?.bundleIdentifier ?? "nil") name=\(front?.localizedName ?? "nil")")
        // Fire a manual paste attempt
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
                print("🔥 Global hotkey pressed!")
                DispatchQueue.main.async {
                    menuBarController.togglePopover()
                }
            }
            
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)
        
        let registerResult = RegisterEventHotKey(hotKeyCode, modifierKeys, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        
        if registerResult == noErr {
            print("✅ Global hotkey Cmd+Shift+V registered successfully")
        } else {
            print("❌ Failed to register global hotkey, error: \(registerResult)")
        }
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
                print("🖱️ Click detected outside popover, closing...")
                DispatchQueue.main.async {
                    self.hidePopover()
                }
            }
        }
        
        print("👁️ Started monitoring for clicks outside popover")
    }
    
    private func stopClickOutsideMonitoring() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
            print("👁️ Stopped monitoring for clicks outside popover")
        }
    }
    
    func cleanup() {
        stopClickOutsideMonitoring()
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        statusItem = nil
        popover = nil
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