import Foundation
import CoreData
import AppKit

class PersistenceManager: ObservableObject {
    static let shared = PersistenceManager()
    
    private init() {}
    
    // MARK: - Core Data Stack
    
    lazy var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "ClipboardData")
        
        // Configure for external binary storage
        if let description = container.persistentStoreDescriptions.first {
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        }
        
        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                // In production, handle this more gracefully
                print("💾 Core Data error: \(error), \(error.userInfo)")
                fatalError("Core Data error: \(error), \(error.userInfo)")
            }
        }
        
        container.viewContext.automaticallyMergesChangesFromParent = true
        return container
    }()
    
    private var context: NSManagedObjectContext {
        return persistentContainer.viewContext
    }
    
    // MARK: - Save Operations
    
    func saveContext() {
        if context.hasChanges {
            do {
                try context.save()
                Logging.debug("💾 Context saved successfully")
            } catch {
                print("💾 Save error: \(error)")
            }
        }
    }
    
    // MARK: - Clipboard Item Persistence
    
    func saveClipboardItem(_ item: ClipboardItem, saveImages: Bool = false) {
        let persistedItem = PersistedClipboardItem(context: context)
        
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
            if saveImages, let image = item.content as? NSImage {
                persistedItem.imageData = image.tiffRepresentation
            }
            
        case .file:
            if let urls = item.content as? [URL] {
                persistedItem.fileURLs = urls as NSObject
            }
        }
        
        saveContext()
    }
    
    /// Number of recent images to load into memory at startup (older images are lazy-loaded)
    private let maxPreloadedImages = 15

    func loadClipboardHistory(limit: Int = 1000) -> [ClipboardItem] {
        let request: NSFetchRequest<PersistedClipboardItem> = PersistedClipboardItem.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \PersistedClipboardItem.createdAt, ascending: false)]
        request.fetchLimit = limit

        do {
            let persistedItems = try context.fetch(request)
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
            print("💾 Load error: \(error)")
            return []
        }
    }
    
    private func convertToClipboardItem(_ persistedItem: PersistedClipboardItem, loadImageData: Bool = true) -> ClipboardItem? {
        guard let id = persistedItem.id,
              let createdAt = persistedItem.createdAt else {
            print("💾 Invalid persisted item: missing id or createdAt")
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
            isImageLoaded: isImageLoaded
        )
    }

    /// Load image data for a specific item (for lazy loading)
    func loadImageData(for itemId: UUID) -> NSImage? {
        let request: NSFetchRequest<PersistedClipboardItem> = PersistedClipboardItem.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", itemId as CVarArg)
        request.fetchLimit = 1

        do {
            if let item = try context.fetch(request).first,
               let imageData = item.imageData,
               let image = NSImage(data: imageData) {
                return image
            }
        } catch {
            print("💾 Error loading image data: \(error)")
        }
        return nil
    }
    
    // MARK: - Favorites

    func toggleFavorite(itemId: UUID) -> Bool {
        let request: NSFetchRequest<PersistedClipboardItem> = PersistedClipboardItem.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", itemId as CVarArg)

        do {
            let items = try context.fetch(request)
            if let item = items.first {
                item.isFavorite = !item.isFavorite
                saveContext()
                Logging.debug("Toggled favorite for item \(itemId): \(item.isFavorite)")
                return item.isFavorite
            }
        } catch {
            print("Toggle favorite error: \(error)")
        }
        return false
    }

    func updateNote(itemId: UUID, note: String?) {
        let request: NSFetchRequest<PersistedClipboardItem> = PersistedClipboardItem.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", itemId as CVarArg)

        do {
            let items = try context.fetch(request)
            if let item = items.first {
                item.note = note
                item.updatedAt = Date()
                saveContext()
                Logging.debug("Updated note for item \(itemId)")
            }
        } catch {
            print("Update note error: \(error)")
        }
    }

    func toggleSensitive(itemId: UUID, isManuallyUnsensitive: Bool) -> Bool {
        let request: NSFetchRequest<PersistedClipboardItem> = PersistedClipboardItem.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", itemId as CVarArg)

        do {
            let items = try context.fetch(request)
            if let item = items.first {
                item.isSensitive = !item.isSensitive
                item.isManuallyUnsensitive = isManuallyUnsensitive
                item.updatedAt = Date()
                saveContext()
                Logging.debug("Toggled sensitive for item \(itemId): \(item.isSensitive), manuallyUnsensitive: \(isManuallyUnsensitive)")
                return item.isSensitive
            }
        } catch {
            print("Toggle sensitive error: \(error)")
        }
        return false
    }

    func setSensitive(itemId: UUID, value: Bool) {
        let request: NSFetchRequest<PersistedClipboardItem> = PersistedClipboardItem.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", itemId as CVarArg)

        do {
            let items = try context.fetch(request)
            if let item = items.first {
                item.isSensitive = value
                item.updatedAt = Date()
                saveContext()
                Logging.debug("Set sensitive for item \(itemId): \(value)")
            }
        } catch {
            print("Set sensitive error: \(error)")
        }
    }

    /// Apply isSensitive=true to all items with isAutoSensitive=true (skip manually unsensitive)
    func applyAutoSensitiveFlag() {
        let request: NSFetchRequest<PersistedClipboardItem> = PersistedClipboardItem.fetchRequest()
        request.predicate = NSPredicate(format: "isAutoSensitive == YES AND isSensitive == NO AND isManuallyUnsensitive == NO")

        do {
            let items = try context.fetch(request)
            for item in items {
                item.isSensitive = true
                item.updatedAt = Date()
            }
            if !items.isEmpty {
                saveContext()
                Logging.debug("💾 Applied sensitive flag to \(items.count) auto-detected items")
            }
        } catch {
            print("Apply auto-sensitive flag error: \(error)")
        }
    }

    /// Apply isSensitive=true to all items with isPasswordLike=true (skip manually unsensitive)
    func applyPasswordLikeFlag() {
        let request: NSFetchRequest<PersistedClipboardItem> = PersistedClipboardItem.fetchRequest()
        request.predicate = NSPredicate(format: "isPasswordLike == YES AND isSensitive == NO AND isManuallyUnsensitive == NO")

        do {
            let items = try context.fetch(request)
            for item in items {
                item.isSensitive = true
                item.updatedAt = Date()
            }
            if !items.isEmpty {
                saveContext()
                Logging.debug("💾 Applied sensitive flag to \(items.count) password-like items")
            }
        } catch {
            print("Apply password-like flag error: \(error)")
        }
    }

    // MARK: - Storage Management

    func getStorageSize() -> Int64 {
        let request: NSFetchRequest<PersistedClipboardItem> = PersistedClipboardItem.fetchRequest()
        
        do {
            let items = try context.fetch(request)
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
            print("💾 Error calculating storage size: \(error)")
            return 0
        }
    }
    
    func cleanupOldItems(olderThan days: Int) {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let request: NSFetchRequest<NSFetchRequestResult> = PersistedClipboardItem.fetchRequest()
        // Skip favorites - they persist indefinitely
        request.predicate = NSPredicate(format: "createdAt < %@ AND isFavorite == NO", cutoffDate as NSDate)
        
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
        
        do {
            let result = try context.execute(deleteRequest) as? NSBatchDeleteResult
            let deletedCount = result?.result as? Int ?? 0
            Logging.debug("💾 Cleaned up \(deletedCount) old items")
            
            // Refresh the context
            context.refreshAllObjects()
        } catch {
            print("💾 Cleanup error: \(error)")
        }
    }
    
    func clearAllData() {
        let request: NSFetchRequest<NSFetchRequestResult> = PersistedClipboardItem.fetchRequest()
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)

        do {
            try context.execute(deleteRequest)
            context.refreshAllObjects()
            Logging.debug("💾 Cleared all persistent data")
        } catch {
            print("💾 Clear all error: \(error)")
        }
    }

    func deleteItems(withIds ids: Set<UUID>) {
        let request: NSFetchRequest<NSFetchRequestResult> = PersistedClipboardItem.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", ids as CVarArg)
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)

        do {
            let result = try context.execute(deleteRequest) as? NSBatchDeleteResult
            let deletedCount = result?.result as? Int ?? 0
            context.refreshAllObjects()
            Logging.debug("💾 Deleted \(deletedCount) items from persistent storage")
        } catch {
            print("💾 Delete items error: \(error)")
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