import AppKit

/// Whether the app follows the Mac's Light/Dark setting, or stays in one of them whatever the Mac
/// is set to.
///
/// Deliberately one `NSApp.appearance` and nothing else. Both appearances already work, because
/// every colour in the app is a semantic one (the rule in `CLAUDE.md`), so the only gap this fills
/// is the user who wants the popover to stay dark while the system is light. Nothing here names a
/// colour, and nothing downstream should start to: a theme system is what this is not.
enum AppearancePreference: String, CaseIterable, Identifiable {
    /// Whatever the Mac is set to, and follows it when it changes, including the automatic switch at
    /// sunset. The default, and the one state in which both appearances get exercised.
    case system
    /// Light, and stays light on a Mac set to dark.
    case light
    /// Dark, and stays dark on a Mac set to light. The case this preference exists for.
    case dark

    static let `default`: AppearancePreference = .system

    var id: String { rawValue }

    /// What AppKit is handed. `nil` is not "leave it alone": it is how `NSApplication` says "follow
    /// the system", so `.system` has to assign it rather than skip the assignment, or switching back
    /// from Dark would leave the override in place with nothing on screen to explain it.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }

    var label: String {
        switch self {
        case .system:
            return L10n.string("System", comment: "Appearance preference, follow the Mac's setting")
        case .light:
            return L10n.string("Light", comment: "Appearance preference, always light")
        case .dark:
            return L10n.string("Dark", comment: "Appearance preference, always dark")
        }
    }

    /// The stored value, or `.system` for anything this build does not recognise: an absent key, a
    /// value written by a later version, a string nobody typed on purpose. Following the system is
    /// the state the app is known to work in either way round, so it is the safe answer to "no idea
    /// what that is", the same way an unusable stored hotkey falls back to the default.
    static func stored(_ rawValue: String?) -> AppearancePreference {
        guard let rawValue, let preference = AppearancePreference(rawValue: rawValue) else {
            return .default
        }
        return preference
    }

    /// Applies the preference to the whole app: every window, the popover, the menus and the alerts,
    /// in one assignment, including the ones built after this runs.
    ///
    /// One assignment is safe precisely because of the surface it cannot reach. AppKit pins the
    /// status bar's own window to the *menu bar's* appearance rather than the app's: measured on a
    /// Mac set to light, the status item button still reports `NSVibrantLight` while the app is
    /// forced to `NSDarkAqua`. So the template glyph stays tinted for the bar it sits in, and a user
    /// who picks Dark cannot end up with a white icon on a light menu bar, which is the one part of
    /// the app they cannot choose to stop looking at. Do not "fix" the menu bar icon to match this
    /// preference; the bar is not ours to theme.
    func apply(to application: NSApplication = .shared) {
        application.appearance = nsAppearance
    }
}
