import Foundation
import ServiceManagement

class UserPreferencesManager: ObservableObject {
    static let shared = UserPreferencesManager()

    private let defaults: UserDefaults

    // Keys for UserDefaults
    private enum Keys {
        static let maxClipboardItems = "maxClipboardItems"
        static let hotKeyEnabled = "hotKeyEnabled"
        static let globalHotkeyKeyCode = "globalHotkeyKeyCode"
        static let globalHotkeyModifiers = "globalHotkeyModifiers"
        static let showImagePreviews = "showImagePreviews"
        static let appearance = "appearance"
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
        static let skipConcealedClips = "skipConcealedClips"
        static let excludedBundleIdentifiers = "excludedBundleIdentifiers"
        static let capturePaused = "capturePaused"
        static let clearHistoryOnQuit = "clearHistoryOnQuit"
        static let automaticUpdateChecksEnabled = "automaticUpdateChecksEnabled"
        static let lastUpdateCheckDate = "lastUpdateCheckDate"
        static let lastSeenLatestVersion = "lastSeenLatestVersion"
        static let skippedUpdateVersion = "skippedUpdateVersion"
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

    /// The combination that opens the popover from any app.
    ///
    /// Stored as its two Carbon halves rather than as a string, because the key code is what
    /// `RegisterEventHotKey` takes and the label is only ever derived for display. `MenuBarController`
    /// re-registers on every change, so a shortcut is live the moment it is recorded.
    @Published var globalHotkey: GlobalHotkeyShortcut {
        didSet {
            defaults.set(Int(globalHotkey.keyCode), forKey: Keys.globalHotkeyKeyCode)
            defaults.set(Int(globalHotkey.carbonModifiers), forKey: Keys.globalHotkeyModifiers)
        }
    }

    /// The stored shortcut, or nil when there is none or it is one this build would refuse to
    /// record. A combination that could not be typed in Settings should not arrive from disk
    /// either, whichever version of the app wrote it.
    private static func storedGlobalHotkey(in defaults: UserDefaults) -> GlobalHotkeyShortcut? {
        guard let keyCode = defaults.object(forKey: Keys.globalHotkeyKeyCode) as? Int,
              let modifiers = defaults.object(forKey: Keys.globalHotkeyModifiers) as? Int,
              keyCode >= 0, keyCode <= Int(UInt16.max), modifiers >= 0 else {
            return nil
        }

        let shortcut = GlobalHotkeyShortcut(keyCode: UInt32(keyCode), carbonModifiers: UInt32(modifiers))
        return shortcut.isValid ? shortcut : nil
    }

    // Whether to show image previews
    @Published var showImagePreviews: Bool {
        didSet {
            defaults.set(showImagePreviews, forKey: Keys.showImagePreviews)
        }
    }
    
    /// Whether the app follows the Mac's Light/Dark setting, or stays in one of them.
    ///
    /// Stored as the raw string rather than an index, so a case added or reordered later cannot
    /// silently turn someone's Dark into Light. Applying it is `AppDelegate`'s job, not this
    /// object's: preferences are read under a test host too, and an `NSApp.appearance` written from
    /// here would reach whichever app is hosting them.
    @Published var appearance: AppearancePreference {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
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

    /// Whether the saved history is cleared when the app quits.
    ///
    /// The answer to "keep history while I work, keep nothing afterwards". Independent of
    /// `persistenceEnabled` on purpose: switching saving off stops new writes but deletes nothing,
    /// so this still has work to do for anyone who declined the purge offered at that moment.
    /// Favorites are spared, like every other clear.
    @Published var clearHistoryOnQuit: Bool {
        didSet {
            defaults.set(clearHistoryOnQuit, forKey: Keys.clearHistoryOnQuit)
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

    /// Whether clips the source app marked confidential are dropped instead of recorded.
    ///
    /// This is a capture guard, not a display rule: `autoDetectSensitiveData` decides whether an
    /// item that *was* recorded is masked behind Cmd+V, while this decides whether it is recorded
    /// at all. Password managers set `org.nspasteboard.ConcealedType` to say "do not record this",
    /// so honouring it has no false positives, but it also means a clip you might have wanted in
    /// history is gone rather than hidden. Off by default for that reason; the Settings copy says
    /// what turning it on costs.
    @Published var skipConcealedClips: Bool {
        didSet {
            defaults.set(skipConcealedClips, forKey: Keys.skipConcealedClips)
        }
    }

    /// Bundle identifiers whose clips are never recorded.
    ///
    /// Stored as an array so the order shown in Settings stays stable, and matched through
    /// `excludedBundleIdentifierSet` because the lookup runs on every pasteboard change. Only the
    /// identifier is stored: it is what a capture is matched against, and an app the user has since
    /// uninstalled should still read as excluded rather than quietly dropping off the list.
    @Published var excludedBundleIdentifiers: [String] {
        didSet {
            defaults.set(excludedBundleIdentifiers, forKey: Keys.excludedBundleIdentifiers)
            excludedBundleIdentifierSet = Set(excludedBundleIdentifiers)
        }
    }

    /// Lookup form of `excludedBundleIdentifiers`, kept in step by its `didSet`.
    private(set) var excludedBundleIdentifierSet: Set<String> = []

    /// Whether the user has switched capture off for now.
    ///
    /// Written through `ClipboardMonitor.setCapturePaused`, which is the only thing that may
    /// change it: resuming has to resynchronise the pasteboard's change count before polling
    /// starts again, and a second writer would skip that step. Stored rather than kept in memory
    /// so a pause survives a relaunch, which is the point of it for anyone who pauses before a
    /// screen share and then reboots.
    @Published var capturePaused: Bool {
        didSet {
            defaults.set(capturePaused, forKey: Keys.capturePaused)
        }
    }

    /// Whether the app looks for a new release on its own, once a day.
    ///
    /// On by default, and switchable off, because this is the only thing MacClipboard does over the
    /// network without being asked. An app whose pitch is that your clipboard never leaves the
    /// machine does not get to make an unprompted request and not offer a way to stop it. Nothing
    /// about the clipboard is sent either way: the request is a GET of the latest release tag.
    /// Switching it off leaves the manual check in Settings and in the menu.
    @Published var automaticUpdateChecksEnabled: Bool {
        didSet {
            defaults.set(automaticUpdateChecksEnabled, forKey: Keys.automaticUpdateChecksEnabled)
        }
    }

    /// When a check last completed, used to decide whether the next one is due. Only a check that
    /// got an answer writes this; see `UpdateChecker.check`.
    var lastUpdateCheckDate: Date? {
        get { defaults.object(forKey: Keys.lastUpdateCheckDate) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastUpdateCheckDate) }
    }

    /// The newest release version the last check saw. Stored so the badge is right the moment the
    /// app launches, rather than only after the first check of the session comes back.
    var lastSeenLatestVersion: String? {
        get { defaults.string(forKey: Keys.lastSeenLatestVersion) }
        set { defaults.set(newValue, forKey: Keys.lastSeenLatestVersion) }
    }

    /// A version the user asked not to be told about again. Anything newer still surfaces.
    var skippedUpdateVersion: String? {
        get { defaults.string(forKey: Keys.skippedUpdateVersion) }
        set { defaults.set(newValue, forKey: Keys.skippedUpdateVersion) }
    }

    func addExcludedApp(_ bundleIdentifier: String) {
        guard !bundleIdentifier.isEmpty, !excludedBundleIdentifiers.contains(bundleIdentifier) else { return }
        excludedBundleIdentifiers.append(bundleIdentifier)
    }

    func removeExcludedApp(_ bundleIdentifier: String) {
        excludedBundleIdentifiers.removeAll { $0 == bundleIdentifier }
    }

    /// Reads and writes `defaults`, which is the standard domain for everything but a test.
    ///
    /// A test needs a domain of its own for two reasons: the settings here decide whether
    /// persistence runs at all, so a machine with it switched off would fail an unrelated test,
    /// and `imageStorageCompacted` is *written* during ordinary use, so a test sharing the
    /// standard domain would change what the developer's own copy does on its next launch.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Load saved preferences or set defaults
        let savedMaxItems = defaults.object(forKey: Keys.maxClipboardItems) as? Int ?? Self.defaultClipboardItems
        self.maxClipboardItems = max(Self.minClipboardItems, min(Self.maxClipboardItems, savedMaxItems))
        self.hotKeyEnabled = defaults.object(forKey: Keys.hotKeyEnabled) as? Bool ?? true
        self.globalHotkey = Self.storedGlobalHotkey(in: defaults) ?? .defaultForCurrentBuild
        self.showImagePreviews = defaults.object(forKey: Keys.showImagePreviews) as? Bool ?? true
        self.appearance = AppearancePreference.stored(defaults.string(forKey: Keys.appearance))
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

        // Dropping confidential clips - disabled by default, because it loses a clip rather than
        // hiding it. Turning it on is a deliberate choice made in Settings.
        self.skipConcealedClips = defaults.object(forKey: Keys.skipConcealedClips) as? Bool ?? false

        let savedExclusions = defaults.array(forKey: Keys.excludedBundleIdentifiers) as? [String] ?? []
        self.excludedBundleIdentifiers = savedExclusions
        self.excludedBundleIdentifierSet = Set(savedExclusions)

        // Capture runs unless the user switched it off, and a pause is remembered until they
        // switch it back on.
        self.capturePaused = defaults.object(forKey: Keys.capturePaused) as? Bool ?? false

        // History outlives a quit unless the user asked otherwise.
        self.clearHistoryOnQuit = defaults.object(forKey: Keys.clearHistoryOnQuit) as? Bool ?? false

        // Looking for a release once a day is on by default: an update nobody hears about is the
        // problem this solves. It is switchable off because it is the one unprompted network call.
        self.automaticUpdateChecksEnabled = defaults.object(forKey: Keys.automaticUpdateChecksEnabled) as? Bool ?? true
    }
    
    func resetToDefaults() {
        maxClipboardItems = Self.defaultClipboardItems
        hotKeyEnabled = true
        // Reset, unlike the three exemptions below, because a shortcut nobody can remember is
        // exactly what this button is for. The default is named on the button next to the
        // recorder as well, so this is the second way back to it rather than the only one.
        globalHotkey = .defaultForCurrentBuild
        showImagePreviews = true
        // Reset, because following the system is the safe direction and the change is visible the
        // moment it happens: unlike the three exemptions below, nothing is lost and nobody has to be
        // told what just changed.
        appearance = .default
        autoStartEnabled = true
        persistenceEnabled = true
        saveImages = true
        maxStorageSize = Self.defaultStorageSize
        persistenceDays = Self.defaultPersistenceDays
        imagePersistenceDays = Self.defaultImagePersistenceDays
        shortcutsEnabled = true
        autoDetectSensitiveData = false
        autoHidePasswordLikeStrings = false
        skipConcealedClips = false
        automaticUpdateChecksEnabled = true
        // Unlike the three exemptions below, forgetting a skipped version is safe to reset: all it
        // does is bring a banner back, in front of the user, with Skip still on it. The cached
        // `lastSeenLatestVersion` and `lastUpdateCheckDate` are left alone because they are a cache
        // of what the server said, not a preference, and clearing them would only cost a request.
        skippedUpdateVersion = nil
        // `excludedBundleIdentifiers` is deliberately left alone. Every other preference here is
        // recoverable by setting it again, but emptying this list starts recording clips from a
        // bank, a terminal or a customer's admin tool with nothing to show that it changed, and a
        // user who wanted the list gone can remove the entries in front of them.
        //
        // `capturePaused` is left alone for the same reason: someone who paused before a screen
        // share and then opened Settings would otherwise be recording again, and Reset is not
        // where anyone looks for that. Resuming is one click on the menu bar icon, which is
        // showing the paused clipboard the whole time.
        //
        // `clearHistoryOnQuit` is the third: turning it off here would leave a history the user
        // expected to be gone sitting on disk after the next quit, with nothing on screen saying
        // so. Every preference this method does reset is one whose default is the safe direction.
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let autoSensitiveSettingEnabled = Notification.Name("autoSensitiveSettingEnabled")
    static let passwordLikeSettingEnabled = Notification.Name("passwordLikeSettingEnabled")
}