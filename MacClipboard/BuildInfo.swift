import Foundation
import Carbon

/// Single source of truth for identifying which build of MacClipboard is running.
///
/// There are three bundle identifiers, and the split exists entirely because macOS keys an
/// Accessibility grant on bundle id *and* the code signing identity recorded with it:
///
/// - `com.macclipboard.app` is the shipped release.
/// - `com.macclipboard.app.dev` is only ever produced by `run.sh`, which signs it with the
///   persistent dev certificate, so its grant survives rebuilds.
/// - `com.macclipboard.app.debug` is what the Debug configuration builds, so Xcode's Run button
///   and the test host get an id of their own. Those products are ad hoc signed, and while they
///   shared the `.dev` id every Run or test pass made tccd refuse the dev copy afterwards
///   ("Failed to match existing code requirement").
///
/// Anything that has to behave differently between a dev build and an installed release build
/// keys off this type instead of re-deriving the check.
enum BuildInfo {
    static let bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.macclipboard.app"

    static let isDebugBuild: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// True for anything that is not a shipped release: a `run.sh` dev build (renamed
    /// bundle id) or a Debug build launched straight from Xcode.
    static let isDevBuild: Bool = bundleIdentifier.hasSuffix(".dev") || isDebugBuild

    /// True when this process was started to host a unit test bundle rather than to be used.
    ///
    /// `xcodebuild test` launches the app itself as the test host, under the Debug bundle id, so
    /// everything `applicationDidFinishLaunching` does runs inside a test run. Without this check
    /// the host quits the copy a developer is using, pops installation alerts nobody is watching,
    /// and opens the store holding their clipboard history. `PersistenceManager.shared` refuses to
    /// exist here for that last reason.
    static let isHostingTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }()

    /// Short label shown in the UI so two copies running side by side are tellable apart.
    static var channelName: String {
        isDevBuild
            ? L10n.string("Dev", comment: "Build channel label for development builds")
            : L10n.string("Release", comment: "Build channel label for shipped builds")
    }

    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// e.g. "0.1.14 (26)"
    static var versionString: String {
        "\(shortVersion) (\(buildNumber))"
    }

    /// Identifying detail for tooltips and diagnostics. Never shown inline in the UI.
    static var diagnosticSummary: String {
        "\(bundleIdentifier)\n\(Bundle.main.bundlePath)"
    }
}

/// The global hotkey that opens the clipboard popover.
///
/// Dev builds deliberately use a different combination. `RegisterEventHotKey` is
/// first-come-first-served system wide, so a dev build and an installed release build
/// would otherwise fight over ⌘⇧V and whichever launched second would silently lose it.
enum GlobalHotkey {
    /// Virtual key code for 'V'.
    static let keyCode: UInt32 = 9

    static var carbonModifiers: UInt32 {
        BuildInfo.isDevBuild ? UInt32(cmdKey | shiftKey | optionKey) : UInt32(cmdKey | shiftKey)
    }

    /// Spaced form used in settings labels, e.g. "⌘ ⇧ V".
    static var displayString: String {
        BuildInfo.isDevBuild ? "⌘ ⇧ ⌥ V" : "⌘ ⇧ V"
    }

    /// Compact form used in the shortcut reference table, e.g. "⌘⇧V".
    static var compactDisplayString: String {
        BuildInfo.isDevBuild ? "⌘⇧⌥V" : "⌘⇧V"
    }
}
