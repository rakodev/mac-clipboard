import Foundation
import AppKit

class ClipboardMonitor: ObservableObject {
    @Published var clipboardHistory: [ClipboardItem] = []
    private var changeCount: Int = 0
    private var timer: Timer?
    private var isPausing = false
    private var userPreferences: UserPreferencesManager
    
    private var maxItems: Int {
        return userPreferences.maxClipboardItems
    }
    
    init(userPreferences: UserPreferencesManager = UserPreferencesManager.shared) {
        self.userPreferences = userPreferences
        startMonitoring()
        
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
            // Use a concrete, non-optional string for logging to avoid optional interpolation warnings
            let display = item.displayText ?? item.previewText
            Logging.debug("🔍 Adding to history: \(display) (Type: \(item.type))")
            Logging.debug("📊 Current history count: \(self.clipboardHistory.count)")
            
            // Remove duplicates (same content)
            let duplicatesFound = self.clipboardHistory.filter { existing in
                let isEqual = existing.contentEquals(item)
                if isEqual {
                    let existingDisplay = existing.displayText ?? existing.previewText
                    Logging.debug("🔍 Found duplicate: \(existingDisplay) == \(display)")
                }
                return isEqual
            }
            
            Logging.debug("🗑️ Removing \(duplicatesFound.count) duplicates")
            self.clipboardHistory.removeAll { existing in
                existing.contentEquals(item)
            }
            
            // Add to beginning of array
            self.clipboardHistory.insert(item, at: 0)
            Logging.debug("✅ Added item. New history count: \(self.clipboardHistory.count)")
            
            // Limit to max items
            if self.clipboardHistory.count > self.maxItems {
                self.clipboardHistory.removeLast(self.clipboardHistory.count - self.maxItems)
                Logging.debug("✂️ Trimmed to max items: \(self.clipboardHistory.count)")
            }
        }
    }
    
    @objc private func preferencesChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Trim history if new limit is smaller than current count
            let currentLimit = self.maxItems
            if self.clipboardHistory.count > currentLimit {
                let itemsToRemove = self.clipboardHistory.count - currentLimit
                self.clipboardHistory.removeLast(itemsToRemove)
                Logging.debug("📊 Preferences changed: Trimmed history to \(currentLimit) items (removed \(itemsToRemove) items)")
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
    }
}

struct ClipboardItem: Identifiable, Equatable {
    let id: UUID
    let content: Any
    let type: ClipboardContentType
    let timestamp: Date
    let displayText: String?
    
    init(id: UUID, content: Any, type: ClipboardContentType, timestamp: Date, displayText: String? = nil) {
        self.id = id
        self.content = content
        self.type = type
        self.timestamp = timestamp
        self.displayText = displayText
    }
    
    var previewText: String {
    Logging.debug("🔍 Computing previewText for item: \(id), type: \(type), displayText: \(String(describing: displayText))")
        
        if let displayText = displayText {
            Logging.debug("🔍 Using displayText: \(displayText)")
            return displayText
        }
        
        switch type {
        case .text:
            if let text = content as? String {
                // Limit preview to first line and 100 characters
                let firstLine = text.components(separatedBy: .newlines).first ?? ""
                let preview = String(firstLine.prefix(100))
                Logging.debug("🔍 Generated text preview: \(preview)")
                return preview
            }
        case .image:
            Logging.debug("🔍 Using image preview")
            return "📷 Image"
        case .file:
            if let urls = content as? [URL] {
                let preview = "📁 \(urls.count) file(s)"
            Logging.debug("🔍 Generated file preview: \(preview)")
                return preview
            }
        }
    Logging.debug("🔍 Using fallback preview")
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
        guard self.type == other.type else { 
            Logging.debug("🔍 contentEquals: Different types - \(self.type) vs \(other.type)")
            return false 
        }
        
        switch type {
        case .text:
            let result = (content as? String) == (other.content as? String)
            Logging.debug("🔍 contentEquals text: \(result)")
            return result
        case .image:
            // For images, compare their data representations
            guard let image1 = content as? NSImage,
                  let image2 = other.content as? NSImage else { 
                Logging.debug("🔍 contentEquals image: Failed to cast to NSImage")
                return false 
            }
            
            let data1 = image1.tiffRepresentation
            let data2 = image2.tiffRepresentation
            let result = data1 == data2
            Logging.debug("🔍 contentEquals image: \(result) (data1: \(data1?.count ?? 0) bytes, data2: \(data2?.count ?? 0) bytes)")
            return result
        case .file:
            let urls1 = content as? [URL] ?? []
            let urls2 = other.content as? [URL] ?? []
            let result = urls1 == urls2
            Logging.debug("🔍 contentEquals file: \(result)")
            return result
        }
    }
    
    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        return lhs.id == rhs.id
    }
}

enum ClipboardContentType {
    case text
    case image
    case file
}