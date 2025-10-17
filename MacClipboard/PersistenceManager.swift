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
                Logging.info("💾 Context saved successfully")
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
    
    func loadClipboardHistory(limit: Int = 1000) -> [ClipboardItem] {
        let request: NSFetchRequest<PersistedClipboardItem> = PersistedClipboardItem.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \PersistedClipboardItem.createdAt, ascending: false)]
        request.fetchLimit = limit
        
        do {
            let persistedItems = try context.fetch(request)
            let clipboardItems = persistedItems.compactMap { convertToClipboardItem($0) }
            Logging.info("💾 Loaded \(clipboardItems.count) items from storage")
            return clipboardItems
        } catch {
            print("💾 Load error: \(error)")
            return []
        }
    }
    
    private func convertToClipboardItem(_ persistedItem: PersistedClipboardItem) -> ClipboardItem? {
        guard let id = persistedItem.id,
              let createdAt = persistedItem.createdAt else {
            print("💾 Invalid persisted item: missing id or createdAt")
            return nil
        }
        
        let contentType = ClipboardContentType(rawValue: Int(persistedItem.contentType)) ?? .text
        var content: Any = ""
        
        switch contentType {
        case .text:
            content = persistedItem.textContent ?? ""
            
        case .image:
            if let imageData = persistedItem.imageData,
               let image = NSImage(data: imageData) {
                content = image
            } else {
                // If image data is missing, skip this item
                return nil
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
            displayText: persistedItem.displayText
        )
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
        request.predicate = NSPredicate(format: "createdAt < %@", cutoffDate as NSDate)
        
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
        
        do {
            let result = try context.execute(deleteRequest) as? NSBatchDeleteResult
            let deletedCount = result?.result as? Int ?? 0
            Logging.info("💾 Cleaned up \(deletedCount) old items")
            
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
            Logging.info("💾 Cleared all persistent data")
        } catch {
            print("💾 Clear all error: \(error)")
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