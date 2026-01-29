import Foundation
import ServiceManagement

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
    static let defaultClipboardItems = 200
    
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
    
    // Whether to auto-start with system (launch at login)
    @Published var autoStartEnabled: Bool {
        didSet {
            defaults.set(autoStartEnabled, forKey: Keys.autoStartEnabled)
            updateLoginItem()
        }
    }

    /// Updates the login item registration based on autoStartEnabled preference
    private func updateLoginItem() {
        let shouldEnable = autoStartEnabled
        DispatchQueue.global(qos: .utility).async {
            do {
                if shouldEnable {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Logging.debug("Failed to update login item: \(error.localizedDescription)")
            }
        }
    }

    /// Ensures login item state matches the preference (call on app launch)
    func syncLoginItemState() {
        updateLoginItem()
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
        self.autoStartEnabled = defaults.object(forKey: Keys.autoStartEnabled) as? Bool ?? true
        
        // Persistence settings - enabled by default as requested
        self.persistenceEnabled = defaults.object(forKey: Keys.persistenceEnabled) as? Bool ?? true
        self.saveImages = defaults.object(forKey: Keys.saveImages) as? Bool ?? true // Images saved by default
        self.maxStorageSize = defaults.object(forKey: Keys.maxStorageSize) as? Int ?? 1000 // 1GB default
        self.persistenceDays = defaults.object(forKey: Keys.persistenceDays) as? Int ?? 60 // 60 days default

        // Keyboard shortcuts - enabled by default
        self.shortcutsEnabled = defaults.object(forKey: Keys.shortcutsEnabled) as? Bool ?? true
    }
    
    func resetToDefaults() {
        maxClipboardItems = Self.defaultClipboardItems
        hotKeyEnabled = true
        showImagePreviews = true
        autoStartEnabled = true
        persistenceEnabled = true
        saveImages = true
        maxStorageSize = 1000
        persistenceDays = 60
        shortcutsEnabled = true
    }
}