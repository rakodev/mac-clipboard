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

    // MARK: - Store Location

    /// Directory that holds the Core Data store.
    ///
    /// `NSPersistentContainer.defaultDirectoryURL()` resolves to the same
    /// `~/Library/Application Support/MacClipboard` folder for a dev build and an installed
    /// release build, because it keys off the executable name rather than the bundle id.
    /// Both processes then hold write handles on one SQLite file, and two independent Core
    /// Data stacks on one store get no cross-process change coordination: each keeps stale
    /// state, cleanup in one can resurrect items in the other, and `destroyPersistentStore`
    /// runs while another process still has the file open. Dev builds therefore get their
    /// own folder.
    ///
    /// The release path is deliberately left byte-for-byte as it was, so no installed copy
    /// loses its existing history. A dev build starts from an empty history the first time
    /// it runs after this change.
    static var storeDirectoryURL: URL {
        let defaultURL = NSPersistentContainer.defaultDirectoryURL()
        guard BuildInfo.isDevBuild else { return defaultURL }
        return defaultURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(defaultURL.lastPathComponent) (Dev)", isDirectory: true)
    }

    static var storeURL: URL {
        storeDirectoryURL.appendingPathComponent("ClipboardData.sqlite")
    }

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
        // Point dev builds at their own store file. See storeDirectoryURL.
        if BuildInfo.isDevBuild {
            let directoryURL = Self.storeDirectoryURL
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                container.persistentStoreDescriptions = [NSPersistentStoreDescription(url: Self.storeURL)]
            } catch {
                // Fall back to the default location rather than failing to start. Worth
                // knowing about, since it means sharing a store with a release build again.
                Logging.info("💾 Could not create the dev store directory, using the default location: \(error.localizedDescription)")
            }
        }

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
        let storeURL = Self.storeURL
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

    /// Runs `work` on the background context's own queue.
    ///
    /// `work` must return value types only. A `PersistedClipboardItem` handed back out of the
    /// block belongs to this queue, so reading any of its properties on the caller's thread
    /// faults the row in from the wrong thread. That corrupts the context's object graph, and
    /// what crashes is the context queue itself, later, inside
    /// `-[NSManagedObjectContext _processRecentChanges:]`, which points nowhere near the code
    /// that caused it. `compactImageStorage` made it reliable enough to hit in the field: it
    /// calls `refreshAllObjects()` between batches, so the snapshot behind a row handed to the UI
    /// is dropped while the UI is still reading it. Convert to `ClipboardItem` (a struct), or
    /// return the bytes, inside the block.
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
                // Seed last-used with creation time so newly captured items sort
                // correctly before they are ever pasted.
                persistedItem.lastUsedAt = item.timestamp
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
                        persistedItem.imageData = image.clipboardStorageData
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
            let (clipboardItems, imageCount): ([ClipboardItem], Int) = try performOnContext {
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

                // Order by last-used time so the "most recently used at top"
                // ordering survives an app restart. Fall back to createdAt for
                // legacy items saved before lastUsedAt existed.
                let persistedItems = (favoriteItems + nonFavoriteItems).sorted {
                    let lhs = $0.lastUsedAt ?? $0.createdAt ?? .distantPast
                    let rhs = $1.lastUsedAt ?? $1.createdAt ?? .distantPast
                    return lhs > rhs
                }

                // Convert inside the block: see `performOnContext`. The rows are read here and
                // only value types leave.
                var imageCount = 0
                let items = persistedItems.compactMap { item -> ClipboardItem? in
                    let isImage = item.contentType == Int16(ClipboardContentType.image.rawValue)
                    if isImage {
                        imageCount += 1
                        // Only load first N images into memory, rest are lazy-loaded
                        let shouldLoadImage = imageCount <= maxPreloadedImages
                        return convertToClipboardItem(item, loadImageData: shouldLoadImage)
                    }
                    return convertToClipboardItem(item, loadImageData: true)
                }
                return (items, imageCount)
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
            // Read the bytes inside the block: see `performOnContext`. Handing the row itself
            // back and reading `imageData` here would fault it in on the caller's thread.
            let imageData: Data? = try performOnContext {
                let request: NSFetchRequest<PersistedClipboardItem> = PersistedClipboardItem.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", itemId as CVarArg)
                request.fetchLimit = 1
                return try backgroundContext.fetch(request).first?.imageData
            }

            if let imageData, let image = NSImage(data: imageData) {
                return image
            }
        } catch {
            Logging.info("💾 Error loading image data: \(error.localizedDescription)")
        }
        return nil
    }
    
    // MARK: - Usage Tracking

    /// Record that an item was just pasted/used so it sorts to the top, and so
    /// that ordering persists across app restarts. Does not touch updatedAt or
    /// createdAt, keeping "time ago" tied to when the item was first captured.
    func markItemUsed(itemId: UUID) {
        do {
            try performOnContext {
                let request: NSFetchRequest<PersistedClipboardItem> = PersistedClipboardItem.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", itemId as CVarArg)

                let items = try backgroundContext.fetch(request)
                if let item = items.first {
                    item.lastUsedAt = Date()
                    if backgroundContext.hasChanges {
                        try backgroundContext.save()
                    }
                    Logging.debug("Marked item used \(itemId)")
                }
            }
        } catch {
            Logging.info("Mark item used error: \(error.localizedDescription)")
        }
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

    /// A favorite read straight out of the store, carrying the raw stored bytes rather than an
    /// `NSImage`. The export re-encodes them itself, so it must not go through the UI's
    /// lazy-image path, which drops the data for anything past the first few images.
    struct FavoriteSnapshot {
        let id: UUID
        let type: ClipboardContentType
        let createdAt: Date
        let note: String?
        let isSensitive: Bool
        let text: String?
        let imageData: Data?
        let fileURLs: [URL]
    }

    func loadFavorites() -> [FavoriteSnapshot] {
        do {
            return try performOnContext {
                let request: NSFetchRequest<PersistedClipboardItem> = PersistedClipboardItem.fetchRequest()
                request.predicate = NSPredicate(format: "isFavorite == YES")
                request.sortDescriptors = [NSSortDescriptor(keyPath: \PersistedClipboardItem.createdAt, ascending: false)]

                return try backgroundContext.fetch(request).compactMap { item in
                    guard let id = item.id, let createdAt = item.createdAt else { return nil }
                    return FavoriteSnapshot(
                        id: id,
                        type: ClipboardContentType(rawValue: Int(item.contentType)) ?? .text,
                        createdAt: createdAt,
                        note: item.note,
                        isSensitive: item.isSensitive,
                        text: item.textContent,
                        imageData: item.imageData,
                        fileURLs: (item.fileURLs as? [URL]) ?? []
                    )
                }
            }
        } catch {
            Logging.info("💾 Load favorites error: \(error.localizedDescription)")
            return []
        }
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

    /// Bytes the history occupies on disk.
    ///
    /// Measured from the files rather than by walking the objects. Reading `imageData` on every
    /// row faults each external image file into memory, so the old implementation moved the whole
    /// image store, better than a gigabyte on a real history, just to produce a number, once an
    /// hour. Stat calls cost nothing by comparison and count the SQLite files too.
    func getStorageSize() -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: Self.storeDirectoryURL,
            includingPropertiesForKeys: keys
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    /// Evicts the oldest non-favorite images until the store fits inside `byteLimit`, returning
    /// how many were removed.
    ///
    /// Images are the only thing worth evicting under pressure. On a measured history, 1683 text
    /// clips came to 717 KB while 176 images came to 1.2 GB, so deleting text to make room would
    /// throw away the useful history to protect the expensive one. Favorites are never evicted.
    @discardableResult
    func evictImagesUntilWithin(byteLimit: Int64, batchSize: Int = 20) -> Int {
        var evicted = 0
        // The store cannot shrink below its non-image content, so stop rather than spin if
        // evicting every image still is not enough.
        while getStorageSize() > byteLimit {
            let removed = (try? deleteBatchOfNonFavorites(matching: Self.imagesOnly, limit: batchSize)) ?? 0
            guard removed > 0 else { break }
            evicted += removed
        }

        if evicted > 0 {
            Logging.debug("💾 Evicted \(evicted) images to stay within the storage limit")
        }
        return evicted
    }

    /// Re-encodes stored images that predate PNG storage, returning the bytes reclaimed.
    ///
    /// Runs once per install, guarded by `UserPreferencesManager.imageStorageCompacted`: new clips
    /// are already PNG, but an existing history can be holding a gigabyte of uncompressed TIFF,
    /// and that is where the win is. Works in small batches, refreshing between them, so peak
    /// memory stays a few images rather than the whole store. A blob is only replaced when the
    /// PNG decodes and is actually smaller, so a failure here cannot damage an image.
    @discardableResult
    func compactImageStorage(batchSize: Int = 5) -> Int64 {
        var reclaimed: Int64 = 0
        var offset = 0

        while true {
            let batch: (processed: Int, saved: Int64) = (try? performOnContext {
                let request: NSFetchRequest<PersistedClipboardItem> = PersistedClipboardItem.fetchRequest()
                request.predicate = Self.imagesOnly
                request.sortDescriptors = [
                    NSSortDescriptor(keyPath: \PersistedClipboardItem.createdAt, ascending: true)
                ]
                // Nothing is deleted here, so paging by offset is stable.
                request.fetchOffset = offset
                request.fetchLimit = batchSize

                let items = try backgroundContext.fetch(request)
                guard !items.isEmpty else { return (0, 0) }

                var saved: Int64 = 0
                for item in items {
                    guard let stored = item.imageData, !stored.isPNGEncoded,
                          let png = Data.pngEncoded(from: stored), png.count < stored.count else { continue }
                    item.imageData = png
                    saved += Int64(stored.count - png.count)
                }

                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                }
                backgroundContext.refreshAllObjects()
                return (items.count, saved)
            }) ?? (0, 0)

            guard batch.processed > 0 else { break }
            reclaimed += batch.saved
            offset += batch.processed
        }

        Logging.debug("💾 Re-encoding stored images reclaimed \(reclaimed) bytes")
        return reclaimed
    }
    
    // MARK: - Bulk Deletion

    /// Favorites are permanent, and the UI says so. The only way to keep that promise is to make
    /// it impossible to forget: every bulk delete runs through `bulkDeleteNonFavorites`, which
    /// always ands this in. A favorite leaves the store one way only, through
    /// `deleteItems(withIds:)`, which is a request for those specific items.
    private static let excludesFavorites = NSPredicate(format: "isFavorite == NO")

    static let imagesOnly = NSPredicate(
        format: "contentType == %d", ClipboardContentType.image.rawValue
    )

    /// What a cleanup pass applies to. Images get their own window: see `CleanupScope.images`.
    enum CleanupScope {
        /// Every kind of item. File items belong here rather than with images, because a file
        /// clip stores only its paths, so it costs about as much as a line of text.
        case everything
        /// Images alone, which are effectively the whole storage cost of a history.
        case images

        var predicate: NSPredicate? {
            switch self {
            case .everything: return nil
            case .images: return PersistenceManager.imagesOnly
            }
        }
    }

    /// Deletes one batch of the non-favorites matching `predicate`, oldest first. Returns how many
    /// rows went, so a caller can keep going until it returns zero.
    ///
    /// Deliberately object deletion rather than `NSBatchDeleteRequest`. A batch delete runs
    /// straight against the store, so Core Data is never told to remove the external files behind
    /// `imageData`, and those files are the entire storage cost. A real store was found still
    /// holding orphaned image files from rows deleted months earlier, which meant deleting images
    /// to reclaim space could reclaim nothing at all.
    @discardableResult
    private func deleteBatchOfNonFavorites(matching predicate: NSPredicate?, limit: Int) throws -> Int {
        try performOnContext {
            let request: NSFetchRequest<PersistedClipboardItem> = PersistedClipboardItem.fetchRequest()
            request.predicate = predicate.map {
                NSCompoundPredicate(andPredicateWithSubpredicates: [$0, Self.excludesFavorites])
            } ?? Self.excludesFavorites
            request.sortDescriptors = [
                NSSortDescriptor(keyPath: \PersistedClipboardItem.createdAt, ascending: true)
            ]
            request.fetchLimit = limit

            let items = try backgroundContext.fetch(request)
            guard !items.isEmpty else { return 0 }

            items.forEach(backgroundContext.delete)
            try backgroundContext.save()
            backgroundContext.refreshAllObjects()
            return items.count
        }
    }

    /// Deletes every non-favorite matching `predicate`, in batches. Returns the number removed.
    @discardableResult
    private func bulkDeleteNonFavorites(matching predicate: NSPredicate?, batchSize: Int = 100) throws -> Int {
        var deleted = 0

        while true {
            let removed = try deleteBatchOfNonFavorites(matching: predicate, limit: batchSize)
            guard removed > 0 else { break }
            deleted += removed
        }

        return deleted
    }

    func cleanupOldItems(olderThan days: Int, scope: CleanupScope = .everything) {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        var predicates = [NSPredicate(format: "createdAt < %@", cutoffDate as NSDate)]
        if let scoped = scope.predicate {
            predicates.append(scoped)
        }

        do {
            let deletedCount = try bulkDeleteNonFavorites(
                matching: NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            )
            if deletedCount > 0 {
                Logging.debug("💾 Cleaned up \(deletedCount) items older than \(days) days (\(scope))")
            }
        } catch {
            Logging.info("💾 Cleanup error: \(error.localizedDescription)")
        }
    }

    /// Clears the history, keeping favorites. Starred items are the ones the user asked to hold
    /// on to, so Clear History leaves them: unstar or delete an item to remove it for good.
    func clearAllData() {
        do {
            let deletedCount = try bulkDeleteNonFavorites(matching: nil)
            Logging.debug("💾 Cleared \(deletedCount) items, kept favorites")
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

// MARK: - Image Storage Format

extension NSImage {
    /// The bytes to store for a clipboard image.
    ///
    /// Images were stored as `tiffRepresentation`, which AppKit writes uncompressed. Measured over
    /// a real history, that averaged 7 MB per screenshot and 1.2 GB in total, where the same pixels
    /// as PNG came to roughly a fortieth of the size. PNG is lossless, so nothing is traded away
    /// for it. Falls back to the TIFF bytes if re-encoding fails, since keeping the image matters
    /// more than keeping it small.
    var clipboardStorageData: Data? {
        guard let tiff = tiffRepresentation else { return nil }
        return Data.pngEncoded(from: tiff) ?? tiff
    }
}

extension Data {
    /// Re-encodes any image bytes AppKit can read as PNG, or nil if they will not decode.
    static func pngEncoded(from data: Data) -> Data? {
        guard let representation = NSBitmapImageRep(data: data) else { return nil }
        return representation.representation(using: .png, properties: [:])
    }

    /// Whether these bytes already carry the PNG signature.
    var isPNGEncoded: Bool {
        starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
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