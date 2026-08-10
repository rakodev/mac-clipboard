import AppKit
import XCTest
@testable import MacClipboard

final class ClipboardColorSwatchTests: XCTestCase {

    // MARK: - Hex

    func testSixDigitHexInEitherCase() {
        assertColor(ClipboardColorSwatch.parse("#FF5733"), 255, 87, 51, 1)
        assertColor(ClipboardColorSwatch.parse("#ff5733"), 255, 87, 51, 1)
        assertColor(ClipboardColorSwatch.parse("#Ff5733"), 255, 87, 51, 1)
    }

    func testThreeDigitHexExpandsEachNibble() {
        // F is FF, not F0: a shorthand colour is the long one it stands for, and getting this wrong
        // shows a swatch that is visibly darker than the colour the clip names.
        assertColor(ClipboardColorSwatch.parse("#F53"), 255, 85, 51, 1)
        assertColor(ClipboardColorSwatch.parse("#000"), 0, 0, 0, 1)
        assertColor(ClipboardColorSwatch.parse("#fff"), 255, 255, 255, 1)
    }

    func testEightDigitHexCarriesAlpha() {
        assertColor(ClipboardColorSwatch.parse("#FF573380"), 255, 87, 51, 128.0 / 255)
        assertColor(ClipboardColorSwatch.parse("#FF573300"), 255, 87, 51, 0)
        assertColor(ClipboardColorSwatch.parse("#FF5733FF"), 255, 87, 51, 1)
    }

    func testFourDigitHexCarriesAlpha() {
        assertColor(ClipboardColorSwatch.parse("#F538"), 255, 85, 51, 136.0 / 255)
    }

    // MARK: - Near misses that must not get a swatch

    func testHexLengthsNoNotationHas() {
        // A colour is 3, 4, 6 or 8 digits. Everything between them is a string that happens to start
        // with a hash, and a swatch on it would be showing a colour the clip does not name.
        XCTAssertNil(ClipboardColorSwatch.parse("#12345"))
        XCTAssertNil(ClipboardColorSwatch.parse("#1234567"))
        XCTAssertNil(ClipboardColorSwatch.parse("#12"))
        XCTAssertNil(ClipboardColorSwatch.parse("#123456789"))
        XCTAssertNil(ClipboardColorSwatch.parse("#"))
    }

    func testCharactersThatAreNotHex() {
        XCTAssertNil(ClipboardColorSwatch.parse("#GGHHII"))
        XCTAssertNil(ClipboardColorSwatch.parse("#ff573g"))
        XCTAssertNil(ClipboardColorSwatch.parse("#ff 573"))
        // A ticket reference and a channel name are both a hash and six characters.
        XCTAssertNil(ClipboardColorSwatch.parse("#123abz"))
    }

    func testFullwidthDigitsAreNotHex() {
        // `Character.isHexDigit` accepts the fullwidth forms; nobody copied those meaning a colour.
        XCTAssertNil(ClipboardColorSwatch.parse("#ＡＢＣ"))
    }

    func testAColourInsideTextIsNotAColourClip() {
        // The whole rule: matching anywhere would put a swatch on most CSS and most code.
        XCTAssertNil(ClipboardColorSwatch.parse("color: #FF5733;"))
        XCTAssertNil(ClipboardColorSwatch.parse("background:#fff"))
        XCTAssertNil(ClipboardColorSwatch.parse("#FF5733 is the brand orange"))
        XCTAssertNil(ClipboardColorSwatch.parse("#FF5733\n#00FF00"))
        XCTAssertNil(ClipboardColorSwatch.parse("rgb(255, 87, 51) with a note"))
    }

    func testClipsLongerThanAColourAreRefusedBeforeTheyAreRead() {
        let stylesheet = String(repeating: "a { color: #FF5733; }\n", count: 200)
        XCTAssertNil(ClipboardColorSwatch.parse(stylesheet))

        // The cap is on the raw string, so a colour padded past it is refused too. That is the
        // trade for the parse being bounded work on every row.
        let padded = "#FF5733" + String(repeating: " ", count: ClipboardColorSwatch.maxLength)
        XCTAssertNil(ClipboardColorSwatch.parse(padded))
    }

    // MARK: - Whitespace around the clip

    func testSurroundingWhitespaceAndNewlinesAreTrimmed() {
        // Copying a colour out of a stylesheet usually takes the newline with it.
        assertColor(ClipboardColorSwatch.parse("  #FF5733\n"), 255, 87, 51, 1)
        assertColor(ClipboardColorSwatch.parse("\n\trgb(255, 87, 51)  "), 255, 87, 51, 1)
    }

    func testEmptyAndWhitespaceOnlyClips() {
        XCTAssertNil(ClipboardColorSwatch.parse(""))
        XCTAssertNil(ClipboardColorSwatch.parse("   \n\t "))
    }

    // MARK: - rgb() and rgba()

    func testLegacyCommaSyntax() {
        assertColor(ClipboardColorSwatch.parse("rgb(255, 87, 51)"), 255, 87, 51, 1)
        assertColor(ClipboardColorSwatch.parse("rgb(255,87,51)"), 255, 87, 51, 1)
        assertColor(ClipboardColorSwatch.parse("RGB(255, 87, 51)"), 255, 87, 51, 1)
        assertColor(ClipboardColorSwatch.parse("rgba(255, 87, 51, 0.5)"), 255, 87, 51, 0.5)
    }

    func testRgbAndRgbaAreAliases() {
        // CSS Color 4 made them the same function, so neither is held to its own component count.
        assertColor(ClipboardColorSwatch.parse("rgb(255, 87, 51, 0.5)"), 255, 87, 51, 0.5)
        assertColor(ClipboardColorSwatch.parse("rgba(255, 87, 51)"), 255, 87, 51, 1)
    }

    func testSpaceSeparatedSyntaxWithASlashForAlpha() {
        assertColor(ClipboardColorSwatch.parse("rgb(255 87 51)"), 255, 87, 51, 1)
        assertColor(ClipboardColorSwatch.parse("rgb(255 87 51 / 0.25)"), 255, 87, 51, 0.25)
        assertColor(ClipboardColorSwatch.parse("rgb(255 87 51 / 50%)"), 255, 87, 51, 0.5)
    }

    func testOutOfRangeIsClampedRatherThanRefused() {
        // What a browser does with it. Somebody wrote a colour badly; they did not copy something
        // that means anything else.
        assertColor(ClipboardColorSwatch.parse("rgb(300, -5, 51)"), 255, 0, 51, 1)
        assertColor(ClipboardColorSwatch.parse("rgba(0, 0, 0, 4)"), 0, 0, 0, 1)
    }

    func testFunctionalNearMisses() {
        XCTAssertNil(ClipboardColorSwatch.parse("rgb(255, 87)"))
        XCTAssertNil(ClipboardColorSwatch.parse("rgb(255, 87, 51, 0.5, 1)"))
        XCTAssertNil(ClipboardColorSwatch.parse("rgb(255, 87, 51"))
        XCTAssertNil(ClipboardColorSwatch.parse("rgb()"))
        XCTAssertNil(ClipboardColorSwatch.parse("rgb (255, 87, 51)"))
        // Percentage channels are the one colour notation this refuses, so that every component
        // parses by one rule. Alpha still takes a percentage, which is where CSS puts them.
        XCTAssertNil(ClipboardColorSwatch.parse("rgb(100%, 0%, 0%)"))
        XCTAssertNil(ClipboardColorSwatch.parse("rgb(255.5, 87, 51)"))
        XCTAssertNil(ClipboardColorSwatch.parse("hsl(9, 100%, 60%)"))
        // A function call that reads like one and is not: three arguments, wrong name.
        XCTAssertNil(ClipboardColorSwatch.parse("max(255, 87, 51)"))
    }

    // MARK: - What the item has to be

    func testOnlyTextItemsAreParsed() {
        XCTAssertNil(ClipboardColorSwatch.swatch(for: nil))
        XCTAssertNil(ClipboardColorSwatch.swatch(for: Self.image()))

        // A file item's `fullText` is its paths, and an image's is its associated text, so the type
        // check is what stops either being read as a colour it never held.
        let file = ClipboardItem(
            id: UUID(),
            content: [URL(fileURLWithPath: "/tmp/#FF5733")],
            type: .file,
            timestamp: Date(timeIntervalSince1970: 0)
        )
        XCTAssertNil(ClipboardColorSwatch.swatch(for: file))
    }

    func testATextItemThatIsAColour() {
        assertColor(ClipboardColorSwatch.swatch(for: Self.text("#FF5733")), 255, 87, 51, 1)
        XCTAssertNil(ClipboardColorSwatch.swatch(for: Self.text("not a colour")))
    }

    // MARK: - The label

    func testHexLabelIsTheColourBackOut() {
        XCTAssertEqual(ClipboardColorSwatch.parse("rgb(255, 87, 51)")?.hexLabel, "#FF5733")
        XCTAssertEqual(ClipboardColorSwatch.parse("#f53")?.hexLabel, "#FF5533")
        XCTAssertEqual(ClipboardColorSwatch.parse("#0a0b0c")?.hexLabel, "#0A0B0C")
    }

    func testHexLabelCarriesAlphaOnlyWhenThereIsSome() {
        XCTAssertEqual(ClipboardColorSwatch.parse("#FF5733")?.hexLabel, "#FF5733")
        XCTAssertEqual(ClipboardColorSwatch.parse("#FF573380")?.hexLabel, "#FF573380")
        // 0.5 rounds to 128, so the alpha byte is 80 rather than 7F.
        XCTAssertEqual(ClipboardColorSwatch.parse("rgba(255, 87, 51, 0.5)")?.hexLabel, "#FF573380")
    }

    func testTheLabelIsOnlyPrintedWhenItSaysSomethingTheClipDoesNot() {
        // The common item is a six digit hex, and a label repeating the line above it is a pixel
        // spent saying nothing.
        XCTAssertFalse(ClipboardColorSwatch.parse("#FF5733")!.addsHexLabel)
        XCTAssertFalse(ClipboardColorSwatch.parse("#ff5733")!.addsHexLabel)
        XCTAssertFalse(ClipboardColorSwatch.parse("  #ff5733 ")!.addsHexLabel)

        XCTAssertTrue(ClipboardColorSwatch.parse("rgb(255, 87, 51)")!.addsHexLabel)
        XCTAssertTrue(ClipboardColorSwatch.parse("#f53")!.addsHexLabel)
    }

    func testTranslucenceDrivesTheCheckerboard() {
        XCTAssertFalse(ClipboardColorSwatch.parse("#FF5733")!.isTranslucent)
        XCTAssertTrue(ClipboardColorSwatch.parse("#FF573380")!.isTranslucent)
        XCTAssertTrue(ClipboardColorSwatch.parse("rgba(0, 0, 0, 0)")!.isTranslucent)
    }

    // MARK: - Helpers

    private func assertColor(
        _ swatch: ClipboardColorSwatch?,
        _ red: Int,
        _ green: Int,
        _ blue: Int,
        _ alpha: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let swatch else {
            return XCTFail("Expected a colour, got nil", file: file, line: line)
        }
        XCTAssertEqual(swatch.red, red, "red", file: file, line: line)
        XCTAssertEqual(swatch.green, green, "green", file: file, line: line)
        XCTAssertEqual(swatch.blue, blue, "blue", file: file, line: line)
        XCTAssertEqual(swatch.alpha, alpha, accuracy: 0.0001, "alpha", file: file, line: line)
    }

    private static func text(_ content: String) -> ClipboardItem {
        ClipboardItem(
            id: UUID(),
            content: content,
            type: .text,
            timestamp: Date(timeIntervalSince1970: 0)
        )
    }

    private static func image() -> ClipboardItem {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        return ClipboardItem(
            id: UUID(),
            content: image,
            type: .image,
            timestamp: Date(timeIntervalSince1970: 0),
            associatedText: "#FF5733"
        )
    }
}
