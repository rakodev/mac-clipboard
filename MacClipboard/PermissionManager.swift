import Foundation
import ApplicationServices
import AppKit

/// Manages accessibility permission state and provides reactive updates
class PermissionManager: ObservableObject {
    @Published var isAccessibilityGranted: Bool = false
    
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
        
        // Only update on change to avoid unnecessary UI updates
        if actuallyWorking != isAccessibilityGranted {
            DispatchQueue.main.async {
                self.isAccessibilityGranted = actuallyWorking
                Logging.info("[PermissionManager] Accessibility status changed: trusted=\(trusted), canCreateEvents=\(canCreateEvents), result=\(actuallyWorking)")
                
                if trusted && !canCreateEvents {
                    Logging.info("[PermissionManager] AXIsProcessTrusted=true but CGEvent creation failed")
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
    Logging.info("[PermissionManager] Requesting accessibility permission")
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        let result = AXIsProcessTrustedWithOptions(options)
        
        // Check again after prompt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.checkPermission()
        }
        
    Logging.info("[PermissionManager] Permission request result: \(result)")
    }
    
    /// Force a complete permission reset - shows system prompt
    func forcePermissionPrompt() {
    Logging.info("[PermissionManager] Forcing accessibility permission prompt")
        
        // First check current status
        let currentTrusted = AXIsProcessTrusted()
    Logging.info("[PermissionManager] Current AXIsProcessTrusted: \(currentTrusted)")
        
        // Always show the prompt to ensure this specific binary gets permission
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        let promptResult = AXIsProcessTrustedWithOptions(options)
    Logging.info("[PermissionManager] Force prompt result: \(promptResult)")
        
        // Check again after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.checkPermission()
            Logging.info("[PermissionManager] Post-prompt check completed")
        }
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