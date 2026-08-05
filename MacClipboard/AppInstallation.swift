import AppKit
import Security

/// Where this copy of MacClipboard lives, and which other copies macOS knows about.
///
/// Duplicate copies are the most common cause of "the Accessibility toggle is switched on but
/// auto-paste does nothing". macOS keys an Accessibility grant on the bundle id *and* the code
/// signing requirement recorded when the grant was made, so a second copy that shares the
/// bundle id but is signed differently (an old local build, a copy still sitting in Downloads,
/// a Gatekeeper-translocated copy) is refused while System Settings keeps listing the app as
/// enabled. Two copies also mean two pasteboard pollers writing to one Core Data store and a
/// race for the global hotkey, so this is worth detecting and telling the user about plainly.
enum AppInstallation {

    // MARK: - This Copy

    static var bundleURL: URL {
        Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
    }

    /// True when Gatekeeper is running us from a randomised read-only mount instead of the
    /// place the user put the app.
    ///
    /// This happens to every quarantined app that is launched from Downloads or straight out
    /// of a disk image without being moved first. The bundle path changes on every launch, so
    /// no Accessibility grant can ever stick, and the user cannot tell from the UI why.
    static var isTranslocated: Bool {
        bundleURL.path.contains("/AppTranslocation/")
    }

    /// True when the app is running from a disk image or any other read-only mount.
    static var isOnReadOnlyVolume: Bool {
        (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
    }

    /// True when the app sits in a system or user Applications folder, which is where a grant
    /// can survive relaunches and upgrades.
    static var isInApplicationsFolder: Bool {
        applicationsDirectories.contains { bundleURL.path.hasPrefix($0.path + "/") }
    }

    /// Every Applications folder that counts as a real install location, most preferred first.
    private static var applicationsDirectories: [URL] {
        FileManager.default
            .urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
            .map { $0.resolvingSymlinksInPath().standardizedFileURL }
    }

    /// Why this copy cannot hold on to its permissions, if that is the case.
    enum LocationProblem: Equatable {
        /// Gatekeeper is running a randomised copy; the bundle path changes every launch.
        case translocated
        /// Running from a disk image or other read-only mount.
        case readOnlyVolume
        /// Running from an arbitrary folder such as Downloads or the Desktop.
        case notInApplicationsFolder
    }

    static var locationProblem: LocationProblem? {
        // A dev build deliberately runs from wherever it was built, and has its own bundle id
        // and its own TCC record, so none of this applies to it.
        guard !BuildInfo.isDevBuild else { return nil }

        if isTranslocated { return .translocated }
        if isOnReadOnlyVolume { return .readOnlyVolume }
        if !isInApplicationsFolder { return .notInApplicationsFolder }
        return nil
    }

    // MARK: - Replaced Underneath Us

    /// What identifies the exact binary this process is running, so a replacement is detectable.
    ///
    /// `cdHash` is the value macOS itself keys code identity on, and it changes on every build.
    /// The inode is the cheap check that says "look again": a bundle is replaced by moving a new
    /// one into its place, so the file at our path becomes a different file.
    struct BinaryFingerprint: Equatable {
        let inode: UInt64
        let cdHash: Data?
        let version: String?

        var isUsable: Bool { inode != 0 }
    }

    /// The identity of the executable this process launched from, captured before anything can
    /// replace it.
    static let launchFingerprint: BinaryFingerprint = fingerprint(ofExecutableAt: bundleURL)

    private static var executableURL: URL {
        Bundle.main.executableURL?.resolvingSymlinksInPath().standardizedFileURL
            ?? bundleURL.appendingPathComponent("Contents/MacOS/MacClipboard")
    }

    static func fingerprint(ofExecutableAt bundle: URL) -> BinaryFingerprint {
        BinaryFingerprint(
            inode: inodeOfExecutable(in: bundle),
            cdHash: codeDirectoryHash(for: bundle),
            version: version(at: bundle)
        )
    }

    /// The cheap half of a fingerprint, and the only part the poll pays for while nothing changes.
    private static func inodeOfExecutable(in bundle: URL) -> UInt64 {
        let executable = bundle == bundleURL
            ? executableURL
            : bundle.appendingPathComponent("Contents/MacOS/MacClipboard")

        var status = stat()
        return stat(executable.path, &status) == 0 ? status.st_ino : 0
    }

    private static func codeDirectoryHash(for url: URL) -> Data? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return nil }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }

        return dictionary[kSecCodeInfoUnique as String] as? Data
    }

    private static func version(at bundle: URL) -> String? {
        guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        else { return nil }
        return info["CFBundleVersion"] as? String
    }

    /// True when the bundle we are running from has been replaced on disk by a different build.
    ///
    /// This is what a Homebrew upgrade does: it moves the old bundle aside and moves the new one
    /// into the same path, without quitting the running app first. macOS then stops honouring
    /// this process's Accessibility grant, because the code identity it recorded no longer
    /// matches the binary now at our path, and the app looks broken while System Settings still
    /// shows it as enabled. Nothing the user can do in System Settings fixes it. Relaunching
    /// does, and `relaunchAfterInPlaceUpdate` is how.
    ///
    /// Only a changed inode *and* a changed code hash counts, so re-copying an identical build
    /// (or anything that merely touches the bundle) is not mistaken for an update.
    static func wasReplacedInPlace() -> Bool {
        // A dev build is replaced by every `run.sh`, which quits and relaunches it itself, and it
        // has its own bundle id and TCC record either way.
        guard !BuildInfo.isDevBuild else { return false }

        let launch = launchFingerprint
        guard launch.isUsable else { return false }

        // Poll on the inode alone. Reading a code signature means going through the Security
        // framework and hashing part of the binary, which is far too much to repeat every few
        // seconds for an app whose whole point is staying out of the way, and it can only tell us
        // something once a different file is actually at our path.
        let inode = inodeOfExecutable(in: bundleURL)
        guard inode != 0, inode != launch.inode else { return false }

        return wasReplaced(launch: launch, current: fingerprint(ofExecutableAt: bundleURL))
    }

    /// The decision behind `wasReplacedInPlace`, separated so it can be tested without needing a
    /// second copy of the app to be installed and replaced.
    static func wasReplaced(launch: BinaryFingerprint, current: BinaryFingerprint) -> Bool {
        // No usable reading of either side means no evidence of anything.
        guard launch.isUsable, current.isUsable else { return false }

        // Same file: nothing has been moved into our place.
        guard current.inode != launch.inode else { return false }

        // A different file with the same code identity is the same build copied again, which
        // macOS keeps trusting. Only a different identity costs us the grant.
        //
        // Mid-upgrade the new bundle can be only partly in place, so an unreadable signature is
        // "not yet" rather than "replaced". The next poll picks it up.
        guard let currentHash = current.cdHash, let launchHash = launch.cdHash else { return false }
        return currentHash != launchHash
    }

    /// Start the new copy and quit this one, so the user ends up on a process macOS trusts.
    ///
    /// Terminating only once the replacement is actually up means a bundle that cannot launch
    /// leaves the user with a working, if outdated, app rather than nothing at all.
    static func relaunchAfterInPlaceUpdate() {
        let destination = bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        // Without this, macOS just activates *this* process, which is the one that has to go.
        configuration.createsNewApplicationInstance = true
        configuration.activates = false

        Logging.info("[Install] Bundle was replaced on disk; relaunching from \(destination.path)")

        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    Logging.info("[Install] Relaunch after update failed: \(error.localizedDescription)")
                    return
                }
                Logging.info("[Install] Replacement instance is up; quitting the updated-away copy")
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Other Copies

    /// One installed copy of this app as LaunchServices sees it.
    struct Copy: Identifiable, Hashable {
        let url: URL
        let version: String?
        let isAdHocSigned: Bool
        let teamIdentifier: String?

        var id: URL { url }

        /// True for a properly distributed build: signed with a Developer ID team, not ad hoc.
        var isDeveloperIDSigned: Bool { !isAdHocSigned && teamIdentifier != nil }

        var displayVersion: String { version ?? "?" }

        /// Path with the home directory abbreviated, for display in alerts.
        var displayPath: String { (url.path as NSString).abbreviatingWithTildeInPath }
    }

    /// Every copy registered under our bundle id, including this one.
    static func registeredCopies() -> [Copy] {
        NSWorkspace.shared
            .urlsForApplications(withBundleIdentifier: BuildInfo.bundleIdentifier)
            .map { $0.resolvingSymlinksInPath().standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(describe(url:))
    }

    /// Copies that are not this one and that the user can actually do something about. Any entry
    /// here can break the Accessibility grant.
    ///
    /// Three kinds of registered copy are deliberately ignored:
    /// - a translocated path, which is this same bundle seen from a randomised mount rather than
    ///   a second install, and is already reported by `locationProblem`;
    /// - anything in a Trash folder, which the user has already dealt with;
    /// - anything on a read-only volume, typically the installer disk image still being mounted,
    ///   which cannot be removed and disappears on eject.
    static func duplicateCopies() -> [Copy] {
        let own = bundleURL
        return registeredCopies().filter { copy in
            guard copy.url != own,
                  !copy.url.path.contains("/AppTranslocation/"),
                  !copy.url.pathComponents.contains(".Trash") else { return false }
            let isReadOnly = (try? copy.url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
            return !isReadOnly
        }
    }

    /// The running copy, described the same way as the others so it can be compared with them.
    static var thisCopy: Copy { describe(url: bundleURL) }

    /// Of every registered copy, the one worth keeping, or nil when that is the running copy and
    /// there is nothing better to point the user at.
    static func betterCopyThanThisOne() -> Copy? {
        let candidates = [thisCopy] + duplicateCopies()
        guard let preferred = preferredCopy(among: candidates), preferred.url != bundleURL else { return nil }
        return preferred
    }

    /// The copy the user should keep: prefer an Applications folder, then a real Developer ID
    /// signature, then the highest version.
    static func preferredCopy(among copies: [Copy]) -> Copy? {
        copies.max { lhs, rhs in
            let lhsScore = score(lhs)
            let rhsScore = score(rhs)
            if lhsScore != rhsScore { return lhsScore < rhsScore }
            return (lhs.version ?? "").compare(rhs.version ?? "", options: .numeric) == .orderedAscending
        }
    }

    private static func score(_ copy: Copy) -> Int {
        var value = 0
        if applicationsDirectories.contains(where: { copy.url.path.hasPrefix($0.path + "/") }) { value += 2 }
        if copy.isDeveloperIDSigned { value += 1 }
        return value
    }

    private static func describe(url: URL) -> Copy {
        let plist = Bundle(url: url)?.infoDictionary
        let signature = signingInformation(for: url)
        return Copy(url: url,
                    version: plist?["CFBundleShortVersionString"] as? String,
                    isAdHocSigned: signature.isAdHoc,
                    teamIdentifier: signature.teamIdentifier)
    }

    // MARK: - Signing Identity

    /// Ad hoc and team identity of a bundle on disk.
    ///
    /// Used to explain a refused Accessibility grant: an ad hoc signature pins the grant to one
    /// exact binary hash, so a locally built copy loses it on every rebuild, and it can never
    /// match a record that a Developer ID signed release created.
    static func signingInformation(for url: URL) -> (isAdHoc: Bool, teamIdentifier: String?) {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return (false, nil) }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return (false, nil) }

        // kSecCodeSignatureAdhoc is not exported to Swift; it is the same 0x2 bit that
        // `codesign -dv` prints as flags=0x2(adhoc).
        let adHocFlag: UInt32 = 0x2
        let flags = dictionary[kSecCodeInfoFlags as String] as? UInt32 ?? 0
        let isAdHoc = flags & adHocFlag != 0
        return (isAdHoc, dictionary[kSecCodeInfoTeamIdentifier as String] as? String)
    }

    /// True when this copy is ad hoc signed, which no shipped release ever is.
    ///
    /// An ad hoc signature pins any Accessibility grant to one exact binary hash, so such a copy
    /// loses the grant on every rebuild and can never match a record a signed release created.
    /// Cached: a running bundle's signature cannot change under it, and the permission check
    /// consults this every couple of seconds.
    static let isAdHocSigned: Bool = signingInformation(for: bundleURL).isAdHoc

    // MARK: - Actions

    static func reveal(_ copies: [Copy]) {
        NSWorkspace.shared.activateFileViewerSelecting(copies.map(\.url))
    }

    /// Move other copies to the Trash, quitting them first so the Trash is not left holding a
    /// running app. Returns the copies that could not be removed.
    static func moveToTrash(_ copies: [Copy]) -> [Copy] {
        var failures: [Copy] = []

        for copy in copies {
            for running in NSWorkspace.shared.runningApplications
            where running.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == copy.url {
                running.terminate()
            }

            do {
                var trashURL: NSURL?
                try FileManager.default.trashItem(at: copy.url, resultingItemURL: &trashURL)
                Logging.info("[Install] Moved duplicate copy to Trash: \(copy.url.path)")
            } catch {
                Logging.info("[Install] Could not trash \(copy.url.path): \(error.localizedDescription)")
                failures.append(copy)
            }
        }

        return failures
    }

    enum RelocationError: LocalizedError {
        case noWritableApplicationsFolder
        case copyFailed(String)
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .noWritableApplicationsFolder:
                return L10n.string("No Applications folder could be written to.", comment: "Relocation failure reason")
            case .copyFailed(let message), .launchFailed(let message):
                return message
            }
        }
    }

    /// Install this copy into Applications, start it from there, and quit.
    ///
    /// This is the only reliable fix for a translocated or loose copy: the grant the user gives
    /// has to belong to a bundle that stays at one path. Copying rather than moving keeps the
    /// original intact until the new copy has actually launched.
    static func relocateToApplicationsAndRelaunch(completion: @escaping (Result<URL, RelocationError>) -> Void) {
        guard let destinationDirectory = writableApplicationsDirectory() else {
            completion(.failure(.noWritableApplicationsFolder))
            return
        }

        let source = bundleURL
        let destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
        let fileManager = FileManager.default

        do {
            if fileManager.fileExists(atPath: destination.path), destination != source {
                // Quit whatever is running from the destination before replacing it, otherwise
                // the running instance keeps its deleted bundle open and the hotkey with it.
                for running in NSWorkspace.shared.runningApplications
                where running.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == destination.resolvingSymlinksInPath().standardizedFileURL {
                    running.terminate()
                }
                var trashURL: NSURL?
                try fileManager.trashItem(at: destination, resultingItemURL: &trashURL)
            }

            try fileManager.copyItem(at: source, to: destination)
            clearQuarantine(at: destination)
        } catch {
            completion(.failure(.copyFailed(error.localizedDescription)))
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true

        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(.launchFailed(error.localizedDescription)))
                    return
                }

                Logging.info("[Install] Relocated to \(destination.path) and relaunched")
                // Only tidy the original away once the new copy is up, and never when it lives
                // on a read-only mount (a disk image) where it is not ours to remove anyway.
                if !isOnReadOnlyVolume && !isTranslocated {
                    var trashURL: NSURL?
                    try? fileManager.trashItem(at: source, resultingItemURL: &trashURL)
                }
                completion(.success(destination))
            }
        }
    }

    private static func writableApplicationsDirectory() -> URL? {
        for directory in applicationsDirectories where FileManager.default.isWritableFile(atPath: directory.path) {
            return directory
        }

        // /Applications needs an admin to write to on some setups. ~/Applications always works
        // and macOS treats it as a real install location, so fall back to it rather than asking
        // the user to authenticate.
        guard let home = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first else {
            return nil
        }
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return FileManager.default.isWritableFile(atPath: home.path) ? home : nil
    }

    /// Drop the quarantine flag from the freshly installed copy so macOS does not translocate
    /// it again on the next launch.
    private static func clearQuarantine(at url: URL) {
        try? (url as NSURL).setResourceValue(nil, forKey: .quarantinePropertiesKey)
    }

    // MARK: - Reporting

    /// Human readable reason a location is a problem, for the Settings panel.
    static func description(of problem: LocationProblem) -> String {
        switch problem {
        case .translocated:
            return L10n.string("MacClipboard is running from a temporary copy macOS made, so permissions cannot be saved.",
                               comment: "Installation health description, translocated app")
        case .readOnlyVolume:
            return L10n.string("MacClipboard is running from a disk image. It will stop working when the image is ejected.",
                               comment: "Installation health description, read-only volume")
        case .notInApplicationsFolder:
            return L10n.string("MacClipboard is not in an Applications folder, so its permission is lost if the app is moved.",
                               comment: "Installation health description, loose copy")
        }
    }

    // MARK: - Diagnostics

    /// One line for the unified log, so a support report shows immediately whether the user is
    /// running the copy that owns the permissions.
    static var diagnosticLine: String {
        let signature = signingInformation(for: bundleURL)
        // "local" covers a self-signed certificate such as the one `scripts/setup-dev-signing.sh`
        // creates: not ad hoc, so the identity is stable across rebuilds, but no Apple team.
        let identity = signature.isAdHoc ? "adhoc" : (signature.teamIdentifier ?? "local")
        let duplicates = duplicateCopies().map(\.displayPath).joined(separator: ", ")
        return "path=\(bundleURL.path) identity=\(identity) inApplications=\(isInApplicationsFolder) "
            + "translocated=\(isTranslocated) readOnlyVolume=\(isOnReadOnlyVolume) "
            + "duplicates=[\(duplicates)]"
    }
}

/// Installation state for the Settings panel, so a user who dismissed the launch alert can still
/// find and fix the problem instead of living with a half working app.
final class InstallationHealth: ObservableObject {
    @Published private(set) var duplicates: [AppInstallation.Copy] = []
    @Published private(set) var locationProblem: AppInstallation.LocationProblem?
    /// Result of the last Trash or Move action, shown inline so the panel is not silent.
    @Published private(set) var actionMessage: String?

    var hasIssue: Bool { !duplicates.isEmpty || locationProblem != nil }

    var ownPath: String { (AppInstallation.bundleURL.path as NSString).abbreviatingWithTildeInPath }

    func refresh() {
        duplicates = AppInstallation.duplicateCopies()
        locationProblem = AppInstallation.locationProblem
    }

    func reveal() {
        AppInstallation.reveal(duplicates)
    }

    func trashDuplicates() {
        let failures = AppInstallation.moveToTrash(duplicates)
        refresh()

        if failures.isEmpty {
            actionMessage = L10n.string("Extra copies moved to the Trash.",
                                        comment: "Installation health success message")
        } else {
            let format = L10n.string("Could not remove: %@",
                                     comment: "Installation health failure message")
            actionMessage = String(format: format, failures.map(\.displayPath).joined(separator: ", "))
        }
    }

    func moveToApplications() {
        AppInstallation.relocateToApplicationsAndRelaunch { [weak self] result in
            switch result {
            case .success:
                NSApp.terminate(nil)
            case .failure(let error):
                let format = L10n.string("Could not move the app: %@",
                                         comment: "Installation health relocation failure message")
                self?.actionMessage = String(format: format, error.localizedDescription)
            }
        }
    }
}
