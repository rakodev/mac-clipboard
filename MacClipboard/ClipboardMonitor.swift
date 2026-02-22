import Foundation
import AppKit

// MARK: - Sensitive Content Detection

struct SensitiveContentDetector {
    // Pasteboard types that indicate sensitive content (from password managers, etc.)
    private static let sensitivePasteboardTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType"
    ]

    // Maximum text size for pattern matching (100KB)
    private static let maxPatternMatchSize = 100 * 1024

    // Regex patterns for detecting sensitive content
    private static let sensitivePatterns: [(pattern: String, description: String)] = [
        // OpenAI/Stripe API keys
        ("sk-[a-zA-Z0-9]{20,}", "API key"),
        // AWS Access Key ID
        ("AKIA[0-9A-Z]{16}", "AWS Access Key"),
        // JWT tokens
        ("eyJ[A-Za-z0-9-_]+\\.[A-Za-z0-9-_]+\\.[A-Za-z0-9-_]*", "JWT token"),
        // Private keys
        ("-----BEGIN[A-Z ]*PRIVATE KEY-----", "Private key"),
        // GitHub tokens
        ("ghp_[A-Za-z0-9]{36,}", "GitHub PAT"),
        ("gho_[A-Za-z0-9]{36,}", "GitHub OAuth token"),
        ("ghs_[A-Za-z0-9]{36,}", "GitHub server token"),
        ("github_pat_[A-Za-z0-9_]{22,}", "GitHub fine-grained PAT"),
        // Generic secrets with assignment
        ("(?i)(password|passwd|secret|api_?key|auth_?token|access_?token)\\s*[=:]\\s*['\"]?[A-Za-z0-9+/=_-]{8,}['\"]?", "Generic secret"),
        // Database connection strings with credentials
        ("(?i)(mysql|postgres|postgresql|mongodb|redis)://[^:]+:[^@]+@", "Database connection string"),
        // Slack tokens
        ("xox[baprs]-[0-9A-Za-z-]+", "Slack token"),
        // Google API key
        ("AIza[0-9A-Za-z-_]{35}", "Google API key"),
        // Heroku API key
        ("[hH][eE][rR][oO][kK][uU].{0,30}[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}", "Heroku API key")
    ]

    /// Check if pasteboard contains sensitive type indicators
    static func hasSensitivePasteboardType(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        let typeStrings = Set(types.map { $0.rawValue })
        return !typeStrings.isDisjoint(with: sensitivePasteboardTypes)
    }

    /// Check if text content matches any sensitive patterns
    static func matchesSensitivePattern(_ text: String) -> Bool {
        // Skip pattern matching for very large text
        guard text.utf8.count <= maxPatternMatchSize else { return false }

        for (pattern, _) in sensitivePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil {
                Logging.debug("🔐 Detected sensitive pattern in clipboard content")
                return true
            }
        }
        return false
    }

    /// Comprehensive check for sensitive content
    static func isSensitive(pasteboard: NSPasteboard, text: String?) -> Bool {
        // Check pasteboard types first (instant)
        if hasSensitivePasteboardType(pasteboard) {
            Logging.debug("🔐 Detected sensitive pasteboard type")
            return true
        }

        // Check text patterns if text is available
        if let text = text, matchesSensitivePattern(text) {
            return true
        }

        return false
    }

    // Patterns that should NOT be considered passwords (common false positives)
    private static let nonPasswordPatterns: [(pattern: String, description: String)] = [
        // URLs
        ("^(https?|ftp|file|ssh|git)://", "URL"),
        // Email addresses (loose pattern - anything with @ and a dot after)
        ("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z0-9]{2,}", "Email"),
        // File paths (Unix and Windows)
        ("^[~/]|^[A-Za-z]:\\\\", "File path"),
        // UUIDs (standard format)
        ("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", "UUID"),
        // IPv4 addresses (with optional port)
        ("^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}(:\\d+)?$", "IPv4"),
        // IPv6 addresses
        ("^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$", "IPv6"),
        // MAC addresses
        ("^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$", "MAC address"),
        // ISO 8601 dates and timestamps
        ("^\\d{4}-\\d{2}-\\d{2}(T\\d{2}:\\d{2}:\\d{2})?", "ISO date"),
        // Semantic versions
        ("^v?\\d+\\.\\d+\\.\\d+(-[A-Za-z0-9.]+)?(\\+[A-Za-z0-9.]+)?$", "Version"),
        // Domain names (with subdomains)
        ("^([A-Za-z0-9-]+\\.)+[A-Za-z]{2,}$", "Domain"),
        // Phone numbers (various formats)
        ("^\\+?[0-9]{1,4}[-. ]?\\(?[0-9]{1,4}\\)?[-. ]?[0-9]{1,4}[-. ]?[0-9]{1,9}$", "Phone number"),
    ]

    /// Check if text matches any non-password pattern (URLs, emails, etc.)
    private static func matchesNonPasswordPattern(_ text: String) -> Bool {
        for (pattern, _) in nonPasswordPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil {
                return true
            }
        }
        return false
    }

    /// Check if text looks like a password (high entropy string)
    /// Criteria: 8-64 chars, no spaces, contains all of: uppercase, lowercase, digit, special char
    static func looksLikePassword(_ text: String) -> Bool {
        // Length check
        guard text.count >= 8 && text.count <= 64 else { return false }

        // No spaces allowed
        guard !text.contains(" ") else { return false }

        // No newlines (multi-line text is not a password)
        guard !text.contains(where: { $0.isNewline }) else { return false }

        // Exclude common non-password patterns (URLs, emails, file paths, etc.)
        if matchesNonPasswordPattern(text) {
            return false
        }

        // Count character types present
        var hasUppercase = false
        var hasLowercase = false
        var hasDigit = false
        var hasSpecial = false

        for char in text {
            if char.isUppercase { hasUppercase = true }
            else if char.isLowercase { hasLowercase = true }
            else if char.isNumber { hasDigit = true }
            else if !char.isLetter && !char.isNumber { hasSpecial = true }
        }

        let typeCount = [hasUppercase, hasLowercase, hasDigit, hasSpecial].filter { $0 }.count

        if typeCount >= 4 {
            Logging.debug("🔑 Detected password-like string")
            return true
        }

        return false
    }
}

class ClipboardMonitor: ObservableObject {
    @Published var clipboardHistory: [ClipboardItem] = []
    private var changeCount: Int = 0
    private var timer: Timer?
    private var isPausing = false
    private var userPreferences: UserPreferencesManager
    private var persistenceManager: PersistenceManager
    private var maintenanceTimer: Timer?
    private var pendingChangeCount: Int?
    private var pendingCaptureAttempts: Int = 0
    private var pendingCaptureRetryScheduled = false
    private let maxPendingCaptureAttempts = 20
    private let pendingCaptureRetryDelay: TimeInterval = 0.25
    
    init(userPreferences: UserPreferencesManager = UserPreferencesManager.shared,
         persistenceManager: PersistenceManager = PersistenceManager.shared) {
        self.userPreferences = userPreferences
        self.persistenceManager = persistenceManager
        
        // Load persisted history first
        self.loadPersistedHistory()
        
        startMonitoring()
        startMaintenanceTimer()
        
        // Listen for preferences changes to trim history if needed
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )

        // Listen for auto-sensitive setting being enabled
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(autoSensitiveSettingEnabled),
            name: .autoSensitiveSettingEnabled,
            object: nil
        )

        // Listen for password-like setting being enabled
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(passwordLikeSettingEnabled),
            name: .passwordLikeSettingEnabled,
            object: nil
        )
    }
    
    deinit {
        stopMonitoring()
        stopMaintenanceTimer()
        NotificationCenter.default.removeObserver(self)
    }
    
    private func startMonitoring() {
        // Check clipboard every 0.8 seconds (balanced between responsiveness and CPU usage)
        let monitoringTimer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
        RunLoop.main.add(monitoringTimer, forMode: .common)
        timer = monitoringTimer
        
        // Initial check
        checkClipboard()
    }
    
    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
    
    
    private func startMaintenanceTimer() {
        // Run maintenance every hour
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.performMaintenance()
        }
    }
    
    private func stopMaintenanceTimer() {
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
    }
    
    private func loadPersistedHistory() {
        guard userPreferences.persistenceEnabled else { return }
        
        let persistedItems = persistenceManager.loadClipboardHistory(limit: userPreferences.maxClipboardItems)
        
        DispatchQueue.main.async {
            self.clipboardHistory = persistedItems
        }
    }
    
    private func saveItemToPersistence(_ item: ClipboardItem) {
        guard userPreferences.persistenceEnabled else { return }
        
        DispatchQueue.global(qos: .utility).async {
            self.persistenceManager.saveClipboardItem(item, saveImages: self.userPreferences.saveImages)
        }
    }
    
    private func performMaintenance() {
        guard userPreferences.persistenceEnabled else { return }
        
        DispatchQueue.global(qos: .utility).async {
            // Clean up old items
            self.persistenceManager.cleanupOldItems(olderThan: self.userPreferences.persistenceDays)
            
            // Check storage size and clean up if needed
            let currentSize = self.persistenceManager.getStorageSize()
            let maxSizeBytes = Int64(self.userPreferences.maxStorageSize) * 1024 * 1024 // Convert MB to bytes
            
            if currentSize > maxSizeBytes {
                // In a more sophisticated implementation, we could selectively remove larger items first
                self.persistenceManager.cleanupOldItems(olderThan: max(1, self.userPreferences.persistenceDays / 2))
            }
        }
    }
    
    private func checkClipboard() {
        // Skip monitoring if we're currently pasting
        guard !isPausing else { return }

        let pasteboard = NSPasteboard.general
        
        // Check if clipboard content changed
        if pasteboard.changeCount != changeCount {
            changeCount = pasteboard.changeCount
            pendingChangeCount = nil
            pendingCaptureAttempts = 0
            
            // Get clipboard content
            if let content = getClipboardContent() {
                addToHistory(content)
            } else {
                pendingChangeCount = changeCount
                schedulePendingCaptureRetry()
            }
        }
    }

    private func schedulePendingCaptureRetry() {
        guard !pendingCaptureRetryScheduled else { return }
        guard let pending = pendingChangeCount, pending == changeCount else { return }
        guard pendingCaptureAttempts < maxPendingCaptureAttempts else {
            Logging.debug("ℹ️ Gave up deferred clipboard capture for changeCount \(changeCount)")
            pendingChangeCount = nil
            return
        }

        pendingCaptureRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + pendingCaptureRetryDelay) { [weak self] in
            guard let self = self else { return }
            self.pendingCaptureRetryScheduled = false
            self.attemptPendingCapture(expectedChangeCount: pending)
        }
    }

    private func attemptPendingCapture(expectedChangeCount: Int) {
        guard !isPausing else {
            schedulePendingCaptureRetry()
            return
        }

        let pasteboard = NSPasteboard.general
        // Clipboard changed again; pending capture is obsolete.
        guard pasteboard.changeCount == expectedChangeCount, expectedChangeCount == changeCount else {
            pendingChangeCount = nil
            pendingCaptureAttempts = 0
            return
        }

        pendingCaptureAttempts += 1

        if let content = getClipboardContent() {
            addToHistory(content)
            pendingChangeCount = nil
            pendingCaptureAttempts = 0
            return
        }

        schedulePendingCaptureRetry()
    }

    func refreshClipboardNow() {
        checkClipboard()
    }

    private struct PasteboardImagePayload {
        let image: NSImage
        let byteCount: Int
        let sourceType: String
    }

    private let supportedImageTypes: [NSPasteboard.PasteboardType] = [
        .png,
        .tiff,
        .pdf,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.heic"),
        NSPasteboard.PasteboardType("public.heif"),
        NSPasteboard.PasteboardType("com.compuserve.gif")
    ]

    private func decodeImagePayload(from item: NSPasteboardItem) -> PasteboardImagePayload? {
        for type in supportedImageTypes {
            if let data = item.data(forType: type), let image = NSImage(data: data) {
                return PasteboardImagePayload(image: image, byteCount: data.count, sourceType: "item:\(type.rawValue)")
            }
        }
        return nil
    }

    private func estimatedPixelCount(for image: NSImage) -> Int {
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            return rep.pixelsWide * rep.pixelsHigh
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let widthPixels = Int(image.size.width * scale)
        let heightPixels = Int(image.size.height * scale)
        return max(0, widthPixels * heightPixels)
    }

    private func shouldSkipImageForSize(image: NSImage, payload: PasteboardImagePayload?) -> Bool {
        let maxImageBytes = 10 * 1024 * 1024
        let maxFallbackPixels = 40_000_000
        let imageBytes = payload?.byteCount ?? (image.tiffRepresentation?.count ?? 0)
        let sourceType = payload?.sourceType ?? "unknown"
        let isDirectEncodedPayload = sourceType.hasPrefix("public.") || sourceType.hasPrefix("item:") || sourceType == "com.compuserve.gif"

        if isDirectEncodedPayload {
            if imageBytes > maxImageBytes {
                Logging.debug("⚠️ Skipped large encoded image (\(imageBytes / 1024 / 1024)MB, source: \(sourceType)) - exceeds 10MB limit")
                return true
            }
            return false
        }

        let pixelCount = estimatedPixelCount(for: image)
        if pixelCount > maxFallbackPixels {
            Logging.debug("⚠️ Skipped very large fallback image (\(pixelCount) pixels, source: \(sourceType))")
            return true
        }

        return false
    }

    private func readImageFromPasteboard(_ pasteboard: NSPasteboard) -> PasteboardImagePayload? {
        for type in supportedImageTypes {
            if let data = pasteboard.data(forType: type), let image = NSImage(data: data) {
                return PasteboardImagePayload(image: image, byteCount: data.count, sourceType: type.rawValue)
            }
        }

        if let items = pasteboard.pasteboardItems {
            for item in items {
                if let payload = decodeImagePayload(from: item) {
                    return payload
                }
            }
        }

        if let image = NSImage(pasteboard: pasteboard) {
            let fallbackSize = image.tiffRepresentation?.count ?? 0
            return PasteboardImagePayload(image: image, byteCount: fallbackSize, sourceType: "NSImage(pasteboard:)")
        }

        if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
            let fallbackSize = image.tiffRepresentation?.count ?? 0
            return PasteboardImagePayload(image: image, byteCount: fallbackSize, sourceType: "NSImage-object")
        }

        return nil
    }
    
    private func getClipboardContent() -> ClipboardItem? {
        let pasteboard = NSPasteboard.general

        // Check pasteboard types for sensitive indicators first (instant check)
        let hasSensitivePasteboardType = SensitiveContentDetector.hasSensitivePasteboardType(pasteboard)

        let textContent = pasteboard.string(forType: .string)
        let hasText = (textContent?.isEmpty == false)
        let imagePayload = readImageFromPasteboard(pasteboard)
        let imageContent = imagePayload?.image
        let hasImage = imageContent != nil

        // Prefer image item when both text and image are present, preserving text as secondary payload
        if hasImage, let image = imageContent {
            if shouldSkipImageForSize(image: image, payload: imagePayload) {
                // Fallback to text representation if available
                if hasText, let string = textContent {
                    let maxTextBytes = 1 * 1024 * 1024
                    if string.utf8.count <= maxTextBytes {
                        let isAutoSensitive = hasSensitivePasteboardType || SensitiveContentDetector.matchesSensitivePattern(string)
                        let isPasswordLike = SensitiveContentDetector.looksLikePassword(string)
                        let isSensitive = (isAutoSensitive && userPreferences.autoDetectSensitiveData) ||
                                          (isPasswordLike && userPreferences.autoHidePasswordLikeStrings)

                        return ClipboardItem(
                            id: UUID(),
                            content: string,
                            type: .text,
                            timestamp: Date(),
                            isSensitive: isSensitive,
                            isAutoSensitive: isAutoSensitive,
                            isPasswordLike: isPasswordLike
                        )
                    }
                }
                return nil
            }

            let attachedText = hasText ? textContent : nil
            let isAutoSensitive = hasSensitivePasteboardType || (attachedText.map { SensitiveContentDetector.matchesSensitivePattern($0) } ?? false)
            let isPasswordLike = attachedText.map { SensitiveContentDetector.looksLikePassword($0) } ?? false
            let isSensitive = (isAutoSensitive && userPreferences.autoDetectSensitiveData) ||
                              (isPasswordLike && userPreferences.autoHidePasswordLikeStrings)

            return ClipboardItem(
                id: UUID(),
                content: image,
                type: .image,
                timestamp: Date(),
                isSensitive: isSensitive,
                isAutoSensitive: isAutoSensitive,
                isPasswordLike: isPasswordLike,
                associatedText: attachedText
            )
        }

        // Check for text content first
        if let string = textContent, !string.isEmpty {
            // Skip extremely large text to prevent memory issues (max 1MB)
            let maxTextBytes = 1 * 1024 * 1024
            if string.utf8.count > maxTextBytes {
                Logging.debug("⚠️ Skipped large text (\(string.utf8.count / 1024)KB) - exceeds 1MB limit")
                return nil
            }

            // Check for sensitive content (API keys, tokens, etc.)
            let isAutoSensitive = hasSensitivePasteboardType || SensitiveContentDetector.matchesSensitivePattern(string)

            // Check for password-like strings
            let isPasswordLike = SensitiveContentDetector.looksLikePassword(string)

            // Determine if should be hidden based on user preferences
            let isSensitive = (isAutoSensitive && userPreferences.autoDetectSensitiveData) ||
                              (isPasswordLike && userPreferences.autoHidePasswordLikeStrings)

            return ClipboardItem(
                id: UUID(),
                content: string,
                type: .text,
                timestamp: Date(),
                isSensitive: isSensitive,
                isAutoSensitive: isAutoSensitive,
                isPasswordLike: isPasswordLike
            )
        }

        // Check for file URLs
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            let fileNames = urls.map { $0.lastPathComponent }.joined(separator: ", ")

            // Files can also be sensitive based on pasteboard type
            let isAutoSensitive = hasSensitivePasteboardType
            let isSensitive = isAutoSensitive && userPreferences.autoDetectSensitiveData

            return ClipboardItem(
                id: UUID(),
                content: urls,
                type: .file,
                timestamp: Date(),
                displayText: fileNames,
                isSensitive: isSensitive,
                isAutoSensitive: isAutoSensitive
            )
        }

        return nil
    }
    
    private func addToHistory(_ item: ClipboardItem) {
        DispatchQueue.main.async {
            // Check for existing duplicate and preserve its metadata (favorite, sensitive, note)
            // For performance: limit duplicate checking for large content
            // - Images: only check last 10 items (TIFF comparison is expensive)
            // - Large text (≥10KB): only check last 10 items
            // - Small text/files: check all items (fast enough)
            var itemToInsert = item
            let isLargeContent = item.type == .image ||
                (item.type == .text && ((item.content as? String)?.count ?? 0) >= 10_000)
            let itemsToCheck = isLargeContent
                ? Array(self.clipboardHistory.prefix(10))
                : self.clipboardHistory

            if let matchIndex = itemsToCheck.firstIndex(where: { $0.contentEquals(item) }),
               let actualIndex = self.clipboardHistory.firstIndex(where: { $0.id == itemsToCheck[matchIndex].id }) {
                // If duplicate is already at the top, do nothing (common case: user copies same thing multiple times to be sure)
                if actualIndex == 0 {
                    return
                }

                let existingItem = self.clipboardHistory[actualIndex]
                // Preserve favorite status, sensitive flag, auto-sensitive flag, password-like flag, manual unsensitive, and note from existing item
                itemToInsert.isFavorite = existingItem.isFavorite
                itemToInsert.isSensitive = existingItem.isSensitive
                itemToInsert.isAutoSensitive = existingItem.isAutoSensitive || itemToInsert.isAutoSensitive
                itemToInsert.isPasswordLike = existingItem.isPasswordLike || itemToInsert.isPasswordLike
                itemToInsert.isManuallyUnsensitive = existingItem.isManuallyUnsensitive
                itemToInsert.note = existingItem.note
                itemToInsert.associatedText = itemToInsert.associatedText ?? existingItem.associatedText

                // Remove the old item from persistence
                self.persistenceManager.deleteItems(withIds: [existingItem.id])

                // Remove from history
                self.clipboardHistory.remove(at: actualIndex)
            }

            // Add to beginning of array
            self.clipboardHistory.insert(itemToInsert, at: 0)

            // Save to persistence
            self.saveItemToPersistence(itemToInsert)

            // Limit to max items
            self.trimHistoryToLimitPreservingFavorites()

            // Unload old images from memory to prevent memory bloat
            self.unloadOldImages()
        }
    }

    /// Maximum number of images to keep loaded in memory
    private static let maxLoadedImages = 15

    /// Unload images beyond the first N to free memory
    private func unloadOldImages() {
        var loadedImageCount = 0

        for i in 0..<clipboardHistory.count {
            if clipboardHistory[i].type == .image && clipboardHistory[i].isImageLoaded {
                loadedImageCount += 1

                // Unload images beyond the limit
                if loadedImageCount > Self.maxLoadedImages {
                    clipboardHistory[i].content = NSNull()
                    clipboardHistory[i].isImageLoaded = false
                }
            }
        }
    }
    
    @objc private func preferencesChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Trim history if new limit is smaller than current count
            self.trimHistoryToLimitPreservingFavorites()
        }
    }

    private func trimHistoryToLimitPreservingFavorites() {
        let currentLimit = userPreferences.maxClipboardItems
        guard clipboardHistory.count > currentLimit else { return }

        var overflow = clipboardHistory.count - currentLimit
        var index = clipboardHistory.count - 1

        // Remove oldest non-favorites first
        while overflow > 0 && index >= 0 {
            if !clipboardHistory[index].isFavorite {
                clipboardHistory.remove(at: index)
                overflow -= 1
            }
            index -= 1
        }

        // If we still overflow, all remaining tail items are favorites.
        // Keep favorites rather than silently evicting them.
        if overflow > 0 {
            Logging.debug("⭐ Keeping \(overflow) favorites above max item limit (\(currentLimit))")
        }
    }

    @objc private func autoSensitiveSettingEnabled() {
        // When auto-detect setting is turned ON, apply isSensitive to all isAutoSensitive items
        // Skip items the user explicitly un-marked (isManuallyUnsensitive)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            var updatedIds: [UUID] = []
            for i in 0..<self.clipboardHistory.count {
                if self.clipboardHistory[i].isAutoSensitive && !self.clipboardHistory[i].isSensitive && !self.clipboardHistory[i].isManuallyUnsensitive {
                    self.clipboardHistory[i].isSensitive = true
                    updatedIds.append(self.clipboardHistory[i].id)
                }
            }

            // Update persistence
            if !updatedIds.isEmpty {
                DispatchQueue.global(qos: .utility).async {
                    self.persistenceManager.applyAutoSensitiveFlag()
                }
                Logging.debug("🔐 Applied sensitive flag to \(updatedIds.count) auto-detected items")
            }
        }
    }

    @objc private func passwordLikeSettingEnabled() {
        // When password-like setting is turned ON, apply isSensitive to all isPasswordLike items
        // Skip items the user explicitly un-marked (isManuallyUnsensitive)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            var updatedIds: [UUID] = []
            for i in 0..<self.clipboardHistory.count {
                if self.clipboardHistory[i].isPasswordLike && !self.clipboardHistory[i].isSensitive && !self.clipboardHistory[i].isManuallyUnsensitive {
                    self.clipboardHistory[i].isSensitive = true
                    updatedIds.append(self.clipboardHistory[i].id)
                }
            }

            // Update persistence
            if !updatedIds.isEmpty {
                DispatchQueue.global(qos: .utility).async {
                    self.persistenceManager.applyPasswordLikeFlag()
                }
                Logging.debug("🔑 Applied sensitive flag to \(updatedIds.count) password-like items")
            }
        }
    }
    
    func copyToClipboard(_ item: ClipboardItem) {
        // Pause monitoring to prevent duplicate entries
        isPausing = true

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.type {
        case .text:
            if let text = item.content as? String {
                pasteboard.setString(text, forType: .string)
            }
        case .image:
            // Handle lazy-loaded images
            if let image = item.content as? NSImage {
                pasteboard.writeObjects([image])
                if let associatedText = item.associatedText, !associatedText.isEmpty {
                    pasteboard.setString(associatedText, forType: .string)
                }
            } else if item.needsImageLoad {
                // Load image synchronously for copy operation
                if let image = persistenceManager.loadImageData(for: item.id) {
                    pasteboard.writeObjects([image])
                    if let associatedText = item.associatedText, !associatedText.isEmpty {
                        pasteboard.setString(associatedText, forType: .string)
                    }
                    // Also update the item in history
                    if let index = clipboardHistory.firstIndex(where: { $0.id == item.id }) {
                        clipboardHistory[index].content = image
                        clipboardHistory[index].isImageLoaded = true
                    }
                }
            }
        case .file:
            if let urls = item.content as? [URL] {
                pasteboard.writeObjects(urls as [NSURL])
            }
        }
        
        // Update change count to match current state
        changeCount = pasteboard.changeCount
        
        // Move item to top of history
        DispatchQueue.main.async {
            if let index = self.clipboardHistory.firstIndex(where: { $0.id == item.id }) {
                let movedItem = self.clipboardHistory.remove(at: index)
                self.clipboardHistory.insert(movedItem, at: 0)
            }
        }
        
        // Resume monitoring after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.isPausing = false
        }
    }
    
    func clearHistory() {
        DispatchQueue.main.async {
            self.clipboardHistory.removeAll()
        }

        // Also clear persistent storage permanently
        DispatchQueue.global(qos: .utility).async {
            self.persistenceManager.clearAllData()
        }
    }

    func toggleFavorite(_ item: ClipboardItem) {
        DispatchQueue.main.async {
            if let index = self.clipboardHistory.firstIndex(where: { $0.id == item.id }) {
                self.clipboardHistory[index].isFavorite.toggle()

                // Update persistence
                let itemId = item.id
                DispatchQueue.global(qos: .utility).async {
                    _ = self.persistenceManager.toggleFavorite(itemId: itemId)
                }
            }
        }
    }

    func updateNote(_ item: ClipboardItem, note: String?) {
        DispatchQueue.main.async {
            if let index = self.clipboardHistory.firstIndex(where: { $0.id == item.id }) {
                self.clipboardHistory[index].note = note

                // Update persistence
                let itemId = item.id
                DispatchQueue.global(qos: .utility).async {
                    self.persistenceManager.updateNote(itemId: itemId, note: note)
                }
            }
        }
    }

    func toggleSensitive(_ item: ClipboardItem) {
        DispatchQueue.main.async {
            if let index = self.clipboardHistory.firstIndex(where: { $0.id == item.id }) {
                let wasAutoDetected = self.clipboardHistory[index].isAutoSensitive || self.clipboardHistory[index].isPasswordLike
                let willBeUnsensitive = self.clipboardHistory[index].isSensitive // currently sensitive → toggling OFF
                self.clipboardHistory[index].isSensitive.toggle()

                // Mark as manually unsensitive when user un-hides an auto-detected item
                // Clear the flag when user re-hides it
                if wasAutoDetected {
                    self.clipboardHistory[index].isManuallyUnsensitive = willBeUnsensitive
                }

                // Update persistence
                let itemId = item.id
                let manuallyUnsensitive = self.clipboardHistory[index].isManuallyUnsensitive
                DispatchQueue.global(qos: .utility).async {
                    _ = self.persistenceManager.toggleSensitive(itemId: itemId, isManuallyUnsensitive: manuallyUnsensitive)
                }
            }
        }
    }

    func deleteItems(withIds ids: Set<UUID>) {
        DispatchQueue.main.async {
            self.clipboardHistory.removeAll { ids.contains($0.id) }
        }

        // Also delete from persistent storage
        DispatchQueue.global(qos: .utility).async {
            self.persistenceManager.deleteItems(withIds: ids)
        }
    }

    /// Load image data for a lazy-loaded item (call when user selects the item)
    func loadImageIfNeeded(_ item: ClipboardItem, completion: @escaping (NSImage?) -> Void) {
        guard item.needsImageLoad else {
            // Already loaded
            completion(item.content as? NSImage)
            return
        }

        // Load from disk on background thread
        DispatchQueue.global(qos: .userInitiated).async {
            let image = self.persistenceManager.loadImageData(for: item.id)

            DispatchQueue.main.async {
                // Update the item in history with loaded image
                if let image = image,
                   let index = self.clipboardHistory.firstIndex(where: { $0.id == item.id }) {
                    self.clipboardHistory[index].content = image
                    self.clipboardHistory[index].isImageLoaded = true
                }
                completion(image)
            }
        }
    }
}

struct ClipboardItem: Identifiable, Equatable {
    let id: UUID
    var content: Any  // Can be nil for lazy-loaded images
    let type: ClipboardContentType
    let timestamp: Date
    let displayText: String?
    var isFavorite: Bool
    var isSensitive: Bool
    var isAutoSensitive: Bool  // True if auto-detected as sensitive (API keys, tokens, etc.)
    var isPasswordLike: Bool   // True if detected as password-like string
    var isManuallyUnsensitive: Bool  // True if user explicitly un-marked as sensitive (prevents re-apply)
    var note: String?
    var associatedText: String?  // Optional text representation when clipboard item is image + text
    var isImageLoaded: Bool  // For lazy loading: false means image needs to be loaded from disk

    init(id: UUID, content: Any, type: ClipboardContentType, timestamp: Date, displayText: String? = nil, isFavorite: Bool = false, isSensitive: Bool = false, isAutoSensitive: Bool = false, isPasswordLike: Bool = false, isManuallyUnsensitive: Bool = false, note: String? = nil, associatedText: String? = nil, isImageLoaded: Bool = true) {
        self.id = id
        self.content = content
        self.type = type
        self.timestamp = timestamp
        self.displayText = displayText
        self.isFavorite = isFavorite
        self.isSensitive = isSensitive
        self.isAutoSensitive = isAutoSensitive
        self.isPasswordLike = isPasswordLike
        self.isManuallyUnsensitive = isManuallyUnsensitive
        self.note = note
        self.associatedText = associatedText
        self.isImageLoaded = (type != .image) || isImageLoaded  // Non-images are always "loaded"
    }

    /// Returns true if this is an image that needs to be loaded from disk
    var needsImageLoad: Bool {
        return type == .image && !isImageLoaded
    }
    
    var previewText: String {
        if let displayText = displayText {
            return displayText
        }
        
        switch type {
        case .text:
            if let text = content as? String {
                // Limit preview to first line and 100 characters
                let firstLine = text.components(separatedBy: .newlines).first ?? ""
                let preview = String(firstLine.prefix(100))
                return preview
            }
        case .image:
            return "📷 Image"
        case .file:
            if let urls = content as? [URL] {
                let preview = "📁 \(urls.count) file(s)"
                return preview
            }
        }
        return "Unknown content"
    }
    
    var fullText: String {
        switch type {
        case .text:
            return content as? String ?? ""
        case .image:
            return associatedText?.isEmpty == false ? associatedText! : "📷 Image content"
        case .file:
            if let urls = content as? [URL] {
                return urls.map { $0.path }.joined(separator: "\n")
            }
        }
        return ""
    }
    
    func contentEquals(_ other: ClipboardItem) -> Bool {
        guard self.type == other.type else { return false }
        
        switch type {
        case .text:
            guard let text1 = content as? String,
                  let text2 = other.content as? String else { return false }
            // Quick rejection: different lengths = different content
            if text1.count != text2.count { return false }
            return text1 == text2
        case .image:
            // For images, use dimension comparison first, then exact data match.
            // A sampled-prefix/suffix comparison caused false duplicates for similar screenshots.
            guard let image1 = content as? NSImage,
                  let image2 = other.content as? NSImage else { return false }

            // Quick rejection: different dimensions = different images
            if image1.size != image2.size {
                return false
            }

            // For same dimensions, compare full normalized TIFF data to avoid false positives.
            guard let data1 = image1.tiffRepresentation,
                  let data2 = image2.tiffRepresentation else { return false }
            return data1 == data2 && self.associatedText == other.associatedText
        case .file:
            let urls1 = content as? [URL] ?? []
            let urls2 = other.content as? [URL] ?? []
            return urls1 == urls2
        }
    }
    
    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        return lhs.id == rhs.id &&
               lhs.isSensitive == rhs.isSensitive &&
               lhs.isFavorite == rhs.isFavorite &&
               lhs.isAutoSensitive == rhs.isAutoSensitive &&
               lhs.isPasswordLike == rhs.isPasswordLike &&
               lhs.isManuallyUnsensitive == rhs.isManuallyUnsensitive &&
               lhs.note == rhs.note &&
               lhs.associatedText == rhs.associatedText &&
               lhs.isImageLoaded == rhs.isImageLoaded
    }
}

enum ClipboardContentType: Int {
    case text = 0
    case image = 1
    case file = 2
}