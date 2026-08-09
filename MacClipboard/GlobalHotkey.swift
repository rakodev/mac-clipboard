import AppKit
import Carbon

/// The combination that opens the clipboard popover from any app.
///
/// Stored rather than hardcoded because ⌘⇧V is "Paste and Match Style" in a great many apps and is
/// the default of more than one other clipboard manager, and `RegisterEventHotKey` is
/// first-come-first-served system wide: whoever asks first keeps it, and everyone else gets a key
/// that does nothing. A user who lands on that collision needs something to change.
///
/// The two halves are exactly what Carbon takes: a virtual key code, which is a position on the
/// keyboard rather than a character, and a modifier mask. Nothing about the character is stored,
/// so a shortcut recorded on one keyboard layout stays on the same physical keys on another and
/// only its *label* moves, which is what every other Mac app does too.
struct GlobalHotkeyShortcut: Equatable {
    static let command = UInt32(cmdKey)
    static let shift = UInt32(shiftKey)
    static let option = UInt32(optionKey)
    static let control = UInt32(controlKey)

    /// The only bits `RegisterEventHotKey` understands. `NSEvent.modifierFlags` also reports caps
    /// lock, the numeric keypad, and the fn key, and passing those through would both change
    /// equality between two otherwise identical shortcuts and ask Carbon for a combination it
    /// cannot register.
    static let supportedModifiers = command | shift | option | control

    /// Virtual key code for 'V' on every layout, since the code is a position.
    static let vKeyCode: UInt32 = 9

    let keyCode: UInt32
    let carbonModifiers: UInt32

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers & Self.supportedModifiers
    }

    init(event: NSEvent) {
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: Self.carbonModifiers(from: event.modifierFlags))
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= command }
        if flags.contains(.shift) { modifiers |= shift }
        if flags.contains(.option) { modifiers |= option }
        if flags.contains(.control) { modifiers |= control }
        return modifiers
    }

    /// ⌘⇧V for a release build, ⌘⇧⌥V for a dev build.
    ///
    /// The split is older than this preference and outlives it. A dev build and an installed
    /// release build run side by side, so a shared default would mean whichever launched second
    /// silently lost the hotkey. The stored value cannot collide by accident either: the two builds
    /// have different bundle identifiers and therefore different preference domains, so changing
    /// the dev build's shortcut leaves the release copy's alone. A developer who deliberately sets
    /// both to the same combination gets the "already taken" banner, which is the honest answer.
    static var defaultForCurrentBuild: GlobalHotkeyShortcut {
        BuildInfo.isDevBuild
            ? GlobalHotkeyShortcut(keyCode: vKeyCode, carbonModifiers: command | shift | option)
            : GlobalHotkeyShortcut(keyCode: vKeyCode, carbonModifiers: command | shift)
    }

    // MARK: - Validation

    /// Why this combination cannot be a global hotkey, or nil if it can.
    ///
    /// Both rules exist because a global hotkey is taken from *every* app, so a bad one is not a
    /// MacClipboard problem, it is a broken Mac until the user finds their way back into Settings.
    var rejection: GlobalHotkeyRejection? {
        if GlobalHotkeyKey.isFunctionKey(keyCode) { return nil }

        let hasHardModifier = carbonModifiers & (Self.command | Self.control | Self.option) != 0
        guard hasHardModifier else { return .needsModifier }

        // ⌘ plus one key is how apps spell their menu items, so taking one globally removes Paste,
        // Save or Quit from everything the user runs.
        if carbonModifiers == Self.command { return .commandAlone }

        return nil
    }

    var isValid: Bool { rejection == nil }

    // MARK: - Display

    /// Spaced form used in settings labels and banners, e.g. "⌘ ⇧ V".
    var displayString: String {
        let modifiers = Self.modifierSymbols(carbonModifiers)
        return (modifiers + [GlobalHotkeyKey.label(for: keyCode)]).joined(separator: " ")
    }

    /// Compact form used in the shortcut reference table, e.g. "⌘⇧V".
    var compactDisplayString: String {
        Self.modifierSymbols(carbonModifiers).joined() + GlobalHotkeyKey.label(for: keyCode)
    }

    /// Modifiers on their own, for the recorder to show while a key is still being waited for.
    static func modifierDisplayString(_ modifiers: UInt32, spaced: Bool) -> String {
        modifierSymbols(modifiers).joined(separator: spaced ? " " : "")
    }

    /// Control, option, shift, command: the order macOS shows modifiers in, in menus and in the
    /// keyboard shortcut panes of System Settings. Anything else reads as a typo.
    private static func modifierSymbols(_ modifiers: UInt32) -> [String] {
        var symbols: [String] = []
        if modifiers & control != 0 { symbols.append("⌃") }
        if modifiers & option != 0 { symbols.append("⌥") }
        if modifiers & shift != 0 { symbols.append("⇧") }
        if modifiers & command != 0 { symbols.append("⌘") }
        return symbols
    }
}

/// The reason a recorded combination was refused, kept apart from its wording so a test pins the
/// rule rather than the copy.
enum GlobalHotkeyRejection: Equatable {
    case needsModifier
    case commandAlone

    var message: String {
        switch self {
        case .needsModifier:
            return L10n.string(
                "A global shortcut needs ⌘, ⌥ or ⌃, or a function key. Without one it would fire while you type.",
                comment: "Rejected global hotkey: no modifier"
            )
        case .commandAlone:
            return L10n.string(
                "⌘ and one key is a menu shortcut in most apps, and a global hotkey would take it from all of them. Add ⇧, ⌥ or ⌃.",
                comment: "Rejected global hotkey: command only"
            )
        }
    }
}

/// Turns a virtual key code into something to put in front of a user.
enum GlobalHotkeyKey {
    /// Keys the keyboard layout cannot label. Asking `UCKeyTranslate` for these returns a control
    /// character or nothing at all, so they are named here, in the glyphs macOS uses in menus.
    static let specialLabels: [UInt32: String] = [
        36: "↩",
        48: "⇥",
        49: L10n.string("Space", comment: "Key label for the space bar"),
        51: "⌫",
        53: "⎋",
        71: "⌧",
        76: "⌤",
        115: "↖",
        116: "⇞",
        117: "⌦",
        119: "↘",
        121: "⇟",
        123: "←",
        124: "→",
        125: "↓",
        126: "↑",
    ]

    /// F1 to F20. Kept separate from `specialLabels` because these are also the one kind of key
    /// that may stand as a hotkey with no modifier at all.
    static let functionKeyLabels: [UInt32: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        functionKeyLabels[keyCode] != nil
    }

    /// Never returns an empty string: a shortcut the user cannot see is worse than an ugly label,
    /// so an unmappable key falls back to naming its code.
    static func label(for keyCode: UInt32) -> String {
        if let special = specialLabels[keyCode] { return special }
        if let function = functionKeyLabels[keyCode] { return function }
        if let character = layoutCharacter(for: keyCode) { return character }
        return String(
            format: L10n.string("Key %d", comment: "Fallback label for an unnamed key, with its virtual key code"),
            Int(keyCode)
        )
    }

    /// What this key prints on the keyboard the user is typing on right now.
    ///
    /// The alternative, a table of key codes to letters, is a table of one layout: key code 6 is Z
    /// on a US keyboard and W on a French one, and a recorder that told a French user they had
    /// pressed Z would be wrong about the key they are looking at.
    private static func layoutCharacter(for keyCode: UInt32) -> String? {
        guard let layoutData = currentKeyboardLayoutData() else { return nil }

        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0

        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }

        guard status == noErr, length > 0 else { return nil }

        let translated = String(utf16CodeUnits: characters, count: length)
        // Control characters and whitespace come back for keys that belong in `specialLabels`, and
        // for codes that are not keys at all.
        guard let first = translated.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(first),
              !CharacterSet.whitespacesAndNewlines.contains(first) else {
            return nil
        }

        return translated.uppercased()
    }

    /// The current layout, falling back to an ASCII-capable one. An input source can be selected
    /// that carries no `UnicodeKeyLayoutData` at all, which is ordinary for the Chinese, Japanese
    /// and Korean input methods, and the fallback is what those report their key positions with.
    private static func currentKeyboardLayoutData() -> Data? {
        let sources = [
            TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
        ]

        for source in sources.compactMap({ $0 }) {
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        }

        return nil
    }
}
