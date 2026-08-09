import AppKit
import CoreData
import XCTest
@testable import MacClipboard

/// A test case with a Core Data store of its own.
///
/// Nothing here may reach `PersistenceManager.shared`. That manager opens the store holding the
/// user's clipboard history, and what these tests exercise is deletion, so a test that reached it
/// would delete real clips. `shared` traps under a test host so the mistake cannot be made
/// quietly; this class is the other half of that, giving each case a temporary directory that is
/// removed afterwards.
class StoreBackedTestCase: XCTestCase {
    private(set) var storeDirectory: URL!
    private(set) var persistence: PersistenceManager!

    /// Overridden by a suite that needs to watch the calls as well as the results.
    func makePersistenceManager(storeDirectory: URL) -> PersistenceManager {
        PersistenceManager(storeLocation: .directory(storeDirectory))
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacClipboardTests-\(UUID().uuidString)", isDirectory: true)
        persistence = makePersistenceManager(storeDirectory: storeDirectory)
    }

    override func tearDownWithError() throws {
        persistence = nil
        if let storeDirectory {
            try? FileManager.default.removeItem(at: storeDirectory)
        }
        storeDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    static func date(daysAgo: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
    }

    @discardableResult
    func saveText(_ text: String, daysAgo: Int = 0, isFavorite: Bool = false) -> ClipboardItem {
        let item = ClipboardItem(
            id: UUID(),
            content: text,
            type: .text,
            timestamp: Self.date(daysAgo: daysAgo),
            isFavorite: isFavorite
        )
        persistence.saveClipboardItem(item)
        return item
    }

    @discardableResult
    func saveImage(daysAgo: Int = 0, isFavorite: Bool = false, size: Int = 32) -> ClipboardItem {
        let item = ClipboardItem(
            id: UUID(),
            content: Self.image(size: size),
            type: .image,
            timestamp: Self.date(daysAgo: daysAgo),
            isFavorite: isFavorite
        )
        persistence.saveClipboardItem(item, saveImages: true)
        return item
    }

    static func image(size: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        return image
    }

    /// The ids currently in the store, read back the way the app reads them.
    func storedIDs() -> Set<UUID> {
        Set(persistence.loadClipboardHistory().map(\.id))
    }

    // MARK: - Waiting

    struct TimedOut: Error, CustomStringConvertible {
        let description: String
    }

    /// Spins the main run loop until `condition` holds.
    ///
    /// `ClipboardMonitor` hops to a background queue to write and back to the main queue to
    /// publish, so nothing it starts has finished by the time the call returns.
    func waitUntil(_ what: String, timeout: TimeInterval = 5, condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                throw TimedOut(description: "Timed out after \(timeout)s waiting for \(what)")
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

/// The seam itself, rather than anything it protects.
final class StoreLocationTests: XCTestCase {

    /// The premise every other guard rests on. `PersistenceManager.shared` traps on this, and the
    /// app skips its menu bar and clipboard monitor on it, so if the environment Xcode sets ever
    /// changes shape the whole protection stops applying with nothing to say it has.
    func testTheTestBundleIsRecognisedAsATestHost() {
        XCTAssertTrue(
            BuildInfo.isHostingTests,
            "a test run is no longer detected as one, so nothing is stopping a test from opening the user's history"
        )
    }

    /// A dev build's store, which is what a test host would otherwise open, is a folder of its own.
    /// Tests always run Debug, so `isDevBuild` is true here.
    func testDevBuildsKeepTheirHistorySomewhereOfTheirOwn() {
        let directory = PersistenceManager.applicationSupportStoreDirectoryURL
        XCTAssertNotEqual(
            directory,
            NSPersistentContainer.defaultDirectoryURL(),
            "a dev build sharing the release store means two Core Data stacks on one SQLite file"
        )
        XCTAssertTrue(directory.lastPathComponent.hasSuffix("(Dev)"), "unexpected dev store folder \(directory.path)")
    }

    func testANamedDirectoryIsTheOneUsed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacClipboardTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = PersistenceManager(storeLocation: .directory(directory))
        XCTAssertEqual(manager.storeDirectoryURL, directory)

        // Force the stack to load, then check the store landed where it was asked to rather than
        // in the user's Application Support folder.
        manager.saveClipboardItem(
            ClipboardItem(id: UUID(), content: "somewhere else entirely", type: .text, timestamp: Date())
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: manager.storeURL.path),
            "no store file at \(manager.storeURL.path)"
        )
    }
}

/// The guarantee the empty state makes to users: a favorite is never removed by anything the app
/// decides on its own. Every automatic path is covered here, because the protection is one `AND`
/// in `bulkDeleteNonFavorites` and a single new cleanup path that skipped it would be silent.
final class FavoriteProtectionTests: StoreBackedTestCase {

    func testAgeCleanupKeepsFavoritesAndRemovesOldNonFavorites() throws {
        let oldFavorite = saveText("starred and ancient", daysAgo: 400, isFavorite: true)
        let oldOrdinary = saveText("ancient", daysAgo: 400)
        let recent = saveText("from this morning")

        persistence.cleanupOldItems(olderThan: 30)

        let remaining = storedIDs()
        XCTAssertTrue(remaining.contains(oldFavorite.id), "a favorite was removed by age cleanup")
        XCTAssertTrue(remaining.contains(recent.id), "a recent item was removed by age cleanup")
        XCTAssertFalse(remaining.contains(oldOrdinary.id), "an old non-favorite survived age cleanup")
    }

    func testImageScopedCleanupKeepsFavoriteImagesAndEveryTextItem() throws {
        let favoriteImage = saveImage(daysAgo: 400, isFavorite: true)
        let ordinaryImage = saveImage(daysAgo: 400)
        let oldText = saveText("older than the image window", daysAgo: 400)

        persistence.cleanupOldItems(olderThan: 30, scope: .images)

        let remaining = storedIDs()
        XCTAssertTrue(remaining.contains(favoriteImage.id), "a favorite image was removed by image cleanup")
        XCTAssertFalse(remaining.contains(ordinaryImage.id), "an old non-favorite image survived image cleanup")
        XCTAssertTrue(
            remaining.contains(oldText.id),
            "image cleanup reached a text item; text ages out on its own, longer window"
        )
    }

    func testClearAllDataKeepsFavoritesAndNothingElse() throws {
        let favorite = saveText("keep me", isFavorite: true)
        let favoriteImage = saveImage(isFavorite: true)
        saveText("clear me")
        saveImage()

        persistence.clearAllData()

        XCTAssertEqual(
            storedIDs(),
            [favorite.id, favoriteImage.id],
            "Clear History is meant to clear the history and leave what the user pinned"
        )
    }

    func testStoragePressureEvictsNonFavoriteImagesOnly() throws {
        let favoriteImage = saveImage(isFavorite: true)
        let ordinaryImage = saveImage()
        let text = saveText("text is never the storage cost")

        // A limit no store can meet, so eviction runs until there is nothing left it is allowed
        // to take. That is also the case that used to spin: it stops on a batch that removes
        // nothing rather than on reaching the limit.
        let evicted = persistence.evictImagesUntilWithin(byteLimit: 1)

        XCTAssertEqual(evicted, 1, "eviction should have taken the one image it was allowed to take")
        let remaining = storedIDs()
        XCTAssertTrue(remaining.contains(favoriteImage.id), "a favorite image was evicted under storage pressure")
        XCTAssertFalse(remaining.contains(ordinaryImage.id), "a non-favorite image survived storage pressure")
        XCTAssertTrue(remaining.contains(text.id), "eviction reached a text item")
    }

    func testDeletingByIdIsTheOneWayAFavoriteLeaves() throws {
        let favorite = saveText("delete me deliberately", isFavorite: true)
        let other = saveText("not asked for")

        persistence.deleteItems(withIds: [favorite.id])

        XCTAssertEqual(storedIDs(), [other.id], "a favorite named directly should be deleted, and only it")
    }
}

/// The numbers the app puts in front of a user before deleting their history. A count that is
/// wrong in either direction is worse than no count: too low and the confirmation understates what
/// it takes, too high and it claims favorites it will not touch.
final class SavedHistorySummaryTests: StoreBackedTestCase {

    func testTheSummarySeparatesWhatAClearTakesFromWhatItKeeps() throws {
        saveText("passing through")
        saveText("also passing through")
        saveImage()
        saveText("pinned", isFavorite: true)
        saveImage(isFavorite: true)

        let summary = persistence.savedHistorySummary()

        XCTAssertEqual(summary.clearableCount, 3, "the count offered for deletion should exclude favorites")
        XCTAssertEqual(summary.favoriteCount, 2, "the count promised to survive should be the favorites")
        XCTAssertGreaterThan(summary.byteCount, 0, "a store with five items should report a size")
    }

    func testAnEmptyStoreHasNothingToOfferDeleting() throws {
        XCTAssertEqual(persistence.savedHistorySummary().clearableCount, 0)
    }

    func testAStoreOfOnlyFavoritesHasNothingToOfferDeleting() throws {
        saveText("pinned", isFavorite: true)

        // Zero is what stops the app asking a question it cannot act on: a clear would remove
        // nothing here, so no confirmation is put in front of the user.
        let summary = persistence.savedHistorySummary()
        XCTAssertEqual(summary.clearableCount, 0)
        XCTAssertEqual(summary.favoriteCount, 1)
    }
}

/// "Clear history when MacClipboard quits", which is a promise about what is on disk after the
/// process is gone. The delete therefore has to be finished before the call returns, not started.
final class QuitTimeHistoryClearTests: StoreBackedTestCase {
    private var preferences: UserPreferencesManager!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "MacClipboardTests-\(UUID().uuidString)"
        preferences = UserPreferencesManager(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        preferences.capturePaused = true
        preferences.imageStorageCompacted = true
    }

    override func tearDownWithError() throws {
        preferences = nil
        if let suiteName {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        suiteName = nil
        try super.tearDownWithError()
    }

    private func makeLoadedMonitor(itemCount: Int) throws -> ClipboardMonitor {
        let monitor = ClipboardMonitor(userPreferences: preferences, persistenceManager: persistence)
        try waitUntil("the monitor to load the persisted history") {
            monitor.clipboardHistory.count == itemCount
        }
        return monitor
    }

    func testQuittingClearsTheSavedHistoryWhenAskedAndKeepsFavorites() throws {
        let favorite = saveText("pinned", daysAgo: 2, isFavorite: true)
        let ordinary = saveText("passing through", daysAgo: 1)
        saveImage()
        preferences.clearHistoryOnQuit = true

        let monitor = try makeLoadedMonitor(itemCount: 3)
        monitor.clearHistoryOnQuitIfRequested()

        // Asserted with no wait at all, which is the point: at quit there is no later. A clear
        // dispatched to another queue would leave every one of these rows on disk.
        XCTAssertEqual(storedIDs(), [favorite.id], "quitting should have taken everything but the favorite")
        XCTAssertFalse(storedIDs().contains(ordinary.id))
        XCTAssertEqual(
            monitor.clipboardHistory.map(\.id),
            [favorite.id],
            "memory should be left in step with the store"
        )
    }

    func testQuittingLeavesTheHistoryAloneByDefault() throws {
        let favorite = saveText("pinned", daysAgo: 2, isFavorite: true)
        let ordinary = saveText("passing through", daysAgo: 1)

        XCTAssertFalse(preferences.clearHistoryOnQuit, "clearing on quit should be something a user opts into")

        let monitor = try makeLoadedMonitor(itemCount: 2)
        monitor.clearHistoryOnQuitIfRequested()

        XCTAssertEqual(storedIDs(), [favorite.id, ordinary.id], "quitting deleted a history nobody asked it to")
    }

    /// Switching saving off stops the writes and deletes nothing, so the clear still has to run
    /// for anyone who declined the purge offered at that moment.
    func testQuittingStillClearsWhenSavingIsAlreadyOff() throws {
        let ordinary = saveText("saved before persistence was switched off")
        preferences.clearHistoryOnQuit = true
        preferences.persistenceEnabled = false

        // Nothing is loaded into memory with persistence off, so the monitor starts empty and the
        // store is the only thing the clear can be judged on.
        let monitor = ClipboardMonitor(userPreferences: preferences, persistenceManager: persistence)
        XCTAssertTrue(storedIDs().contains(ordinary.id), "the store should still hold what was saved earlier")

        monitor.clearHistoryOnQuitIfRequested()

        XCTAssertTrue(storedIDs().isEmpty, "turning saving off must not exempt the store from the quit clear")
    }

    /// Reset is not where anyone looks to start keeping their history again, and turning this off
    /// there would leave a history the user expected gone sitting on disk after the next quit.
    func testResetToDefaultsLeavesTheQuitClearOn() throws {
        preferences.clearHistoryOnQuit = true

        preferences.resetToDefaults()

        XCTAssertTrue(preferences.clearHistoryOnQuit)
        XCTAssertTrue(preferences.persistenceEnabled, "Reset should still restore the settings it does own")
    }
}

/// Records the persistence calls a monitor makes, in order, and does the real work as well, so a
/// test can assert both what ended up in the store and how it got there.
private final class RecordingPersistenceManager: PersistenceManager {
    enum Call: Equatable {
        case save(UUID)
        case delete(Set<UUID>)
    }

    private let lock = NSLock()
    private var recorded: [Call] = []

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    override func saveClipboardItem(_ item: ClipboardItem, saveImages: Bool = false) {
        super.saveClipboardItem(item, saveImages: saveImages)
        record(.save(item.id))
    }

    override func deleteItems(withIds ids: Set<UUID>) {
        super.deleteItems(withIds: ids)
        record(.delete(ids))
    }

    private func record(_ call: Call) {
        lock.lock()
        recorded.append(call)
        lock.unlock()
    }
}

/// `ClipboardMonitor` over a store of its own, so the ordering rules it is responsible for can be
/// checked against a real Core Data stack rather than inferred.
final class ClipboardMonitorPersistenceTests: StoreBackedTestCase {
    private var recording: RecordingPersistenceManager!
    private var preferences: UserPreferencesManager!
    private var suiteName: String!

    override func makePersistenceManager(storeDirectory: URL) -> PersistenceManager {
        let manager = RecordingPersistenceManager(storeLocation: .directory(storeDirectory))
        recording = manager
        return manager
    }

    override func setUpWithError() throws {
        try super.setUpWithError()

        suiteName = "MacClipboardTests-\(UUID().uuidString)"
        preferences = UserPreferencesManager(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        // Capture stays off for the length of the test. A monitor that polled would record
        // whatever the developer happened to copy while the suite ran, which is both a surprise
        // in the assertions and their clipboard in a test fixture.
        preferences.capturePaused = true
        // The one-time image re-encode has nothing to do with what is being tested here, and it
        // runs on a background queue against the same store.
        preferences.imageStorageCompacted = true
    }

    override func tearDownWithError() throws {
        preferences = nil
        recording = nil
        if let suiteName {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        suiteName = nil
        try super.tearDownWithError()
    }

    private func makeMonitor() -> ClipboardMonitor {
        ClipboardMonitor(userPreferences: preferences, persistenceManager: persistence)
    }

    func testRecopyingAFavoriteWritesTheReplacementBeforeDroppingTheOriginal() throws {
        let original = ClipboardItem(
            id: UUID(),
            content: "the snippet I paste every day",
            type: .text,
            timestamp: Self.date(daysAgo: 2),
            isFavorite: true
        )
        // Something newer has to sit above it. A match that is already at the top is left exactly
        // where it is and nothing is written, so that arrangement would not exercise anything.
        let newer = ClipboardItem(
            id: UUID(), content: "copied since", type: .text, timestamp: Self.date(daysAgo: 1)
        )
        persistence.saveClipboardItem(original)
        persistence.saveClipboardItem(newer)

        let monitor = makeMonitor()
        try waitUntil("the monitor to load the persisted history") {
            monitor.clipboardHistory.map(\.id) == [newer.id, original.id]
        }

        // Saving an edit whose text already exists takes the same path as re-copying it: one row
        // replaces the other. It is reachable from a test, where the capture path is not.
        let source = ClipboardItem(id: UUID(), content: "unrelated", type: .text, timestamp: Date())
        let outcome = monitor.saveEditedText(original.fullText, basedOn: source)

        guard case .alreadyInHistory(let replacementID) = outcome, replacementID != original.id else {
            return XCTFail("expected the edit to supersede the row it matched, got \(outcome)")
        }

        try waitUntil("the replacement to be written and the original dropped") {
            recording.calls.contains(.delete([original.id]))
        }

        XCTAssertEqual(
            recording.calls,
            [.save(original.id), .save(newer.id), .save(replacementID), .delete([original.id])],
            "the row it supersedes must be dropped after the replacement is written, never before"
        )

        let stored = persistence.loadClipboardHistory()
        XCTAssertEqual(
            Set(stored.map(\.id)),
            [replacementID, newer.id],
            "the store should hold one row for the re-copied clip, not two and not none"
        )
        let replacement = try XCTUnwrap(stored.first { $0.id == replacementID })
        XCTAssertTrue(replacement.isFavorite, "re-copying a favorite should not cost it its star")
    }

    func testClearingHistoryLeavesFavoritesInMemoryAndOnDisk() throws {
        let favorite = ClipboardItem(
            id: UUID(), content: "pinned", type: .text, timestamp: Self.date(daysAgo: 2), isFavorite: true
        )
        let ordinary = ClipboardItem(
            id: UUID(), content: "passing through", type: .text, timestamp: Self.date(daysAgo: 1)
        )
        persistence.saveClipboardItem(favorite)
        persistence.saveClipboardItem(ordinary)

        let monitor = makeMonitor()
        try waitUntil("the monitor to load both items") { monitor.clipboardHistory.count == 2 }

        monitor.clearHistory()

        try waitUntil("the clear to reach memory and the store") {
            monitor.clipboardHistory.map(\.id) == [favorite.id] && self.storedIDs() == [favorite.id]
        }
    }
}
