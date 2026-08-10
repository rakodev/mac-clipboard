import AppKit
import XCTest
@testable import MacClipboard

final class AppearancePreferenceTests: XCTestCase {

    // MARK: - What Is Stored

    func testRawValuesAreTheStoredStrings() {
        // These strings are on disk in every user's preferences. Renaming a case without keeping its
        // raw value would read as an unrecognised value and quietly hand someone back the system
        // appearance they had switched off.
        XCTAssertEqual(AppearancePreference.system.rawValue, "system")
        XCTAssertEqual(AppearancePreference.light.rawValue, "light")
        XCTAssertEqual(AppearancePreference.dark.rawValue, "dark")
    }

    func testStoredReadsEachValueBack() {
        XCTAssertEqual(AppearancePreference.stored("system"), .system)
        XCTAssertEqual(AppearancePreference.stored("light"), .light)
        XCTAssertEqual(AppearancePreference.stored("dark"), .dark)
    }

    func testNothingStoredMeansFollowTheSystem() {
        XCTAssertEqual(AppearancePreference.stored(nil), .system)
        XCTAssertEqual(AppearancePreference.default, .system)
    }

    func testUnrecognisedValueFallsBackToTheSystem() {
        // A value written by a later version, a case that has since been removed, or a string nobody
        // typed on purpose. Following the system is the state both appearances are exercised in.
        XCTAssertEqual(AppearancePreference.stored("midnight"), .system)
        XCTAssertEqual(AppearancePreference.stored(""), .system)
        XCTAssertEqual(AppearancePreference.stored("Dark"), .system)
    }

    // MARK: - What AppKit Is Handed

    func testSystemHandsAppKitNoAppearance() {
        // nil is not "leave it alone", it is "follow the system", which is why the case has to have
        // something to assign rather than skipping the assignment.
        XCTAssertNil(AppearancePreference.system.nsAppearance)
    }

    func testLightAndDarkNameTheTwoSystemAppearances() {
        XCTAssertEqual(AppearancePreference.light.nsAppearance?.name, .aqua)
        XCTAssertEqual(AppearancePreference.dark.nsAppearance?.name, .darkAqua)
    }

    func testApplyingSetsAndThenClearsTheOverride() {
        let application = NSApplication.shared
        let original = application.appearance
        defer { application.appearance = original }

        AppearancePreference.dark.apply(to: application)
        XCTAssertEqual(application.appearance?.name, .darkAqua)

        AppearancePreference.light.apply(to: application)
        XCTAssertEqual(application.appearance?.name, .aqua)

        // The half that is easy to lose: going back to System has to clear the override, not leave
        // the last one in place.
        AppearancePreference.system.apply(to: application)
        XCTAssertNil(application.appearance)
    }

    // MARK: - The Control's Order

    func testSystemIsOfferedFirst() {
        // The segmented control in Settings is drawn from allCases, and the default belongs at the
        // left-hand end of it.
        XCTAssertEqual(AppearancePreference.allCases, [.system, .light, .dark])
    }

    // MARK: - Round Trip Through Preferences

    func testPreferenceSurvivesARelaunch() throws {
        let defaults = try makeDefaults()

        UserPreferencesManager(defaults: defaults).appearance = .dark

        XCTAssertEqual(UserPreferencesManager(defaults: defaults).appearance, .dark)
    }

    func testPreferenceDefaultsToTheSystemWithNothingStored() throws {
        let defaults = try makeDefaults()

        XCTAssertEqual(UserPreferencesManager(defaults: defaults).appearance, .system)
    }

    func testStoredRubbishReadsAsTheSystem() throws {
        let defaults = try makeDefaults()
        defaults.set("solarized", forKey: "appearance")

        XCTAssertEqual(UserPreferencesManager(defaults: defaults).appearance, .system)
    }

    func testResetGoesBackToTheSystem() throws {
        let defaults = try makeDefaults()
        let preferences = UserPreferencesManager(defaults: defaults)
        preferences.appearance = .light

        preferences.resetToDefaults()

        XCTAssertEqual(preferences.appearance, .system)
        XCTAssertEqual(UserPreferencesManager(defaults: defaults).appearance, .system)
    }

    // MARK: - Helpers

    /// A suite of its own per test, for the reason `UserPreferencesManager` takes a `UserDefaults` at
    /// all: the standard domain is the developer's own copy of the app.
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "com.macclipboard.tests.appearance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
