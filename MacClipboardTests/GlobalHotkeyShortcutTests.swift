import AppKit
import Carbon
import XCTest
@testable import MacClipboard

/// The global hotkey is the one shortcut that is taken from every app on the Mac, so the rules
/// about what may be recorded, and what a recorded combination is shown as, are worth pinning.
final class GlobalHotkeyShortcutTests: XCTestCase {
    private let command = GlobalHotkeyShortcut.command
    private let shift = GlobalHotkeyShortcut.shift
    private let option = GlobalHotkeyShortcut.option
    private let control = GlobalHotkeyShortcut.control

    // MARK: - Defaults

    func testDefaultIsVWithAnExtraModifierForDevBuilds() {
        let shortcut = GlobalHotkeyShortcut.defaultForCurrentBuild

        XCTAssertEqual(shortcut.keyCode, GlobalHotkeyShortcut.vKeyCode)
        XCTAssertEqual(
            shortcut.carbonModifiers,
            BuildInfo.isDevBuild ? (command | shift | option) : (command | shift),
            "A dev build and an installed release build run side by side and would fight over one combination."
        )
        XCTAssertTrue(shortcut.isValid)
    }

    // MARK: - Display

    func testModifiersAreShownInTheOrderMacOSUsesThem() {
        // Key code 123 is the left arrow, which is labelled from a table rather than from the
        // keyboard layout, so this asserts the ordering on any layout the tests run on.
        let all = GlobalHotkeyShortcut(keyCode: 123, carbonModifiers: command | shift | option | control)

        XCTAssertEqual(all.displayString, "⌃ ⌥ ⇧ ⌘ ←")
        XCTAssertEqual(all.compactDisplayString, "⌃⌥⇧⌘←")
    }

    func testModifierDisplayStringRendersModifiersOnTheirOwn() {
        XCTAssertEqual(GlobalHotkeyShortcut.modifierDisplayString(command | shift, spaced: true), "⇧ ⌘")
        XCTAssertEqual(GlobalHotkeyShortcut.modifierDisplayString(command | shift, spaced: false), "⇧⌘")
        XCTAssertEqual(GlobalHotkeyShortcut.modifierDisplayString(0, spaced: true), "")
    }

    func testKeysWithoutAPrintableCharacterAreNamed() {
        XCTAssertEqual(GlobalHotkeyKey.label(for: 36), "↩")
        XCTAssertEqual(GlobalHotkeyKey.label(for: 48), "⇥")
        XCTAssertEqual(GlobalHotkeyKey.label(for: 51), "⌫")
        XCTAssertEqual(GlobalHotkeyKey.label(for: 53), "⎋")
        XCTAssertEqual(GlobalHotkeyKey.label(for: 126), "↑")
        XCTAssertEqual(GlobalHotkeyKey.label(for: 122), "F1")
        XCTAssertEqual(GlobalHotkeyKey.label(for: 111), "F12")
    }

    /// A shortcut whose key has no label is a shortcut the user cannot see, which is worse than an
    /// ugly one. Every key code has to produce something printable, including the ones no keyboard
    /// has and the ones the current layout cannot translate.
    func testEveryKeyCodeProducesAPrintableLabel() {
        for keyCode in UInt32(0)...UInt32(200) {
            let label = GlobalHotkeyKey.label(for: keyCode)
            XCTAssertFalse(label.isEmpty, "Key code \(keyCode) produced an empty label")
            XCTAssertNil(
                label.rangeOfCharacter(from: .controlCharacters),
                "Key code \(keyCode) produced a control character: \(label.debugDescription)"
            )
        }
    }

    // MARK: - Validation

    func testACombinationWithoutCommandControlOrOptionIsRefused() {
        XCTAssertEqual(GlobalHotkeyShortcut(keyCode: 9, carbonModifiers: 0).rejection, .needsModifier)
        XCTAssertEqual(GlobalHotkeyShortcut(keyCode: 9, carbonModifiers: shift).rejection, .needsModifier)
    }

    func testCommandPlusOneKeyIsRefused() {
        // ⌘V globally would take Paste away from every app on the Mac.
        XCTAssertEqual(GlobalHotkeyShortcut(keyCode: 9, carbonModifiers: command).rejection, .commandAlone)

        XCTAssertTrue(GlobalHotkeyShortcut(keyCode: 9, carbonModifiers: command | shift).isValid)
        XCTAssertTrue(GlobalHotkeyShortcut(keyCode: 9, carbonModifiers: command | option).isValid)
        XCTAssertTrue(GlobalHotkeyShortcut(keyCode: 9, carbonModifiers: control).isValid)
        XCTAssertTrue(GlobalHotkeyShortcut(keyCode: 9, carbonModifiers: option | shift).isValid)
    }

    func testFunctionKeysStandAloneWithNoModifier() {
        XCTAssertTrue(GlobalHotkeyShortcut(keyCode: 105, carbonModifiers: 0).isValid, "F13")
        XCTAssertTrue(GlobalHotkeyShortcut(keyCode: 122, carbonModifiers: 0).isValid, "F1")
        XCTAssertTrue(GlobalHotkeyShortcut(keyCode: 122, carbonModifiers: command).isValid, "⌘F1")
        XCTAssertFalse(GlobalHotkeyKey.isFunctionKey(9))
    }

    // MARK: - Modifier flags

    /// `NSEvent.modifierFlags` also reports caps lock, the keypad and fn. Carbon cannot register
    /// those, and keeping them would make two otherwise identical shortcuts compare unequal
    /// depending on whether caps lock happened to be down when one of them was recorded.
    func testUnsupportedModifierBitsAreDropped() {
        let flags: NSEvent.ModifierFlags = [.command, .shift, .capsLock, .function, .numericPad]
        let recorded = GlobalHotkeyShortcut(
            keyCode: 9,
            carbonModifiers: GlobalHotkeyShortcut.carbonModifiers(from: flags)
        )

        XCTAssertEqual(recorded, GlobalHotkeyShortcut(keyCode: 9, carbonModifiers: command | shift))
        XCTAssertEqual(recorded.carbonModifiers & ~GlobalHotkeyShortcut.supportedModifiers, 0)
    }

    func testEveryCarbonModifierIsCarriedOver() {
        let flags: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

        XCTAssertEqual(
            GlobalHotkeyShortcut.carbonModifiers(from: flags),
            command | shift | option | control
        )
    }
}

/// The stored half. A hotkey nobody can reach is a support request rather than a bug report, so
/// what comes back from disk matters as much as what goes to it.
final class GlobalHotkeyPreferenceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "MacClipboardTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults = nil
        if let suiteName {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        suiteName = nil
        try super.tearDownWithError()
    }

    func testARecordedShortcutSurvivesARelaunch() {
        let recorded = GlobalHotkeyShortcut(
            keyCode: 8,
            carbonModifiers: GlobalHotkeyShortcut.control | GlobalHotkeyShortcut.option
        )

        UserPreferencesManager(defaults: defaults).globalHotkey = recorded

        XCTAssertEqual(UserPreferencesManager(defaults: defaults).globalHotkey, recorded)
    }

    func testNothingStoredMeansTheDefaultForThisBuild() {
        XCTAssertEqual(UserPreferencesManager(defaults: defaults).globalHotkey, .defaultForCurrentBuild)
    }

    /// A combination the recorder would refuse must not arrive from disk either, whichever version
    /// of the app wrote it: ⌘ plus one key would take that key from every app, and the user would
    /// have no way to know why.
    func testAnUnusableStoredShortcutFallsBackToTheDefault() {
        defaults.set(9, forKey: "globalHotkeyKeyCode")
        defaults.set(Int(GlobalHotkeyShortcut.command), forKey: "globalHotkeyModifiers")

        XCTAssertEqual(UserPreferencesManager(defaults: defaults).globalHotkey, .defaultForCurrentBuild)
    }

    func testGarbageStoredValuesFallBackToTheDefault() {
        defaults.set("nine", forKey: "globalHotkeyKeyCode")
        defaults.set(-1, forKey: "globalHotkeyModifiers")

        XCTAssertEqual(UserPreferencesManager(defaults: defaults).globalHotkey, .defaultForCurrentBuild)
    }

    func testResetRestoresTheDefaultShortcut() {
        let preferences = UserPreferencesManager(defaults: defaults)
        preferences.globalHotkey = GlobalHotkeyShortcut(
            keyCode: 8,
            carbonModifiers: GlobalHotkeyShortcut.control | GlobalHotkeyShortcut.option
        )

        preferences.resetToDefaults()

        XCTAssertEqual(preferences.globalHotkey, .defaultForCurrentBuild)
    }
}
