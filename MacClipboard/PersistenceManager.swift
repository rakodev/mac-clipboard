import Foundation
import CoreData
import AppKit

extension Notification.Name {
    static let persistenceStoreDidRecoverTemporarily = Notification.Name("persistenceStoreDidRecoverTemporarily")
}

class PersistenceManager: ObservableObject {
    static let shared = PersistenceManager()

    @Published private(set) var isUsingTemporaryStore = false
    @Published private(set) var lastStoreLoadError: String?

    var persistenceDiagnosticsMessage: String? {
        guard isUsingTemporaryStore else { return nil }
        let details = lastStoreLoadError.map { "\n\nDetails: \($0)" } ?? ""
        return "Clipboard history storage could not be opened. MacClipboard is using temporary storage for this session.\(details)"
    }
    
    private init() {}
    
    // MARK: - Core Data Stack
    
    lazy var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "ClipboardData")
        configure(container: container)
        return container
    }()

    private lazy var backgroundContext: NSManagedObjectContext = {
        let context = persistentContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.automaticallyMergesChangesFromParent = true
        return context
    }()

    private func configure(container: NSPersistentContainer) {
        
        // Configure for external binary storage
        if let description = container.persistentStoreDescriptions.first {
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        }
        
        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                Logging.info("💾 Core Data store load failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.lastStoreLoadError = error.localizedDescription
                }
                self.loadTemporaryStore(into: container)
            }
        }
        
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    private func loadTemporaryStore(into container: NSPersistentContainer) {
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]

        container.loadPersistentStores { _, error in
            if let error = error {
                Logging.info("💾 Temporary Core Data store load failed: \(error.localizedDescription)")
                return
            }
            Logging.info("💾 Using temporary clipboard history storage for this session")
            DispatchQueue.main.async {
                self.isUsingTemporaryStore = true
                NotificationCenter.default.post(name: .persistenceStoreDidRecoverTemporarily, object: self)
            }
        }
    }

    func resetPersistentStoreFiles() -> Bool {
        let storeURL = NSPersistentContainer.defaultDirectoryURL().appendingPathComponent("ClipboardData.sqlite")
        let fileManager = FileManager.default
        var didFail = false

        do {
            if fileManager.fileExists(atPath: storeURL.path) {
                try persistentContainer.persistentStoreCoordinator.destroyPersistentStore(at: storeURL, ofType: NSSQLiteStoreType, options: nil)
            }
        } catch {
            Logging.info("💾 Failed to destroy persistent store: \(error.localizedDescription)")
            didFail = true
        }

        for suffix in ["", "-shm", "-wal"] {
            let url = URL(fileURLWithPath: storeURL.path + suffix)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                Logging.info("💾 Failed to remove persistent store file \(url.lastPathComponent): \(error.localizedDescription)")
                didFail = true
            }
        }

        return !didFail
    }

    private func performOnContext<T>(_ work: () throws -> T) throws -> T {
        var result: Result<T, Error>!
        backgroundContext.performAndWait {
            do {
                result = .success(try work())
            } catch {
                result = .failure(error)
            }
        }
        return try result.get()
    }
    
    // MARK: - Save Operations
    
    func saveContext() {
        do {
            try performOnContext {
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    Logging.debug("💾 Context saved successfully")
                }
            }
        } catch {
            Logging.info("💾 Save error: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Clipboard Item Persistence
    
    func saveClipboardItem(_ item: ClipboardItem, saveImages: Bool = false) {
        do {
            try performOnContext {
                let persistedItem = PersistedClipboardItem(context: backgroundContext)

                persistedItem.id = item.id
                persistedItem.createdAt = item.timestamp
                persistedItem.updatedAt = Date()
                persistedItem.contentType = Int16(item.type.rawValue)
                persistedItem.displayText = item.displayText
                persistedItem.isFavorite = item.isFavorite
                persistedItem.isSensitive = item.isSensitive
                persistedItem.isAutoSensitive = item.isAutoSensitive
                persistedItem.isPasswordLike = item.isPasswordLike
                persistedItem.isManuallyUnsensitive = item.isManuallyUnsensitive
                persistedItem.note = item.note

                switch item.type {
                case .text:
                    if let text = item.content as? String {
                        persistedItem.textContent = text
                    }

                case .image:
                    // Preserve text representation for mixed clipboard payloads (image + text)
                    persistedItem.textContent = item.associatedText
                    if saveImages, let image = item.content as? NSImage {
                        persistedItem.imageData = image.tiffRepresentation
                    }

                case .file:
                    if let urls = item.content as? [URL] {
                        persistedItem.fileURLs = urls as NSObject
                    }
                }

                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    Logging.debug("💾 Context saved successfully")
                }
            }
        } catch {
            Logging.info("💾 Save error: \(error.localizedDescription)")
        }
    }
    
    /// Number of recent images to load into memory at startup (older images are lazy-loaded)
    private let maxPreloadedImages = 15

    func loadClipboardHistory(limit: Int = 1000) -> [ClipboardItem] {
        do {
            let persistedItems: [PersistedClipboardItem] = try performOnContext {
                let favoritesRequest: NSFetchRequest<PersistedClipboardItem> = PersistedClipboardItem.fetchRequest()
                favoritesRequest.sortDescriptors = [NSSortDescriptor(keyPath: \PersistedClipboardItem.createdAt, ascending: false)]
                favoritesRequest.predicate = NSPredicate(format: "isFavorite == YES")

                let favoriteItems = try backgroundContext.fetch(favoritesRequest)

                let nonFavoriteLimit = max(0, limit - favoriteItems.count)
                var nonFavoriteItems: [PersistedClipboardItem] = []
                if nonFavoriteLimit > 0 {
                    let nonFavoritesRequest: NSFetchRequest<PersistedClipboardItem> = PersistedClipboardItem.fetchRequest()
                    nonFavoritesRequest.sortDescriptors = [NSSortDescriptor(keyPath: \PersistedClipboardItem.createdAt, ascending: false)]
                    nonFavoritesRequest.predicate = NSPredicate(format: "isFavorite == NO")
                    nonFavoritesRequest.fetchLimit = nonFavoriteLimit
                    nonFavoriteItems = try backgroundContext.fetch(nonFavoritesRequest)
                }

                return (favoriteItems + nonFavoriteItems).sorted {
                    ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
                }
            }

            var imageCount = 0
            let clipboardItems = persistedItems.compactMap { item -> ClipboardItem? in
                let isImage = item.contentType == Int16(ClipboardContentType.image.rawValue)
                if isImage {
                    imageCount += 1
                    // Only load first N images into memory, rest are lazy-loaded
                    let shouldLoadImage = imageCount <= maxPreloadedImages
                    return convertToClipboardItem(item, loadImageData: shouldLoadImage)
                }
                return convertToClipboardItem(item, loadImageData: true)
            }
            let lazyCount = max(0, imageCount - maxPreloadedImages)
            Logging.debug("💾 Loaded \(clipboardItems.count) items (\(imageCount) images, \(lazyCount) lazy)")
            return clipboardItems
        } catch {
            Logging.info("💾 Load error: \(error.localizedDescription)")
            return []
        }
    }
    
    private func convertToClipboardItem(_ persistedItem: PersistedClipboardItem, loadImageData: Bool = true) -> ClipboardItem? {
        guard let id = persistedItem.id,
              let createdAt = persistedItem.createdAt else {
            Logging.info("💾 Invalid persisted item: missing id or createdAt")
            return nil
        }

        let contentType = ClipboardContentType(rawValue: Int(persistedItem.contentType)) ?? .text
        var content: Any = ""
        var isImageLoaded = true

        switch contentType {
        case .text:
            content = persistedItem.textContent ?? ""

        case .image:
            if loadImageData {
                if let imageData = persistedItem.imageData,
                   let image = NSImage(data: imageData) {
                    content = image
                } else {
                    // If image data is missing, skip this item
                    return nil
                }
            } else {
                // Lazy load: don't load image data yet, use placeholder
                content = NSNull()  // Placeholder for unloaded image
                isImageLoaded = false
            }

        case .file:
            if let urls = persistedItem.fileURLs as? [URL] {
                // Validate that files still exist
                let validURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
                if validURLs.isEmpty {
                    return nil
                }
                content = validURLs
            } else {
                return nil
            }
        }

        return ClipboardItem(
            id: id,
            content: content,
            type: contentType,
            timestamp: createdAt,
            displayText: persistedItem.displayText,
            isFavorite: persistedItem.isFavorite,
            isSensitive: persistedItem.isSensitive,
            isAutoSensitive: persistedItem.isAutoSensitive,
            isPasswordLike: persistedItem.isPasswordLike,
            isManuallyUnsensitive: persistedItem.isManuallyUnsensitive,
            note: persistedItem.note,
            associatedText: contentType == .image ? persistedItem.textContent : nil,
            isImageLoaded: isImageLoaded
        )
    }

    /// Load image data for a specific item (for lazy loading)
    func loadImageData(for itemId: UUID) -> NSImage? {
        do {
            let item: PersistedClipboardItem? = try performOnContext {
                let request: NSFetchRequest<PersistedClipboardItem> = PersistedClipboardItem.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", itemId as CVarArg)
                request.fetchLimit = 1
                return try backgroundContext.fetch(request).first
            }

            if let item,
               let imageData = item.imageData,
               let image = NSImage(data: imageData) {
                return image
            }
        } catch {
            Logging.info("💾 Error loading image data: \(error.localizedDescription)")
        }
        return nil
    }
    
    // MARK: - Favorites

    func toggleFavorite(itemId: UUID) -> Bool {
        do {
            return try performOnContext {
                let request: NSFetchRequest<PersistedClipboardItem> = PersistedClipboardItem.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", itemId as CVarArg)

                let items = try backgroundContext.fetch(request)
                if let item = items.first {
                    item.isFavorite = !item.isFavorite
                    item.updatedAt = Date()
                    if backgroundContext.hasChanges {
                        try backgroundContext.save()
                    }
                    Logging.debug("Toggled favorite for item \(itemId): \(item.isFavorite)")
                    return item.isFavorite
                }
                return false
            }
        } catch {
            Logging.info("Toggle favorite error: \(error.localizedDescription)")
        }
        return false
    }

    func updateNote(itemId: UUID, note: String?) {
        do {
            try performOnContext {
                let request: NSFetchRequest<PersistedClipboardItem> = PersistedClipboardItem.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", itemId as CVarArg)

                let items = try backgroundContext.fetch(request)
                if let item = items.first {
                    item.note = note
                    item.updatedAt = Date()
                    if backgroundContext.hasChanges {
                        try backgroundContext.save()
                    }
                    Logging.debug("Updated note for item \(itemId)")
                }
            }
        } catch {
            Logging.info("Update note error: \(error.localizedDescription)")
        }
    }

    func toggleSensitive(itemId: UUID, isManuallyUnsensitive: Bool) -> Bool {
        do {
            return try performOnContext {
                let request: NSFetchRequest<PersistedClipboardItem> = PersistedClipboardItem.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", itemId as CVarArg)

                let items = try backgroundContext.fetch(request)
                if let item = items.first {
                    item.isSensitive = !item.isSensitive
                    item.isManuallyUnsensitive = isManuallyUnsensitive
                    item.updatedAt = Date()
                    if backgroundContext.hasChanges {
                        try backgroundContext.save()
                    }
                    Logging.debug("Toggled sensitive for item \(itemId): \(item.isSensitive), manuallyUnsensitive: \(isManuallyUnsensitive)")
                    return item.isSensitive
                }
                return false
            }
        } catch {
            Logging.info("Toggle sensitive error: \(error.localizedDescription)")
        }
        return false
    }

    func setSensitive(itemId: UUID, value: Bool) {
        do {
            try performOnContext {
                let request: NSFetchRequest<PersistedClipboardItem> = PersistedClipboardItem.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", itemId as CVarArg)

                let items = try backgroundContext.fetch(request)
                if let item = items.first {
                    item.isSensitive = value
                    item.updatedAt = Date()
                    if backgroundContext.hasChanges {
                        try backgroundContext.save()
                    }
                    Logging.debug("Set sensitive for item \(itemId): \(value)")
                }
            }
        } catch {
            Logging.info("Set sensitive error: \(error.localizedDescription)")
        }
    }

    /// Apply isSensitive=true to all items with isAutoSensitive=true (skip manually unsensitive)
    func applyAutoSensitiveFlag() {
        do {
            try performOnContext {
                let request: NSFetchRequest<PersistedClipboardItem> = PersistedClipboardItem.fetchRequest()
                request.predicate = NSPredicate(format: "isAutoSensitive == YES AND isSensitive == NO AND isManuallyUnsensitive == NO")

                let items = try backgroundContext.fetch(request)
                for item in items {
                    item.isSensitive = true
                    item.updatedAt = Date()
                }
                if !items.isEmpty {
                    if backgroundContext.hasChanges {
                        try backgroundContext.save()
                    }
                    Logging.debug("💾 Applied sensitive flag to \(items.count) auto-detected items")
                }
            }
        } catch {
            Logging.info("Apply auto-sensitive flag error: \(error.localizedDescription)")
        }
    }

    /// Apply isSensitive=true to all items with isPasswordLike=true (skip manually unsensitive)
    func applyPasswordLikeFlag() {
        do {
            try performOnContext {
                let request: NSFetchRequest<PersistedClipboardItem> = PersistedClipboardItem.fetchRequest()
                request.predicate = NSPredicate(format: "isPasswordLike == YES AND isSensitive == NO AND isManuallyUnsensitive == NO")

                let items = try backgroundContext.fetch(request)
                for item in items {
                    item.isSensitive = true
                    item.updatedAt = Date()
                }
                if !items.isEmpty {
                    if backgroundContext.hasChanges {
                        try backgroundContext.save()
                    }
                    Logging.debug("💾 Applied sensitive flag to \(items.count) password-like items")
                }
            }
        } catch {
            Logging.info("Apply password-like flag error: \(error.localizedDescription)")
        }
    }

    // MARK: - Storage Management

    func getStorageSize() -> Int64 {
        do {
            let items: [PersistedClipboardItem] = try performOnContext {
                let request: NSFetchRequest<PersistedClipboardItem> = PersistedClipboardItem.fetchRequest()
                return try backgroundContext.fetch(request)
            }
            let totalSize = items.reduce(0) { total, item in
                var itemSize: Int64 = 0
                
                // Text size
                if let text = item.textContent {
                    itemSize += Int64(text.utf8.count)
                }
                
                // Image size
                if let imageData = item.imageData {
                    itemSize += Int64(imageData.count)
                }
                
                // File URLs (small overhead)
                if let urls = item.fileURLs as? [URL] {
                    itemSize += Int64(urls.count * 100) // Estimate 100 bytes per URL
                }
                
                return total + Int(itemSize)
            }
            
            return Int64(totalSize)
        } catch {
            Logging.info("💾 Error calculating storage size: \(error.localizedDescription)")
            return 0
        }
    }
    
    func cleanupOldItems(olderThan days: Int) {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()

        do {
            try performOnContext {
                let request: NSFetchRequest<NSFetchRequestResult> = PersistedClipboardItem.fetchRequest()
                // Skip favorites - they persist indefinitely
                request.predicate = NSPredicate(format: "createdAt < %@ AND isFavorite == NO", cutoffDate as NSDate)

                let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
                let result = try backgroundContext.execute(deleteRequest) as? NSBatchDeleteResult
                let deletedCount = result?.result as? Int ?? 0
                Logging.debug("💾 Cleaned up \(deletedCount) old items")

                // Refresh the context
                backgroundContext.refreshAllObjects()
            }
        } catch {
            Logging.info("💾 Cleanup error: \(error.localizedDescription)")
        }
    }
    
    func clearAllData() {
        do {
            try performOnContext {
                let request: NSFetchRequest<NSFetchRequestResult> = PersistedClipboardItem.fetchRequest()
                let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
                try backgroundContext.execute(deleteRequest)
                backgroundContext.refreshAllObjects()
                Logging.debug("💾 Cleared all persistent data")
            }
        } catch {
            Logging.info("💾 Clear all error: \(error.localizedDescription)")
        }
    }

    func deleteItems(withIds ids: Set<UUID>) {
        do {
            try performOnContext {
                let request: NSFetchRequest<NSFetchRequestResult> = PersistedClipboardItem.fetchRequest()
                request.predicate = NSPredicate(format: "id IN %@", ids as CVarArg)
                let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)

                let result = try backgroundContext.execute(deleteRequest) as? NSBatchDeleteResult
                let deletedCount = result?.result as? Int ?? 0
                backgroundContext.refreshAllObjects()
                Logging.debug("💾 Deleted \(deletedCount) items from persistent storage")
            }
        } catch {
            Logging.info("💾 Delete items error: \(error.localizedDescription)")
        }
    }
}

// MARK: - ClipboardContentType Extension

extension ClipboardContentType {
    var rawValue: Int {
        switch self {
        case .text: return 0
        case .image: return 1
        case .file: return 2
        }
    }
    
    init?(rawValue: Int) {
        switch rawValue {
        case 0: self = .text
        case 1: self = .image
        case 2: self = .file
        default: return nil
        }
    }
}