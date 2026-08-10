import AppKit
import XCTest
@testable import MacClipboard

final class ClipboardSelectionExtensionTests: XCTestCase {
    func testFirstExtendDownTakesTheCursorRowAndTheOneBelowIt() {
        let items = Self.items(count: 5)

        let result = ClipboardSelectionExtension.extending(
            from: 1,
            by: 1,
            in: items,
            selectedIds: [],
            anchor: nil
        )

        XCTAssertEqual(result?.index, 2)
        XCTAssertEqual(result?.selectedIds, Set([items[1].id, items[2].id]))
        XCTAssertEqual(result?.anchor.itemId, items[1].id)
    }

    func testRepeatedExtendsGrowTheRange() {
        let items = Self.items(count: 5)

        let first = ClipboardSelectionExtension.extending(from: 0, by: 1, in: items, selectedIds: [], anchor: nil)
        let second = ClipboardSelectionExtension.extending(
            from: first!.index,
            by: 1,
            in: items,
            selectedIds: first!.selectedIds,
            anchor: first!.anchor
        )

        XCTAssertEqual(second?.index, 2)
        XCTAssertEqual(second?.selectedIds, Set(items[0...2].map(\.id)))
        // The anchor does not move as the range grows.
        XCTAssertEqual(second?.anchor.itemId, items[0].id)
    }

    func testReversingDirectionGivesBackWhatThePreviousPressesTook() {
        let items = Self.items(count: 5)

        var result = ClipboardSelectionExtension.extending(from: 0, by: 1, in: items, selectedIds: [], anchor: nil)!
        result = ClipboardSelectionExtension.extending(
            from: result.index, by: 1, in: items, selectedIds: result.selectedIds, anchor: result.anchor
        )!
        XCTAssertEqual(result.selectedIds, Set(items[0...2].map(\.id)))

        result = ClipboardSelectionExtension.extending(
            from: result.index, by: -1, in: items, selectedIds: result.selectedIds, anchor: result.anchor
        )!

        XCTAssertEqual(result.index, 1)
        XCTAssertEqual(result.selectedIds, Set(items[0...1].map(\.id)))
    }

    func testCrossingBackOverTheAnchorSelectsTheOtherSide() {
        let items = Self.items(count: 5)

        // Start at 2, extend down to 3, then walk back up past the anchor to 1.
        var result = ClipboardSelectionExtension.extending(from: 2, by: 1, in: items, selectedIds: [], anchor: nil)!
        result = ClipboardSelectionExtension.extending(
            from: result.index, by: -1, in: items, selectedIds: result.selectedIds, anchor: result.anchor
        )!
        XCTAssertEqual(result.selectedIds, Set([items[2].id]))

        result = ClipboardSelectionExtension.extending(
            from: result.index, by: -1, in: items, selectedIds: result.selectedIds, anchor: result.anchor
        )!

        XCTAssertEqual(result.index, 1)
        XCTAssertEqual(result.selectedIds, Set(items[1...2].map(\.id)))
    }

    func testAnExistingSelectionSurvivesARangeSweepingOverItAndRetreating() {
        let items = Self.items(count: 6)
        // Whatever was ⌘-clicked before the run is the base: row 4, well below the cursor.
        let clicked: Set<UUID> = [items[4].id]

        var result = ClipboardSelectionExtension.extending(from: 0, by: 1, in: items, selectedIds: clicked, anchor: nil)!
        XCTAssertEqual(result.selectedIds, Set([items[0].id, items[1].id, items[4].id]))

        result = ClipboardSelectionExtension.extending(
            from: result.index, by: -1, in: items, selectedIds: result.selectedIds, anchor: result.anchor
        )!

        // The range gave back row 1, and left the ⌘-click on row 4 alone.
        XCTAssertEqual(result.selectedIds, Set([items[0].id, items[4].id]))
    }

    func testEndsOfTheListChangeNothing() {
        let items = Self.items(count: 3)

        XCTAssertNil(ClipboardSelectionExtension.extending(from: 0, by: -1, in: items, selectedIds: [], anchor: nil))
        XCTAssertNil(ClipboardSelectionExtension.extending(from: 2, by: 1, in: items, selectedIds: [], anchor: nil))
    }

    func testAnEmptyListHasNothingToExtend() {
        XCTAssertNil(ClipboardSelectionExtension.extending(from: 0, by: 1, in: [], selectedIds: [], anchor: nil))
    }

    func testTheAnchorIsHeldByIdSoAnArrivingClipDoesNotShiftIt() {
        let items = Self.items(count: 4)

        let first = ClipboardSelectionExtension.extending(from: 1, by: 1, in: items, selectedIds: [], anchor: nil)!
        XCTAssertEqual(first.selectedIds, Set(items[1...2].map(\.id)))

        // A capture arrives at the top while the popover is open: every index moves down by one.
        let shifted = [Self.item("new")] + items

        let second = ClipboardSelectionExtension.extending(
            from: first.index + 1,
            by: 1,
            in: shifted,
            selectedIds: first.selectedIds,
            anchor: first.anchor
        )!

        // Still anchored on the same row, so the range is the same three original items.
        XCTAssertEqual(second.anchor.itemId, items[1].id)
        XCTAssertEqual(second.selectedIds, Set(items[1...3].map(\.id)))
    }

    func testAnAnchorWhoseRowIsGoneStartsTheRunAgainFromTheCursor() {
        let items = Self.items(count: 4)
        let deleted = ClipboardSelectionExtension.Anchor(itemId: UUID(), base: [])

        let result = ClipboardSelectionExtension.extending(
            from: 2,
            by: 1,
            in: items,
            selectedIds: [],
            anchor: deleted
        )

        XCTAssertEqual(result?.index, 3)
        XCTAssertEqual(result?.selectedIds, Set(items[2...3].map(\.id)))
        XCTAssertEqual(result?.anchor.itemId, items[2].id)
    }

    func testACursorOutsideTheListIsClamped() {
        let items = Self.items(count: 3)

        // The cursor can be stale for a moment after the list is refiltered.
        let result = ClipboardSelectionExtension.extending(from: 9, by: -1, in: items, selectedIds: [], anchor: nil)

        XCTAssertEqual(result?.index, 1)
        XCTAssertEqual(result?.selectedIds, Set(items[1...2].map(\.id)))
    }

    // MARK: - Helpers

    private static func item(_ content: String) -> ClipboardItem {
        ClipboardItem(id: UUID(), content: content, type: .text, timestamp: Date(timeIntervalSince1970: 0))
    }

    private static func items(count: Int) -> [ClipboardItem] {
        (0..<count).map { item("item \($0)") }
    }
}
