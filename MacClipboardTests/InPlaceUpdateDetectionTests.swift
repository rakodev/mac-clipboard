import AppKit
import XCTest
@testable import MacClipboard

/// Covers the detection behind `AppInstallation.wasReplacedInPlace`.
///
/// A Homebrew upgrade moves the old bundle aside and moves the new one into the same path while
/// the app keeps running. macOS then refuses that process for Accessibility, because the code
/// identity it recorded no longer matches the binary now at its path, so auto-paste and the
/// global hotkey stop working while System Settings still shows MacClipboard as enabled. Getting
/// this decision wrong is expensive in both directions: too eager and the app restarts itself
/// under a user who did not ask for it, too shy and the upgrade silently breaks the app.
final class InPlaceUpdateDetectionTests: XCTestCase {

    private func fingerprint(inode: UInt64, cdHash: String?, version: String? = "1") -> AppInstallation.BinaryFingerprint {
        AppInstallation.BinaryFingerprint(
            inode: inode,
            cdHash: cdHash.map { Data($0.utf8) },
            version: version
        )
    }

    func testReplacementIsDetectedWhenTheFileAndItsCodeIdentityBothChange() {
        let launch = fingerprint(inode: 1, cdHash: "old-build")
        let current = fingerprint(inode: 2, cdHash: "new-build", version: "2")

        XCTAssertTrue(AppInstallation.wasReplaced(launch: launch, current: current))
    }

    func testUntouchedBundleIsNotAReplacement() {
        let launch = fingerprint(inode: 1, cdHash: "same-build")

        XCTAssertFalse(AppInstallation.wasReplaced(launch: launch, current: launch))
    }

    /// The same build copied into place again keeps its code identity, and macOS keeps trusting
    /// the running process, so restarting the user's app would be pure disruption.
    func testSameBuildCopiedAgainIsNotAReplacement() {
        let launch = fingerprint(inode: 1, cdHash: "same-build")
        let current = fingerprint(inode: 2, cdHash: "same-build")

        XCTAssertFalse(AppInstallation.wasReplaced(launch: launch, current: current))
    }

    /// Halfway through an upgrade the new bundle can be on disk without a readable signature yet.
    /// That has to read as "not yet", because the poll comes round again a moment later, and
    /// quitting into a half-written bundle would leave the user with nothing running.
    func testUnreadableSignatureIsNotYetAReplacement() {
        let launch = fingerprint(inode: 1, cdHash: "old-build")

        XCTAssertFalse(AppInstallation.wasReplaced(launch: launch, current: fingerprint(inode: 2, cdHash: nil)))
        XCTAssertFalse(AppInstallation.wasReplaced(launch: fingerprint(inode: 1, cdHash: nil),
                                                   current: fingerprint(inode: 2, cdHash: "new-build")))
    }

    /// A missing file gives inode 0. Treating that as a replacement would relaunch from a path
    /// that has nothing at it.
    func testUnusableFingerprintIsNotAReplacement() {
        let usable = fingerprint(inode: 1, cdHash: "old-build")
        let missing = fingerprint(inode: 0, cdHash: nil, version: nil)

        XCTAssertFalse(AppInstallation.wasReplaced(launch: usable, current: missing))
        XCTAssertFalse(AppInstallation.wasReplaced(launch: missing, current: usable))
    }

    /// The reading side: a real bundle on disk has to produce something usable, otherwise the
    /// decision above never gets the inputs it needs. The test host is a signed bundle, so it
    /// stands in for an installed copy.
    func testFingerprintReadsTheRunningBundle() {
        let running = AppInstallation.fingerprint(ofExecutableAt: AppInstallation.bundleURL)

        XCTAssertTrue(running.isUsable, "the running bundle's executable should be stattable")
        XCTAssertNotNil(running.cdHash, "a signed bundle should report a code directory hash")
        XCTAssertEqual(running.version, Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
    }

    func testFingerprintOfMissingBundleIsUnusable() {
        let missing = AppInstallation.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("NoSuchApp-\(UUID().uuidString).app")

        XCTAssertFalse(AppInstallation.fingerprint(ofExecutableAt: missing).isUsable)
    }
}
