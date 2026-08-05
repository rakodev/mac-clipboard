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
        static let imagePersistenceDays = "imagePersistenceDays"
        static let imageStorageCompacted = "imageStorageCompacted"
        static let shortcutsEnabled = "shortcutsEnabled"
        static let autoDetectSensitiveData = "autoDetectSensitiveData"
        static let autoHidePasswordLikeStrings = "autoHidePasswordLikeStrings"
    }
    
    // Constants
    static let minClipboardItems = 10
    static let maxClipboardItems = 1000
    static let defaultClipboardItems = 200
    static let minStorageSize = 10
    static let maxStorageSize = 10000
    static let defaultStorageSize = 1000
    static let defaultPersistenceDays = 60
    /// Images get a shorter default window than text. One image costs thousands of times more to
    /// keep than one text clip, and a screenshot is usually pasted once, while a copied snippet is
    /// often reference material you come back to weeks later.
    static let defaultImagePersistenceDays = 30
    
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
    ///
    /// Dev builds are skipped. `SMAppService.mainApp` registers whichever bundle is running, so a
    /// dev build asks macOS to launch `~/Applications/MacClipboard-Dev.app` at every login, which
    /// nobody wants, and the user ends up with dev copies in their Login Items list next to the
    /// real app. The preference is still stored; it takes effect for the installed build.
    private func updateLoginItem() {
        guard !BuildInfo.isDevBuild else {
            Logging.debug("Skipping login item update for a dev build (\(BuildInfo.bundleIdentifier))")
            return
        }

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
            let clampedValue = max(Self.minStorageSize, min(Self.maxStorageSize, maxStorageSize))
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

    // Number of days to keep images. Kept separate from `persistenceDays` because images are
    // effectively the entire storage cost of a history.
    @Published var imagePersistenceDays: Int {
        didSet {
            let clampedValue = max(1, min(365, imagePersistenceDays))
            if clampedValue != imagePersistenceDays {
                imagePersistenceDays = clampedValue
                return
            }
            defaults.set(imagePersistenceDays, forKey: Keys.imagePersistenceDays)
        }
    }

    /// Whether the one-time re-encode of pre-PNG stored images has run. Not user facing.
    var imageStorageCompacted: Bool {
        get { defaults.bool(forKey: Keys.imageStorageCompacted) }
        set { defaults.set(newValue, forKey: Keys.imageStorageCompacted) }
    }

    // Whether keyboard shortcuts are enabled
    @Published var shortcutsEnabled: Bool {
        didSet {
            defaults.set(shortcutsEnabled, forKey: Keys.shortcutsEnabled)
        }
    }

    // Whether to auto-detect and hide sensitive content (passwords, API keys, etc.)
    @Published var autoDetectSensitiveData: Bool {
        didSet {
            defaults.set(autoDetectSensitiveData, forKey: Keys.autoDetectSensitiveData)
            // Post notification when setting is turned ON to apply to existing items
            if autoDetectSensitiveData {
                NotificationCenter.default.post(name: .autoSensitiveSettingEnabled, object: nil)
            }
        }
    }

    // Whether to auto-hide password-like strings (high-entropy text)
    @Published var autoHidePasswordLikeStrings: Bool {
        didSet {
            defaults.set(autoHidePasswordLikeStrings, forKey: Keys.autoHidePasswordLikeStrings)
            // Post notification when setting is turned ON to apply to existing items
            if autoHidePasswordLikeStrings {
                NotificationCenter.default.post(name: .passwordLikeSettingEnabled, object: nil)
            }
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
        self.maxStorageSize = defaults.object(forKey: Keys.maxStorageSize) as? Int ?? Self.defaultStorageSize
        self.persistenceDays = defaults.object(forKey: Keys.persistenceDays) as? Int ?? Self.defaultPersistenceDays
        self.imagePersistenceDays = defaults.object(forKey: Keys.imagePersistenceDays) as? Int
            ?? Self.defaultImagePersistenceDays

        // Keyboard shortcuts - enabled by default
        self.shortcutsEnabled = defaults.object(forKey: Keys.shortcutsEnabled) as? Bool ?? true

        // Auto-detect sensitive data - disabled by default, let user decide
        self.autoDetectSensitiveData = defaults.object(forKey: Keys.autoDetectSensitiveData) as? Bool ?? false

        // Auto-hide password-like strings - disabled by default (can have false positives)
        self.autoHidePasswordLikeStrings = defaults.object(forKey: Keys.autoHidePasswordLikeStrings) as? Bool ?? false
    }
    
    func resetToDefaults() {
        maxClipboardItems = Self.defaultClipboardItems
        hotKeyEnabled = true
        showImagePreviews = true
        autoStartEnabled = true
        persistenceEnabled = true
        saveImages = true
        maxStorageSize = Self.defaultStorageSize
        persistenceDays = Self.defaultPersistenceDays
        imagePersistenceDays = Self.defaultImagePersistenceDays
        shortcutsEnabled = true
        autoDetectSensitiveData = false
        autoHidePasswordLikeStrings = false
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let autoSensitiveSettingEnabled = Notification.Name("autoSensitiveSettingEnabled")
    static let passwordLikeSettingEnabled = Notification.Name("passwordLikeSettingEnabled")
}