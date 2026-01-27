import Foundation
import AppKit

class ClipboardMonitor: ObservableObject {
    @Published var clipboardHistory: [ClipboardItem] = []
    private var changeCount: Int = 0
    private var timer: Timer?
    private var isPausing = false
    private var userPreferences: UserPreferencesManager
    private var persistenceManager: PersistenceManager
    private var maintenanceTimer: Timer?
    
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
    }
    
    deinit {
        stopMonitoring()
        stopMaintenanceTimer()
        NotificationCenter.default.removeObserver(self)
    }
    
    private func startMonitoring() {
        // Check clipboard every 0.5 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
        
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
            
            // Get clipboard content
            if let content = getClipboardContent() {
                addToHistory(content)
            }
        }
    }
    
    private func getClipboardContent() -> ClipboardItem? {
        let pasteboard = NSPasteboard.general
        
        // Check for text content first
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            return ClipboardItem(
                id: UUID(),
                content: string,
                type: .text,
                timestamp: Date()
            )
        }
        
        // Check for image content
        if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
            return ClipboardItem(
                id: UUID(),
                content: image,
                type: .image,
                timestamp: Date()
            )
        }
        
        // Check for file URLs
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            let fileNames = urls.map { $0.lastPathComponent }.joined(separator: ", ")
            return ClipboardItem(
                id: UUID(),
                content: urls,
                type: .file,
                timestamp: Date(),
                displayText: fileNames
            )
        }
        
        return nil
    }
    
    private func addToHistory(_ item: ClipboardItem) {
        DispatchQueue.main.async {
            // Check for existing duplicate and preserve its metadata (favorite, sensitive, note)
            var itemToInsert = item
            if let existingIndex = self.clipboardHistory.firstIndex(where: { $0.contentEquals(item) }) {
                let existingItem = self.clipboardHistory[existingIndex]
                // Preserve favorite status, sensitive flag, and note from existing item
                itemToInsert.isFavorite = existingItem.isFavorite
                itemToInsert.isSensitive = existingItem.isSensitive
                itemToInsert.note = existingItem.note

                // Remove the old item from persistence
                self.persistenceManager.deleteItems(withIds: [existingItem.id])

                // Remove from history
                self.clipboardHistory.remove(at: existingIndex)
            }

            // Add to beginning of array
            self.clipboardHistory.insert(itemToInsert, at: 0)

            // Save to persistence
            self.saveItemToPersistence(itemToInsert)

            // Limit to max items
            if self.clipboardHistory.count > self.userPreferences.maxClipboardItems {
                self.clipboardHistory.removeLast(self.clipboardHistory.count - self.userPreferences.maxClipboardItems)
            }
        }
    }
    
    @objc private func preferencesChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Trim history if new limit is smaller than current count
            let currentLimit = self.userPreferences.maxClipboardItems
            if self.clipboardHistory.count > currentLimit {
                let itemsToRemove = self.clipboardHistory.count - currentLimit
                self.clipboardHistory.removeLast(itemsToRemove)
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
            if let image = item.content as? NSImage {
                pasteboard.writeObjects([image])
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
                self.clipboardHistory[index].isSensitive.toggle()

                // Update persistence
                let itemId = item.id
                DispatchQueue.global(qos: .utility).async {
                    _ = self.persistenceManager.toggleSensitive(itemId: itemId)
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
}

struct ClipboardItem: Identifiable, Equatable {
    let id: UUID
    let content: Any
    let type: ClipboardContentType
    let timestamp: Date
    let displayText: String?
    var isFavorite: Bool
    var isSensitive: Bool
    var note: String?

    init(id: UUID, content: Any, type: ClipboardContentType, timestamp: Date, displayText: String? = nil, isFavorite: Bool = false, isSensitive: Bool = false, note: String? = nil) {
        self.id = id
        self.content = content
        self.type = type
        self.timestamp = timestamp
        self.displayText = displayText
        self.isFavorite = isFavorite
        self.isSensitive = isSensitive
        self.note = note
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
            return "📷 Image content"
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
            return (content as? String) == (other.content as? String)
        case .image:
            // For images, compare their data representations
        guard let image1 = content as? NSImage,
            let image2 = other.content as? NSImage else { return false }

        let data1 = image1.tiffRepresentation
        let data2 = image2.tiffRepresentation
        return data1 == data2
        case .file:
            let urls1 = content as? [URL] ?? []
            let urls2 = other.content as? [URL] ?? []
            return urls1 == urls2
        }
    }
    
    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        return lhs.id == rhs.id
    }
}

enum ClipboardContentType: Int {
    case text = 0
    case image = 1
    case file = 2
}