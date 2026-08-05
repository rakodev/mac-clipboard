import Foundation
import Carbon

/// Single source of truth for identifying which build of MacClipboard is running.
///
/// `run.sh` gives development builds their own bundle identifier
/// (`com.macclipboard.app.dev`) so macOS treats them as a separate app in the TCC
/// database. Anything that has to behave differently between a dev build and an
/// installed release build keys off this type instead of re-deriving the check.
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
