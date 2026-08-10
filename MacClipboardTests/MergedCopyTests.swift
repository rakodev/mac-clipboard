import AppKit
import XCTest
@testable import MacClipboard

final class ClipboardMergedCopyPlanTests: XCTestCase {
    func testJoinsSelectedTextInListOrderWithNewlines() {
        let top = Self.text("first")
        let middle = Self.text("second")
        let bottom = Self.text("third")

        // Selected bottom-up, to prove the order comes off the list and not off the selection.
        let plan = ClipboardMergedCopy.plan(
            forSelectionIn: [top, middle, bottom],
            selectedIds: [bottom.id, top.id, middle.id]
        )

        XCTAssertEqual(plan?.text, "first\nsecond\nthird")
        XCTAssertEqual(plan?.mergedCount, 3)
        XCTAssertEqual(plan?.skippedCount, 0)
    }

    func testUnselectedItemsAreLeftOut() {
        let first = Self.text("keep")
        let skipped = Self.text("not selected")
        let second = Self.text("me too")

        let plan = ClipboardMergedCopy.plan(
            forSelectionIn: [first, skipped, second],
            selectedIds: [first.id, second.id]
        )

        XCTAssertEqual(plan?.text, "keep\nme too")
        XCTAssertEqual(plan?.mergedCount, 2)
    }

    func testWhitespaceIsContentAndIsNotTrimmed() {
        let indented = Self.text("\tindented line ")
        let blankEnded = Self.text("trailing\n\n")

        let plan = ClipboardMergedCopy.plan(
            forSelectionIn: [indented, blankEnded],
            selectedIds: [indented.id, blankEnded.id]
        )

        XCTAssertEqual(plan?.text, "\tindented line \ntrailing\n\n")
    }

    func testNonTextItemsAreSkippedAndCounted() {
        let first = Self.text("one")
        let image = ClipboardItem(id: UUID(), content: Self.makeImage(), type: .image, timestamp: Date())
        let files = ClipboardItem(id: UUID(), content: [URL(fileURLWithPath: "/tmp/a")], type: .file, timestamp: Date())
        let second = Self.text("two")

        let plan = ClipboardMergedCopy.plan(
            forSelectionIn: [first, image, files, second],
            selectedIds: [first.id, image.id, files.id, second.id]
        )

        XCTAssertEqual(plan?.text, "one\ntwo")
        XCTAssertEqual(plan?.mergedCount, 2)
        XCTAssertEqual(plan?.skippedCount, 2)
    }

    func testFewerThanTwoTextItemsIsNoPlan() {
        let text = Self.text("alone")
        let image = ClipboardItem(id: UUID(), content: Self.makeImage(), type: .image, timestamp: Date())

        XCTAssertNil(ClipboardMergedCopy.plan(forSelectionIn: [text, image], selectedIds: []))
        XCTAssertNil(ClipboardMergedCopy.plan(forSelectionIn: [text, image], selectedIds: [text.id]))
        // Two selected, but only one of them carries text, so there is nothing to join.
        XCTAssertNil(ClipboardMergedCopy.plan(forSelectionIn: [text, image], selectedIds: [text.id, image.id]))
    }

    func testIdsThatAreNoLongerInTheListAreIgnored() {
        // The selection outlives a filter change or a delete, so it can name rows that are gone.
        let first = Self.text("one")
        let second = Self.text("two")

        let plan = ClipboardMergedCopy.plan(
            forSelectionIn: [first],
            selectedIds: [first.id, second.id]
        )

        XCTAssertNil(plan)
    }

    func testMaskedSourceIsReportedAndSkippedItemsAreNot() {
        let plain = Self.text("visible")
        let masked = Self.text("secret", isSensitive: true)
        let maskedImage = ClipboardItem(
            id: UUID(),
            content: Self.makeImage(),
            type: .image,
            timestamp: Date(),
            isSensitive: true
        )
        let other = Self.text("also visible")

        let withMaskedText = ClipboardMergedCopy.plan(
            forSelectionIn: [plain, masked],
            selectedIds: [plain.id, masked.id]
        )
        XCTAssertEqual(withMaskedText?.includesSensitiveSource, true)

        // The image contributes nothing to the joined text, so its own flag says nothing about it.
        let withMaskedImageOnly = ClipboardMergedCopy.plan(
            forSelectionIn: [plain, maskedImage, other],
            selectedIds: [plain.id, maskedImage.id, other.id]
        )
        XCTAssertEqual(withMaskedImageOnly?.includesSensitiveSource, false)
        XCTAssertEqual(withMaskedImageOnly?.skippedCount, 1)
    }

    // MARK: - The merged item

    func testMergedItemIsAnOrdinaryNewPlainTextItem() {
        let plan = ClipboardMergedCopy.Plan(
            text: "one\ntwo",
            mergedCount: 2,
            skippedCount: 0,
            includesSensitiveSource: false
        )

        let merged = ClipboardMergedCopy.mergedItem(from: plan, sensitivity: Self.noFlags)

        XCTAssertEqual(merged.type, .text)
        XCTAssertEqual(merged.content as? String, "one\ntwo")
        XCTAssertFalse(merged.isFavorite)
        XCTAssertNil(merged.note)
        XCTAssertFalse(merged.isSensitive)
        // Splicing several RTF or HTML documents together would claim to be what the user copied,
        // so a merged clip pastes plain and the row shows no formatting marker.
        XCTAssertNil(merged.rtfData)
        XCTAssertNil(merged.htmlData)
        XCTAssertFalse(merged.carriesFormatting)
    }

    func testMaskingIsGainedFromASourceEvenWithTheDetectorsOff() {
        let plan = ClipboardMergedCopy.Plan(
            text: "harmless\nsecret",
            mergedCount: 2,
            skippedCount: 0,
            includesSensitiveSource: true
        )

        let merged = ClipboardMergedCopy.mergedItem(from: plan, sensitivity: Self.noFlags)

        XCTAssertTrue(merged.isSensitive)
    }

    func testMaskingIsGainedFromThePolicyOnTheJoinedText() {
        let plan = ClipboardMergedCopy.Plan(
            text: "harmless\nalso harmless",
            mergedCount: 2,
            skippedCount: 0,
            includesSensitiveSource: false
        )

        let merged = ClipboardMergedCopy.mergedItem(
            from: plan,
            sensitivity: ClipboardSensitivityFlags(isSensitive: true, isAutoSensitive: true, isPasswordLike: false)
        )

        XCTAssertTrue(merged.isSensitive)
        XCTAssertTrue(merged.isAutoSensitive)
        XCTAssertFalse(merged.isManuallyUnsensitive)
    }

    // MARK: - The action's title

    func testActionTitleStatesTheCountAndTheOrder() {
        let plan = ClipboardMergedCopy.Plan(text: "a\nb\nc", mergedCount: 3, skippedCount: 0, includesSensitiveSource: false)

        XCTAssertEqual(ClipboardMergedCopyContent.actionTitle(for: plan), "Copy 3 Merged, Top to Bottom")
    }

    func testActionTitleStatesWhatIsBeingLeftOut() {
        let plan = ClipboardMergedCopy.Plan(text: "a\nb", mergedCount: 2, skippedCount: 1, includesSensitiveSource: false)

        XCTAssertEqual(ClipboardMergedCopyContent.actionTitle(for: plan), "Copy 2 Merged, Top to Bottom (1 Skipped)")
    }

    func testActionTitleExplainsItselfWithNothingToMerge() {
        XCTAssertEqual(
            ClipboardMergedCopyContent.actionTitle(for: nil),
            "Copy Merged (⌘-Click Two or More Text Items)"
        )
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

    private static func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        return image
    }
}
