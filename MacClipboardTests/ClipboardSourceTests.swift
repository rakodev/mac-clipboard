import AppKit
import XCTest
@testable import MacClipboard

/// The bundle identifier a clip records, and what is shown for it.
///
/// A bundle identifier no app can own, so the "gone from this Mac" path is deterministic rather
/// than dependent on what the machine running the tests happens to have installed.
private let uninstalledBundleIdentifier = "com.macclipboard.tests.no-such-app"

final class ClipboardSourceTests: XCTestCase {

    // MARK: - What Is Worth Recording

    func testNoFrontmostAppRecordsNoSource() {
        // The case this whole attribute has to get right: `NSWorkspace` naming no frontmost app is
        // not an app called "Unknown", it is nothing recorded, and a row shows nothing for it.
        XCTAssertNil(ClipboardSource.storableBundleIdentifier(nil))
    }

    func testProcessWithoutABundleIdentifierRecordsNoSource() {
        // A plain executable or a script has no identifier of its own, and an empty string stored
        // as one would draw a row with a blank name and a placeholder icon.
        XCTAssertNil(ClipboardSource.storableBundleIdentifier(""))
        XCTAssertNil(ClipboardSource.storableBundleIdentifier("   "))
        XCTAssertNil(ClipboardSource.storableBundleIdentifier("\n\t"))
    }

    func testIdentifierIsTrimmedAndOtherwiseKeptVerbatim() {
        XCTAssertEqual(ClipboardSource.storableBundleIdentifier("com.apple.Safari"), "com.apple.Safari")
        XCTAssertEqual(ClipboardSource.storableBundleIdentifier("  com.apple.Safari \n"), "com.apple.Safari")
        // Case is part of a bundle identifier, so it is never folded: the excluded-apps list
        // compares identifiers exactly and these two have to agree about what an identifier is.
        XCTAssertEqual(ClipboardSource.storableBundleIdentifier("COM.APPLE.SAFARI"), "COM.APPLE.SAFARI")
    }

    func testAnItemBuiltWithAnEmptySourceHasNone() {
        let item = ClipboardItem(
            id: UUID(),
            content: "hello",
            type: .text,
            timestamp: Date(),
            sourceBundleIdentifier: "   "
        )

        XCTAssertNil(item.sourceBundleIdentifier)
    }

    func testEveryKindOfClipCanCarryASource() {
        // Unlike the text flavours and the read-from-an-image marker, which are text only: an image
        // and a set of files were copied out of an app just as a sentence was.
        let text = ClipboardItem(id: UUID(), content: "hello", type: .text, timestamp: Date(), sourceBundleIdentifier: "com.apple.Safari")
        let image = ClipboardItem(id: UUID(), content: NSImage(size: NSSize(width: 2, height: 2)), type: .image, timestamp: Date(), sourceBundleIdentifier: "com.apple.Safari")
        let file = ClipboardItem(id: UUID(), content: [URL(fileURLWithPath: "/tmp/a")], type: .file, timestamp: Date(), sourceBundleIdentifier: "com.apple.Safari")

        XCTAssertEqual(text.sourceBundleIdentifier, "com.apple.Safari")
        XCTAssertEqual(image.sourceBundleIdentifier, "com.apple.Safari")
        XCTAssertEqual(file.sourceBundleIdentifier, "com.apple.Safari")
    }

    func testAnItemMadeByTheUserHasNoSource() {
        // An edit, a merge, a split and text read out of an image were all copied out of nothing, so
        // none of them may claim an app. All four go through these builders, which take no source.
        let source = ClipboardItem(id: UUID(), content: "line one\nline two", type: .text, timestamp: Date(), sourceBundleIdentifier: "com.apple.Safari")
        let flags = ClipboardSensitivityFlags(isSensitive: false, isAutoSensitive: false, isPasswordLike: false)

        let edited = ClipboardTextEdit.editedItem(from: source, text: "edited", sensitivity: flags)
        XCTAssertNil(edited.sourceBundleIdentifier)

        let mergePlan = ClipboardMergedCopy.plan(forSelectionIn: [source], selectedIds: [source.id])
        let merged = mergePlan.map { ClipboardMergedCopy.mergedItem(from: $0, sensitivity: flags) }
        XCTAssertNil(merged?.sourceBundleIdentifier)

        let splitPlan = ClipboardTextSplit.plan(for: source)
        let pieces = splitPlan.map { ClipboardTextSplit.items(from: $0) { _ in flags } } ?? []
        XCTAssertFalse(pieces.isEmpty)
        XCTAssertTrue(pieces.allSatisfy { $0.sourceBundleIdentifier == nil })

        let image = ClipboardItem(id: UUID(), content: NSImage(size: NSSize(width: 2, height: 2)), type: .image, timestamp: Date(), sourceBundleIdentifier: "com.apple.Safari")
        let recognizePlan = ClipboardImageTextRecognition.plan(for: image, isRevealed: false)
        let recognized = recognizePlan.map {
            ClipboardImageTextRecognition.recognizedItem(from: $0, text: "read out of it", sensitivity: flags)
        }
        XCTAssertNotNil(recognized)
        XCTAssertNil(recognized?.sourceBundleIdentifier)
    }

    // MARK: - The Capture Guard and the Recorded Source Agree

    func testAClipFromAnExcludedAppIsStillSkippedWhenTheSourceIsRecorded() {
        let decision = ClipboardCapturePolicy.decision(
            hasSensitivePasteboardType: false,
            skipConcealedClips: false,
            sourceBundleIdentifier: ClipboardSource.storableBundleIdentifier("com.apple.Safari"),
            excludedBundleIdentifiers: ["com.apple.Safari"]
        )

        XCTAssertEqual(decision, .skipExcludedApp(bundleIdentifier: "com.apple.Safari"))
    }

    func testWithNoFrontmostAppNothingIsExcludedAndTheClipIsKept() {
        // The guard and the source come off one read, so this is the same nil in both: an unnamed
        // frontmost app can match no exclusion, and the clip is captured with no source.
        let decision = ClipboardCapturePolicy.decision(
            hasSensitivePasteboardType: false,
            skipConcealedClips: false,
            sourceBundleIdentifier: ClipboardSource.storableBundleIdentifier(nil),
            excludedBundleIdentifiers: ["com.apple.Safari"]
        )

        XCTAssertEqual(decision, .capture)
    }

    // MARK: - A Re-Copy Updates the Source

    func testRecopyingFromAnotherAppReplacesTheRowRatherThanKeepingTheOldSource() {
        // Formatting's rule, applied to the source: a re-copy is a property of the copy, so the row
        // has to stop naming the app the user has not copied out of since.
        let existing = ClipboardItem(
            id: UUID(),
            content: "same words",
            type: .text,
            timestamp: Date(timeIntervalSince1970: 1),
            isFavorite: true,
            note: "keep this",
            sourceBundleIdentifier: "com.apple.mail"
        )
        let incoming = ClipboardItem(
            id: UUID(),
            content: "same words",
            type: .text,
            timestamp: Date(timeIntervalSince1970: 2),
            sourceBundleIdentifier: "com.tinyspeck.slackmacgap"
        )

        let result = ClipboardHistoryMerger.inserting(incoming, into: [existing])

        XCTAssertTrue(result.shouldPersistInsertedItem)
        XCTAssertEqual(result.removedItemIDs, [existing.id])
        XCTAssertEqual(result.history[0].sourceBundleIdentifier, "com.tinyspeck.slackmacgap")
        // The user's own decisions about the clip survive it, as they do for a formatting change.
        XCTAssertTrue(result.history[0].isFavorite)
        XCTAssertEqual(result.history[0].note, "keep this")
    }

    func testRecopyingFromTheSameAppAtTheTopChangesNothing() {
        let existing = ClipboardItem(
            id: UUID(),
            content: "same words",
            type: .text,
            timestamp: Date(timeIntervalSince1970: 1),
            sourceBundleIdentifier: "com.apple.mail"
        )
        let incoming = ClipboardItem(
            id: UUID(),
            content: "same words",
            type: .text,
            timestamp: Date(timeIntervalSince1970: 2),
            sourceBundleIdentifier: "com.apple.mail"
        )

        let result = ClipboardHistoryMerger.inserting(incoming, into: [existing])

        XCTAssertFalse(result.shouldPersistInsertedItem)
        XCTAssertTrue(result.removedItemIDs.isEmpty)
        XCTAssertEqual(result.history, [existing])
    }

    func testAnOlderClipRecopiedFromAnotherAppDoesNotInheritItsSource() {
        let existing = ClipboardItem(
            id: UUID(),
            content: "same words",
            type: .text,
            timestamp: Date(timeIntervalSince1970: 1),
            sourceBundleIdentifier: "com.apple.mail"
        )
        let other = ClipboardItem(id: UUID(), content: "unrelated", type: .text, timestamp: Date(timeIntervalSince1970: 2))
        let incoming = ClipboardItem(
            id: UUID(),
            content: "same words",
            type: .text,
            timestamp: Date(timeIntervalSince1970: 3),
            sourceBundleIdentifier: nil
        )

        let result = ClipboardHistoryMerger.inserting(incoming, into: [other, existing])

        // Nothing recorded a source for the new copy, so nothing is shown for it. Falling back to
        // the old row's app would be inventing provenance for a clip that has none.
        XCTAssertNil(result.history[0].sourceBundleIdentifier)
    }

    // MARK: - Resolving a Name at Display Time

    func testAnUninstalledAppReadsAsItsIdentifier() {
        let app = ClipboardSourceAppCatalog.app(for: uninstalledBundleIdentifier)

        XCTAssertEqual(app.bundleIdentifier, uninstalledBundleIdentifier)
        XCTAssertEqual(app.name, uninstalledBundleIdentifier)
        XCTAssertFalse(app.isInstalled)
        // No icon, which is the row's cue to draw the placeholder rather than a stand-in that would
        // look like a real app.
        XCTAssertNil(ClipboardSourceAppCatalog.icon(for: uninstalledBundleIdentifier))
    }

    func testAnInstalledAppReadsAsItsName() {
        // Finder is the one app that cannot be missing from a Mac running these tests.
        let app = ClipboardSourceAppCatalog.app(for: "com.apple.finder")

        XCTAssertTrue(app.isInstalled)
        XCTAssertFalse(app.name.isEmpty)
        XCTAssertNotEqual(app.name, "com.apple.finder")
        XCTAssertNotNil(ClipboardSourceAppCatalog.icon(for: "com.apple.finder"))
    }

    func testResolutionSurvivesInvalidation() {
        let before = ClipboardSourceAppCatalog.app(for: "com.apple.finder")
        ClipboardSourceAppCatalog.invalidate()
        let after = ClipboardSourceAppCatalog.app(for: "com.apple.finder")

        XCTAssertEqual(before, after)
    }

    // MARK: - Searching by Source

    func testSearchMatchesTheNameTheRowShows() {
        let fromSlack = ClipboardItem(
            id: UUID(),
            content: "the standup notes",
            type: .text,
            timestamp: Date(timeIntervalSince1970: 2),
            sourceBundleIdentifier: "com.tinyspeck.slackmacgap"
        )
        let fromMail = ClipboardItem(
            id: UUID(),
            content: "an address",
            type: .text,
            timestamp: Date(timeIntervalSince1970: 1),
            sourceBundleIdentifier: "com.apple.mail"
        )
        let names = ["com.tinyspeck.slackmacgap": "Slack", "com.apple.mail": "Mail"]

        let result = ClipboardFilter.filteredItems(
            from: [fromSlack, fromMail],
            selectedFilter: .all,
            searchText: "slack",
            sourceAppName: { names[$0] }
        )

        XCTAssertEqual(result.map(\.id), [fromSlack.id])
    }

    func testSearchDoesNotMatchTheBundleIdentifierOfAnInstalledApp() {
        // "com.google.Chrome" would otherwise make a search for "google", or for "com", return
        // every clip copied out of Chrome.
        let item = ClipboardItem(
            id: UUID(),
            content: "nothing to do with the vendor",
            type: .text,
            timestamp: Date(),
            sourceBundleIdentifier: "com.google.Chrome"
        )

        let result = ClipboardFilter.filteredItems(
            from: [item],
            selectedFilter: .all,
            searchText: "google",
            sourceAppName: { _ in "Chrome" }
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testAClipWithNoSourceIsNeverMatchedBySourceSearch() {
        let item = ClipboardItem(id: UUID(), content: "a clip from before this shipped", type: .text, timestamp: Date())

        let result = ClipboardFilter.filteredItems(
            from: [item],
            selectedFilter: .all,
            searchText: "Slack",
            sourceAppName: { _ in "Slack" }
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testSourceSearchIsAddedToContentSearchRatherThanReplacingIt() {
        let byContent = ClipboardItem(
            id: UUID(),
            content: "mail the invoice",
            type: .text,
            timestamp: Date(timeIntervalSince1970: 2),
            sourceBundleIdentifier: "com.tinyspeck.slackmacgap"
        )
        let bySource = ClipboardItem(
            id: UUID(),
            content: "an address",
            type: .text,
            timestamp: Date(timeIntervalSince1970: 1),
            sourceBundleIdentifier: "com.apple.mail"
        )
        let names = ["com.tinyspeck.slackmacgap": "Slack", "com.apple.mail": "Mail"]

        let result = ClipboardFilter.filteredItems(
            from: [byContent, bySource],
            selectedFilter: .all,
            searchText: "mail",
            sourceAppName: { names[$0] }
        )

        XCTAssertEqual(Set(result.map(\.id)), [byContent.id, bySource.id])
    }

    // MARK: - Filtering by Source

    func testTheSourceFilterKeepsOnlyThatAppsClips() {
        let fromSlack = ClipboardItem(id: UUID(), content: "a", type: .text, timestamp: Date(timeIntervalSince1970: 3), sourceBundleIdentifier: "com.tinyspeck.slackmacgap")
        let fromMail = ClipboardItem(id: UUID(), content: "b", type: .text, timestamp: Date(timeIntervalSince1970: 2), sourceBundleIdentifier: "com.apple.mail")
        let noSource = ClipboardItem(id: UUID(), content: "c", type: .text, timestamp: Date(timeIntervalSince1970: 1))

        let result = ClipboardFilter.filteredItems(
            from: [fromSlack, fromMail, noSource],
            selectedFilter: .all,
            searchText: "",
            sourceBundleIdentifier: "com.tinyspeck.slackmacgap"
        )

        XCTAssertEqual(result.map(\.id), [fromSlack.id])
    }

    func testTheSourceFilterIsExactWhereTheSearchIsNot() {
        // The whole reason both exist. Typing "Mail" is a find over everything a row shows and turns
        // up the clip that merely says the word; the filter is "only the clips from that app".
        let mentionsMail = ClipboardItem(id: UUID(), content: "mail the invoice", type: .text, timestamp: Date(timeIntervalSince1970: 2), sourceBundleIdentifier: "com.tinyspeck.slackmacgap")
        let fromMail = ClipboardItem(id: UUID(), content: "an address", type: .text, timestamp: Date(timeIntervalSince1970: 1), sourceBundleIdentifier: "com.apple.mail")
        let items = [mentionsMail, fromMail]
        let names = ["com.tinyspeck.slackmacgap": "Slack", "com.apple.mail": "Mail"]

        let searched = ClipboardFilter.filteredItems(from: items, selectedFilter: .all, searchText: "mail", sourceAppName: { names[$0] })
        XCTAssertEqual(Set(searched.map(\.id)), [mentionsMail.id, fromMail.id])

        let filtered = ClipboardFilter.filteredItems(from: items, selectedFilter: .all, searchText: "", sourceBundleIdentifier: "com.apple.mail")
        XCTAssertEqual(filtered.map(\.id), [fromMail.id])
    }

    func testTheSourceFilterCombinesWithTheTabAndTheSearch() {
        let wanted = ClipboardItem(id: UUID(), content: "quarterly report", type: .text, timestamp: Date(timeIntervalSince1970: 3), isFavorite: true, sourceBundleIdentifier: "com.apple.mail")
        let notFavorite = ClipboardItem(id: UUID(), content: "quarterly report", type: .text, timestamp: Date(timeIntervalSince1970: 2), sourceBundleIdentifier: "com.apple.mail")
        let otherText = ClipboardItem(id: UUID(), content: "something else", type: .text, timestamp: Date(timeIntervalSince1970: 1), isFavorite: true, sourceBundleIdentifier: "com.apple.mail")
        let otherApp = ClipboardItem(id: UUID(), content: "quarterly report", type: .text, timestamp: Date(timeIntervalSince1970: 0), isFavorite: true, sourceBundleIdentifier: "com.tinyspeck.slackmacgap")

        let result = ClipboardFilter.filteredItems(
            from: [wanted, notFavorite, otherText, otherApp],
            selectedFilter: .favorites,
            searchText: "quarterly",
            sourceBundleIdentifier: "com.apple.mail",
            sourceAppName: { _ in nil }
        )

        XCTAssertEqual(result.map(\.id), [wanted.id])
    }

    func testNoSourceFilterLeavesEveryItemAlone() {
        let withSource = ClipboardItem(id: UUID(), content: "a", type: .text, timestamp: Date(timeIntervalSince1970: 2), sourceBundleIdentifier: "com.apple.mail")
        let without = ClipboardItem(id: UUID(), content: "b", type: .text, timestamp: Date(timeIntervalSince1970: 1))

        let result = ClipboardFilter.filteredItems(from: [withSource, without], selectedFilter: .all, searchText: "")

        XCTAssertEqual(result.map(\.id), [withSource.id, without.id])
    }

    func testFilteringByAnAppWithNothingInTheListGivesNothing() {
        // The menu is built from the apps present so this cannot be picked, but the state can
        // outlive the clips: filtering to Slack and then deleting the last Slack clip lands here.
        let item = ClipboardItem(id: UUID(), content: "a", type: .text, timestamp: Date(), sourceBundleIdentifier: "com.apple.mail")

        let result = ClipboardFilter.filteredItems(
            from: [item],
            selectedFilter: .all,
            searchText: "",
            sourceBundleIdentifier: "com.tinyspeck.slackmacgap"
        )

        XCTAssertTrue(result.isEmpty)
    }
}

/// The attribute is optional and nothing migrates it, so what a store gives back for a row written
/// before it existed is the part worth pinning.
final class ClipboardSourceStoreTests: StoreBackedTestCase {

    func testASourceSurvivesTheStore() {
        let item = ClipboardItem(
            id: UUID(),
            content: "copied out of Mail",
            type: .text,
            timestamp: Date(),
            sourceBundleIdentifier: "com.apple.mail"
        )
        persistence.saveClipboardItem(item)

        let loaded = persistence.loadClipboardHistory().first { $0.id == item.id }

        XCTAssertEqual(loaded?.sourceBundleIdentifier, "com.apple.mail")
    }

    func testAnImageKeepsItsSourceToo() {
        let item = ClipboardItem(
            id: UUID(),
            content: Self.image(size: 8),
            type: .image,
            timestamp: Date(),
            sourceBundleIdentifier: "com.apple.Safari"
        )
        persistence.saveClipboardItem(item, saveImages: true)

        let loaded = persistence.loadClipboardHistory().first { $0.id == item.id }

        XCTAssertEqual(loaded?.sourceBundleIdentifier, "com.apple.Safari")
    }

    func testARowWithNoSourceLoadsWithNone() {
        // What every clip captured before this shipped looks like on the next launch: the column is
        // simply null, and the row shows nothing rather than an app it cannot name.
        let item = ClipboardItem(id: UUID(), content: "from before", type: .text, timestamp: Date())
        persistence.saveClipboardItem(item)

        let loaded = persistence.loadClipboardHistory().first { $0.id == item.id }

        XCTAssertNotNil(loaded)
        XCTAssertNil(loaded?.sourceBundleIdentifier)
    }
}
