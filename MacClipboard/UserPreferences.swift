import Foundation

class UserPreferencesManager: ObservableObject {
    static let shared = UserPreferencesManager()
    
    private let defaults = UserDefaults.standard
    
    // Keys for UserDefaults
    private enum Keys {
        static let maxClipboardItems = "maxClipboardItems"
        static let hotKeyEnabled = "hotKeyEnabled"
        static let showImagePreviews = "showImagePreviews"
        static let autoStartEnabled = "autoStartEnabled"
    }
    
    // Constants
    static let minClipboardItems = 10
    static let maxClipboardItems = 1000
    static let defaultClipboardItems = 50
    
    // Maximum number of clipboard items to keep
    @Published var maxClipboardItems: Int {
        didSet {
            // Ensure value is within safe bounds
            let clampedValue = max(Self.minClipboardItems, min(Self.maxClipboardItems, maxClipboardItems))
            if clampedValue != maxClipboardItems {
                maxClipboardItems = clampedValue
                return
            }
            defaults.set(maxClipboardItems, forKey: Keys.maxClipboardItems)
        }
    }
    
    // Whether global hotkey is enabled
    @Published var hotKeyEnabled: Bool {
        didSet {
            defaults.set(hotKeyEnabled, forKey: Keys.hotKeyEnabled)
        }
    }
    
    // Whether to show image previews
    @Published var showImagePreviews: Bool {
        didSet {
            defaults.set(showImagePreviews, forKey: Keys.showImagePreviews)
        }
    }
    
    // Whether to auto-start with system
    @Published var autoStartEnabled: Bool {
        didSet {
            defaults.set(autoStartEnabled, forKey: Keys.autoStartEnabled)
        }
    }
    
    private init() {
        // Load saved preferences or set defaults
        let savedMaxItems = defaults.object(forKey: Keys.maxClipboardItems) as? Int ?? Self.defaultClipboardItems
        self.maxClipboardItems = max(Self.minClipboardItems, min(Self.maxClipboardItems, savedMaxItems))
        self.hotKeyEnabled = defaults.object(forKey: Keys.hotKeyEnabled) as? Bool ?? true
        self.showImagePreviews = defaults.object(forKey: Keys.showImagePreviews) as? Bool ?? true
        self.autoStartEnabled = defaults.object(forKey: Keys.autoStartEnabled) as? Bool ?? false
    }
    
    func resetToDefaults() {
        maxClipboardItems = Self.defaultClipboardItems
        hotKeyEnabled = true
        showImagePreviews = true
        autoStartEnabled = false
    }
}