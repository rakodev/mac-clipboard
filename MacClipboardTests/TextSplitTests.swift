import AppKit
import XCTest
@testable import MacClipboard

final class ClipboardTextSplitPlanTests: XCTestCase {

    // MARK: - What becomes a piece

    func testSplitsOnLineEndingsInReadingOrder() {
        let plan = ClipboardTextSplit.plan(for: Self.text("Ada\nGrace\nAlan"))

        XCTAssertEqual(plan?.pieces, ["Ada", "Grace", "Alan"])
        XCTAssertEqual(plan?.pieceCount, 3)
        XCTAssertEqual(plan?.droppedBlankLineCount, 0)
    }

    func testLinesAreNotTrimmed() {
        // Whitespace inside a clip is content, as it is in the editor: the leading tab on a line
        // pasted back into a code block is usually the point of it.
        let plan = ClipboardTextSplit.plan(for: Self.text("\tindented \nplain\t"))

        XCTAssertEqual(plan?.pieces, ["\tindented ", "plain\t"])
    }

    func testBlankAndWhitespaceOnlyLinesAreDropped() {
        // A run of tabs between two blocks is a blank line, not a clip: it would arrive as a row
        // showing nothing, indistinguishable from an empty one.
        let plan = ClipboardTextSplit.plan(for: Self.text("first\n\nsecond\n \t \nthird\n"))

        XCTAssertEqual(plan?.pieces, ["first", "second", "third"])
        XCTAssertEqual(plan?.droppedBlankLineCount, 3)
    }

    func testCRLFAndBareCRProduceNoEmptyPieces() {
        let plan = ClipboardTextSplit.plan(for: Self.text("one\r\ntwo\rthree"))

        XCTAssertEqual(plan?.pieces, ["one", "two", "three"])
    }

    // MARK: - When there is nothing to split

    func testSingleLineTextIsNoPlan() {
        XCTAssertNil(ClipboardTextSplit.plan(for: Self.text("just the one line")))
        XCTAssertNil(ClipboardTextSplit.plan(for: Self.text("")))
        // Two lines, but only one of them carries anything, so splitting would produce the item
        // the user already has.
        XCTAssertNil(ClipboardTextSplit.plan(for: Self.text("alone\n\n   \n")))
    }

    func testNoSelectionIsNoPlan() {
        XCTAssertNil(ClipboardTextSplit.plan(for: nil))
    }

    func testNonTextItemsAreNeverSplit() {
        // `fullText` answers for every kind of item, so the type check is what stops an image with
        // multi-line associated text offering to be split into clips the row never claimed to hold.
        let image = ClipboardItem(
            id: UUID(),
            content: Self.makeImage(),
            type: .image,
            timestamp: Date(),
            associatedText: "recognised\ntext\nlines"
        )
        let files = ClipboardItem(
            id: UUID(),
            content: [URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b")],
            type: .file,
            timestamp: Date()
        )

        XCTAssertNil(ClipboardTextSplit.plan(for: image))
        XCTAssertNil(ClipboardTextSplit.plan(for: files))
    }

    // MARK: - The count cap

    func testConfirmationIsAskedForOnlyAboveTheThreshold() {
        let atThreshold = Self.lines(ClipboardTextSplit.confirmationThreshold)
        let aboveThreshold = Self.lines(ClipboardTextSplit.confirmationThreshold + 1)

        XCTAssertEqual(ClipboardTextSplit.plan(for: atThreshold)?.needsConfirmation, false)
        XCTAssertEqual(ClipboardTextSplit.plan(for: aboveThreshold)?.needsConfirmation, true)
    }

    // MARK: - The items the plan produces

    func testPiecesAreProducedInReadingOrderNewestFirst() {
        let plan = ClipboardTextSplit.plan(for: Self.text("first\nsecond\nthird"))!

        let items = ClipboardTextSplit.items(
            from: plan,
            sensitivity: { _ in Self.noFlags },
            timestamp: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(items.map { $0.content as? String }, ["first", "second", "third"])
        // The array order decides where they land while the popover is open; these decide the order
        // they come back in after a relaunch, and the two have to agree that the first line is the
        // newest item.
        XCTAssertGreaterThan(items[0].timestamp, items[1].timestamp)
        XCTAssertGreaterThan(items[1].timestamp, items[2].timestamp)
    }

    func testPiecesInheritNothingButMasking() {
        let source = ClipboardItem(
            id: UUID(),
            content: "one\ntwo",
            type: .text,
            timestamp: Date(),
            isFavorite: true,
            note: "a note about the whole clip",
            rtfData: Self.rtf("one\ntwo"),
            htmlData: Data("<p>one</p>".utf8)
        )
        let plan = ClipboardTextSplit.plan(for: source)!

        let items = ClipboardTextSplit.items(from: plan, sensitivity: { _ in Self.noFlags })

        for item in items {
            XCTAssertFalse(item.isFavorite)
            XCTAssertNil(item.note)
            // A line out of the middle of an RTF or HTML document is not a document, and the row's
            // marker promises the formatting the clip was copied with.
            XCTAssertNil(item.rtfData)
            XCTAssertNil(item.htmlData)
            XCTAssertFalse(item.carriesFormatting)
        }
    }

    func testAMaskedSourceCannotProduceVisiblePieces() {
        let plan = ClipboardTextSplit.plan(for: Self.text("harmless\nalso harmless", isSensitive: true))!

        let items = ClipboardTextSplit.items(from: plan, sensitivity: { _ in Self.noFlags })

        XCTAssertEqual(items.filter { $0.isSensitive }.count, 2)
    }

    func testThePolicyIsRunPerPieceSoOneSecretDoesNotMaskTheRest() {
        let plan = ClipboardTextSplit.plan(for: Self.text("username\nhunter2!Aa\nemail"))!

        let items = ClipboardTextSplit.items(from: plan) { piece in
            piece == "hunter2!Aa"
                ? ClipboardSensitivityFlags(isSensitive: true, isAutoSensitive: false, isPasswordLike: true)
                : Self.noFlags
        }

        XCTAssertEqual(items.map(\.isSensitive), [false, true, false])
        XCTAssertEqual(items.map(\.isPasswordLike), [false, true, false])
        XCTAssertFalse(items[1].isManuallyUnsensitive)
    }

    // MARK: - The action's title and the confirmation

    func testActionTitleStatesTheCountAndWhichItemItTakes() {
        let plan = ClipboardTextSplit.plan(for: Self.text("a\nb\nc"))

        XCTAssertEqual(ClipboardTextSplitContent.actionTitle(for: plan), "Split Selected Item into 3 Items")
    }

    func testActionTitleExplainsItselfWithNothingToSplit() {
        XCTAssertEqual(
            ClipboardTextSplitContent.actionTitle(for: nil),
            "Split into Lines (Select a Multi-Line Text Item)"
        )
    }

    func testConfirmationNamesTheHistoryLimitOnlyWhenTheSplitWouldReachIt() {
        let underTheLimit = ClipboardTextSplitContent.confirmationMessage(pieceCount: 120, historyLimit: 200)
        let overTheLimit = ClipboardTextSplitContent.confirmationMessage(pieceCount: 240, historyLimit: 200)

        XCTAssertEqual(
            underTheLimit,
            "This adds 120 items to your history, one per line, and leaves the original item as it is."
        )
        XCTAssertTrue(overTheLimit.hasPrefix("This adds 240 items to your history, one per line,"))
        XCTAssertTrue(overTheLimit.contains("keeps 200 items"))
    }

    // MARK: - Helpers

    private static let noFlags = ClipboardSensitivityFlags(isSensitive: false, isAutoSensitive: false, isPasswordLike: false)

    private static func text(_ content: String, isSensitive: Bool = false) -> ClipboardItem {
        ClipboardItem(
            id: UUID(),
            content: content,
            type: .text,
            timestamp: Date(timeIntervalSince1970: 0),
            isSensitive: isSensitive
        )
    }

    private static func lines(_ count: Int) -> ClipboardItem {
        text((1...count).map { "line \($0)" }.joined(separator: "\n"))
    }

    private static func rtf(_ string: String) -> Data {
        let attributed = NSAttributedString(string: string)
        return attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:])!
    }

    private static func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        return image
    }
}
