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

    /// A concealed clip that is captured anyway (the guard off) is still only masked when the
    /// display preference asks for it. This is the default install: nothing is skipped and nothing
    /// is hidden, which is why the capture guard exists as a separate choice.
    func testConcealedClipIsNotMaskedWhenAutoDetectIsOff() {
        let flags = ClipboardSensitivityPolicy.flags(
            for: "hunter2",
            hasSensitivePasteboardType: true,
            autoDetectSensitiveData: false,
            autoHidePasswordLikeStrings: false
        )

        XCTAssertTrue(flags.isAutoSensitive)
        XCTAssertFalse(flags.isSensitive)
    }

    // MARK: - Capture guard

    func testConcealedClipIsSkippedOnlyWhenPreferenceIsEnabled() {
        XCTAssertEqual(
            ClipboardCapturePolicy.decision(
                hasSensitivePasteboardType: true,
                skipConcealedClips: true,
                sourceBundleIdentifier: "com.example.passwords",
                excludedBundleIdentifiers: []
            ),
            .skipConcealed
        )

        XCTAssertEqual(
            ClipboardCapturePolicy.decision(
                hasSensitivePasteboardType: true,
                skipConcealedClips: false,
                sourceBundleIdentifier: "com.example.passwords",
                excludedBundleIdentifiers: []
            ),
            .capture
        )
    }

    func testOrdinaryClipIsCapturedWithTheGuardEnabled() {
        XCTAssertEqual(
            ClipboardCapturePolicy.decision(
                hasSensitivePasteboardType: false,
                skipConcealedClips: true,
                sourceBundleIdentifier: "com.example.editor",
                excludedBundleIdentifiers: []
            ),
            .capture
        )
    }

    func testExcludedAppIsSkippedAndOtherAppsAreNot() {
        let excluded: Set<String> = ["com.example.bank", "com.example.terminal"]

        XCTAssertEqual(
            ClipboardCapturePolicy.decision(
                hasSensitivePasteboardType: false,
                skipConcealedClips: false,
                sourceBundleIdentifier: "com.example.bank",
                excludedBundleIdentifiers: excluded
            ),
            .skipExcludedApp(bundleIdentifier: "com.example.bank")
        )

        XCTAssertEqual(
            ClipboardCapturePolicy.decision(
                hasSensitivePasteboardType: false,
                skipConcealedClips: false,
                sourceBundleIdentifier: "com.example.editor",
                excludedBundleIdentifiers: excluded
            ),
            .capture
        )
    }

    /// Exclusion matches on the exact identifier. A prefix or a suffix of an excluded app's
    /// identifier is a different app, including the app's own helper processes.
    func testExclusionMatchesTheWholeBundleIdentifier() {
        let excluded: Set<String> = ["com.example.bank"]

        XCTAssertEqual(
            ClipboardCapturePolicy.decision(
                hasSensitivePasteboardType: false,
                skipConcealedClips: false,
                sourceBundleIdentifier: "com.example.bank.helper",
                excludedBundleIdentifiers: excluded
            ),
            .capture
        )

        XCTAssertEqual(
            ClipboardCapturePolicy.decision(
                hasSensitivePasteboardType: false,
                skipConcealedClips: false,
                sourceBundleIdentifier: "com.example",
                excludedBundleIdentifiers: excluded
            ),
            .capture
        )
    }

    /// An app with no bundle identifier cannot be told apart from any other, so it is captured
    /// rather than matched against the list by accident.
    func testUnknownSourceAppIsCaptured() {
        XCTAssertEqual(
            ClipboardCapturePolicy.decision(
                hasSensitivePasteboardType: false,
                skipConcealedClips: false,
                sourceBundleIdentifier: nil,
                excludedBundleIdentifiers: ["com.example.bank"]
            ),
            .capture
        )
    }

    /// The concealed marker comes from the app that owns the secret, so it decides before the
    /// frontmost-app guess does. Both paths skip, and the reported reason is the reliable one.
    func testConcealedMarkerIsReportedAheadOfAppExclusion() {
        XCTAssertEqual(
            ClipboardCapturePolicy.decision(
                hasSensitivePasteboardType: true,
                skipConcealedClips: true,
                sourceBundleIdentifier: "com.example.bank",
                excludedBundleIdentifiers: ["com.example.bank"]
            ),
            .skipConcealed
        )
    }

    // MARK: - Pausing capture

    /// The trap the pause exists to avoid. `changeCount` still holds the last clip capture saw, so
    /// resuming without adopting the pasteboard's current count would make the very next tick
    /// record the clip the user paused in order not to record.
    func testResumingSkipsWhateverWasCopiedWhilePaused() {
        let lastCaptured = 5
        // Two copies made while capture was off.
        let whilePaused = 7

        let resumed = ClipboardCapturePause.changeCountOnResume(pasteboardChangeCount: whilePaused)

        XCTAssertFalse(
            ClipboardCapturePause.hasUnseenClip(pasteboardChangeCount: whilePaused, lastSeenChangeCount: resumed)
        )
        XCTAssertTrue(
            ClipboardCapturePause.hasUnseenClip(pasteboardChangeCount: whilePaused, lastSeenChangeCount: lastCaptured),
            "Without the resync on resume, the clip copied while paused reads as new"
        )
    }

    /// Resuming suppresses exactly one thing: what is already on the pasteboard. The next copy is
    /// captured as normal, or the pause would never really end.
    func testTheFirstCopyAfterResumingIsCaptured() {
        let resumed = ClipboardCapturePause.changeCountOnResume(pasteboardChangeCount: 7)

        XCTAssertTrue(
            ClipboardCapturePause.hasUnseenClip(pasteboardChangeCount: 8, lastSeenChangeCount: resumed)
        )
    }

    /// Pausing and resuming with nothing copied in between leaves capture exactly where it was.
    func testResumingWithNothingCopiedInBetweenLosesNothing() {
        let lastCaptured = 5

        let resumed = ClipboardCapturePause.changeCountOnResume(pasteboardChangeCount: lastCaptured)

        XCTAssertEqual(resumed, lastCaptured)
        XCTAssertFalse(
            ClipboardCapturePause.hasUnseenClip(pasteboardChangeCount: lastCaptured, lastSeenChangeCount: resumed)
        )
    }

    /// Both guards off is the default install, and it must not change what is captured.
    func testNothingIsSkippedByDefault() {
        XCTAssertEqual(
            ClipboardCapturePolicy.decision(
                hasSensitivePasteboardType: true,
                skipConcealedClips: false,
                sourceBundleIdentifier: "com.example.passwords",
                excludedBundleIdentifiers: []
            ),
            .capture
        )
    }
}