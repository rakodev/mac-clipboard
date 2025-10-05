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
    
    // Maximum number of clipboard items to keep
    @Published var maxClipboardItems: Int {
        didSet {
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
        self.maxClipboardItems = defaults.object(forKey: Keys.maxClipboardItems) as? Int ?? 50
        self.hotKeyEnabled = defaults.object(forKey: Keys.hotKeyEnabled) as? Bool ?? true
        self.showImagePreviews = defaults.object(forKey: Keys.showImagePreviews) as? Bool ?? true
        self.autoStartEnabled = defaults.object(forKey: Keys.autoStartEnabled) as? Bool ?? false
    }
    
    func resetToDefaults() {
        maxClipboardItems = 50
        hotKeyEnabled = true
        showImagePreviews = true
        autoStartEnabled = false
    }
}