import AppKit

/// Which app a clip was copied out of.
///
/// The pasteboard carries no author. `NSPasteboard` has no metadata saying which process wrote a
/// clip, so the only answer available is which app was frontmost at the moment the change was
/// noticed. `ClipboardMonitor.checkClipboard` samples that once, on the same read that feeds
/// `ClipboardCapturePolicy`, so the guard that may drop the clip and the source recorded on it can
/// never disagree about which app was in front.
///
/// With 0.8 s polling that is a good guess rather than a fact, exactly as the excluded-apps copy in
/// Settings already says: copy and switch apps inside the same moment and the recorded app is the
/// wrong one. Do not try to sharpen it with `NSWorkspace.didActivateApplicationNotification`
/// history, which is a heuristic layered on a heuristic; the honest way to narrow the window is a
/// shorter tick, which is task 15 in `docs/BACKLOG.md`.
///
/// Only the bundle identifier is stored, as `excludedBundleIdentifiers` does. The name and the icon
/// are resolved at display time by `ClipboardSourceAppCatalog`, so an app the user has since
/// uninstalled still reads correctly and no icon bytes ever reach the store.
enum ClipboardSource {
    /// The identifier worth recording, or nil when there is no honest answer.
    ///
    /// nil for a process with no bundle identifier of its own (a plain executable, a script run
    /// from a terminal) and when AppKit names no frontmost app at all. That is the same nil every
    /// clip captured before this attribute existed carries, and the same nil an item the user made
    /// themselves carries, because an edit, a merge and a split were copied out of nothing. All
    /// three show no source rather than an "Unknown app", which would be a claim about a clip that
    /// nothing was ever recorded for.
    ///
    /// Run on the way out of the store as well as on the way in, as the text flavours are: a blank
    /// string written by some other build must not become a row that shows an empty name.
    static func storableBundleIdentifier(_ bundleIdentifier: String?) -> String? {
        guard let trimmed = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// A source app as it is shown: the identifier that was stored, the name to print, and whether the
/// app is still on this Mac.
struct ClipboardSourceApp: Equatable {
    let bundleIdentifier: String
    /// What the row and the preview print, and what a search over the source matches. The bundle
    /// identifier itself once the app is gone, because that is then the only name there is, and
    /// matching what is displayed is the rule that stays explainable.
    let name: String
    let isInstalled: Bool
}

/// Resolves a stored bundle identifier to a name and an icon, at display time.
///
/// Display time rather than capture time for the reason `ExcludedAppRow` resolves the same way: a
/// name recorded on a clip would be a name frozen at the moment of the copy, and icon bytes on
/// every row would be a store full of pictures of apps. This way an app that was renamed reads
/// correctly, and an app that was uninstalled reads as its identifier instead of dropping off.
///
/// Cached because the callers are a `LazyVStack` row body and a search predicate: without it, every
/// keystroke in the search field would put a LaunchServices lookup on every item in the history.
enum ClipboardSourceAppCatalog {
    private static let lock = NSLock()
    private static var apps: [String: ClipboardSourceApp] = [:]
    private static var icons: [String: NSImage?] = [:]

    static func app(for bundleIdentifier: String) -> ClipboardSourceApp {
        startObservingInstalls()

        lock.lock()
        if let cached = apps[bundleIdentifier] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        let resolved = ClipboardSourceApp(
            bundleIdentifier: bundleIdentifier,
            name: url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleIdentifier,
            isInstalled: url != nil
        )

        lock.lock()
        apps[bundleIdentifier] = resolved
        lock.unlock()

        return resolved
    }

    /// nil when the app is gone, which is the caller's cue to draw a placeholder rather than a
    /// stand-in icon that would look like a real app.
    static func icon(for bundleIdentifier: String) -> NSImage? {
        startObservingInstalls()

        lock.lock()
        if let cached = icons[bundleIdentifier] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }

        lock.lock()
        icons[bundleIdentifier] = icon
        lock.unlock()

        return icon
    }

    /// Drops every resolution, so the next read asks LaunchServices again.
    static func invalidate() {
        lock.lock()
        apps.removeAll()
        icons.removeAll()
        lock.unlock()
    }

    /// A launch is the cheapest reliable sign that what is installed may have changed, and clearing
    /// a dictionary of a handful of entries costs nothing. Misses are cached along with hits, which
    /// is what keeps a search over a history full of clips from an uninstalled app cheap; without
    /// this observer that miss would then never correct itself until the next relaunch.
    private static func startObservingInstalls() {
        _ = installObserver
    }

    private static let installObserver: NSObjectProtocol = {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: nil
        ) { _ in
            invalidate()
        }
    }()
}
