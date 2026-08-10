import SwiftUI
import AppKit
import Carbon
import Combine

/// A text edit in progress, held outside `ContentView`.
///
/// `showPopover` builds a fresh `ContentView` on every open so the selection resets, and any click
/// outside the popover closes it. A draft kept in SwiftUI state would therefore be lost the moment
/// the user looked something up in another app, which is exactly what people do while editing. One
/// draft at a time is enough: the editor takes over the whole popover.
///
/// The source item is stored by value so a draft outlives it: the row can be deleted, aged out, or
/// trimmed away while the popover is closed, and the edit still saves as a new item.
final class ClipboardEditDraftStore {
    struct Draft {
        let source: ClipboardItem
        var text: String

        var isDirty: Bool { text != source.fullText }
    }

    private(set) var draft: Draft?

    var isDirty: Bool { draft?.isDirty ?? false }

    func begin(source: ClipboardItem, text: String) {
        draft = Draft(source: source, text: text)
    }

    func update(text: String) {
        draft?.text = text
    }

    func clear() {
        draft = nil
    }
}

class MenuBarController: NSObject, ObservableObject {
    /// Not `@Published`: nothing observes it, and republishing on every keystroke would redraw the
    /// popover for no reason. `ContentView` reads it when it appears and writes to it as the user
    /// types.
    let editDraft = ClipboardEditDraftStore()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var clipboardMonitor: ClipboardMonitor
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyEventHandlerRef: EventHandlerRef?
    private var hotKeyPreferenceCancellable: AnyCancellable?
    private var capturePauseCancellable: AnyCancellable?
    private var availableUpdateCancellable: AnyCancellable?
    /// True while the Settings recorder is waiting for a key press, which is the one time the
    /// hotkey has to be out of the way. See `setGlobalHotkeyRecording`.
    private var isRecordingGlobalHotkey = false
    /// What the app knows about a newer release. Not private: `ContentView` shows the banner from
    /// the same state the icon badge is drawn from, so the two cannot disagree.
    let updateChecker: UpdateChecker
    private var previousApplication: NSRunningApplication?
    private var clickOutsideMonitor: Any?
    private var settingsWindow: NSWindow?
    
    let permissionManager = PermissionManager()

    /// True when the global hotkey is switched on in preferences but macOS refused the
    /// registration, which happens when another app already owns the combination.
    /// Surfaced in the popover: silently losing the hotkey is very hard to diagnose.
    @Published private(set) var isGlobalHotkeyUnavailable: Bool = false

    // Helper function to convert string to fourCharCode
    private func fourCharCode(_ string: String) -> OSType {
        guard string.count == 4 else { return 0 }
        let chars = Array(string.utf8)
        return OSType(chars[0]) << 24 | OSType(chars[1]) << 16 | OSType(chars[2]) << 8 | OSType(chars[3])
    }
    
    private lazy var hotKeyID: EventHotKeyID = EventHotKeyID(signature: fourCharCode("ClpM"), id: 1)
    
    init(clipboardMonitor: ClipboardMonitor, updateChecker: UpdateChecker = .shared) {
        self.clipboardMonitor = clipboardMonitor
        self.updateChecker = updateChecker
        super.init()
        setupStatusItem()
        setupPopover()
        setupGlobalHotkeyPreferenceObserver()
        setupCapturePauseObserver()
        setupAvailableUpdateObserver()
        updateGlobalHotkeyRegistration()
        updateChecker.start()
        
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
        // Dev builds use the filled variant so that a dev build and an installed release
        // build sitting next to each other in the menu bar can be told apart at a glance.
        let symbolNames = BuildInfo.isDevBuild
            ? ["doc.on.clipboard.fill", "clipboard.fill", "doc.on.doc.fill", "doc.on.clipboard"]
            : ["doc.on.clipboard", "clipboard", "doc.on.doc"]

        for symbolName in symbolNames {
            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: statusItemLabel) {
                image.isTemplate = true
                image.size = NSSize(width: 17, height: 17)

                // Pause first, then the badge: the slash is drawn through the clipboard glyph, and
                // knocking it out after the dot was added would cut a notch through the dot too.
                var composed = clipboardMonitor.isCapturePaused ? Self.slashed(image) : image
                if updateChecker.availableUpdate != nil {
                    composed = Self.badged(composed)
                }
                return composed
            }
        }

        return nil
    }

    /// The icon with a dot in its top-right corner, for a release the user has not looked at yet.
    ///
    /// This is the only surface that reaches someone working in another app, and it has to say
    /// "there is something here" without saying it loudly: an update is not urgent, and a menu bar
    /// is not somewhere to put a red badge for a minor version. So it stays a template image and
    /// takes the menu bar's own tint, like the glyph it sits on, rather than being coloured.
    ///
    /// The canvas is widened rather than the glyph inset, so the clipboard does not visibly shrink
    /// when an update appears.
    private static func badged(_ base: NSImage) -> NSImage {
        let dotDiameter = max(4.0, base.size.width * 0.30)
        // Only the width grows. A taller image would be centred by the status item and the glyph
        // would sit low against the menu bar's baseline.
        let canvas = NSSize(width: base.size.width + dotDiameter * 0.5, height: base.size.height)

        let badgedImage = NSImage(size: canvas, flipped: false) { _ in
            base.draw(in: NSRect(origin: .zero, size: base.size))

            let dot = NSRect(
                x: canvas.width - dotDiameter,
                y: canvas.height - dotDiameter,
                width: dotDiameter,
                height: dotDiameter
            )

            // Knock a ring out from under the dot so it reads as separate from the glyph rather
            // than as a lump on its corner, the same trick the slash uses.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: dot.insetBy(dx: -dotDiameter * 0.22, dy: -dotDiameter * 0.22)).fill()

            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()

            return true
        }

        badgedImage.isTemplate = true
        return badgedImage
    }

    /// The clipboard with a line struck through it, for a paused capture.
    ///
    /// Composed rather than picked from SF Symbols, which has no slashed clipboard in any weight.
    /// Swapping to a generic `pause` glyph instead would cost the user the one thing the menu bar
    /// icon is for, which is knowing at a glance which icon is MacClipboard. The slash runs
    /// lower-left to upper-right like every `.slash` symbol Apple ships, and a gap is knocked out
    /// of the glyph underneath it so it stays readable at 17pt.
    private static func slashed(_ base: NSImage) -> NSImage {
        let slashedImage = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)

            let inset = rect.width * 0.10
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX + inset, y: rect.minY + inset))
            slash.line(to: NSPoint(x: rect.maxX - inset, y: rect.maxY - inset))
            slash.lineCapStyle = .round
            NSColor.black.setStroke()

            NSGraphicsContext.current?.compositingOperation = .destinationOut
            slash.lineWidth = max(2.4, rect.width * 0.20)
            slash.stroke()

            NSGraphicsContext.current?.compositingOperation = .sourceOver
            slash.lineWidth = max(1.2, rect.width * 0.10)
            slash.stroke()

            return true
        }

        // Template, like the symbol it is drawn from, so it still follows the menu bar's tint.
        slashedImage.isTemplate = true
        return slashedImage
    }

    /// "MacClipboard", or "MacClipboard (Dev)" for a dev build.
    private var statusItemLabel: String {
        let name = L10n.string("MacClipboard", comment: "Menu bar button accessibility label")
        guard BuildInfo.isDevBuild else { return name }
        return "\(name) (\(BuildInfo.channelName))"
    }

    /// What the icon says about itself, in the tooltip and to VoiceOver. The icon shows the pause
    /// but only the label can say what it means.
    /// Both states can be true at once, and the icon shows both marks, so the label lists whatever
    /// applies rather than picking one. Without this the badge is a dot with no explanation, which
    /// tells a VoiceOver user nothing at all.
    private var statusItemStateLabel: String {
        var states: [String] = []

        if clipboardMonitor.isCapturePaused {
            states.append(L10n.string("capture paused", comment: "Menu bar button state, capture is switched off"))
        }

        if let update = updateChecker.availableUpdate {
            let format = L10n.string("update to v%@ available", comment: "Menu bar button state, a newer release exists")
            states.append(String(format: format, update.version))
        }

        guard !states.isEmpty else { return statusItemLabel }

        let format = L10n.string("%1$@ (%2$@)", comment: "Menu bar button accessibility label with its current states")
        let separator = L10n.string(", ", comment: "Separator between menu bar button states")
        return String(format: format, statusItemLabel, states.joined(separator: separator))
    }

    private func configureStatusButton(_ button: NSStatusBarButton) {
        if let image = makeStatusBarImage() {
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = BuildInfo.isDevBuild ? "📋*" : "📋"
        }

        button.toolTip = "\(statusItemStateLabel) \(BuildInfo.versionString)"
        button.setAccessibilityLabel(statusItemStateLabel)
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
        
        let showClipboardItem = NSMenuItem(title: L10n.string("Show Clipboard", comment: "Menu item title"), action: #selector(showPopover), keyEquivalent: "")
        showClipboardItem.target = self
        menu.addItem(showClipboardItem)

        // The title says what the item does, rather than a checkmark next to "Pause" that has to
        // be read twice to work out which way round it is.
        let pauseTitle = clipboardMonitor.isCapturePaused
            ? L10n.string("Resume Capture", comment: "Menu item title, switch clipboard capture back on")
            : L10n.string("Pause Capture", comment: "Menu item title, switch clipboard capture off")
        let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(toggleCapturePaused), keyEquivalent: "")
        pauseItem.target = self
        pauseItem.toolTip = clipboardMonitor.isCapturePaused
            ? L10n.string("Start saving new copies again", comment: "Menu item tooltip, resume capture")
            : L10n.string("Stop saving new copies until you resume. Your history is kept.", comment: "Menu item tooltip, pause capture")
        menu.addItem(pauseItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: L10n.string("Settings...", comment: "Menu item title"), action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let aboutItem = NSMenuItem(title: L10n.string("About MacClipboard", comment: "Menu item title"), action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        // When a release is already known about, the item says so and goes straight to it. Making
        // the user re-run a check that has already happened, to be told what the badge and the
        // banner are both showing, is a round trip for nothing.
        let updateItem: NSMenuItem
        if let update = updateChecker.availableUpdate {
            let format = L10n.string("Update to v%@...", comment: "Menu item title when a newer release is available")
            updateItem = NSMenuItem(
                title: String(format: format, update.version),
                action: #selector(showAvailableUpdate),
                keyEquivalent: ""
            )
            let tooltipFormat = L10n.string("You are running v%@", comment: "Menu item tooltip naming the running version")
            updateItem.toolTip = String(format: tooltipFormat, BuildInfo.shortVersion)
        } else {
            updateItem = NSMenuItem(
                title: L10n.string("Check for Updates...", comment: "Menu item title"),
                action: #selector(checkForUpdates),
                keyEquivalent: ""
            )
        }
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(title: L10n.string("Clear History", comment: "Menu item title"), action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: L10n.string("Quit Clipboard Manager", comment: "Menu item title"), action: #selector(quit), keyEquivalent: "q")
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
        let versionFormat = L10n.string("Version %@ (Build %@)", comment: "About panel version and build format")
        options[.applicationVersion] = String(format: versionFormat, version, build)
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The user asked, so this one reports back whatever it finds, including "nothing".
    ///
    /// A check that runs on its own never gets here: it updates `UpdateChecker.availableUpdate` and
    /// the three passive surfaces follow. An alert is what someone who pressed a button is owed,
    /// and it is the only path that shows one.
    @objc func checkForUpdates() {
        updateChecker.check(userInitiated: true) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(.updateAvailable(_, let latestVersion, let downloadURL)):
                self.presentAvailableUpdate(version: latestVersion, releaseURL: downloadURL)

            case .success(.upToDate(let currentVersion)):
                let messageFormat = L10n.string("MacClipboard v%@ is the latest version.", comment: "No update available alert message")
                self.showUpdateAlert(
                    title: L10n.string("You're Up to Date", comment: "No update available alert title"),
                    message: String(format: messageFormat, currentVersion)
                )

            case .failure(.cancelled):
                return

            case .failure(let error):
                self.showUpdateAlert(
                    title: L10n.string("Update Check Failed", comment: "Update check failure alert title"),
                    message: error.localizedDescription
                )
            }
        }
    }

    /// Opens the release the app already knows about, without checking again.
    @objc func showAvailableUpdate() {
        guard let update = updateChecker.availableUpdate else {
            checkForUpdates()
            return
        }

        presentAvailableUpdate(version: update.version, releaseURL: update.releaseURL)
    }

    /// The one modal in the feature, and only ever after the user asked for it.
    ///
    /// A Homebrew install is offered the command instead of a download, because downloading the DMG
    /// over a cask-managed copy leaves `brew` believing the old version is installed and the next
    /// `brew upgrade` walks it backwards.
    private func presentAvailableUpdate(version: String, releaseURL: URL) {
        let alert = NSAlert()
        alert.messageText = L10n.string("Update Available", comment: "Update available alert title")
        alert.alertStyle = .informational

        let isHomebrew = UpdateChecker.isHomebrewManaged
        let updateFormat = isHomebrew
            ? L10n.string(
                "MacClipboard v%1$@ is available. You are running v%2$@, installed with Homebrew, so upgrade it with:\n\n%3$@",
                comment: "Update available alert message for a Homebrew install"
            )
            : L10n.string(
                "MacClipboard v%1$@ is available. You are running v%2$@.",
                comment: "Update available alert message"
            )
        alert.informativeText = isHomebrew
            ? String(format: updateFormat, version, BuildInfo.shortVersion, UpdateChecker.homebrewUpgradeCommand)
            : String(format: updateFormat, version, BuildInfo.shortVersion)

        alert.addButton(withTitle: isHomebrew
            ? L10n.string("Copy Command", comment: "Update alert button, copy the Homebrew upgrade command")
            : L10n.string("Download", comment: "Update alert download button title"))
        alert.addButton(withTitle: L10n.string("Skip This Version", comment: "Update alert button, stop showing this version"))
        alert.addButton(withTitle: L10n.string("Later", comment: "Update alert dismiss button title"))

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            let action = updateChecker.performPrimaryAction(
                for: AvailableUpdate(version: version, releaseURL: releaseURL)
            )
            if action == .copiedHomebrewCommand {
                showUpdateAlert(
                    title: L10n.string("Command Copied", comment: "Confirmation alert title after copying the upgrade command"),
                    message: L10n.string(
                        "Paste it into Terminal to upgrade. MacClipboard restarts itself afterwards, and your history is kept.",
                        comment: "Confirmation alert message after copying the Homebrew upgrade command"
                    )
                )
            }
        case .alertSecondButtonReturn:
            updateChecker.skipAvailableUpdate()
        default:
            break
        }
    }

    private func showUpdateAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.string("OK", comment: "Standard confirmation button title"))
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
            clipboardMonitor: clipboardMonitor,
            menuBarController: self,
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
        
        window.title = L10n.string("MacClipboard Settings", comment: "Settings window title")
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
            guard !editDraft.isDirty else {
                focusPopover()
                return
            }
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
                self.focusPopover()
            }
        }
    }

    private func focusPopover() {
        popover?.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func togglePopover() {
        if popover?.isShown == true {
            // An unsaved edit is not something to lose to the hotkey or a stray click on the menu
            // bar icon, so those bring the popover back instead of dismissing it. Closing it is
            // still one Esc, or one click on the X, away.
            guard !editDraft.isDirty else {
                focusPopover()
                return
            }
            hidePopover()
        } else {
            showPopover()
        }
    }
    
    @objc private func clearHistory() {
        clipboardMonitor.clearHistory()
    }

    @objc private func toggleCapturePaused() {
        clipboardMonitor.toggleCapturePaused()
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

        guard permissionManager.isAccessibilityGranted else {
            // The item is already on the clipboard (copyToClipboard ran before this),
            // so the user can paste manually with Cmd+V. Do NOT fire the system
            // accessibility prompt here: it re-appears on every call while untrusted
            // and spams the user. The in-popover banner guides them to grant access.
            Logging.debug("[MenuBar] Skipping auto-paste: accessibility not granted (content copied for manual paste)")
            return
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

    /// Keeps the menu bar icon in step with the pause, whichever control flipped it. The icon is
    /// the only part of this the user can see while working in another app, so it is not allowed
    /// to lag behind the state.
    private func setupCapturePauseObserver() {
        capturePauseCancellable = clipboardMonitor.$isCapturePaused
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let button = self.statusItem?.button else { return }
                self.configureStatusButton(button)
            }
    }

    /// Keeps the badge in step with what the checker knows, for the same reason the pause observer
    /// above exists: a check completes ten seconds after launch, or a day into a session, and the
    /// icon is the only surface visible at that moment.
    private func setupAvailableUpdateObserver() {
        availableUpdateCancellable = updateChecker.$availableUpdate
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let button = self.statusItem?.button else { return }
                self.configureStatusButton(button)
            }
    }

    /// Both halves of the preference re-register: whether there is a hotkey at all, and which one.
    ///
    /// `@Published` fires before the property has taken its new value, so the hop to the main
    /// runloop is load-bearing rather than tidy: without it the registration would read the value
    /// being replaced and the new shortcut would take effect one change late.
    private func setupGlobalHotkeyPreferenceObserver() {
        let preferences = UserPreferencesManager.shared
        hotKeyPreferenceCancellable = preferences.$hotKeyEnabled
            .removeDuplicates()
            .map { _ in () }
            .merge(with: preferences.$globalHotkey.removeDuplicates().map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.updateGlobalHotkeyRegistration()
            }
    }

    /// Suspends the hotkey while Settings is recording a new one.
    ///
    /// A Carbon hotkey is taken system wide before the key event reaches this app, which makes the
    /// combination currently registered the one combination a recorder could never capture:
    /// pressing it would open the popover instead of being written down. Letting go of it for the
    /// length of the recording is what makes "type your shortcut" mean every shortcut, including
    /// the one already set.
    func setGlobalHotkeyRecording(_ recording: Bool) {
        guard isRecordingGlobalHotkey != recording else { return }
        isRecordingGlobalHotkey = recording
        updateGlobalHotkeyRegistration()
    }

    /// Always unregisters first. Carbon has no way to change a registration in place, and this runs
    /// only when a preference changes or a recording starts or ends, so there is nothing to save by
    /// working out whether the registration would have come back the same.
    private func updateGlobalHotkeyRegistration() {
        unregisterGlobalHotkey()

        guard !isRecordingGlobalHotkey, UserPreferencesManager.shared.hotKeyEnabled else { return }

        registerGlobalHotkey(UserPreferencesManager.shared.globalHotkey)
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

    private func registerGlobalHotkey(_ shortcut: GlobalHotkeyShortcut) {
        installGlobalHotkeyHandlerIfNeeded()
        guard hotKeyEventHandlerRef != nil else {
            setGlobalHotkeyUnavailable(true)
            return
        }

        let registerResult = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerResult != noErr {
            hotKeyRef = nil
            setGlobalHotkeyUnavailable(true)
            Logging.info("Failed to register global hotkey \(shortcut.displayString): OSStatus \(registerResult)")
        } else {
            setGlobalHotkeyUnavailable(false)
        }
    }

    private func unregisterGlobalHotkey() {
        setGlobalHotkeyUnavailable(false)
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
    }

    private func setGlobalHotkeyUnavailable(_ unavailable: Bool) {
        guard isGlobalHotkeyUnavailable != unavailable else { return }
        if Thread.isMainThread {
            isGlobalHotkeyUnavailable = unavailable
        } else {
            DispatchQueue.main.async { self.isGlobalHotkeyUnavailable = unavailable }
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
                // An unsaved edit outweighs the convenience of click-to-dismiss: the popover stays
                // open until the user saves, cancels, or closes it deliberately.
                guard !self.editDraft.isDirty else { return }

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
    
    /// Runs the quit-time history clear, if Settings asks for one.
    ///
    /// Kept out of `cleanup()`, which `deinit` also calls: a controller being torn down is not a
    /// quit, and clearing the user's history from a deallocation would be the worst kind of
    /// surprise. `AppDelegate.applicationWillTerminate` is the one caller.
    func clearHistoryOnQuitIfRequested() {
        clipboardMonitor.clearHistoryOnQuitIfRequested()
    }

    func cleanup() {
        stopClickOutsideMonitoring()
        unregisterGlobalHotkey()
        if let hotKeyEventHandlerRef {
            RemoveEventHandler(hotKeyEventHandlerRef)
            self.hotKeyEventHandlerRef = nil
        }
        updateChecker.stop()
        hotKeyPreferenceCancellable = nil
        capturePauseCancellable = nil
        availableUpdateCancellable = nil
        NotificationCenter.default.removeObserver(self)
        statusItem = nil
        popover = nil
    }
    
    deinit {
        cleanup()
    }
}

