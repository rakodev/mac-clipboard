import AppKit
import XCTest
@testable import MacClipboard

final class ClipboardHistoryMergerTests: XCTestCase {
    func testDuplicateTextPreservesMetadataAndMovesToTop() {
        let existingID = UUID()
        let existing = ClipboardItem(
            id: existingID,
            content: "repeat me",
            type: .text,
            timestamp: Date(timeIntervalSince1970: 1),
            isFavorite: true,
            isSensitive: true,
            isAutoSensitive: true,
            isPasswordLike: true,
            isManuallyUnsensitive: true,
            note: "keep this"
        )
        let other = ClipboardItem(id: UUID(), content: "other", type: .text, timestamp: Date(timeIntervalSince1970: 2))
        let incoming = ClipboardItem(id: UUID(), content: "repeat me", type: .text, timestamp: Date(timeIntervalSince1970: 3))

        let result = ClipboardHistoryMerger.inserting(incoming, into: [other, existing])

        XCTAssertTrue(result.shouldPersistInsertedItem)
        XCTAssertEqual(result.removedItemIDs, [existingID])
        XCTAssertEqual(result.history.map(\.id), [incoming.id, other.id])
        XCTAssertEqual(result.history[0].content as? String, "repeat me")
        XCTAssertTrue(result.history[0].isFavorite)
        XCTAssertTrue(result.history[0].isSensitive)
        XCTAssertTrue(result.history[0].isAutoSensitive)
        XCTAssertTrue(result.history[0].isPasswordLike)
        XCTAssertTrue(result.history[0].isManuallyUnsensitive)
        XCTAssertEqual(result.history[0].note, "keep this")
    }

    func testDuplicateAtTopDoesNotMoveOrPersistAgain() {
        let existing = ClipboardItem(
            id: UUID(),
            content: "already first",
            type: .text,
            timestamp: Date(timeIntervalSince1970: 1),
            isFavorite: true,
            note: "top"
        )
        let incoming = ClipboardItem(id: UUID(), content: "already first", type: .text, timestamp: Date(timeIntervalSince1970: 2))

        let result = ClipboardHistoryMerger.inserting(incoming, into: [existing])

        XCTAssertFalse(result.shouldPersistInsertedItem)
        XCTAssertTrue(result.removedItemIDs.isEmpty)
        XCTAssertEqual(result.history, [existing])
    }

    func testDuplicateImagePreservesMetadataAndAssociatedText() {
        let image = Self.makeImage()
        let existingID = UUID()
        let existing = ClipboardItem(
            id: existingID,
            content: image,
            type: .image,
            timestamp: Date(timeIntervalSince1970: 1),
            isFavorite: true,
            isSensitive: true,
            isAutoSensitive: true,
            isPasswordLike: true,
            isManuallyUnsensitive: true,
            note: "image note",
            associatedText: "alt text"
        )
        let other = ClipboardItem(id: UUID(), content: "other", type: .text, timestamp: Date(timeIntervalSince1970: 2))
        let incoming = ClipboardItem(id: UUID(), content: image, type: .image, timestamp: Date(timeIntervalSince1970: 3))

        let result = ClipboardHistoryMerger.inserting(incoming, into: [other, existing])

        XCTAssertTrue(result.shouldPersistInsertedItem)
        XCTAssertEqual(result.removedItemIDs, [existingID])
        XCTAssertEqual(result.history.map(\.id), [incoming.id, other.id])
        XCTAssertTrue(result.history[0].isFavorite)
        XCTAssertTrue(result.history[0].isSensitive)
        XCTAssertTrue(result.history[0].isAutoSensitive)
        XCTAssertTrue(result.history[0].isPasswordLike)
        XCTAssertTrue(result.history[0].isManuallyUnsensitive)
        XCTAssertEqual(result.history[0].note, "image note")
        XCTAssertEqual(result.history[0].associatedText, "alt text")
    }

    func testDuplicateFilePreservesMetadataAndMovesToTop() {
        let fileURL = URL(fileURLWithPath: "/tmp/MacClipboardTest.txt")
        let existingID = UUID()
        let existing = ClipboardItem(
            id: existingID,
            content: [fileURL],
            type: .file,
            timestamp: Date(timeIntervalSince1970: 1),
            displayText: "MacClipboardTest.txt",
            isFavorite: true,
            isSensitive: true,
            isAutoSensitive: true,
            isManuallyUnsensitive: true,
            note: "file note"
        )
        let other = ClipboardItem(id: UUID(), content: "other", type: .text, timestamp: Date(timeIntervalSince1970: 2))
        let incoming = ClipboardItem(id: UUID(), content: [fileURL], type: .file, timestamp: Date(timeIntervalSince1970: 3))

        let result = ClipboardHistoryMerger.inserting(incoming, into: [other, existing])

        XCTAssertTrue(result.shouldPersistInsertedItem)
        XCTAssertEqual(result.removedItemIDs, [existingID])
        XCTAssertEqual(result.history.map(\.id), [incoming.id, other.id])
        XCTAssertTrue(result.history[0].isFavorite)
        XCTAssertTrue(result.history[0].isSensitive)
        XCTAssertTrue(result.history[0].isAutoSensitive)
        XCTAssertTrue(result.history[0].isManuallyUnsensitive)
        XCTAssertEqual(result.history[0].note, "file note")
    }

    private static func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 4, height: 4)).fill()
        image.unlockFocus()
        return image
    }
}

final class ClipboardTextEditTests: XCTestCase {
    func testIntentDistinguishesEmptyUnchangedAndSave() {
        XCTAssertEqual(ClipboardTextEdit.intent(newText: "", sourceText: "original"), .empty)
        XCTAssertEqual(ClipboardTextEdit.intent(newText: "original", sourceText: "original"), .unchanged)
        XCTAssertEqual(ClipboardTextEdit.intent(newText: "edited", sourceText: "original"), .save)
    }

    func testIntentTreatsWhitespaceOnlyChangesAsAnEdit() {
        // Whitespace is content in a clip, so " original " is not the same text as "original".
        XCTAssertEqual(ClipboardTextEdit.intent(newText: " original ", sourceText: "original"), .save)
        XCTAssertEqual(ClipboardTextEdit.intent(newText: "   ", sourceText: "original"), .save)
    }

    func testEditedItemPreservesWhitespaceExactly() {
        let source = ClipboardItem(id: UUID(), content: "before", type: .text, timestamp: Date())

        let edited = ClipboardTextEdit.editedItem(
            from: source,
            text: "  padded line\n\n",
            sensitivity: Self.noFlags
        )

        XCTAssertEqual(edited.content as? String, "  padded line\n\n")
        XCTAssertEqual(edited.type, .text)
    }

    func testEditedItemDoesNotInheritFavoriteOrNote() {
        let source = ClipboardItem(
            id: UUID(),
            content: "before",
            type: .text,
            timestamp: Date(),
            isFavorite: true,
            note: "source note"
        )

        let edited = ClipboardTextEdit.editedItem(from: source, text: "after", sensitivity: Self.noFlags)

        XCTAssertNotEqual(edited.id, source.id)
        XCTAssertFalse(edited.isFavorite)
        XCTAssertNil(edited.note)
    }

    func testEditingAHiddenItemKeepsTheCopyHidden() {
        // The edited text triggers nothing on its own, so only the source's own flag can mask it.
        let source = ClipboardItem(
            id: UUID(),
            content: "sk-livekeythatwasdetected0000",
            type: .text,
            timestamp: Date(),
            isSensitive: true,
            isAutoSensitive: true
        )

        let edited = ClipboardTextEdit.editedItem(from: source, text: "harmless note", sensitivity: Self.noFlags)

        XCTAssertTrue(edited.isSensitive)
        XCTAssertFalse(edited.isAutoSensitive)
        XCTAssertFalse(edited.isManuallyUnsensitive)
    }

    func testEditingIntoASecretHidesTheCopy() {
        let source = ClipboardItem(id: UUID(), content: "harmless", type: .text, timestamp: Date())
        let secret = "AKIAIOSFODNN7EXAMPLE"
        let sensitivity = ClipboardSensitivityPolicy.flags(
            for: secret,
            hasSensitivePasteboardType: false,
            autoDetectSensitiveData: true,
            autoHidePasswordLikeStrings: true
        )

        let edited = ClipboardTextEdit.editedItem(from: source, text: secret, sensitivity: sensitivity)

        XCTAssertTrue(edited.isSensitive)
        XCTAssertTrue(edited.isAutoSensitive)
    }

    private static let noFlags = ClipboardSensitivityFlags(
        isSensitive: false,
        isAutoSensitive: false,
        isPasswordLike: false
    )
}

final class ClipboardTimeAgoTests: XCTestCase {
    /// Items that arrive while the popover is open used to render as "unknown", which is what an
    /// edit saved as a new item always was: it is created while the user is looking at the list.
    func testAnItemJustCreatedReadsAsNow() {
        let now = Date()
        let formatter = ClipboardTimeAgo.makeFormatter()

        XCTAssertEqual(ClipboardTimeAgo.string(for: now, relativeTo: now, formatter: formatter), "now")
        XCTAssertEqual(ClipboardTimeAgo.string(for: now.addingTimeInterval(-1), relativeTo: now, formatter: formatter), "now")
    }

    func testATimestampAheadOfTheReferenceAlsoReadsAsNow() {
        let now = Date()
        let formatter = ClipboardTimeAgo.makeFormatter()

        XCTAssertEqual(ClipboardTimeAgo.string(for: now.addingTimeInterval(30), relativeTo: now, formatter: formatter), "now")
    }

    func testOlderItemsAreFormattedRelatively() {
        let now = Date()
        let formatter = ClipboardTimeAgo.makeFormatter()

        for age in [ClipboardTimeAgo.nowThreshold, 60, 3600, 86_400] as [TimeInterval] {
            let text = ClipboardTimeAgo.string(for: now.addingTimeInterval(-age), relativeTo: now, formatter: formatter)
            XCTAssertNotEqual(text, "now", "\(age)s old should carry a relative time")
            XCTAssertFalse(text.isEmpty)
            XCTAssertNotEqual(text, "unknown")
        }
    }
}

final class ClipboardPreviewClickTests: XCTestCase {
    func testAPlainClickOpensTheEditor() {
        XCTAssertTrue(ClipboardPreviewClick.opensEditor(selectionLength: 0, modifiers: []))
    }

    func testASelectionStaysInThePreview() {
        // Dragging, double clicking and triple clicking all leave something selected: the user is
        // selecting text to copy, not asking to edit.
        XCTAssertFalse(ClipboardPreviewClick.opensEditor(selectionLength: 12, modifiers: []))
    }

    func testModifiedClicksStayInThePreview() {
        for modifier in [NSEvent.ModifierFlags.command, .shift, .option, .control] {
            XCTAssertFalse(
                ClipboardPreviewClick.opensEditor(selectionLength: 0, modifiers: modifier),
                "\(modifier) is a selection gesture, not an edit"
            )
        }
    }

    func testUnrelatedModifiersStillOpenTheEditor() {
        XCTAssertTrue(ClipboardPreviewClick.opensEditor(selectionLength: 0, modifiers: [.capsLock, .function]))
    }
}

final class ClipboardTextViewCaretTests: XCTestCase {
    /// The click point handed to `characterIndexForInsertion(at:)` is in view coordinates, so it has
    /// to include the text container origin. Getting that wrong puts the caret a line or a few
    /// characters away from where the user clicked, which is the whole point of the feature.
    ///
    /// The index is a caret position, not a character: it snaps to the nearest character boundary,
    /// so a click lands before or after the glyph depending on which half was hit.
    func testAClickOnAGlyphMapsToTheBoundaryItIsNearest() throws {
        let text = "first line\nsecond line\nthird line"
        let textView = Self.makeTextView(text: text)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: container)

        // The "s" that starts "second line", i.e. the character after the first newline.
        let target = NSRange(location: 11, length: 1)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: target, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        let origin = textView.textContainerOrigin

        let leadingEdge = NSPoint(x: rect.minX + 1 + origin.x, y: rect.midY + origin.y)
        XCTAssertEqual(textView.characterIndexForInsertion(at: leadingEdge), 11)

        let trailingEdge = NSPoint(x: rect.maxX - 1 + origin.x, y: rect.midY + origin.y)
        XCTAssertEqual(textView.characterIndexForInsertion(at: trailingEdge), 12)
    }

    func testAPointPastTheEndMapsToTheEndOfTheText() {
        let text = "one\ntwo"
        let textView = Self.makeTextView(text: text)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)

        let point = NSPoint(x: 380, y: 190)

        XCTAssertEqual(textView.characterIndexForInsertion(at: point), (text as NSString).length)
    }

    private static func makeTextView(text: String) -> CallbackTextView {
        // Configured the way ClipboardTextView configures it, inset included.
        let textView = CallbackTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.string = text
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 2, height: 3)
        textView.textContainer?.widthTracksTextView = true
        return textView
    }
}

final class ClipboardFilterTests: XCTestCase {
    func testSelectedFilterLimitsItemsByTab() {
        let favorite = ClipboardItem(id: UUID(), content: "favorite", type: .text, timestamp: Date(), isFavorite: true)
        let hidden = ClipboardItem(id: UUID(), content: "hidden", type: .text, timestamp: Date(), isSensitive: true)
        let image = ClipboardItem(id: UUID(), content: NSImage(size: NSSize(width: 4, height: 4)), type: .image, timestamp: Date())

        XCTAssertEqual(ClipboardFilter.filteredItems(from: [favorite, hidden, image], selectedFilter: .favorites, searchText: ""), [favorite])
        XCTAssertEqual(ClipboardFilter.filteredItems(from: [favorite, hidden, image], selectedFilter: .hidden, searchText: ""), [hidden])
        XCTAssertEqual(ClipboardFilter.filteredItems(from: [favorite, hidden, image], selectedFilter: .images, searchText: ""), [image])
    }

    func testSearchMatchesPreviewFullTextAndNotesWithPrioritySort() {
        let plainMatch = ClipboardItem(id: UUID(), content: "alpha plain", type: .text, timestamp: Date())
        let favoriteMatch = ClipboardItem(id: UUID(), content: "alpha favorite", type: .text, timestamp: Date(), isFavorite: true)
        let noteMatch = ClipboardItem(id: UUID(), content: "unrelated", type: .text, timestamp: Date(), note: "alpha note")

        let result = ClipboardFilter.filteredItems(
            from: [plainMatch, noteMatch, favoriteMatch],
            selectedFilter: .all,
            searchText: "alpha"
        )

        XCTAssertEqual(result, [favoriteMatch, noteMatch, plainMatch])
    }
}

final class ClipboardDeletionConfirmationContentTests: XCTestCase {
    func testDeleteConfirmationContentForCurrentOrAllMode() {
        XCTAssertEqual(ClipboardDeletionConfirmationContent.deleteTitle(selectedCount: 0), "Delete Items")
        XCTAssertEqual(
            ClipboardDeletionConfirmationContent.deleteMessage(selectedCount: 0),
            "Choose to delete the currently previewed item or clear all history."
        )
        XCTAssertEqual(ClipboardDeletionConfirmationContent.deleteAllChoiceTitle(itemCount: 42), "Delete All 42 Items...")
        XCTAssertEqual(ClipboardDeletionConfirmationContent.deleteAllTitle(itemCount: 42), "Delete All 42 Items?")
        XCTAssertEqual(
            ClipboardDeletionConfirmationContent.deleteAllMessage(itemCount: 42),
            "Are you sure? This will permanently delete 42 items from your clipboard history. Favorites are kept, so unstar anything you also want removed. This action cannot be undone."
        )
    }

    func testDeleteConfirmationContentForSelectedItems() {
        XCTAssertEqual(ClipboardDeletionConfirmationContent.deleteTitle(selectedCount: 1), "Delete Selected Items?")
        XCTAssertEqual(ClipboardDeletionConfirmationContent.selectedDeleteButtonTitle(selectedCount: 1), "Delete 1 Item")
        XCTAssertEqual(
            ClipboardDeletionConfirmationContent.deleteMessage(selectedCount: 1),
            "This will permanently delete 1 selected item. This action cannot be undone."
        )

        XCTAssertEqual(ClipboardDeletionConfirmationContent.selectedDeleteButtonTitle(selectedCount: 3), "Delete 3 Items")
        XCTAssertEqual(
            ClipboardDeletionConfirmationContent.deleteMessage(selectedCount: 3),
            "This will permanently delete 3 selected items. This action cannot be undone."
        )
    }
}