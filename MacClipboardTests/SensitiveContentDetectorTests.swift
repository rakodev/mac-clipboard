import XCTest
@testable import MacClipboard

final class SensitiveContentDetectorTests: XCTestCase {
    func testDetectsCommonSensitivePatterns() {
        XCTAssertTrue(SensitiveContentDetector.matchesSensitivePattern("OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz123456"))
        XCTAssertTrue(SensitiveContentDetector.matchesSensitivePattern("aws_access_key_id = AKIAABCDEFGHIJKLMNOP"))
        XCTAssertTrue(SensitiveContentDetector.matchesSensitivePattern("token=ghp_abcdefghijklmnopqrstuvwxyz1234567890AB"))
        XCTAssertTrue(SensitiveContentDetector.matchesSensitivePattern("postgres://user:secret@example.com/db"))
    }

    func testPasswordLikeDetectionAndFalsePositives() {
        XCTAssertTrue(SensitiveContentDetector.looksLikePassword("Aabbcc11!!"))
        XCTAssertFalse(SensitiveContentDetector.looksLikePassword("https://example.com/Aabbcc11!!"))
        XCTAssertFalse(SensitiveContentDetector.looksLikePassword("person@example.com"))
        XCTAssertFalse(SensitiveContentDetector.looksLikePassword("550e8400-e29b-41d4-a716-446655440000"))
        XCTAssertFalse(SensitiveContentDetector.looksLikePassword("CorrectHorseBatteryStaple"))
        XCTAssertFalse(SensitiveContentDetector.looksLikePassword("Aabb cc11!!"))
    }

    func testLargeTextSkipsPatternMatching() {
        let largeText = String(repeating: "a", count: 100 * 1024 + 1) + " sk-abcdefghijklmnopqrstuvwxyz123456"

        XCTAssertFalse(SensitiveContentDetector.matchesSensitivePattern(largeText))
    }

    func testPreferencePolicyControlsAutoSensitiveVisibility() {
        let secretText = "OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz123456"

        let disabled = ClipboardSensitivityPolicy.flags(
            for: secretText,
            hasSensitivePasteboardType: false,
            autoDetectSensitiveData: false,
            autoHidePasswordLikeStrings: false
        )
        XCTAssertTrue(disabled.isAutoSensitive)
        XCTAssertFalse(disabled.isSensitive)

        let enabled = ClipboardSensitivityPolicy.flags(
            for: secretText,
            hasSensitivePasteboardType: false,
            autoDetectSensitiveData: true,
            autoHidePasswordLikeStrings: false
        )
        XCTAssertTrue(enabled.isAutoSensitive)
        XCTAssertTrue(enabled.isSensitive)
    }

    func testPreferencePolicyControlsPasswordLikeVisibility() {
        let passwordLike = "Aabbcc11!!"

        let disabled = ClipboardSensitivityPolicy.flags(
            for: passwordLike,
            hasSensitivePasteboardType: false,
            autoDetectSensitiveData: false,
            autoHidePasswordLikeStrings: false
        )
        XCTAssertTrue(disabled.isPasswordLike)
        XCTAssertFalse(disabled.isSensitive)

        let enabled = ClipboardSensitivityPolicy.flags(
            for: passwordLike,
            hasSensitivePasteboardType: false,
            autoDetectSensitiveData: false,
            autoHidePasswordLikeStrings: true
        )
        XCTAssertTrue(enabled.isPasswordLike)
        XCTAssertTrue(enabled.isSensitive)
    }

    func testSensitivePasteboardTypeHonorsAutoDetectPreference() {
        let flags = ClipboardSensitivityPolicy.flags(
            for: nil,
            hasSensitivePasteboardType: true,
            autoDetectSensitiveData: true,
            autoHidePasswordLikeStrings: false
        )

        XCTAssertTrue(flags.isAutoSensitive)
        XCTAssertTrue(flags.isSensitive)
        XCTAssertFalse(flags.isPasswordLike)
    }
}