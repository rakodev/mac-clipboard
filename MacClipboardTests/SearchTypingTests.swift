import XCTest
import AppKit
@testable import MacClipboard

/// What a key pressed over the popover means. The rules that matter are the two that were bugs: a
/// letter must never be lost to a shortcut case that then declines it, and a letter typed before
/// AppKit has handed the search field the keyboard must still reach the search.
final class SearchTypingTests: XCTestCase {

    // MARK: - Starting a search

    func testALetterOverTheListStartsASearch() {
        XCTAssertEqual(outcome(characters: "p", keyCode: keyP), .start("p"))
    }

    func testTheLettersThatUsedToBeSwallowedByAShortcutStartASearchToo() {
        // f, d, z, e, h, v, n and m each match a ⌘-shortcut's key code. Without the modifier they
        // are letters, and while this was decided in the shortcut table's default arm they reached
        // neither the table nor the field: "favorite" searched for "avorite".
        let swallowed: [(String, UInt16)] = [
            ("f", 3), ("d", 2), ("z", 6), ("e", 14), ("h", 4), ("v", 9), ("n", 45), ("m", 46)
        ]

        for (character, keyCode) in swallowed {
            XCTAssertEqual(
                outcome(characters: character, keyCode: keyCode),
                .start(character),
                "\(character) should start a search"
            )
        }
    }

    func testADigitStartsASearchNowThatItNoLongerJumpsTheSelection() {
        let digits: [(String, UInt16)] = [
            ("0", 29), ("1", 18), ("2", 19), ("3", 20), ("4", 21),
            ("5", 23), ("6", 22), ("7", 26), ("8", 28), ("9", 25)
        ]

        for (character, keyCode) in digits {
            XCTAssertEqual(
                outcome(characters: character, keyCode: keyCode),
                .start(character),
                "\(character) should start a search"
            )
        }
    }

    func testSpaceAndPunctuationAreSearchableCharacters() {
        XCTAssertEqual(outcome(characters: " ", keyCode: 49), .start(" "))
        XCTAssertEqual(outcome(characters: "-", keyCode: 27), .start("-"))
        XCTAssertEqual(outcome(characters: "@", keyCode: 19), .start("@"))
    }

    func testAcceptedCharactersAreNotLimitedToASCII() {
        // ⌥e then e is an é, and a clip is as likely to hold one as not.
        XCTAssertEqual(outcome(characters: "é", keyCode: 14, modifiers: []), .start("é"))
    }

    func testAStartedSearchReplacesWhateverTheFieldWasLeftShowing() {
        // The field keeps its text when the list takes the keyboard back, so the first letter of the
        // next search has to mean a new search rather than an addition to the old one.
        let state = ClipboardSearchTyping.State(
            fieldHasKeyboard: false,
            noteHasKeyboard: false,
            searchIsFocused: false,
            searchIsEmpty: false
        )

        XCTAssertEqual(outcome(characters: "p", keyCode: keyP, state: state), .start("p"))
    }

    // MARK: - The gap between asking for focus and having it

    func testALetterTypedBeforeTheFieldHasTheKeyboardExtendsTheSearch() {
        // The whole bug: "pickup" typed quickly arrived as "pckup", because the second letter was
        // tested against an intention that had already flipped and so was claimed by nobody.
        XCTAssertEqual(outcome(characters: "i", keyCode: keyI, state: handoffInFlight), .extend("i"))
    }

    func testEveryLetterOfAFastSearchSurvivesTheHandoff() {
        var searchText = ""
        var isFocused = false

        // The field is still catching up throughout, which is the worst case rather than an unlikely
        // one: it is what typing at speed looks like.
        for character in "pickup" {
            let state = ClipboardSearchTyping.State(
                fieldHasKeyboard: false,
                noteHasKeyboard: false,
                searchIsFocused: isFocused,
                searchIsEmpty: searchText.isEmpty
            )

            switch outcome(characters: String(character), keyCode: keyP, state: state) {
            case .start(let text):
                searchText = text
                isFocused = true
            case .extend(let text):
                searchText += text
            default:
                XCTFail("\(character) was not claimed for the search")
            }
        }

        XCTAssertEqual(searchText, "pickup")
    }

    func testTheFieldGetsItsOwnKeysOnceItHasTheKeyboard() {
        let state = ClipboardSearchTyping.State(
            fieldHasKeyboard: true,
            noteHasKeyboard: false,
            searchIsFocused: true,
            searchIsEmpty: false
        )

        // Claiming here as well would type every letter twice.
        XCTAssertEqual(outcome(characters: "i", keyCode: keyI, state: state), .shortcut)
    }

    func testBackspaceCorrectsASearchOnlyWhileOneIsBeingTyped() {
        XCTAssertEqual(outcome(characters: "\u{8}", keyCode: 51, state: handoffInFlight), .deleteLast)

        let nothingTyped = ClipboardSearchTyping.State(
            fieldHasKeyboard: false,
            noteHasKeyboard: false,
            searchIsFocused: false,
            searchIsEmpty: true
        )
        XCTAssertEqual(outcome(characters: "\u{8}", keyCode: 51, state: nothingTyped), .shortcut)

        let searchEmptied = ClipboardSearchTyping.State(
            fieldHasKeyboard: false,
            noteHasKeyboard: false,
            searchIsFocused: true,
            searchIsEmpty: true
        )
        XCTAssertEqual(outcome(characters: "\u{8}", keyCode: 51, state: searchEmptied), .shortcut)
    }

    // MARK: - What the shortcut table keeps

    func testModifiedLettersAreShortcuts() {
        XCTAssertEqual(outcome(characters: "f", keyCode: 3, modifiers: .command), .shortcut)
        XCTAssertEqual(outcome(characters: "m", keyCode: 46, modifiers: [.command, .shift]), .shortcut)
        XCTAssertEqual(outcome(characters: "c", keyCode: 8, modifiers: .control), .shortcut)
    }

    func testShiftIsNotAModifierThatMakesAShortcut() {
        // A capital letter is a search term.
        XCTAssertEqual(outcome(characters: "P", keyCode: keyP, modifiers: .shift), .start("P"))
    }

    func testTheKeysThatDriveTheListAreNeverTyping() {
        let navigation: [UInt16] = [
            36,  // Return
            48,  // Tab
            53,  // Escape
            117, // Forward delete
            123, 124, 125, 126 // Arrows
        ]

        for keyCode in navigation {
            XCTAssertEqual(
                outcome(characters: "\u{f700}", keyCode: keyCode),
                .shortcut,
                "key code \(keyCode) should be left to the shortcut table"
            )
        }
    }

    func testANoteBeingWrittenIsNotASearch() {
        let state = ClipboardSearchTyping.State(
            fieldHasKeyboard: false,
            noteHasKeyboard: true,
            searchIsFocused: false,
            searchIsEmpty: true
        )

        XCTAssertEqual(outcome(characters: "p", keyCode: keyP, state: state), .shortcut)
    }

    func testAKeyCarryingNoCharacterIsNotTyping() {
        XCTAssertEqual(outcome(characters: nil, keyCode: keyP), .shortcut)
        XCTAssertEqual(outcome(characters: "", keyCode: keyP), .shortcut)
    }

    // MARK: - Helpers

    private let keyP: UInt16 = 35
    private let keyI: UInt16 = 34

    /// Nothing typed yet, and the list has the keyboard.
    private let atRest = ClipboardSearchTyping.State(
        fieldHasKeyboard: false,
        noteHasKeyboard: false,
        searchIsFocused: false,
        searchIsEmpty: true
    )

    /// A search has been started and the field has not been given the keyboard yet.
    private let handoffInFlight = ClipboardSearchTyping.State(
        fieldHasKeyboard: false,
        noteHasKeyboard: false,
        searchIsFocused: true,
        searchIsEmpty: false
    )

    private func outcome(
        characters: String?,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        state: ClipboardSearchTyping.State? = nil
    ) -> ClipboardSearchTyping.Outcome {
        ClipboardSearchTyping.outcome(
            characters: characters,
            keyCode: keyCode,
            modifiers: modifiers,
            state: state ?? atRest
        )
    }
}
