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