import AppKit
import XCTest
@testable import MacClipboard

/// The value-level half of reading the text in an image: what the action applies to, how the boxes
/// Vision returns become one clip, and what the resulting item inherits.
///
/// Vision itself is not exercised here. It is behind `ImageTextRecognizing` precisely so these rules
/// can be pinned without a fixture image whose recognition would then be the thing under test.
final class ClipboardImageTextRecognitionTests: XCTestCase {

    // MARK: - What the action applies to

    func testAnImageItemHasAPlan() {
        let plan = ClipboardImageTextRecognition.plan(for: Self.image(), isRevealed: false)

        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.sourceIsSensitive, false)
    }

    func testTextAndFileItemsHaveNoPlan() {
        let text = ClipboardItem(id: UUID(), content: "already text", type: .text, timestamp: Date())
        let files = ClipboardItem(
            id: UUID(),
            content: [URL(fileURLWithPath: "/tmp/a")],
            type: .file,
            timestamp: Date()
        )

        XCTAssertNil(ClipboardImageTextRecognition.plan(for: text, isRevealed: false))
        XCTAssertNil(ClipboardImageTextRecognition.plan(for: files, isRevealed: false))
        XCTAssertNil(ClipboardImageTextRecognition.plan(for: nil, isRevealed: false))
    }

    func testAMaskedImageIsRefusedUntilItIsRevealed() {
        // The editor makes the same test for the same reason: reading a hidden image would write a
        // new row holding text the user never got to see.
        let hidden = Self.image(isSensitive: true)

        XCTAssertNil(ClipboardImageTextRecognition.plan(for: hidden, isRevealed: false))
        XCTAssertEqual(
            ClipboardImageTextRecognition.plan(for: hidden, isRevealed: true)?.sourceIsSensitive,
            true
        )
    }

    // MARK: - Putting the boxes back into reading order

    func testLinesAreOrderedTopToBottomWhateverOrderTheyArriveIn() {
        // Vision's own result order is not documented as reading order, and the order is the whole
        // output here, so it is rebuilt from the boxes rather than trusted.
        let lines = [
            Self.line("third", y: 0.1),
            Self.line("first", y: 0.8),
            Self.line("second", y: 0.5),
        ]

        XCTAssertEqual(ClipboardImageTextRecognition.text(from: lines), "first\nsecond\nthird")
    }

    func testBoxesOnOneLineBecomeOneLineLeftToRight() {
        // Two observations that overlap vertically are one line of text: a sentence Vision split in
        // two, or a row of table cells. Either way a newline between them would be wrong.
        let lines = [
            Self.line("right", y: 0.5, x: 0.6),
            Self.line("left", y: 0.5, x: 0.1),
            Self.line("below", y: 0.2),
        ]

        XCTAssertEqual(ClipboardImageTextRecognition.text(from: lines), "left right\nbelow")
    }

    func testASlightlyStaggeredLineIsStillOneLine() {
        // Boxes on one line are rarely at the same y: a capital or a descender moves the box a
        // little. The overlap threshold is what keeps them together.
        let lines = [
            Self.line("Ada", y: 0.502, height: 0.04),
            Self.line("Lovelace", y: 0.498, height: 0.04, x: 0.4),
        ]

        XCTAssertEqual(ClipboardImageTextRecognition.text(from: lines), "Ada Lovelace")
    }

    func testADescendingColumnDoesNotCollapseIntoOneLine() {
        // Each box overlaps the one above it by more than the threshold, but not the first of the
        // row: comparing against the row's first box is what stops a whole column chaining into a
        // single very tall line.
        let lines = (0..<5).map { index in
            Self.line("line \(index)", y: 0.8 - 0.021 * Double(index), height: 0.04)
        }

        XCTAssertEqual(
            ClipboardImageTextRecognition.text(from: lines),
            "line 0\nline 1\nline 2\nline 3\nline 4"
        )
    }

    func testBoxesHoldingOnlyWhitespaceAreDropped() {
        let lines = [
            Self.line("real", y: 0.8),
            Self.line("   \t ", y: 0.5),
            Self.line("", y: 0.3),
        ]

        XCTAssertEqual(ClipboardImageTextRecognition.text(from: lines), "real")
    }

    func testAnImageWithNothingReadableGivesEmptyText() {
        // The empty string is what `ClipboardMonitor` turns into `.noTextFound`, so nothing is
        // written for a photo of a beach.
        XCTAssertEqual(ClipboardImageTextRecognition.text(from: []), "")
        XCTAssertEqual(ClipboardImageTextRecognition.text(from: [Self.line(" ", y: 0.5)]), "")
    }

    // MARK: - The item it produces

    func testTheRecognisedItemIsAnOrdinaryTextItemMarkedAsDerived() {
        let plan = ClipboardImageTextRecognition.plan(for: Self.image(), isRevealed: false)!

        let item = ClipboardImageTextRecognition.recognizedItem(
            from: plan,
            text: "read out of a screenshot",
            sensitivity: Self.noFlags
        )

        XCTAssertEqual(item.type, .text)
        XCTAssertEqual(item.content as? String, "read out of a screenshot")
        XCTAssertTrue(item.isRecognizedText)
        // The marker is the item's own, not a note written on the user's behalf: the note field is
        // theirs, and a note would also outrank ordinary matches in search.
        XCTAssertNil(item.note)
        XCTAssertFalse(item.isFavorite)
        XCTAssertNil(item.rtfData)
        XCTAssertNil(item.htmlData)
    }

    func testTextReadFromAHiddenImageIsHiddenToo() {
        let plan = ClipboardImageTextRecognition.plan(for: Self.image(isSensitive: true), isRevealed: true)!

        let item = ClipboardImageTextRecognition.recognizedItem(
            from: plan,
            text: "whatever was in it",
            sensitivity: Self.noFlags
        )

        XCTAssertTrue(item.isSensitive)
    }

    func testMaskingIsGainedFromThePolicyAsWell() {
        let plan = ClipboardImageTextRecognition.plan(for: Self.image(), isRevealed: false)!

        let item = ClipboardImageTextRecognition.recognizedItem(
            from: plan,
            text: "hunter2!Aa",
            sensitivity: ClipboardSensitivityFlags(isSensitive: true, isAutoSensitive: false, isPasswordLike: true)
        )

        XCTAssertTrue(item.isSensitive)
        XCTAssertTrue(item.isPasswordLike)
        XCTAssertFalse(item.isManuallyUnsensitive)
    }

    func testOnlyTextCanBeMarkedAsReadFromAnImage() {
        // The marker says this text was read out of an image, so an image or a file carrying it
        // would be a claim the row cannot make about itself.
        let image = ClipboardItem(
            id: UUID(),
            content: Self.makeImage(),
            type: .image,
            timestamp: Date(),
            isRecognizedText: true
        )

        XCTAssertFalse(image.isRecognizedText)
    }

    // MARK: - Helpers

    private static let noFlags = ClipboardSensitivityFlags(
        isSensitive: false,
        isAutoSensitive: false,
        isPasswordLike: false
    )

    private static func line(
        _ text: String,
        y: Double,
        height: Double = 0.05,
        x: Double = 0.1,
        width: Double = 0.3
    ) -> ClipboardImageTextRecognition.RecognizedLine {
        // Normalised, origin at the bottom left, as Vision reports it. `y` is the middle of the box,
        // which is what the ordering compares.
        ClipboardImageTextRecognition.RecognizedLine(
            text: text,
            boundingBox: CGRect(x: x, y: y - height / 2, width: width, height: height)
        )
    }

    private static func image(isSensitive: Bool = false) -> ClipboardItem {
        ClipboardItem(
            id: UUID(),
            content: makeImage(),
            type: .image,
            timestamp: Date(timeIntervalSince1970: 0),
            isSensitive: isSensitive
        )
    }

    private static func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        return image
    }
}

/// The other half: what `ClipboardMonitor.recognizeText` does with what the recogniser returns.
///
/// Store-backed, because the outcome is decided by `insertIntoHistory` and the history is what the
/// dedupe case is about. The recogniser is a stub, so nothing here depends on Vision reading a
/// fixture image correctly.
final class ClipboardMonitorTextRecognitionTests: StoreBackedTestCase {
    private var preferences: UserPreferencesManager!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()

        suiteName = "MacClipboardTests-\(UUID().uuidString)"
        preferences = UserPreferencesManager(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        // Capture off for the length of the test, and the one-time image re-encode already done:
        // both would otherwise run against this store while the assertions do.
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

    private func makeMonitor(recognizer: StubImageTextRecognizer) -> ClipboardMonitor {
        ClipboardMonitor(
            userPreferences: preferences,
            persistenceManager: persistence,
            textRecognizer: recognizer
        )
    }

    func testRecognisedTextBecomesANewItemAndLeavesTheImageAlone() throws {
        let image = saveImage()
        let monitor = makeMonitor(recognizer: StubImageTextRecognizer(lines: [
            StubImageTextRecognizer.line("second", y: 0.3),
            StubImageTextRecognizer.line("first", y: 0.7),
        ]))
        try waitUntil("the monitor to load the image") { monitor.clipboardHistory.count == 1 }

        let plan = try XCTUnwrap(ClipboardImageTextRecognition.plan(for: monitor.clipboardHistory[0], isRevealed: false))
        var outcome: ClipboardImageTextRecognitionOutcome?
        monitor.recognizeText(plan) { outcome = $0 }
        try waitUntil("the recognition to finish") { outcome != nil }

        guard case .recognized(let id, let lineCount) = outcome else {
            return XCTFail("expected the text to be saved as a new item, got \(String(describing: outcome))")
        }
        XCTAssertEqual(lineCount, 2)

        let recognized = try XCTUnwrap(monitor.clipboardHistory.first { $0.id == id })
        XCTAssertEqual(recognized.fullText, "first\nsecond")
        XCTAssertTrue(recognized.isRecognizedText)
        // The image is still there, unchanged, and still an image: this action derives an item, it
        // does not convert one.
        XCTAssertEqual(monitor.clipboardHistory.map(\.type), [.text, .image])
        XCTAssertTrue(monitor.clipboardHistory.contains { $0.id == image.id })

        // And the marker survives a relaunch, which is the reason it is an attribute rather than
        // something the popover remembers.
        try waitUntil("the new item to reach the store") { self.storedIDs().contains(id) }
        let reloaded = try XCTUnwrap(persistence.loadClipboardHistory().first { $0.id == id })
        XCTAssertTrue(reloaded.isRecognizedText)
    }

    func testAnImageWithNoReadableTextAddsNothing() throws {
        saveImage()
        let monitor = makeMonitor(recognizer: StubImageTextRecognizer(lines: []))
        try waitUntil("the monitor to load the image") { monitor.clipboardHistory.count == 1 }

        let plan = try XCTUnwrap(ClipboardImageTextRecognition.plan(for: monitor.clipboardHistory[0], isRevealed: false))
        var outcome: ClipboardImageTextRecognitionOutcome?
        monitor.recognizeText(plan) { outcome = $0 }
        try waitUntil("the recognition to finish") { outcome != nil }

        XCTAssertEqual(outcome, .noTextFound)
        XCTAssertEqual(monitor.clipboardHistory.count, 1, "nothing should be written for an image with no text in it")
    }

    func testAFailedRecognitionSaysSoAndAddsNothing() throws {
        saveImage()
        let monitor = makeMonitor(recognizer: StubImageTextRecognizer(failure: StubImageTextRecognizer.Failure.refused))
        try waitUntil("the monitor to load the image") { monitor.clipboardHistory.count == 1 }

        let plan = try XCTUnwrap(ClipboardImageTextRecognition.plan(for: monitor.clipboardHistory[0], isRevealed: false))
        var outcome: ClipboardImageTextRecognitionOutcome?
        monitor.recognizeText(plan) { outcome = $0 }
        try waitUntil("the recognition to finish") { outcome != nil }

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(monitor.clipboardHistory.count, 1)
    }

    func testTextThatIsAlreadyTheTopClipIsNotAddedTwice() throws {
        // The merger dedupes by content, so reading the same image twice, or reading text the user
        // has since copied by hand, moves that row rather than adding a second copy of it.
        saveImage()
        let monitor = makeMonitor(recognizer: StubImageTextRecognizer(lines: [
            StubImageTextRecognizer.line("the same words", y: 0.5),
        ]))
        try waitUntil("the monitor to load the image") { monitor.clipboardHistory.count == 1 }

        let plan = try XCTUnwrap(ClipboardImageTextRecognition.plan(for: monitor.clipboardHistory[0], isRevealed: false))
        var first: ClipboardImageTextRecognitionOutcome?
        monitor.recognizeText(plan) { first = $0 }
        try waitUntil("the first recognition to finish") { first != nil }

        var second: ClipboardImageTextRecognitionOutcome?
        monitor.recognizeText(plan) { second = $0 }
        try waitUntil("the second recognition to finish") { second != nil }

        guard case .alreadyInHistory = second else {
            return XCTFail("expected the second pass to report the text was already there, got \(String(describing: second))")
        }
        XCTAssertEqual(monitor.clipboardHistory.count, 2, "the second pass should not add a third row")
    }
}

/// A recogniser that answers with whatever the test asked for, on the main queue as the protocol
/// requires.
private struct StubImageTextRecognizer: ImageTextRecognizing {
    enum Failure: Error { case refused }

    var lines: [ClipboardImageTextRecognition.RecognizedLine] = []
    var failure: Error?

    static func line(_ text: String, y: Double) -> ClipboardImageTextRecognition.RecognizedLine {
        ClipboardImageTextRecognition.RecognizedLine(
            text: text,
            boundingBox: CGRect(x: 0.1, y: y - 0.025, width: 0.3, height: 0.05)
        )
    }

    func recognizeText(
        in image: NSImage,
        completion: @escaping (Result<[ClipboardImageTextRecognition.RecognizedLine], Error>) -> Void
    ) {
        DispatchQueue.main.async {
            if let failure {
                completion(.failure(failure))
            } else {
                completion(.success(lines))
            }
        }
    }
}
