import AppKit
import Foundation

enum UpdateCheckResult: Equatable {
    case upToDate(currentVersion: String)
    case updateAvailable(currentVersion: String, latestVersion: String, downloadURL: URL)
}


enum UpdateCheckError: LocalizedError, Equatable {
    case cancelled
    case invalidResponse
    case invalidPayload
    case rateLimited(resetDate: Date?)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return L10n.string("Update check was cancelled.", comment: "Update check cancellation error")
        case .invalidResponse:
            return L10n.string("The update server returned an unexpected response.", comment: "Update check invalid response error")
        case .invalidPayload:
            return L10n.string("Could not parse update information.", comment: "Update check invalid payload error")
        case .rateLimited(let resetDate):
            if let resetDate {
                let format = L10n.string("GitHub rate-limited update checks. Try again after %@.", comment: "Update check rate limited error with reset time")
                return String(format: format, resetDate.formatted(date: .omitted, time: .shortened))
            }
            return L10n.string("GitHub rate-limited update checks. Try again later.", comment: "Update check rate limited error without reset time")
        case .requestFailed(let message):
            return message
        }
    }
}

final class UpdateService {
    static let shared = UpdateService()

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: URL?

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    private let session: URLSession
    private let latestReleaseEndpoint: URL
    private let fallbackReleaseURL: URL
    private var currentTask: URLSessionDataTask?

    init(
        session: URLSession = .shared,
        latestReleaseEndpoint: URL = URL(string: "https://api.github.com/repos/rakodev/mac-clipboard/releases/latest")!,
        fallbackReleaseURL: URL = URL(string: "https://github.com/rakodev/mac-clipboard/releases/latest")!
    ) {
        self.session = session
        self.latestReleaseEndpoint = latestReleaseEndpoint
        self.fallbackReleaseURL = fallbackReleaseURL
    }

    func checkForUpdates(
        currentVersion: String,
        completion: @escaping (Result<UpdateCheckResult, UpdateCheckError>) -> Void
    ) {
        cancel()

        var request = URLRequest(url: latestReleaseEndpoint)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        currentTask = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            defer { self.currentTask = nil }

            if let nsError = error as NSError? {
                if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                    completion(.failure(.cancelled))
                } else {
                    completion(.failure(.requestFailed(nsError.localizedDescription)))
                }
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 403 || httpResponse.statusCode == 429 {
                    completion(.failure(.rateLimited(resetDate: self.rateLimitResetDate(from: httpResponse))))
                    return
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    completion(.failure(.invalidResponse))
                    return
                }
            }

            guard let data,
                  let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
                completion(.failure(.invalidPayload))
                return
            }

            let latestVersion = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            if Self.isVersion(latestVersion, newerThan: currentVersion) {
                completion(.success(.updateAvailable(
                    currentVersion: currentVersion,
                    latestVersion: latestVersion,
                    downloadURL: release.htmlURL ?? fallbackReleaseURL
                )))
            } else {
                completion(.success(.upToDate(currentVersion: currentVersion)))
            }
        }

        currentTask?.resume()
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    private func rateLimitResetDate(from response: HTTPURLResponse) -> Date? {
        guard let resetValue = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
              let resetTime = TimeInterval(resetValue) else {
            return nil
        }
        return Date(timeIntervalSince1970: resetTime)
    }

    static func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        ReleaseVersion(tag: v2) < ReleaseVersion(tag: v1)
    }
}

/// A newer release the user has not dismissed, ready to be shown.
struct AvailableUpdate: Equatable {
    let version: String
    let releaseURL: URL
}

/// When a background check is allowed to run.
///
/// Pure, and separate from `UpdateChecker`, because "is a check due" is the whole of the scheduling
/// behaviour worth testing and a timer is not a thing a test can wait for.
enum UpdateCheckSchedule {
    /// Once a day. Frequent enough that a user hears about a release within a day of it landing,
    /// rare enough that it is not a daily-noise problem for a project that ships every few days.
    static let interval: TimeInterval = 24 * 60 * 60

    /// How often the timer wakes to ask whether a check is due. A single 24 hour timer would be
    /// simpler and would not survive sleep: the poll is what makes the interval mean elapsed time
    /// rather than uptime.
    static let pollInterval: TimeInterval = 60 * 60

    static func isDue(lastCheck: Date?, now: Date, interval: TimeInterval = interval) -> Bool {
        guard let lastCheck else { return true }
        // A stored date in the future means the clock moved backwards (a timezone fix, a dead
        // battery, a restore). Treating that as "not due" would wedge checks until the date came
        // round again, so it counts as due and the next success writes a sane date.
        if lastCheck > now { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }
}

/// Whether a version found by a check should be put in front of the user.
///
/// Pure for the same reason as `UpdateCheckSchedule`: this is the rule that decides whether the
/// badge, the banner and the menu item title appear, and all three read it through `UpdateChecker`.
enum UpdateAvailabilityPolicy {
    static func versionToSurface(latest: String?, current: String, skipped: String?) -> String? {
        guard let latest, !latest.isEmpty else { return nil }
        guard UpdateService.isVersion(latest, newerThan: current) else { return nil }
        // A skipped version stays skipped, but anything newer than it comes back. Skip means "not
        // this one", not "stop telling me about updates"; the preference is what means that.
        if let skipped, !UpdateService.isVersion(latest, newerThan: skipped) { return nil }
        return latest
    }
}

/// Owns what the app knows about a newer release, and when it goes looking.
///
/// The check itself lives in `UpdateService`; this is the part that runs without being asked and
/// remembers the answer. Three surfaces read `availableUpdate` and nothing else: the menu bar icon
/// badge, the popover banner, and the Settings footer. None of them blocks, which is the whole
/// point: a modal alert appears only when the user asked for a check themselves.
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    /// The update worth showing, or nil. Published so the badge can never lag the state, the same
    /// reason `MenuBarController` observes `$isCapturePaused`.
    @Published private(set) var availableUpdate: AvailableUpdate?
    /// True while a check is in flight, so the Settings row can say so rather than looking inert.
    @Published private(set) var isChecking = false

    private let service: UpdateService
    private let preferences: UserPreferencesManager
    private let currentVersion: String
    private let releaseTagURLBuilder: (String) -> URL?
    private var pollTimer: Timer?

    /// Long enough to stay out of the way of launch, which is already loading the history, checking
    /// permissions and registering a hotkey. Nobody is waiting on this.
    private static let launchDelay: TimeInterval = 10

    init(
        service: UpdateService = .shared,
        preferences: UserPreferencesManager = .shared,
        currentVersion: String = BuildInfo.shortVersion,
        releaseTagURLBuilder: @escaping (String) -> URL? = { version in
            URL(string: "https://github.com/rakodev/mac-clipboard/releases/tag/v\(version)")
        }
    ) {
        self.service = service
        self.preferences = preferences
        self.currentVersion = currentVersion
        self.releaseTagURLBuilder = releaseTagURLBuilder
    }

    /// True when this copy was installed by Homebrew, so the user is told to `brew upgrade` rather
    /// than sent to download a DMG that would leave the cask stale.
    ///
    /// Both prefixes are checked because Homebrew lives in `/opt/homebrew` on Apple silicon and
    /// `/usr/local` on Intel. Computed once: nobody moves an install while the app runs.
    static let isHomebrewManaged: Bool = {
        let caskrooms = ["/opt/homebrew/Caskroom/macclipboard", "/usr/local/Caskroom/macclipboard"]
        guard caskrooms.contains(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return false
        }
        return AppInstallation.bundleURL.path.hasPrefix("/Applications/")
    }()

    /// The command that upgrades a Homebrew install.
    static let homebrewUpgradeCommand = "brew upgrade --cask macclipboard"

    /// Restores what the last check found, then starts the poll.
    ///
    /// Restoring first is what makes the badge correct at launch instead of ten seconds into it: the
    /// version is already on disk, so there is no reason to make the user wait for the network to
    /// find out something the app knew before it quit.
    func start() {
        refreshFromStoredState()

        // A dev build is built from whatever is checked out, so its version is routinely ahead of
        // the latest release and a nag would be wrong as often as it was right. `run.sh` is how a
        // dev build updates. Manual checks still work, which is how this path gets tested.
        guard !BuildInfo.isDevBuild, !BuildInfo.isHostingTests else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchDelay) { [weak self] in
            self?.checkIfDue()
        }

        let timer = Timer.scheduledTimer(
            withTimeInterval: UpdateCheckSchedule.pollInterval,
            repeats: true
        ) { [weak self] _ in
            self?.checkIfDue()
        }
        // Nothing depends on this firing on time, and the tolerance lets macOS coalesce it with
        // other work instead of waking the machine for it.
        timer.tolerance = UpdateCheckSchedule.pollInterval * 0.5
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        service.cancel()
    }

    /// Re-derives `availableUpdate` from what is on disk. Called after a check, after a skip, and
    /// at launch, so the three surfaces always agree with the stored state.
    private func refreshFromStoredState() {
        let version = UpdateAvailabilityPolicy.versionToSurface(
            latest: preferences.lastSeenLatestVersion,
            current: currentVersion,
            skipped: preferences.skippedUpdateVersion
        )

        guard let version, let url = releaseTagURLBuilder(version) else {
            availableUpdate = nil
            return
        }

        availableUpdate = AvailableUpdate(version: version, releaseURL: url)
    }

    private func checkIfDue() {
        guard preferences.automaticUpdateChecksEnabled else { return }
        guard UpdateCheckSchedule.isDue(lastCheck: preferences.lastUpdateCheckDate, now: Date()) else { return }
        check(userInitiated: false, completion: nil)
    }

    /// Runs a check. `userInitiated` only decides whether the caller is handed the raw result to
    /// report on; the stored state is updated either way.
    func check(
        userInitiated: Bool,
        completion: ((Result<UpdateCheckResult, UpdateCheckError>) -> Void)?
    ) {
        isChecking = true

        service.checkForUpdates(currentVersion: currentVersion) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isChecking = false

                switch result {
                case .success(let outcome):
                    // Only a completed check moves the date. A failure leaving it alone is what
                    // makes the next poll retry, which is the behaviour anyone offline wants.
                    self.preferences.lastUpdateCheckDate = Date()

                    switch outcome {
                    case .updateAvailable(_, let latestVersion, _):
                        self.preferences.lastSeenLatestVersion = latestVersion
                    case .upToDate:
                        // Record the version actually running, so a copy that has caught up stops
                        // surfacing the release it was behind.
                        self.preferences.lastSeenLatestVersion = self.currentVersion
                    }

                    self.refreshFromStoredState()

                case .failure:
                    break
                }

                completion?(result)
            }
        }
    }

    /// What "update me" does for this install. The banner and the alert both call it, so the
    /// Homebrew rule cannot be right in one place and stale in the other.
    enum PrimaryAction: Equatable {
        /// The upgrade command is now on the pasteboard.
        case copiedHomebrewCommand
        /// The release page was opened.
        case openedReleasePage
    }

    @discardableResult
    func performPrimaryAction(for update: AvailableUpdate) -> PrimaryAction {
        guard Self.isHomebrewManaged else {
            NSWorkspace.shared.open(update.releaseURL)
            return .openedReleasePage
        }

        // Downloading a DMG over a cask-managed copy leaves `brew` believing the old version is
        // still installed, and the next `brew upgrade` walks the app backwards. So a Homebrew user
        // gets the command rather than the download.
        //
        // `ClipboardMonitor` will capture this write like any other copy, which is correct: the user
        // did copy it, and a command they are about to paste into a terminal belongs in history.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.homebrewUpgradeCommand, forType: .string)
        return .copiedHomebrewCommand
    }

    /// Stops surfacing this version. Anything newer still surfaces; see `UpdateAvailabilityPolicy`.
    func skipAvailableUpdate() {
        guard let version = availableUpdate?.version else { return }
        preferences.skippedUpdateVersion = version
        refreshFromStoredState()
    }
}

/// A release tag, parsed so two of them can be ordered.
///
/// Naive `split(separator: ".").compactMap { Int($0) }` reads `0.1.25-beta.1` as `[0, 1]`, because
/// `Int("25-beta")` is nil, so a prerelease of the *next* version compares as older than the
/// release before it and the update is never offered. `/releases/latest` excludes prereleases, so
/// nothing has shipped through that hole yet, and the parse is what stops it opening the first time
/// someone tags a beta.
struct ReleaseVersion: Equatable, Comparable {
    /// The dotted numbers, e.g. `[0, 1, 25]`. A segment that is not a number ends the run.
    let numbers: [Int]
    /// The identifiers after the first `-`, or nil for an ordinary release.
    let prerelease: String?

    init(tag: String) {
        var text = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" {
            text = String(text.dropFirst())
        }

        // Build metadata never affects precedence (semver 2.0.0 §10), so it is dropped rather
        // than parsed.
        if let plus = text.firstIndex(of: "+") {
            text = String(text[text.startIndex..<plus])
        }

        if let hyphen = text.firstIndex(of: "-") {
            let identifiers = String(text[text.index(after: hyphen)...])
            self.prerelease = identifiers.isEmpty ? nil : identifiers
            text = String(text[text.startIndex..<hyphen])
        } else {
            self.prerelease = nil
        }

        // `prefix(while:)` rather than `compactMap`: a trailing segment that is not a number means
        // the tag is not one this app understands, and guessing at the rest of it would be worse
        // than treating what came before as the whole version.
        self.numbers = text.split(separator: ".").prefix { Int($0) != nil }.map { Int($0)! }
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        for index in 0..<max(lhs.numbers.count, rhs.numbers.count) {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right }
        }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        // A prerelease precedes the release it leads up to.
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (.some(let left), .some(let right)):
            // Lexicographic, which orders `alpha` before `beta` before `rc` and is right for every
            // tag this project is likely to cut. It is not full semver identifier comparison, so
            // `beta.10` sorts before `beta.9`; that only matters between two prereleases, and both
            // are hidden from `/releases/latest` anyway.
            return left < right
        }
    }
}