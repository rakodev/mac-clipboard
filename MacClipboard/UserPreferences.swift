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
        static let persistenceEnabled = "persistenceEnabled"
        static let saveImages = "saveImages"
        static let maxStorageSize = "maxStorageSize"
        static let persistenceDays = "persistenceDays"
        static let shortcutsEnabled = "shortcutsEnabled"
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
    
    // Whether persistence is enabled
    @Published var persistenceEnabled: Bool {
        didSet {
            defaults.set(persistenceEnabled, forKey: Keys.persistenceEnabled)
        }
    }
    
    // Whether to save images to persistent storage
    @Published var saveImages: Bool {
        didSet {
            defaults.set(saveImages, forKey: Keys.saveImages)
        }
    }
    
    // Maximum storage size in MB
    @Published var maxStorageSize: Int {
        didSet {
            let clampedValue = max(10, min(10000, maxStorageSize)) // 10MB to 10GB
            if clampedValue != maxStorageSize {
                maxStorageSize = clampedValue
                return
            }
            defaults.set(maxStorageSize, forKey: Keys.maxStorageSize)
        }
    }
    
    // Number of days to keep items in persistent storage
    @Published var persistenceDays: Int {
        didSet {
            let clampedValue = max(1, min(365, persistenceDays)) // 1 day to 1 year
            if clampedValue != persistenceDays {
                persistenceDays = clampedValue
                return
            }
            defaults.set(persistenceDays, forKey: Keys.persistenceDays)
        }
    }

    // Whether keyboard shortcuts are enabled
    @Published var shortcutsEnabled: Bool {
        didSet {
            defaults.set(shortcutsEnabled, forKey: Keys.shortcutsEnabled)
        }
    }

    private init() {
        // Load saved preferences or set defaults
        let savedMaxItems = defaults.object(forKey: Keys.maxClipboardItems) as? Int ?? Self.defaultClipboardItems
        self.maxClipboardItems = max(Self.minClipboardItems, min(Self.maxClipboardItems, savedMaxItems))
        self.hotKeyEnabled = defaults.object(forKey: Keys.hotKeyEnabled) as? Bool ?? true
        self.showImagePreviews = defaults.object(forKey: Keys.showImagePreviews) as? Bool ?? true
        self.autoStartEnabled = defaults.object(forKey: Keys.autoStartEnabled) as? Bool ?? false
        
        // Persistence settings - enabled by default as requested
        self.persistenceEnabled = defaults.object(forKey: Keys.persistenceEnabled) as? Bool ?? true
        self.saveImages = defaults.object(forKey: Keys.saveImages) as? Bool ?? false // Images off by default due to size
        self.maxStorageSize = defaults.object(forKey: Keys.maxStorageSize) as? Int ?? 500 // 500MB default
        self.persistenceDays = defaults.object(forKey: Keys.persistenceDays) as? Int ?? 30 // 30 days default

        // Keyboard shortcuts - enabled by default
        self.shortcutsEnabled = defaults.object(forKey: Keys.shortcutsEnabled) as? Bool ?? true
    }
    
    func resetToDefaults() {
        maxClipboardItems = Self.defaultClipboardItems
        hotKeyEnabled = true
        showImagePreviews = true
        autoStartEnabled = false
        persistenceEnabled = true
        saveImages = false
        maxStorageSize = 500
        persistenceDays = 30
        shortcutsEnabled = true
    }
}