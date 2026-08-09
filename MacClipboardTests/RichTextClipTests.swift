import AppKit
import XCTest
@testable import MacClipboard

/// The formatting a text clip carries beside its plain text.
///
/// Nothing here touches `NSPasteboard`: it is shared machine state, so a test that wrote to it
/// would put its fixtures on the developer's own clipboard and race the running dev build's
/// polling. `ClipboardRichText` exists as a value-level seam for exactly that reason, and the
/// pasteboard-facing half is a checklist item in `CLAUDE.md` instead.
final class ClipboardRichTextTests: XCTestCase {

    // MARK: - Fixtures

    /// Real RTF, produced the way a source app produces it rather than written by hand, so the
    /// signature check is tested against bytes AppKit would actually put on the pasteboard.
    static func rtf(_ text: String, bold: Bool = true) -> Data {
        let font = bold
            ? NSFont.boldSystemFont(ofSize: 13)
            : NSFont.systemFont(ofSize: 13)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        return attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:])!
    }

    /// Valid RTF padded to exactly `byteCount` bytes, for the cap.
    static func rtf(ofExactly byteCount: Int) -> Data {
        let prefix = Data("{\\rtf1\\ansi ".utf8)
        let suffix = Data("}".utf8)
        let padding = Data(repeating: UInt8(ascii: "a"), count: byteCount - prefix.count - suffix.count)
        let data = prefix + padding + suffix
        precondition(data.count == byteCount)
        return data
    }

    // MARK: - What is worth storing

    func testRealRTFIsStored() {
        let data = Self.rtf("styled")
        XCTAssertEqual(ClipboardRichText.storableRTF(data), data)
    }

    func testNothingOnThePasteboardStoresNothing() {
        XCTAssertNil(ClipboardRichText.storableRTF(nil))
        XCTAssertNil(ClipboardRichText.storableRTF(Data()))
    }

    /// The marker in the row says an item keeps its formatting, so it may only be shown for bytes
    /// that are actually RTF. A pasteboard can carry anything under any type.
    func testBytesThatAreNotRTFAreRefused() {
        XCTAssertNil(ClipboardRichText.storableRTF(Data("<html><b>bold</b></html>".utf8)))
        XCTAssertNil(ClipboardRichText.storableRTF(Data("plain text".utf8)))
        XCTAssertNil(ClipboardRichText.storableRTF(Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])))
        // Shorter than the signature itself: the length guard, not the comparison.
        XCTAssertNil(ClipboardRichText.storableRTF(Data("{\\rt".utf8)))
    }

    func testRTFExactlyAtTheCapIsStored() {
        let data = Self.rtf(ofExactly: ClipboardRichText.maxBytes)
        XCTAssertEqual(ClipboardRichText.storableRTF(data)?.count, ClipboardRichText.maxBytes)
    }

    /// One byte over and the formatting is dropped. The clip itself is unaffected: the capture path
    /// builds a text item either way, so refusing formatting never loses what was copied.
    func testRTFOverTheCapIsDroppedRatherThanStored() {
        let data = Self.rtf(ofExactly: ClipboardRichText.maxBytes + 1)
        XCTAssertNil(ClipboardRichText.storableRTF(data))
    }

    // MARK: - HTML, which is what browsers write instead

    /// The fragment shapes that turn up in practice. Chrome's begins with a `<meta>`, a full
    /// document with `<!DOCTYPE`, and an app writing a snippet with a bare tag or a closing one.
    func testTheHTMLShapesAppsActuallyWriteAreStored() {
        let fragments = [
            "<meta charset='utf-8'><span style=\"font-weight:700\">bold</span>",
            "<!DOCTYPE html><html><body><p>hello</p></body></html>",
            "<p>a paragraph</p>",
            "</span> trailing fragment",
            "  \n  <b>after leading whitespace</b>",
        ]
        for fragment in fragments {
            let data = Data(fragment.utf8)
            XCTAssertEqual(ClipboardRichText.storableHTML(data), data, "should have stored: \(fragment)")
        }
    }

    /// UTF-16, where every ASCII byte is followed by a zero. Recognised because a pasteboard is
    /// free to hand over either encoding.
    func testUTF16HTMLIsRecognised() {
        let data = "<p>hello</p>".data(using: .utf16LittleEndian)!
        XCTAssertEqual(ClipboardRichText.storableHTML(data), data)
    }

    func testBytesThatAreNotHTMLAreRefused() {
        XCTAssertNil(ClipboardRichText.storableHTML(nil))
        XCTAssertNil(ClipboardRichText.storableHTML(Data()))
        XCTAssertNil(ClipboardRichText.storableHTML(Data("plain text with no markup".utf8)))
        XCTAssertNil(ClipboardRichText.storableHTML(Data([0x00, 0x01, 0x02, 0x03])))
        // Prose, not markup: a space cannot start a tag name, so the comparison in it is not HTML.
        XCTAssertNil(ClipboardRichText.storableHTML(Data("the case where a < b holds".utf8)))
    }

    func testHTMLOverTheCapIsDroppedRatherThanStored() {
        let padding = String(repeating: "x", count: ClipboardRichText.maxBytes)
        let data = Data("<p>\(padding)</p>".utf8)
        XCTAssertGreaterThan(data.count, ClipboardRichText.maxBytes)
        XCTAssertNil(ClipboardRichText.storableHTML(data))
    }

    /// The cap applies per flavour, so a page with enormous HTML does not cost the clip the RTF
    /// that came with it, and the item still counts as formatted.
    func testOversizedHTMLDoesNotTakeTheRTFWithIt() {
        let rtf = Self.rtf("styled")
        let oversized = Data("<p>\(String(repeating: "x", count: ClipboardRichText.maxBytes))</p>".utf8)

        let item = ClipboardItem(
            id: UUID(),
            content: "styled",
            type: .text,
            timestamp: Date(),
            rtfData: ClipboardRichText.storableRTF(rtf),
            htmlData: ClipboardRichText.storableHTML(oversized)
        )

        XCTAssertEqual(item.rtfData, rtf)
        XCTAssertNil(item.htmlData)
        XCTAssertTrue(item.carriesFormatting)
    }

    /// A Chrome copy: HTML and plain text, no RTF at all. Measured on a real one, which is what
    /// this feature exists for; storing RTF alone would have left it plain.
    func testAClipWithHTMLAndNoRTFStillCountsAsFormatted() {
        let html = Data("<meta charset='utf-8'><span>from a browser</span>".utf8)
        let item = ClipboardItem(
            id: UUID(),
            content: "from a browser",
            type: .text,
            timestamp: Date(),
            htmlData: html
        )

        XCTAssertTrue(item.carriesFormatting)
        XCTAssertEqual(
            ClipboardRichText.flavours(text: "from a browser", rtfData: nil, htmlData: html, asPlainText: false),
            [.html(html), .plainText("from a browser")]
        )
    }

    // MARK: - What a paste writes

    func testAFormattedItemWritesBothFlavoursRichestFirst() {
        let data = Self.rtf("styled")
        let flavours = ClipboardRichText.flavours(text: "styled", rtfData: data, htmlData: nil, asPlainText: false)
        XCTAssertEqual(flavours, [.rtf(data), .plainText("styled")])
    }

    /// A clip that carries both is written with both, rather than one being picked here. Which one
    /// gets used is the receiving app's choice: a rich text editor asks for RTF first and a web view
    /// asks for HTML first, from the same pasteboard.
    func testAClipCarryingBothWritesBoth() {
        let rtf = Self.rtf("styled")
        let html = Data("<p>styled</p>".utf8)

        XCTAssertEqual(
            ClipboardRichText.flavours(text: "styled", rtfData: rtf, htmlData: html, asPlainText: false),
            [.rtf(rtf), .html(html), .plainText("styled")]
        )
    }

    func testPlainTextPasteWritesTheTextAlone() {
        let data = Self.rtf("styled")
        let flavours = ClipboardRichText.flavours(text: "styled", rtfData: data, htmlData: nil, asPlainText: true)
        XCTAssertEqual(flavours, [.plainText("styled")])
    }

    /// ⇧⏎ drops every flavour, not just the first one found.
    func testPlainTextPasteDropsHTMLAsWell() {
        XCTAssertEqual(
            ClipboardRichText.flavours(
                text: "styled",
                rtfData: Self.rtf("styled"),
                htmlData: Data("<p>styled</p>".utf8),
                asPlainText: true
            ),
            [.plainText("styled")]
        )
    }

    func testAnItemWithNoFormattingWritesTheTextAlone() {
        XCTAssertEqual(
            ClipboardRichText.flavours(text: "plain", rtfData: nil, htmlData: nil, asPlainText: false),
            [.plainText("plain")]
        )
    }

    /// Defensive, and the reason the check is repeated here rather than trusted from capture time:
    /// a row written by another build could hold anything, and writing it to the pasteboard under
    /// `public.rtf` would hand the receiving app bytes it cannot parse.
    func testBytesThatAreNotRTFAreNeverWrittenToThePasteboard() {
        XCTAssertEqual(
            ClipboardRichText.flavours(text: "plain", rtfData: Data("not rtf".utf8), htmlData: Data("not html".utf8), asPlainText: false),
            [.plainText("plain")]
        )
    }

    // MARK: - The item

    func testOnlyTextItemsCarryFormatting() {
        let text = ClipboardItem(id: UUID(), content: "styled", type: .text, timestamp: Date(), rtfData: Self.rtf("styled"))
        XCTAssertTrue(text.carriesFormatting)

        let plain = ClipboardItem(id: UUID(), content: "plain", type: .text, timestamp: Date())
        XCTAssertFalse(plain.carriesFormatting)

        // An image or a file with RTF attached would put a marker in the row that no paste could
        // honour, since neither writes a text flavour.
        let image = ClipboardItem(
            id: UUID(),
            content: StoreBackedTestCase.image(size: 8),
            type: .image,
            timestamp: Date(),
            rtfData: Self.rtf("styled"),
            htmlData: Data("<p>styled</p>".utf8)
        )
        XCTAssertNil(image.rtfData)
        XCTAssertNil(image.htmlData)
        XCTAssertFalse(image.carriesFormatting)
    }

    // MARK: - Deduplication

    /// Formatting is not part of what makes two clips the same clip, so the same sentence copied
    /// from Word and then from Terminal stays one entry rather than becoming two.
    func testTheSameTextWithAndWithoutFormattingIsTheSameClip() {
        let rich = ClipboardItem(id: UUID(), content: "same words", type: .text, timestamp: Date(), rtfData: Self.rtf("same words"))
        let plain = ClipboardItem(id: UUID(), content: "same words", type: .text, timestamp: Date())

        XCTAssertTrue(rich.contentEquals(plain))
        XCTAssertTrue(plain.contentEquals(rich))
    }

    /// The merger inherits the decisions the user made about a clip, and deliberately does not
    /// inherit its formatting: re-copying the same text as plain means the next paste is plain, and
    /// the row stops claiming otherwise.
    func testRecopyingAsPlainTextKeepsTheUsersDecisionsAndDropsTheFormatting() {
        let existing = ClipboardItem(
            id: UUID(),
            content: "same words",
            type: .text,
            timestamp: Date(timeIntervalSince1970: 1),
            isFavorite: true,
            note: "keep this",
            rtfData: Self.rtf("same words")
        )
        let incoming = ClipboardItem(id: UUID(), content: "same words", type: .text, timestamp: Date(timeIntervalSince1970: 2))

        let result = ClipboardHistoryMerger.inserting(incoming, into: [existing])

        XCTAssertEqual(result.history.count, 1)
        XCTAssertTrue(result.history[0].isFavorite)
        XCTAssertEqual(result.history[0].note, "keep this")
        XCTAssertNil(result.history[0].rtfData)
        XCTAssertFalse(result.history[0].carriesFormatting)
    }

    /// The mirror: re-copying the same text *with* formatting after a plain copy starts pasting it
    /// formatted again, because the incoming clip is what the item now describes.
    ///
    /// This one runs against the item that is already at the top of the history, which is the case
    /// the merger short-circuits as "nothing to do". Formatting is the one part of a text clip that
    /// can differ while `contentEquals` still calls the two the same clip, so it is the one thing
    /// that has to get through that short-circuit.
    func testRecopyingWithFormattingStartsCarryingItAgain() {
        let data = Self.rtf("same words")
        let existing = ClipboardItem(id: UUID(), content: "same words", type: .text, timestamp: Date(timeIntervalSince1970: 1))
        let incoming = ClipboardItem(id: UUID(), content: "same words", type: .text, timestamp: Date(timeIntervalSince1970: 2), rtfData: data)

        let result = ClipboardHistoryMerger.inserting(incoming, into: [existing])

        XCTAssertTrue(result.shouldPersistInsertedItem)
        XCTAssertEqual(result.removedItemIDs, [existing.id], "the row is replaced rather than added beside itself")
        XCTAssertEqual(result.history.count, 1)
        XCTAssertEqual(result.history[0].rtfData, data)
    }

    /// The same words copied from Word and then from Chrome: one clip, whose formatting changed
    /// from RTF to HTML. The item has to follow the most recent copy, so a paste into a web view
    /// gets the browser's own markup rather than a rendering of what Word wrote.
    func testRecopyingFromAnAppThatWritesAnotherFlavourSwapsIt() {
        let html = Data("<meta charset='utf-8'><span>same words</span>".utf8)
        let existing = ClipboardItem(
            id: UUID(),
            content: "same words",
            type: .text,
            timestamp: Date(timeIntervalSince1970: 1),
            rtfData: Self.rtf("same words")
        )
        let incoming = ClipboardItem(
            id: UUID(),
            content: "same words",
            type: .text,
            timestamp: Date(timeIntervalSince1970: 2),
            htmlData: html
        )

        let result = ClipboardHistoryMerger.inserting(incoming, into: [existing])

        XCTAssertTrue(result.shouldPersistInsertedItem)
        XCTAssertEqual(result.history.count, 1)
        XCTAssertNil(result.history[0].rtfData)
        XCTAssertEqual(result.history[0].htmlData, html)
    }

    /// A formatted clip re-copied while it is already at the top writes nothing, exactly as a plain
    /// one does: the RTF must not open a second path to a duplicate row.
    func testAFormattedDuplicateAtTheTopIsNotWrittenAgain() {
        let data = Self.rtf("same words")
        let existing = ClipboardItem(id: UUID(), content: "same words", type: .text, timestamp: Date(timeIntervalSince1970: 1), rtfData: data)
        let incoming = ClipboardItem(id: UUID(), content: "same words", type: .text, timestamp: Date(timeIntervalSince1970: 2), rtfData: data)

        let result = ClipboardHistoryMerger.inserting(incoming, into: [existing])

        XCTAssertFalse(result.shouldPersistInsertedItem)
        XCTAssertEqual(result.history.map(\.id), [existing.id])
    }

    // MARK: - Editing

    /// The editor is a plain-text `NSTextView` by design, so an edit produces a plain-text item.
    /// Saving one that still claimed to carry formatting would paste the *source's* styling over
    /// text the user has since changed.
    func testEditingAFormattedItemSavesAPlainTextCopy() {
        let source = ClipboardItem(id: UUID(), content: "styled", type: .text, timestamp: Date(), rtfData: Self.rtf("styled"))

        let edited = ClipboardTextEdit.editedItem(
            from: source,
            text: "styled and edited",
            sensitivity: ClipboardSensitivityFlags(isSensitive: false, isAutoSensitive: false, isPasswordLike: false)
        )

        XCTAssertNil(edited.rtfData)
        XCTAssertFalse(edited.carriesFormatting)
        XCTAssertEqual(source.rtfData, Self.rtf("styled"), "the source item is left as it was")
    }
}

/// The stored half, over a Core Data store of the test's own.
final class RichTextPersistenceTests: StoreBackedTestCase {

    func testFormattingSurvivesARestart() throws {
        let data = ClipboardRichTextTests.rtf("styled")
        let item = ClipboardItem(id: UUID(), content: "styled", type: .text, timestamp: Date(), rtfData: data)
        persistence.saveClipboardItem(item)

        let loaded = try XCTUnwrap(persistence.loadClipboardHistory().first)
        XCTAssertEqual(loaded.rtfData, data)
        XCTAssertTrue(loaded.carriesFormatting)
        XCTAssertEqual(loaded.content as? String, "styled")
    }

    /// The browser case, stored and read back: HTML alone is enough to count as formatted.
    func testHTMLSurvivesARestartOnItsOwn() throws {
        let html = Data("<meta charset='utf-8'><span style=\"color:#c00\">from a browser</span>".utf8)
        let item = ClipboardItem(id: UUID(), content: "from a browser", type: .text, timestamp: Date(), htmlData: html)
        persistence.saveClipboardItem(item)

        let loaded = try XCTUnwrap(persistence.loadClipboardHistory().first)
        XCTAssertNil(loaded.rtfData)
        XCTAssertEqual(loaded.htmlData, html)
        XCTAssertTrue(loaded.carriesFormatting)
    }

    func testBothFlavoursSurviveTogether() throws {
        let rtf = ClipboardRichTextTests.rtf("styled")
        let html = Data("<p>styled</p>".utf8)
        persistence.saveClipboardItem(
            ClipboardItem(id: UUID(), content: "styled", type: .text, timestamp: Date(), rtfData: rtf, htmlData: html)
        )

        let loaded = try XCTUnwrap(persistence.loadClipboardHistory().first)
        XCTAssertEqual(loaded.rtfData, rtf)
        XCTAssertEqual(loaded.htmlData, html)
    }

    func testAPlainClipComesBackPlain() throws {
        persistence.saveClipboardItem(ClipboardItem(id: UUID(), content: "plain", type: .text, timestamp: Date()))

        let loaded = try XCTUnwrap(persistence.loadClipboardHistory().first)
        XCTAssertNil(loaded.rtfData)
        XCTAssertNil(loaded.htmlData)
    }

    func testAnImageNeverComesBackCarryingFormatting() throws {
        saveImage()

        let loaded = try XCTUnwrap(persistence.loadClipboardHistory().first)
        XCTAssertEqual(loaded.type, .image)
        XCTAssertNil(loaded.rtfData)
        XCTAssertNil(loaded.htmlData)
    }

    /// The load-side guard. A row holding bytes that are not RTF, whatever wrote it, must not come
    /// back as an item the row would mark as formatted and a paste would write under `public.rtf`.
    func testARowHoldingSomethingOtherThanRTFLoadsAsPlainText() throws {
        var item = ClipboardItem(id: UUID(), content: "styled", type: .text, timestamp: Date())
        item.rtfData = Data("just some bytes".utf8)
        item.htmlData = Data("also just some bytes".utf8)
        persistence.saveClipboardItem(item)

        let loaded = try XCTUnwrap(persistence.loadClipboardHistory().first)
        XCTAssertNil(loaded.rtfData)
        XCTAssertNil(loaded.htmlData)
        XCTAssertFalse(loaded.carriesFormatting)
        XCTAssertEqual(loaded.content as? String, "styled", "the clip itself is untouched")
    }
}
