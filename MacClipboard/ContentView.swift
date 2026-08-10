import SwiftUI
import CoreGraphics
import ApplicationServices

enum FilterTab: String, CaseIterable {
    case all = "All"
    case favorites = "Favorites"
    case images = "Images"
    case hidden = "Hidden"

    var titleKey: LocalizedStringKey {
        switch self {
        case .all:
            return "All"
        case .favorites:
            return "Favorites"
        case .images:
            return "Images"
        case .hidden:
            return "Hidden"
        }
    }
}

struct ClipboardTimeAgo {
    /// Anything this new reads as "now". A clip that has just been captured, or an edit just saved
    /// as a new item, is not "0 sec. ago" to the person watching it appear.
    static let nowThreshold: TimeInterval = 5

    static func makeFormatter() -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }

    static func string(for date: Date, relativeTo reference: Date, formatter: RelativeDateTimeFormatter) -> String {
        // A negative interval (a clock change, or a timestamp taken a moment after this reference)
        // also lands here, which is the right answer for it.
        guard reference.timeIntervalSince(date) >= nowThreshold else {
            return L10n.string("now", comment: "Relative time for a clipboard item created moments ago")
        }

        return formatter.localizedString(for: date, relativeTo: reference)
    }
}

struct ClipboardFilter {
    /// `sourceAppName` is what the item's source app is *shown* as, which is also the rule for
    /// matching it: typing "Slack" finds what was copied out of Slack, and an app that has since
    /// been uninstalled matches on the identifier the row prints for it because that is then the
    /// only name it has. The bundle identifier of an installed app is deliberately not matched;
    /// "com.google.Chrome" would make a search for "google" return every clip from Chrome.
    ///
    /// Injected so this stays a pure function: the real resolver is a LaunchServices lookup.
    ///
    /// `sourceBundleIdentifier` is the exact filter, and it is a different thing from the search
    /// matching above: the search is a fuzzy find over everything a row shows, this is "only the
    /// clips from that app". It is an identifier rather than a name because two apps can print the
    /// same name and the identifier is what was actually recorded.
    static func filteredItems(
        from items: [ClipboardItem],
        selectedFilter: FilterTab,
        searchText: String,
        sourceBundleIdentifier: String? = nil,
        sourceAppName: (String) -> String? = { ClipboardSourceAppCatalog.app(for: $0).name }
    ) -> [ClipboardItem] {
        var filtered: [ClipboardItem]
        switch selectedFilter {
        case .all:
            filtered = items
        case .favorites:
            filtered = items.filter { $0.isFavorite }
        case .images:
            filtered = items.filter { $0.type == .image }
        case .hidden:
            filtered = items.filter { $0.isSensitive }
        }

        if let sourceBundleIdentifier {
            filtered = filtered.filter { $0.sourceBundleIdentifier == sourceBundleIdentifier }
        }

        guard !searchText.isEmpty else { return filtered }

        filtered = filtered.filter { item in
            let previewMatch = item.previewText.localizedCaseInsensitiveContains(searchText)
            let fullTextMatch = item.fullText.localizedCaseInsensitiveContains(searchText)
            let noteMatch = item.note?.localizedCaseInsensitiveContains(searchText) ?? false
            let sourceMatch = item.sourceBundleIdentifier
                .flatMap { sourceAppName($0) }?
                .localizedCaseInsensitiveContains(searchText) ?? false
            return previewMatch || fullTextMatch || noteMatch || sourceMatch
        }

        // Sort by score descending, keeping the original (recency) order for equal
        // scores. Swift's sorted(by:) is not guaranteed stable, so we use the original
        // index as an explicit tiebreaker to avoid items reshuffling on every recompute.
        return filtered.enumerated().sorted { lhs, rhs in
            let score1 = (lhs.element.isFavorite ? 2 : 0) + ((lhs.element.note?.isEmpty == false) ? 1 : 0)
            let score2 = (rhs.element.isFavorite ? 2 : 0) + ((rhs.element.note?.isEmpty == false) ? 1 : 0)
            if score1 != score2 { return score1 > score2 }
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }
}

/// Growing a multi-selection from the keyboard, with ⌘ or ⇧ held on an arrow key.
///
/// The set the popover keeps is free-form: ⌘-click toggles any row, in any order, and nothing
/// records which rows went in together. An arrow key cannot work off that alone, because reversing
/// direction has to give back exactly the rows the presses before it took, and a set with no anchor
/// cannot say which those were. So a run of extends is a range between an anchor and the cursor,
/// recomputed on every press, unioned with whatever was already selected when the run began.
///
/// Both modifiers extend: ⌘ because ⌘-click is this app's own multi-select gesture and the hand is
/// already there, ⇧ because it is what every other list on the Mac uses.
struct ClipboardSelectionExtension {
    /// Where the current run started. Held by id rather than by index: a capture arriving while the
    /// popover is open pushes a row in at the top and shifts every index below it, and the anchor
    /// has to keep meaning the row the user started from.
    struct Anchor: Equatable {
        let itemId: UUID
        /// What was selected when the run began, so ⌘-clicks made beforehand are not swept away by
        /// a range that happens to pass over them and then retreat.
        let base: Set<UUID>
    }

    struct Result: Equatable {
        let index: Int
        let selectedIds: Set<UUID>
        let anchor: Anchor
    }

    /// `delta` is -1 for up and +1 for down.
    ///
    /// Returns nil at either end of the list, so the key changes nothing rather than redrawing the
    /// same selection: pressing ⇧↑ on the first row should not quietly select it.
    static func extending(
        from currentIndex: Int,
        by delta: Int,
        in items: [ClipboardItem],
        selectedIds: Set<UUID>,
        anchor: Anchor?
    ) -> Result? {
        guard !items.isEmpty else { return nil }

        let cursor = min(max(currentIndex, 0), items.count - 1)
        let next = cursor + delta
        guard items.indices.contains(next) else { return nil }

        // An anchor whose row has been filtered away or deleted starts the run again from the
        // cursor, which is the one place on screen the user can see it starting from.
        let resolved: (index: Int, base: Set<UUID>) = anchor
            .flatMap { candidate in
                items.firstIndex(where: { $0.id == candidate.itemId })
                    .map { (index: $0, base: candidate.base) }
            }
            ?? (index: cursor, base: selectedIds)

        let range = min(resolved.index, next)...max(resolved.index, next)

        return Result(
            index: next,
            selectedIds: resolved.base.union(items[range].map(\.id)),
            anchor: Anchor(itemId: items[resolved.index].id, base: resolved.base)
        )
    }
}

/// What a key pressed over the popover means: something to search for, or something for the shortcut
/// table.
///
/// It is a decision of its own because it has to be made *before* the shortcut table rather than in
/// its default arm, and because the state it reads is subtle enough to be worth stating in tests.
/// Two bugs live here, and both were the same mistake of asking the wrong question:
///
/// - A shortcut's key code matching, and then its ⌘ test failing, used to swallow the key: typing
///   over the list, `f`, `d`, `z`, `e`, `h`, `v` and `n` searched for nothing at all. So the letters
///   are claimed first, and only what carries ⌘ or ⌃ is left to the table.
/// - Focus was read as an intention (`@FocusState`, set the instant it is assigned) rather than as
///   the fact of holding the keyboard, which AppKit hands over a runloop pass or two later. Every
///   key in that gap was tested against a flag that had already flipped, so it was neither claimed
///   here nor delivered to a field that was not listening yet: typed quickly, "pickup" arrived as
///   "pckup". `fieldHasKeyboard` is the fact, and `.extend` is what covers the gap.
enum ClipboardSearchTyping {
    struct State: Equatable {
        /// Whether the search field is the one AppKit is delivering keys to.
        let fieldHasKeyboard: Bool
        let noteHasKeyboard: Bool
        /// Whether a search has been started, whether or not the field has caught up.
        let searchIsFocused: Bool
        let searchIsEmpty: Bool
    }

    enum Outcome: Equatable {
        /// Start a search with this text, replacing whatever the field was left showing, and ask for
        /// focus.
        case start(String)
        /// Add to the search being typed. The field has not been handed the keyboard yet, so nothing
        /// else would receive this key.
        case extend(String)
        /// Take the last character back off the search.
        case deleteLast
        /// Not typing. The shortcut table should have it.
        case shortcut
    }

    /// Keys that carry a character but mean something else. Space is not one of them: it is a
    /// character in a clip like any other.
    private static let nonTypingKeyCodes: Set<UInt16> = [
        36,  // Return
        48,  // Tab
        51,  // Delete
        53,  // Escape
        117, // Forward delete
        123, 124, 125, 126, // Arrows
        96, 97, 98, 99, 100, 101, 103, 111 // F1-F8
    ]

    private static let deleteKeyCode: UInt16 = 51

    static func outcome(
        characters: String?,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        state: State
    ) -> Outcome {
        // The field has the keyboard, so these keys are already going where they belong; and a note
        // being written is not a search.
        guard !state.fieldHasKeyboard, !state.noteHasKeyboard else { return .shortcut }

        // ⌘ and ⌃ make a shortcut out of a letter. ⌥ does not: it composes characters, and ⌥e e is
        // an é somebody meant to search for.
        guard !modifiers.contains(.command), !modifiers.contains(.control) else { return .shortcut }

        // Backspace only corrects a search that is being typed. Over the list it still means
        // nothing, and ⌘⌫ was left to the table above.
        if keyCode == deleteKeyCode {
            return state.searchIsFocused && !state.searchIsEmpty ? .deleteLast : .shortcut
        }

        guard isTypedCharacter(characters: characters, keyCode: keyCode),
              let characters else { return .shortcut }

        return state.searchIsFocused ? .extend(characters) : .start(characters)
    }

    /// Whether the key is something a user could be searching for. Digits are, since `0`-`9` stopped
    /// jumping the selection: a clip is as likely to be found by a house number or a year as by a
    /// word, and a search that silently ignores every digit typed at it is worse than no search.
    static func isTypedCharacter(characters: String?, keyCode: UInt16) -> Bool {
        guard let characters, let char = characters.first else { return false }
        guard !nonTypingKeyCodes.contains(keyCode) else { return false }

        return char.isPrintableASCII || char.isLetter || char.isNumber || char.isSymbol || char == " "
    }
}

/// A text clip that is *exactly* a colour, shown as a swatch beside the row and in the preview.
///
/// Derived at display time and stored nowhere, so there is no attribute, no migration, and a history
/// with no colours in it pays nothing. `#3A7BD5` is a string that says nothing until you paste it
/// somewhere that renders it, and the swatch is the whole feature: it turns a row of hex into the
/// colour it names.
///
/// The scoping rule is what keeps it from becoming noise: the **whole trimmed clip** has to be a
/// colour. Matching a colour found anywhere inside the text would put a swatch on most CSS, most
/// stylesheets, and a good deal of ordinary code, which is a marker that means nothing because it is
/// on everything.
struct ClipboardColorSwatch: Equatable {
    /// 0...255 rather than a fraction, so `hexLabel` is the bytes back out rather than a float
    /// rounded a second time.
    let red: Int
    let green: Int
    let blue: Int
    /// 0...1. Below 1 the swatch is drawn over a checkerboard, because a translucent colour over the
    /// row's background is indistinguishable from a lighter opaque one.
    let alpha: Double
    /// The trimmed source, kept only so the preview can tell whether `hexLabel` says anything the
    /// clip does not already say itself.
    let sourceText: String

    /// Longer than this cannot be a colour, and the check runs before anything is allocated: a
    /// 5,000 character clip must not pay for a trim and a lowercase to find out it is not seven
    /// characters of hex. This is what makes the parse free on a full history.
    static let maxLength = 40

    // MARK: - Parsing

    /// Nil for anything that is not a text item whose entire content is a colour.
    static func swatch(for item: ClipboardItem?) -> ClipboardColorSwatch? {
        guard let item, item.type == .text else { return nil }
        return parse(item.fullText)
    }

    static func parse(_ text: String) -> ClipboardColorSwatch? {
        // `prefix` stops counting at the cap, so this is bounded work whatever the clip holds.
        guard text.prefix(maxLength + 1).count <= maxLength else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("#") {
            return parseHex(trimmed)
        }
        return parseFunctional(trimmed)
    }

    /// `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`, in either case.
    ///
    /// Four digit counts and nothing between them: `#GGHHII` is the length of a colour and none of
    /// the characters, and `#1234567` is hex of a length no notation has. Both are the near misses
    /// this has to refuse, since a swatch showing a colour the clip does not name is worse than no
    /// swatch at all.
    private static func parseHex(_ trimmed: String) -> ClipboardColorSwatch? {
        let digits = trimmed.dropFirst()
        // ASCII as well as hex: `Character.isHexDigit` accepts the fullwidth forms, and `#ＡＢＣ` is
        // not something anyone copied meaning a colour.
        guard digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }

        let values = digits.compactMap { $0.hexDigitValue }
        switch values.count {
        case 3:
            // Each nibble doubles: F becomes FF, which is ×17.
            return make(values[0] * 17, values[1] * 17, values[2] * 17, 1, trimmed)
        case 4:
            return make(values[0] * 17, values[1] * 17, values[2] * 17, Double(values[3] * 17) / 255, trimmed)
        case 6:
            return make(values[0] << 4 | values[1], values[2] << 4 | values[3], values[4] << 4 | values[5], 1, trimmed)
        case 8:
            return make(
                values[0] << 4 | values[1],
                values[2] << 4 | values[3],
                values[4] << 4 | values[5],
                Double(values[6] << 4 | values[7]) / 255,
                trimmed
            )
        default:
            return nil
        }
    }

    /// `rgb(255, 87, 51)` and `rgba(255, 87, 51, 0.5)`, plus the space-separated spelling CSS Color 4
    /// added: `rgb(255 87 51 / 50%)`.
    ///
    /// `rgb` and `rgba` are aliases in that spec, so both take three or four components rather than
    /// each being held to its own name. Channels are whole numbers only: `rgb(100%, 0%, 0%)` is a
    /// colour this refuses, which costs a swatch on a notation almost nobody copies and keeps the
    /// parse to one rule per component.
    private static func parseFunctional(_ trimmed: String) -> ClipboardColorSwatch? {
        let lowered = trimmed.lowercased()
        guard lowered.hasSuffix(")") else { return nil }

        let body: Substring
        if lowered.hasPrefix("rgba(") {
            body = lowered.dropFirst(5).dropLast()
        } else if lowered.hasPrefix("rgb(") {
            body = lowered.dropFirst(4).dropLast()
        } else {
            return nil
        }

        // A comma anywhere means the legacy spelling; without one the components are separated by
        // whitespace and the alpha by a slash. Mixing them gives a field that parses as neither.
        let fields: [String] = body.contains(",")
            ? body.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            : body.split(whereSeparator: { $0 == "/" || $0.isWhitespace }).map(String.init)

        guard fields.count == 3 || fields.count == 4 else { return nil }
        guard let red = Int(fields[0]), let green = Int(fields[1]), let blue = Int(fields[2]) else { return nil }

        var alpha = 1.0
        if fields.count == 4 {
            guard let parsed = parseAlpha(fields[3]) else { return nil }
            alpha = parsed
        }

        return make(red, green, blue, alpha, trimmed)
    }

    /// `0.5` or `50%`.
    private static func parseAlpha(_ field: String) -> Double? {
        if field.hasSuffix("%") {
            guard let percent = Double(field.dropLast()) else { return nil }
            return percent / 100
        }
        return Double(field)
    }

    /// Out of range is clamped rather than refused, which is what a browser does with it.
    /// `rgb(300, 0, 0)` is a colour somebody wrote badly, not a clip that means something else.
    private static func make(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Double, _ source: String) -> ClipboardColorSwatch {
        ClipboardColorSwatch(
            red: min(max(red, 0), 255),
            green: min(max(green, 0), 255),
            blue: min(max(blue, 0), 255),
            alpha: min(max(alpha, 0), 1),
            sourceText: source
        )
    }

    // MARK: - Display

    /// sRGB, deliberately: that is what a hex colour on the web means, and reading it in the display
    /// profile would show a colour other than the one the clip names.
    var color: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, opacity: alpha)
    }

    var isTranslucent: Bool { alpha < 1 }

    var hexLabel: String {
        let base = String(format: "#%02X%02X%02X", red, green, blue)
        guard isTranslucent else { return base }
        return base + String(format: "%02X", Int((alpha * 255).rounded()))
    }

    /// Whether the preview should print `hexLabel` beside the swatch.
    ///
    /// False for a clip that already reads as that hex, whatever case it is written in, so the
    /// common item does not get a label repeating the line above it. True for `rgb(255, 87, 51)` and
    /// for `#F53`, where the hex is the conversion the user would otherwise do by hand.
    var addsHexLabel: Bool {
        sourceText.uppercased() != hexLabel
    }
}

struct ContentView: View {
    @ObservedObject var clipboardMonitor: ClipboardMonitor
    @ObservedObject var menuBarController: MenuBarController
    @State private var selectedItem: ClipboardItem?
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var filterTask: Task<Void, Never>?
    @State private var computedFilteredItems: [ClipboardItem] = []
    @State private var selectedIndex: Int = 0
    @State private var showImageModal = false
    @State private var selectedFilter: FilterTab = .all
    /// The one app the list is narrowed to, or nil for all of them. Deliberately not persisted and
    /// not a preference: `showPopover` rebuilds this view on every open, so the filter lasts as long
    /// as the popover does. A source filter that outlived the session would be a way to lose clips
    /// behind a setting nobody remembers turning on.
    @State private var sourceFilter: String?
    @State private var showClearConfirmation = false
    @State private var showDeleteAllConfirmation = false  // Second confirmation for delete all
    @State private var selectedItemIds: Set<UUID> = []  // For multi-selection
    /// Set while ⌘/⇧ arrows are growing the selection, nil at every other time. See
    /// `ClipboardSelectionExtension`.
    @State private var selectionAnchor: ClipboardSelectionExtension.Anchor?
    /// Whether the search field *should* have the keyboard. Plain `@State` rather than `@FocusState`
    /// because the search field is an `NSTextField` of the app's own (`ClipboardSearchField`); see
    /// there for why SwiftUI's could not be kept.
    @State private var isSearchFocused = false
    /// Whether the search field *does* have the keyboard, reported by the field itself. It lags
    /// `isSearchFocused` by a runloop pass or two on the way up, and that gap is where typed letters
    /// used to disappear: `handleKeyEvent` keeps claiming keys until this turns true.
    @State private var searchFieldHasKeyboard = false
    @FocusState private var isNoteFocused: Bool
    @State private var timeAgoCache: [UUID: String] = [:]
    @State private var editingNote: String = ""
    @State private var revealedSensitiveIds: Set<UUID> = []  // Temporarily revealed sensitive items
    @State private var loadingImageIds: Set<UUID> = []  // Images currently being loaded from disk
    /// Images whose text is being read right now. The recognition runs on `ClipboardMonitor`, so
    /// closing the popover mid-pass still lands the new row; this is only the spinner's state.
    @State private var recognizingImageIds: Set<UUID> = []
    @State private var loadedImages: [UUID: NSImage] = [:]  // Cache for lazy-loaded images
    @State private var showShortcuts: Bool = false
    @State private var isScrolledDown: Bool = false
    @State private var shouldResetSelectionAfterFilterChange = false
    @State private var isEditing = false
    @State private var editSource: ClipboardItem?
    @State private var editText: String = ""
    @State private var editDraftRestored = false
    @State private var showDiscardEditConfirmation = false
    @State private var actionStatus: ClipboardActionStatus?
    @State private var actionStatusTask: Task<Void, Never>?
    /// Held while the confirmation for a large split is on screen, so the alert acts on the plan the
    /// user was shown rather than on whatever the selection has become since.
    @State private var pendingSplitPlan: ClipboardTextSplit.Plan?
    @State private var showSplitConfirmation = false
    @State private var pendingSelectionId: UUID?
    @State private var keyFocusToken = 0
    @State private var editorFocusToken = 0
    @State private var editCaretOffset: Int?

    @ObservedObject private var permissionManager: PermissionManager
    @ObservedObject private var userPreferences = UserPreferencesManager.shared
    /// The same state the menu bar icon badge is drawn from, so the dot and this banner can never
    /// disagree about whether there is an update.
    @ObservedObject private var updateChecker: UpdateChecker

    init(clipboardMonitor: ClipboardMonitor, menuBarController: MenuBarController) {
        self.clipboardMonitor = clipboardMonitor
        self.menuBarController = menuBarController
        self.permissionManager = menuBarController.permissionManager
        self.updateChecker = menuBarController.updateChecker
    }
    
    private var filteredItems: [ClipboardItem] {
        return computedFilteredItems
    }

    /// Compute filtered items on background thread to keep typing smooth
    private func recomputeFilteredItems() {
        filterTask?.cancel()

        let items = clipboardMonitor.clipboardHistory
        let filter = selectedFilter
        let searchQuery = debouncedSearchText
        let source = sourceFilter

        filterTask = Task.detached(priority: .userInitiated) {
            let filtered = ClipboardFilter.filteredItems(
                from: items,
                selectedFilter: filter,
                searchText: searchQuery,
                sourceBundleIdentifier: source
            )

            // Check if cancelled before updating UI
            let finalResult = filtered
            if !Task.isCancelled {
                await MainActor.run {
                    computedFilteredItems = finalResult
                }
            }
        }
    }
    
    private var dynamicHeight: CGFloat {
        // Get screen height and limit to reasonable size
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 1000
        let maxAllowedHeight = screenHeight * 0.6 // Reduced to 60% for cleaner look

        let itemHeight: CGFloat = 32  // Compact row height

        // Permission banner height (when shown)
        let permissionHeight: CGFloat = !permissionManager.isAccessibilityGranted ? 80 : 0

        // Hotkey conflict banner height (when shown)
        let hotkeyWarningHeight: CGFloat = menuBarController.isGlobalHotkeyUnavailable ? 58 : 0

        // Paused banner height (when shown)
        let capturePausedHeight: CGFloat = clipboardMonitor.isCapturePaused ? 52 : 0

        // Update banner height (when shown)
        let updateBannerHeight: CGFloat = updateChecker.availableUpdate == nil ? 0 : 52

        // The editor replaces the list and the preview, so give it as much room as the popover is
        // allowed to take. 259pt of preview pane is not somewhere anyone can edit text. The banners
        // are added on top rather than taken out of it, so the editor is the same size either way.
        if isEditing {
            return min(
                maxAllowedHeight,
                460 + permissionHeight + hotkeyWarningHeight + capturePausedHeight + updateBannerHeight
            )
        }

        let baseHeight: CGFloat = 78  // header + search + filter picker + minimal padding

        // Calculate items to show based on available content
        let itemCount = filteredItems.count
        let minItemsToShow: Int = min(itemCount, 6)  // Show at least 6 items if available
        let maxItemsToShow = min(itemCount, 16)     // Max items for horizontal layout
        let itemsToShow = max(minItemsToShow, min(maxItemsToShow, itemCount))
        
        let listHeight = CGFloat(itemsToShow) * itemHeight

        // Post-save confirmation line (when shown)
        let actionStatusHeight: CGFloat = actionStatus == nil ? 0 : 22

        // Calculate total height (no additional preview height since it's now horizontal)
        let totalHeight = baseHeight + permissionHeight + hotkeyWarningHeight + capturePausedHeight
            + updateBannerHeight + actionStatusHeight + listHeight

        // Set a minimum height to ensure preview is always visible
        // This is especially important when there's only 1 item
        let minimumHeight: CGFloat = 325  // Enough space for header + search + list + preview

        let finalHeight = max(minimumHeight, min(totalHeight, maxAllowedHeight))
        
        return finalHeight
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            if !permissionManager.isAccessibilityGranted {
                permissionBanner
            }
            if menuBarController.isGlobalHotkeyUnavailable {
                hotkeyConflictBanner
            }
            if clipboardMonitor.isCapturePaused {
                capturePausedBanner
            }
            if let update = updateChecker.availableUpdate {
                updateAvailableBanner(update)
            }
            if !isEditing {
                searchBarView
                filterPickerView

                if let actionStatus {
                    ClipboardActionStatusBanner(status: actionStatus)
                }
            }

            if isEditing, let editSource {
                ClipboardTextEditorView(
                    source: editSource,
                    text: $editText,
                    focusToken: editorFocusToken,
                    caretOffset: editCaretOffset,
                    isRestoredDraft: editDraftRestored,
                    canSave: canSaveEdit,
                    onCancel: requestCancelEdit,
                    onSave: { saveEdit(thenPaste: false) },
                    onSaveAndPaste: { saveEdit(thenPaste: true) }
                )
            } else if showShortcuts {
                ShortcutReferenceView()
            } else if filteredItems.isEmpty {
                ClipboardEmptyStateView(
                    selectedFilter: selectedFilter,
                    isCapturePaused: clipboardMonitor.isCapturePaused
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if let selectedItem = selectedItem {
                    // Horizontal layout with list and preview side by side
                    HStack(spacing: 0) {
                        clipboardListView
                            .frame(width: 260)
                        Divider()
                        ClipboardCompactPreviewView(
                            item: selectedItem,
                            isRevealed: revealedSensitiveIds.contains(selectedItem.id),
                            loadedImage: loadedImages[selectedItem.id],
                            isLoadingImage: loadingImageIds.contains(selectedItem.id),
                            editingNote: $editingNote,
                            isNoteFocused: $isNoteFocused,
                            showImageModal: $showImageModal,
                            onCopy: {
                                clipboardMonitor.copyToClipboard(selectedItem)
                                menuBarController.hidePopoverAndActivatePreviousApp()
                            },
                            onCopyPlain: {
                                pasteItem(selectedItem, asPlainText: true)
                            },
                            onToggleFavorite: {
                                clipboardMonitor.toggleFavorite(selectedItem)
                                if var updatedItem = self.selectedItem {
                                    updatedItem.isFavorite.toggle()
                                    self.selectedItem = updatedItem
                                }
                            },
                            onToggleSensitive: {
                                clipboardMonitor.toggleSensitive(selectedItem)
                                if var updatedItem = self.selectedItem {
                                    updatedItem.isSensitive.toggle()
                                    if updatedItem.isAutoSensitive || updatedItem.isPasswordLike {
                                        updatedItem.isManuallyUnsensitive = !updatedItem.isSensitive
                                    }
                                    self.selectedItem = updatedItem
                                }
                            },
                            onToggleReveal: {
                                if revealedSensitiveIds.contains(selectedItem.id) {
                                    revealedSensitiveIds.remove(selectedItem.id)
                                } else {
                                    revealedSensitiveIds.insert(selectedItem.id)
                                }
                            },
                            onReveal: {
                                revealedSensitiveIds.insert(selectedItem.id)
                            },
                            onLoadImage: {
                                loadLazyImage(selectedItem)
                            },
                            canRecognizeText: recognizeTextPlan != nil,
                            isRecognizingText: recognizingImageIds.contains(selectedItem.id),
                            onRecognizeText: {
                                recognizeSelectedItemText()
                            },
                            onSaveNote: {
                                saveNote(for: selectedItem)
                            },
                            onEdit: { caretOffset in
                                beginEditing(caretOffset: caretOffset)
                            },
                            onSearchSource: { bundleIdentifier in
                                setSourceFilter(bundleIdentifier)
                            },
                            onReleaseKeyboard: {
                                keyFocusToken += 1
                            }
                        )
                            .frame(width: 259)
                            .id(selectedItem.id)
                    }
                } else {
                    // Full width list when no preview
                    clipboardListView
                }
            }
        }
        .frame(width: 520, height: dynamicHeight, alignment: .top)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            // Initialize time cache when popover opens
            initializeTimeCache()

            // Pick up an edit a previous close interrupted, before anything moves the selection.
            restoreEditDraftIfNeeded()

            // Initialize filtered items immediately
            computedFilteredItems = clipboardMonitor.clipboardHistory
            recomputeFilteredItems()

            // Ensure we have items and properly select the first one
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if !isEditing, !filteredItems.isEmpty {
                    selectedIndex = 0
                    updateSelectedItem()
                }
                // Update popover size after selection is set
                updatePopoverSize()
            }
        }
        .onDisappear {
            // Save any pending note when popover closes
            saveCurrentNote()
            // Cancel any pending tasks
            searchDebounceTask?.cancel()
            filterTask?.cancel()
            actionStatusTask?.cancel()
            // Clear revealed sensitive items when popover closes
            revealedSensitiveIds.removeAll()
        }
        .onChange(of: editText) { newValue in
            // Mirror every keystroke into the controller's draft. This view does not survive the
            // popover closing, and the draft has to.
            menuBarController.editDraft.update(text: newValue)
        }
        .onChange(of: searchText) { newValue in
            // Debounce search to keep typing smooth
            searchDebounceTask?.cancel()

            // Immediate update when clearing search (no delay needed)
            if newValue.isEmpty {
                debouncedSearchText = ""
                recomputeFilteredItems()
                return
            }

            searchDebounceTask = Task {
                // Short, because the filtering itself already runs off the main thread: this only
                // stops a burst of keystrokes starting a task each. 300ms read as the search lagging
                // behind the typing.
                try? await Task.sleep(nanoseconds: 120_000_000)
                if !Task.isCancelled {
                    await MainActor.run {
                        debouncedSearchText = newValue
                        recomputeFilteredItems()
                    }
                }
            }
        }
        .onChange(of: dynamicHeight) { newHeight in
            updatePopoverSize()
        }
        .onChange(of: computedFilteredItems) { newItems in
            // A specific row was asked for (a saved edit, or the item an edit was cancelled on).
            // Checked before the filter reset below, which would otherwise jump back to the top.
            if let wanted = pendingSelectionId,
               let index = newItems.firstIndex(where: { $0.id == wanted }) {
                pendingSelectionId = nil
                shouldResetSelectionAfterFilterChange = false
                clearMultiSelection()
                selectedIndex = index
                selectedItem = newItems[index]
                updatePopoverSize()
                return
            }

            if shouldResetSelectionAfterFilterChange {
                shouldResetSelectionAfterFilterChange = false
                selectedIndex = 0
                clearMultiSelection()
                updateSelectedItem()
            } else if let currentItem = selectedItem,
               let newIndex = newItems.firstIndex(where: { $0.id == currentItem.id }) {
                // Try to preserve the currently selected item
                selectedIndex = newIndex
                // Update selectedItem with fresh data (e.g., toggled isSensitive/isFavorite)
                selectedItem = newItems[newIndex]
            } else {
                // Item no longer in filtered list (e.g., un-favorited while on Favorites tab)
                selectedIndex = 0
                updateSelectedItem()
            }
            // Update size when items change
            updatePopoverSize()
        }
        .onChange(of: selectedFilter) { _ in
            // Dismiss shortcuts view when switching tabs
            showShortcuts = false
            shouldResetSelectionAfterFilterChange = true
            selectedIndex = 0
            selectedItem = nil
            clearMultiSelection()
            isScrolledDown = false
            // Recompute when filter tab changes
            recomputeFilteredItems()
        }
        .onChange(of: sourceFilter) { _ in
            // Narrowing to one app changes what the list holds exactly as switching tabs does, so
            // it resets the same state. Every writer goes through `setSourceFilter`, and the reset
            // lives here rather than there so neither entry point can skip it.
            showShortcuts = false
            shouldResetSelectionAfterFilterChange = true
            selectedIndex = 0
            selectedItem = nil
            clearMultiSelection()
            isScrolledDown = false
            recomputeFilteredItems()
        }
        .onChange(of: clipboardMonitor.clipboardHistory) { _ in
            // Give anything that just arrived a relative time, or it renders as "unknown"
            cacheTimeAgoForNewItems()
            // Recompute when clipboard history changes
            recomputeFilteredItems()
            // Reset selection if needed
            if !filteredItems.isEmpty && selectedIndex >= filteredItems.count {
                selectedIndex = 0
                updateSelectedItem()
            }
        }
        .background(KeyEventHandler(focusToken: keyFocusToken) { keyEvent in
            handleKeyEvent(keyEvent)
        })
        .alert("Discard changes?", isPresented: $showDiscardEditConfirmation) {
            Button("Keep Editing", role: .cancel) {
                focusEditor()
            }
            Button("Discard", role: .destructive) {
                endEditing(selecting: editSource?.id)
            }
        } message: {
            Text("Your edit has not been saved as a new item yet.")
        }
        .alert(
            ClipboardTextSplitContent.confirmationTitle(pieceCount: pendingSplitPlan?.pieceCount ?? 0),
            isPresented: $showSplitConfirmation,
            presenting: pendingSplitPlan
        ) { plan in
            Button("Cancel", role: .cancel) { pendingSplitPlan = nil }
            Button(ClipboardTextSplitContent.confirmButtonTitle(pieceCount: plan.pieceCount)) {
                pendingSplitPlan = nil
                performSplit(plan)
            }
        } message: { plan in
            Text(ClipboardTextSplitContent.confirmationMessage(
                pieceCount: plan.pieceCount,
                historyLimit: userPreferences.maxClipboardItems
            ))
        }
        .clipboardDeletionConfirmation(
            selectedItem: selectedItem,
            selectedItemIds: $selectedItemIds,
            // Only what Clear History will actually remove, so the count is not a promise the
            // confirmation cannot keep: favorites stay.
            itemCount: clipboardMonitor.clipboardHistory.lazy.filter { !$0.isFavorite }.count,
            showDeleteConfirmation: $showClearConfirmation,
            showDeleteAllConfirmation: $showDeleteAllConfirmation,
            onDeleteCurrent: { item in
                clipboardMonitor.deleteItems(withIds: [item.id])
            },
            onDeleteSelected: { ids in
                clipboardMonitor.deleteItems(withIds: ids)
                selectionAnchor = nil
            },
            onDeleteAll: {
                clipboardMonitor.clearHistory()
            }
        )
    }

    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 4) {
                permissionMessage

                if let repairFailureMessage = permissionManager.repairFailureMessage {
                    Text("Repair failed: \(repairFailureMessage). Remove MacClipboard from the Accessibility list with the “−” button, then add it again.")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }

                HStack(spacing: 8) {
                    Button("Open Settings") {
                        permissionManager.openAccessibilitySettings()
                    }
                    .buttonStyle(.borderless)
                    Button("Retry") {
                        permissionManager.refreshPermission()
                    }
                    .buttonStyle(.borderless)

                    switch permissionManager.diagnosis {
                    case .conflictingCopies:
                        Button("Show Copies") {
                            permissionManager.revealConflictingCopies()
                        }
                        .buttonStyle(.borderless)
                        .help("Reveal the other installed copies of MacClipboard in Finder")

                    case .updatedInPlace:
                        Button("Restart MacClipboard") {
                            permissionManager.relaunchAfterUpdate()
                        }
                        .buttonStyle(.borderless)
                        .help("Quit this copy and start the updated one, which macOS accepts again")

                    case .staleRecord:
                        Button(permissionManager.isRepairing ? "Repairing…" : "Repair") {
                            permissionManager.repairPermission()
                        }
                        .buttonStyle(.borderless)
                        .disabled(permissionManager.isRepairing)
                        .help("Remove the stale Accessibility entry for MacClipboard and request permission again")

                    case .notGranted:
                        Button("Force Reset") {
                            permissionManager.forcePermissionPrompt()
                        }
                        .buttonStyle(.borderless)
                        .help("Force macOS to show accessibility permission prompt")
                    }
                }
            }
            Spacer()
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
        .overlay(Divider(), alignment: .bottom)
    }

    /// What the banner says. Each case needs a different fix, and naming the wrong one sends the
    /// user to System Settings to switch on something that is already on.
    @ViewBuilder
    private var permissionMessage: some View {
        if permissionManager.cannotHoldGrant {
            // An ad hoc signature is the whole problem, so every other message here is a dead
            // end: the grant would be gone again after the next build. Only reachable in
            // development, so it is deliberately not localised.
            Text("This build cannot keep Accessibility permission")
                .font(.caption).bold()
            Text("It is ad hoc signed, so macOS pins any grant to this exact binary and the next build invalidates it. Run ./run.sh and use the copy it installs in ~/Applications, which is signed with the persistent dev certificate.")
                .font(.caption2)
                .foregroundColor(.secondary)
        } else {
            switch permissionManager.diagnosis {
            case .conflictingCopies(let copies):
                // Any grant that exists belongs to one specific copy, and it may well be one
                // of the others. A reset here would only move the problem across, so name the
                // real cause instead of asking the user to switch something on again.
                Text("More than one copy of MacClipboard is installed")
                    .font(.caption).bold()
                Text("macOS gives Accessibility access to one specific copy of an app, so a permission granted to another copy does not apply here. Keep a single copy in Applications and remove \(copies.map(\.displayPath).joined(separator: ", ")). You can still copy items.")
                    .font(.caption2)
                    .foregroundColor(.secondary)

            case .updatedInPlace:
                // The grant is fine and belongs to the new binary. This process is the stale
                // one, so the only thing to fix is that it is still running.
                Text("MacClipboard was updated and needs to restart")
                    .font(.caption).bold()
                Text("The app was replaced on disk while this copy kept running, so macOS no longer accepts it for Accessibility. Restarting restores auto‑paste and the hotkey. Nothing needs changing in System Settings. You can still copy items.")
                    .font(.caption2)
                    .foregroundColor(.secondary)

            case .staleRecord:
                // Telling the user to switch the app on is useless here: it already looks
                // switched on. The record has to be deleted and recreated instead.
                Text("Accessibility permission stopped working")
                    .font(.caption).bold()
                if BuildInfo.isDevBuild {
                    // A dev build is never updated by Homebrew, so "after an update" would be a
                    // false lead. What does happen is that another locally built copy claimed the
                    // same bundle id, which is what `./run.sh --reset-permissions` clears up.
                    Text("macOS refuses this dev copy while still showing it as enabled, usually because another locally built copy claimed the same bundle id. Run ./run.sh --reset-permissions, or use Repair, then grant access once more. You can still copy items.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("MacClipboard may still show as enabled in System Settings while macOS refuses it, usually after an update. Repair removes the stale entry and asks again. You can still copy items.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

            case .notGranted:
                Text("Accessibility permission required for auto‑paste")
                    .font(.caption).bold()
                Text("Enable MacClipboard in System Settings > Privacy & Security > Accessibility. You can still copy items.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var hotkeyConflictBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "keyboard.badge.ellipsis")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Global hotkey \(userPreferences.globalHotkey.displayString) is unavailable")
                    .font(.caption).bold()
                Text("Another app registered it first. Click the menu bar icon to open MacClipboard, or record a different shortcut in Settings.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
        .overlay(Divider(), alignment: .bottom)
    }

    /// Says the history stopped growing on purpose.
    ///
    /// Without it a paused app is indistinguishable from a broken one: nothing new appears, and
    /// the list a user is looking at is the same list either way. Deliberately not styled as a
    /// warning, because this is a state the user asked for.
    private var capturePausedBanner: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "pause.circle.fill")
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Clipboard capture is paused")
                    .font(.caption).bold()
                Text("New copies are not being saved. Everything already in your history is still here.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Resume") {
                clipboardMonitor.toggleCapturePaused()
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.12))
        .overlay(Divider(), alignment: .bottom)
    }

    /// Says a newer release exists, without standing in the way of the clipboard.
    ///
    /// This is the surface that carries the detail, because it is the only one the user is already
    /// looking at when they see it: the icon badge can only say "something", and Settings is
    /// somewhere you have to go. Styled like the pause banner rather than as a warning, because
    /// running last week's version is not a problem, and it keeps its Skip button so the popover
    /// cannot become a thing that nags every time it opens.
    private func updateAvailableBanner(_ update: AvailableUpdate) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("MacClipboard v\(update.version) is available")
                    .font(.caption).bold()
                Text(UpdateChecker.isHomebrewManaged
                     ? "You are on v\(BuildInfo.shortVersion). Installed with Homebrew, so upgrade with brew."
                     : "You are on v\(BuildInfo.shortVersion). Your clipboard history is kept when you update.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            // Does the thing, rather than opening an alert that then offers to do the thing. The
            // banner is already the non-blocking surface; putting a modal behind its button would
            // undo the point of it.
            Button(UpdateChecker.isHomebrewManaged ? "Copy Command" : "Update") {
                if updateChecker.performPrimaryAction(for: update) == .copiedHomebrewCommand {
                    showActionStatus(.copiedUpgradeCommand)
                }
            }
            .buttonStyle(.borderless)
            Button("Skip") {
                updateChecker.skipAvailableUpdate()
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
            .help(Text("Stop showing v\(update.version). A newer release will still appear here."))
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.10))
        .overlay(Divider(), alignment: .bottom)
    }

    private var headerView: some View {
        HStack {
            ProjectTitleLink()

            // Only dev builds are badged here: a "Release" badge on every popover would be
            // noise. The Settings footer names the channel either way.
            if BuildInfo.isDevBuild {
                BuildChannelBadge()
            }

            Spacer()

            Button(action: {
                clipboardMonitor.toggleCapturePaused()
            }) {
                Image(systemName: clipboardMonitor.isCapturePaused ? "play.circle" : "pause.circle")
                    .foregroundColor(clipboardMonitor.isCapturePaused ? .accentColor : .secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel(clipboardMonitor.isCapturePaused ? "Resume Capture" : "Pause Capture")
            .help(clipboardMonitor.isCapturePaused
                  ? "Resume capture and start saving new copies again"
                  : "Pause capture: new copies are not saved until you resume. Your history is kept.")

            Button(action: {
                showShortcuts.toggle()
            }) {
                Image(systemName: "keyboard")
                    .foregroundColor(showShortcuts ? .accentColor : .secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Keyboard Shortcuts")
            .help("Keyboard Shortcuts (⌘/)")

            Button(action: {
                menuBarController.showSettings()
            }) {
                Image(systemName: "gearshape")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Settings")
            .help("Settings")
            
            Button(action: {
                showClearConfirmation = true
            }) {
                Image(systemName: "trash")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Clear History")
            .help("Clear History")
            
            Button(action: {
                menuBarController.hidePopover()
            }) {
                Image(systemName: "xmark")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Close")
            .help("Close")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var searchBarView: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            
            ClipboardSearchField(
                text: $searchText,
                placeholder: "Search clipboard... (or just start typing)",
                isFocused: isSearchFocused
            ) { hasKeyboard in
                searchFieldHasKeyboard = hasKeyboard
                // A click into the field, or anything that takes the keyboard away from it, decides
                // this as much as the key handler does, so what the app wants follows what happened.
                isSearchFocused = hasKeyboard
            }

            sourceFilterMenu
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color(NSColor.controlBackgroundColor))
    }

    /// The apps that actually have something in the list, which is the only set worth offering.
    ///
    /// Read off the current tab rather than off the whole history, so the menu never offers an app
    /// that would leave the list empty, and deliberately *before* the source filter and the search
    /// are applied, or picking an app would empty the menu that picked it.
    ///
    /// Cheap enough to be a computed property: a set of a handful of identifiers over at most a
    /// thousand items, and every name behind it is a dictionary hit in `ClipboardSourceAppCatalog`.
    private var sourceAppsInList: [ClipboardSourceApp] {
        let identifiers = Set(
            ClipboardFilter.filteredItems(
                from: clipboardMonitor.clipboardHistory,
                selectedFilter: selectedFilter,
                searchText: ""
            ).compactMap { $0.sourceBundleIdentifier }
        )

        return identifiers
            .map { ClipboardSourceAppCatalog.app(for: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Picking one app out of the ones present, from the search bar.
    ///
    /// A menu rather than a row of app tabs: the set is different on every Mac and grows with the
    /// history, so tabs would either wrap or truncate, and a menu bar app pays for every pixel. It
    /// collapses to a single icon-width button, and it is not drawn at all until something in the
    /// list has a source to filter by, so a history from before this shipped costs nothing.
    @ViewBuilder private var sourceFilterMenu: some View {
        let apps = sourceAppsInList

        if !apps.isEmpty {
            Menu {
                Button {
                    setSourceFilter(nil)
                } label: {
                    // A tick would be the Mac convention, but `Menu` gives no control over the
                    // selection mark, so the state is carried by the button in the search bar.
                    Text("All Apps")
                }

                Divider()

                ForEach(apps, id: \.bundleIdentifier) { app in
                    Button {
                        setSourceFilter(app.bundleIdentifier)
                    } label: {
                        Text(app.name)
                        if let icon = ClipboardSourceAppCatalog.icon(for: app.bundleIdentifier) {
                            Image(nsImage: icon)
                        }
                    }
                }
            } label: {
                if let sourceFilter, let icon = ClipboardSourceAppCatalog.icon(for: sourceFilter) {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: sourceFilter == nil ? "app.dashed" : "questionmark.app.dashed")
                        .foregroundColor(sourceFilter == nil ? .secondary : .accentColor)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(sourceFilterLabel)
            .help(sourceFilterLabel)
        }
    }

    private var sourceFilterLabel: String {
        guard let sourceFilter else {
            return L10n.string("Show clips from one app", comment: "Tooltip for the source app filter when it is off")
        }
        return String(
            format: L10n.string("Showing clips from %@ only. Choose All Apps to stop.", comment: "Tooltip for the active source app filter"),
            ClipboardSourceAppCatalog.app(for: sourceFilter).name
        )
    }

    private var filterPickerView: some View {
        Picker("", selection: $selectedFilter) {
            ForEach(FilterTab.allCases, id: \.self) { tab in
                Text(tab.titleKey).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Clipboard Filter")
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var clipboardListView: some View {
        // Worked out once per rebuild rather than per row: every row's context menu describes the
        // same selection, and the plans carry the joined text and the pieces.
        let plan = mergePlan
        let mergeActionTitle = ClipboardMergedCopyContent.actionTitle(for: plan)
        let splitPlan = self.splitPlan
        let splitActionTitle = ClipboardTextSplitContent.actionTitle(for: splitPlan)

        return ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                            ClipboardItemRow(
                                item: item,
                                isSelected: selectedIndex == index,
                                isMultiSelected: selectedItemIds.contains(item.id),
                                isRevealed: revealedSensitiveIds.contains(item.id),
                                onSelect: {
                                    selectedIndex = index
                                    clearMultiSelection()  // A plain click starts over
                                    updateSelectedItem()
                                },
                                onCopy: {
                                    pasteItem(item)
                                },
                                onToggleFavorite: {
                                    clipboardMonitor.toggleFavorite(item)
                                },
                                onToggleMultiSelect: {
                                    if selectedItemIds.contains(item.id) {
                                        selectedItemIds.remove(item.id)
                                    } else {
                                        selectedItemIds.insert(item.id)
                                    }
                                    // A ⌘-click ends whatever run of arrows was going, so the next
                                    // ⌘↓ grows from the cursor and keeps this click.
                                    endSelectionRun()
                                },
                                onToggleReveal: {
                                    if revealedSensitiveIds.contains(item.id) {
                                        revealedSensitiveIds.remove(item.id)
                                    } else {
                                        revealedSensitiveIds.insert(item.id)
                                    }
                                },
                                timeAgoText: timeAgoText(for: item),
                                mergeActionTitle: mergeActionTitle,
                                canCopyMerged: plan != nil,
                                onCopyMerged: { copyMergedSelection() },
                                splitActionTitle: splitActionTitle,
                                canSplit: splitPlan != nil,
                                onSplit: { splitSelectedItem() }
                            )
                            .id(item.id)
                            .onAppear {
                                if index == 0 { isScrolledDown = false }
                            }
                            .onDisappear {
                                if index == 0 { isScrolledDown = true }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                // Rebuilt when the search settles, never per keystroke: this identity throws the
                // whole scroll view away and builds it again, and doing that on every letter is what
                // made typing feel heavy on a long history.
                .id("listview-\(debouncedSearchText)-\(selectedFilter.rawValue)")
                .onChange(of: selectedIndex) { newIndex in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if newIndex < filteredItems.count {
                            proxy.scrollTo(filteredItems[newIndex].id, anchor: .center)
                        }
                    }
                }

                if isScrolledDown {
                    Button(action: {
                        endSelectionRun()
                        selectedIndex = 0
                        updateSelectedItem()
                        if !filteredItems.isEmpty {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(filteredItems[0].id, anchor: .top)
                            }
                        }
                    }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.accentColor)
                            .background(Circle().fill(Color(NSColor.windowBackgroundColor)).padding(2))
                            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel("Scroll to top")
                    .padding(6)
                    .help("Scroll to top (⌥↑)")
                }
            }
        }
    }
    
    private func saveNote(for item: ClipboardItem) {
        let trimmedNote = editingNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteToSave = trimmedNote.isEmpty ? nil : trimmedNote

        // Only save if note actually changed
        if noteToSave != item.note {
            clipboardMonitor.updateNote(item, note: noteToSave)
        }
    }
    
    // MARK: - Editing a Copy

    /// Text only, and only when it is actually on screen. Editing a masked item would be editing
    /// blind, and it would write the secret into a new row the user never got to read.
    private var canEditSelectedItem: Bool {
        guard let item = selectedItem, item.type == .text else { return false }
        return !item.isSensitive || revealedSensitiveIds.contains(item.id)
    }

    private var canSaveEdit: Bool {
        guard let editSource else { return false }
        return ClipboardTextEdit.intent(newText: editText, sourceText: editSource.fullText) == .save
    }

    /// `caretOffset` is a UTF-16 offset into the item's text, from a click in the preview. Nil (the
    /// pencil, or ⌘E) starts at the beginning.
    private func beginEditing(caretOffset: Int?) {
        guard canEditSelectedItem, let item = selectedItem else { return }

        saveCurrentNote()
        unfocusSearch()
        isNoteFocused = false
        showShortcuts = false
        clearActionStatus()

        editSource = item
        editText = item.fullText
        editDraftRestored = false
        isEditing = true
        menuBarController.editDraft.begin(source: item, text: item.fullText)
        editCaretOffset = caretOffset ?? 0
        editorFocusToken += 1
    }

    /// Picks up an edit that closing the popover interrupted. The draft lives on the controller
    /// precisely because this view is rebuilt from scratch on every open.
    private func restoreEditDraftIfNeeded() {
        guard let draft = menuBarController.editDraft.draft, draft.isDirty else {
            menuBarController.editDraft.clear()
            return
        }

        editSource = draft.source
        editText = draft.text
        editDraftRestored = true
        isEditing = true
        // Line the list up behind the editor, so cancelling lands back on the item being edited.
        pendingSelectionId = draft.source.id
        editCaretOffset = nil
        editorFocusToken += 1
    }

    /// Puts the keyboard back in the editor without moving the caret, after the discard alert.
    private func focusEditor() {
        editCaretOffset = nil
        editorFocusToken += 1
    }

    private func requestCancelEdit() {
        guard let editSource else {
            endEditing(selecting: nil)
            return
        }

        if editText != editSource.fullText {
            showDiscardEditConfirmation = true
            return
        }

        endEditing(selecting: editSource.id)
    }

    private func endEditing(selecting id: UUID?) {
        menuBarController.editDraft.clear()
        isEditing = false
        editSource = nil
        editText = ""
        editDraftRestored = false
        editCaretOffset = nil

        // The editor held first responder and nothing hands it back when it disappears, so the
        // key handler has to take it, or arrows and Enter stay dead for the rest of the session.
        keyFocusToken += 1

        if let id {
            selectItem(withId: id)
        }
    }

    private func saveEdit(thenPaste: Bool) {
        guard let editSource else { return }

        switch clipboardMonitor.saveEditedText(editText, basedOn: editSource) {
        case .empty, .unchanged:
            // Both buttons are disabled in these cases; nothing to do if one is triggered anyway.
            return
        case .saved(let id):
            finishSave(id: id, status: .savedNew, thenPaste: thenPaste)
        case .alreadyInHistory(let id):
            finishSave(id: id, status: .alreadyInHistory, thenPaste: thenPaste)
        }
    }

    private func finishSave(id: UUID, status: ClipboardActionStatus, thenPaste: Bool) {
        endEditing(selecting: nil)

        if thenPaste, let saved = clipboardMonitor.clipboardHistory.first(where: { $0.id == id }) {
            pasteItem(saved)
            return
        }

        revealWrittenItem(withId: id)
        showActionStatus(status)
    }

    /// Selects the row an action just wrote, whatever tab or search the user was on.
    ///
    /// A write that lands outside the current filter looks like a write that did nothing. The All
    /// tab shows every item, hidden ones included, which is what a masked result needs: both the
    /// editor and Copy Merged can only gain masking, so either can produce a row that the Hidden
    /// tab is the only other place to find.
    ///
    /// The source filter is checked with the rest and cleared with them, and it is the one every
    /// write here trips: an edit, a merge, a split and text read from an image all have no source,
    /// so a list narrowed to an app can never contain what they just wrote.
    private func revealWrittenItem(withId id: UUID) {
        guard let written = clipboardMonitor.clipboardHistory.first(where: { $0.id == id }) else { return }

        let isVisible = !ClipboardFilter.filteredItems(
            from: [written],
            selectedFilter: selectedFilter,
            searchText: searchText,
            sourceBundleIdentifier: sourceFilter
        ).isEmpty

        if !isVisible {
            searchText = ""
            debouncedSearchText = ""
            selectedFilter = .all
            sourceFilter = nil
        }

        selectItem(withId: id)
    }

    /// Narrows the list to one app, or widens it back to all of them.
    ///
    /// The one writer of `sourceFilter`, from the menu in the search bar and from the preview's
    /// source button, so the selection reset that a changed list needs cannot be forgotten by one
    /// of them. Exact, unlike typing the app's name into the search: that is a find over everything
    /// a row shows and will also turn up clips that merely mention the word.
    private func setSourceFilter(_ bundleIdentifier: String?) {
        sourceFilter = bundleIdentifier
    }

    // MARK: - Merging a Selection

    /// What ⌘M and the row's context menu would do right now, or nil when the selection cannot be
    /// merged. Read off `filteredItems` rather than off `selectedItemIds`, so the join order is the
    /// order on screen.
    private var mergePlan: ClipboardMergedCopy.Plan? {
        ClipboardMergedCopy.plan(forSelectionIn: filteredItems, selectedIds: selectedItemIds)
    }

    // MARK: - Splitting an Item

    /// What ⌘⇧M and the row's context menu would do right now, or nil when there is nothing to
    /// split. Worked out from the cursor's item, as ⌘E is, not from the clicked row: computing it
    /// per row would mean scanning every visible clip's text on every rebuild, and a clip can be
    /// megabytes.
    ///
    /// A multi-selection belongs to Copy Merged, so the two actions are never both offered: with two
    /// or more rows ⌘-clicked, ⌘M is the one that applies.
    private var splitPlan: ClipboardTextSplit.Plan? {
        guard selectedItemIds.count < 2 else { return nil }
        return ClipboardTextSplit.plan(for: selectedItem)
    }

    /// Returns false when there was nothing to split, so the key can fall through unclaimed.
    @discardableResult
    private func splitSelectedItem() -> Bool {
        guard let plan = splitPlan else { return false }

        guard !plan.needsConfirmation else {
            pendingSplitPlan = plan
            showSplitConfirmation = true
            return true
        }

        performSplit(plan)
        return true
    }

    private func performSplit(_ plan: ClipboardTextSplit.Plan) {
        let outcome = clipboardMonitor.splitIntoItems(plan)

        // The list means something else now: the source has been pushed down by everything the
        // split added, so a ⌘-click made before it is a highlight on a row that has moved.
        clearMultiSelection()

        if let id = outcome.topItemId {
            revealWrittenItem(withId: id)
        }
        showActionStatus(.split(count: plan.pieceCount, moved: outcome.movedCount))
    }

    // MARK: - Reading the Text in an Image

    /// What ⌘R and the preview's button would do right now, or nil when there is nothing to read:
    /// anything that is not an image, and an image that is still masked.
    private var recognizeTextPlan: ClipboardImageTextRecognition.Plan? {
        guard let selectedItem else { return nil }
        return ClipboardImageTextRecognition.plan(
            for: selectedItem,
            isRevealed: revealedSensitiveIds.contains(selectedItem.id)
        )
    }

    /// Returns false when there is nothing to read, so the key can fall through unclaimed.
    @discardableResult
    private func recognizeSelectedItemText() -> Bool {
        guard let plan = recognizeTextPlan else { return false }
        // A second ⌘R while the first pass is still running would read the same image twice and
        // deduplicate down to one row, having spent the work twice.
        guard !recognizingImageIds.contains(plan.itemId) else { return true }

        recognizingImageIds.insert(plan.itemId)
        clipboardMonitor.recognizeText(plan) { outcome in
            recognizingImageIds.remove(plan.itemId)

            switch outcome {
            case .recognized(let id, let lineCount):
                revealWrittenItem(withId: id)
                showActionStatus(.recognizedText(lines: lineCount))
            case .alreadyInHistory(let id):
                revealWrittenItem(withId: id)
                showActionStatus(.alreadyInHistory)
            case .noTextFound:
                showActionStatus(.noTextRecognized)
            case .failed:
                showActionStatus(.textRecognitionFailed)
            }
        }
        return true
    }

    /// Returns false when there was nothing to merge, so the key can fall through unclaimed.
    @discardableResult
    private func copyMergedSelection() -> Bool {
        guard let plan = mergePlan else { return false }

        let outcome = clipboardMonitor.copyMerged(plan)
        // The selection has been spent. Leaving it highlighted would invite a second ⌘M that
        // silently does nothing, the join already being the item at the top.
        clearMultiSelection()

        switch outcome {
        case .merged(let id):
            revealWrittenItem(withId: id)
            showActionStatus(.merged(count: plan.mergedCount, skipped: plan.skippedCount))
        case .alreadyInHistory(let id):
            revealWrittenItem(withId: id)
            showActionStatus(.alreadyInHistory)
        }

        return true
    }

    /// Selects `id` if it is in the list already, otherwise leaves it pending for the next
    /// recompute. Saving changes the history, and filtering it again is asynchronous.
    private func selectItem(withId id: UUID) {
        if let index = filteredItems.firstIndex(where: { $0.id == id }) {
            pendingSelectionId = nil
            selectedIndex = index
            selectedItem = filteredItems[index]
        } else {
            pendingSelectionId = id
        }
    }

    private func showActionStatus(_ status: ClipboardActionStatus) {
        actionStatusTask?.cancel()
        actionStatus = status
        actionStatusTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { actionStatus = nil }
        }
    }

    private func clearActionStatus() {
        actionStatusTask?.cancel()
        actionStatusTask = nil
        actionStatus = nil
    }

    // MARK: - Navigation Functions

    /// Drops the multi-selection and the run that was growing it. Everything that makes the list
    /// mean something else goes through here, so the two can never disagree.
    private func clearMultiSelection() {
        selectedItemIds.removeAll()
        selectionAnchor = nil
    }

    private func navigateUp() {
        // Always navigate, unfocus search if needed
        if isSearchFocused {
            unfocusSearch()
        }
        endSelectionRun()
        selectedIndex = max(0, selectedIndex - 1)
        updateSelectedItem()
    }

    private func navigateDown() {
        // Always navigate, unfocus search if needed
        if isSearchFocused {
            unfocusSearch()
        }
        endSelectionRun()
        selectedIndex = min(filteredItems.count - 1, selectedIndex + 1)
        updateSelectedItem()
    }

    /// Ends a run of ⌘/⇧ arrows without touching what is selected.
    ///
    /// A plain arrow, or a ⌘-click, means the next extend should grow from where the cursor is now
    /// rather than from wherever the last run started. What is already selected survives, and
    /// becomes the base the next run builds on, so a user can pick a block, step past a row they do
    /// not want, and pick another block.
    private func endSelectionRun() {
        selectionAnchor = nil
    }

    /// ⌘ or ⇧ on an arrow key grows the multi-selection instead of moving the cursor alone.
    private func extendSelection(by delta: Int) {
        if isSearchFocused {
            unfocusSearch()
        }

        guard let result = ClipboardSelectionExtension.extending(
            from: selectedIndex,
            by: delta,
            in: filteredItems,
            selectedIds: selectedItemIds,
            anchor: selectionAnchor
        ) else { return }

        selectionAnchor = result.anchor
        selectedItemIds = result.selectedIds
        selectedIndex = result.index
        updateSelectedItem()
    }

    private func updateSelectedItem() {
        saveCurrentNote()
        revealedSensitiveIds.removeAll()

        guard !filteredItems.isEmpty else {
            selectedItem = nil
            editingNote = ""
            return
        }

        selectedIndex = max(0, min(selectedIndex, filteredItems.count - 1))

        if selectedIndex < filteredItems.count {
            selectedItem = filteredItems[selectedIndex]
            editingNote = selectedItem?.note ?? ""
        } else {
            selectedItem = nil
            editingNote = ""
        }
    }

    private func saveCurrentNote() {
        guard let item = selectedItem else { return }
        let trimmedNote = editingNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteToSave = trimmedNote.isEmpty ? nil : trimmedNote

        // Only save if note actually changed
        if noteToSave != item.note {
            clipboardMonitor.updateNote(item, note: noteToSave)
        }
    }

    /// Load a lazy-loaded image from disk
    private func loadLazyImage(_ item: ClipboardItem) {
        guard item.needsImageLoad,
              !loadingImageIds.contains(item.id),
              loadedImages[item.id] == nil else { return }

        loadingImageIds.insert(item.id)

        clipboardMonitor.loadImageIfNeeded(item) { image in
            loadingImageIds.remove(item.id)
            if let image = image {
                loadedImages[item.id] = image
                // Limit cache size to prevent memory bloat
                if loadedImages.count > 20 {
                    // Remove oldest entries (this is a simple approach)
                    let keysToRemove = Array(loadedImages.keys.prefix(loadedImages.count - 20))
                    for key in keysToRemove {
                        loadedImages.removeValue(forKey: key)
                    }
                }
            }
        }
    }

    private func initializeTimeCache() {
        timeAgoCache.removeAll()
        cacheTimeAgoForNewItems()
    }

    private func timeAgoText(for item: ClipboardItem) -> String {
        if let cached = timeAgoCache[item.id] { return cached }

        // Only reached if an item got into the list before the cache heard about it. Formatting one
        // row costs less than showing "unknown", which is what this fallback used to do.
        return ClipboardTimeAgo.string(
            for: item.timestamp,
            relativeTo: Date(),
            formatter: ClipboardTimeAgo.makeFormatter()
        )
    }

    /// Formats the relative time of any item that does not have one yet.
    ///
    /// The cache used to be filled once, when the popover appeared, so anything that arrived while
    /// it was open rendered as "unknown": a copy made from another app, and every edit saved as a
    /// new item, since that is created while the user is looking at the list.
    private func cacheTimeAgoForNewItems() {
        let missing = clipboardMonitor.clipboardHistory.filter { timeAgoCache[$0.id] == nil }
        guard !missing.isEmpty else { return }

        let formatter = ClipboardTimeAgo.makeFormatter()
        let now = Date()
        for item in missing {
            timeAgoCache[item.id] = ClipboardTimeAgo.string(for: item.timestamp, relativeTo: now, formatter: formatter)
        }
    }
    
    private func updatePopoverSize() {
        DispatchQueue.main.async {
            self.menuBarController.updatePopoverSize(to: NSSize(width: 520, height: self.dynamicHeight))
        }
    }
    
    private func pasteSelectedItem(asPlainText: Bool = false) {
        guard let item = selectedItem else { return }
        pasteItem(item, asPlainText: asPlainText)
    }

    private func pasteItem(_ item: ClipboardItem, asPlainText: Bool = false) {
        // Copy item to clipboard
        clipboardMonitor.copyToClipboard(item, asPlainText: asPlainText)

        // Hide popover & activate previous app
        menuBarController.hidePopoverAndActivatePreviousApp()
        // Ask controller to schedule paste once previous app regains focus
        menuBarController.schedulePasteAfterActivation()
    }
    
    // MARK: - Key Event Handling
    
    private func handleKeyEvent(_ keyEvent: NSEvent) -> Bool {
        // The editor owns the keyboard while it is open. Everything below assumes a list to
        // navigate: ⌘⌫ would offer to clear the history instead of deleting to the start of a
        // line, a digit would jump the selection, ⌘V would toggle a reveal instead of pasting into
        // the text. Only the keys that leave the editor are claimed.
        if isEditing {
            return handleEditorKeyEvent(keyEvent)
        }

        // Typing belongs to the search field, and it is claimed here rather than in the switch's
        // `default` arm. Every shortcut below carries ⌘, so a bare letter can never be one, but a
        // case that matches on key code alone and then fails its inner test returns false and the
        // key reaches nobody: that is why f, d, z, e, h, v and n used to start no search at all.
        if let claimed = claimTypingForSearch(keyEvent) {
            return claimed
        }

        switch keyEvent.keyCode {
        case 126: // Up arrow
            // ⌥↑ jumps to the top. It used to be ⌘↑, and moved when ⌘ became a modifier that grows
            // the selection: ⌘↑ has to mean the same thing as ⌘↓ or neither is learnable.
            if keyEvent.modifierFlags.contains(.option) {
                endSelectionRun()
                selectedIndex = 0
                updateSelectedItem()
                return true
            }
            if extendsSelection(keyEvent) {
                extendSelection(by: -1)
                return true
            }
            navigateUp()
            return true
        case 125: // Down arrow
            if extendsSelection(keyEvent) {
                extendSelection(by: 1)
                return true
            }
            navigateDown()
            return true
        case 123: // Left arrow
            if !isSearchFocused {
                let allCases = FilterTab.allCases
                if let currentIndex = allCases.firstIndex(of: selectedFilter), currentIndex > 0 {
                    selectedFilter = allCases[currentIndex - 1]
                }
                return true
            }
        case 124: // Right arrow
            if !isSearchFocused {
                let allCases = FilterTab.allCases
                if let currentIndex = allCases.firstIndex(of: selectedFilter), currentIndex < allCases.count - 1 {
                    selectedFilter = allCases[currentIndex + 1]
                }
                return true
            }
        case 36: // Return/Enter
            // Always paste the selected item, unfocus search if needed
            if isSearchFocused {
                unfocusSearch()
            }
            // ⇧⏎ pastes the same item without the formatting it was copied with. Deliberately next
            // to the paste key rather than somewhere mnemonic: it is the same action with one thing
            // taken away. Harmless on an item that carries no formatting, which is why it is not
            // conditional on one; ⌘⇧V, the usual "paste and match style", is the app's default
            // global hotkey and cannot be taken for this.
            let asPlainText = keyEvent.modifierFlags.contains(.shift) && userPreferences.shortcutsEnabled
            pasteSelectedItem(asPlainText: asPlainText)
            return true
        case 44: // / key (slash)
            if keyEvent.modifierFlags.contains(.command) {
                showShortcuts.toggle()
                return true
            }
        case 53: // Escape
            if showShortcuts {
                showShortcuts = false
                return true
            }
            if isNoteFocused {
                if let item = selectedItem { saveNote(for: item) }
                isNoteFocused = false
                return true
            }
            if isSearchFocused {
                unfocusSearch()
                return true
            }
            menuBarController.hidePopoverAndActivatePreviousApp()
            return true
        case 3: // F key
            if keyEvent.modifierFlags.contains(.command) && userPreferences.shortcutsEnabled {
                selectedFilter = selectedFilter == .favorites ? .all : .favorites
                return true
            }
        case 2: // D key
            if keyEvent.modifierFlags.contains(.command) && userPreferences.shortcutsEnabled {
                if let item = selectedItem {
                    clipboardMonitor.toggleFavorite(item)
                    return true
                }
            }
        case 6: // Z key
            if keyEvent.modifierFlags.contains(.command) && userPreferences.shortcutsEnabled {
                if let item = selectedItem, item.type == .image {
                    showImageModal = true
                    return true
                }
            }
        case 14: // E key
            if keyEvent.modifierFlags.contains(.command) && userPreferences.shortcutsEnabled {
                if canEditSelectedItem {
                    beginEditing(caretOffset: nil)
                    return true
                }
            }
        case 4: // H key
            if keyEvent.modifierFlags.contains(.command) && userPreferences.shortcutsEnabled {
                if var item = selectedItem {
                    clipboardMonitor.toggleSensitive(item)
                    item.isSensitive.toggle()
                    if item.isAutoSensitive || item.isPasswordLike {
                        item.isManuallyUnsensitive = !item.isSensitive
                    }
                    selectedItem = item
                    return true
                }
            }
        case 9: // V key
            if keyEvent.modifierFlags.contains(.command) && userPreferences.shortcutsEnabled {
                if let item = selectedItem, item.isSensitive {
                    if revealedSensitiveIds.contains(item.id) {
                        revealedSensitiveIds.remove(item.id)
                    } else {
                        revealedSensitiveIds.insert(item.id)
                    }
                    return true
                }
            }
        case 15 where keyEvent.modifierFlags.contains(.command): // R key
            // The modifier is matched in the pattern rather than tested inside the case, for the
            // reason spelled out under `case 46`: a case that matches and then does nothing swallows
            // the key, and a bare r has to reach the search field.
            guard userPreferences.shortcutsEnabled else { return false }
            return recognizeSelectedItemText()
        case 46 where keyEvent.modifierFlags.contains(.command): // M key
            // The modifier is matched in the pattern rather than tested inside the case, unlike the
            // letters above. A case that matches and then does nothing swallows the key: that is why
            // typing f, d, z, e, h, v or n over the list starts no search, and m should not join
            // them. Only ⌘M and ⌘⇧M are claimed here, so a bare m still reaches `default` and the
            // search field, and either with shortcuts switched off does nothing rather than typing
            // an m.
            //
            // ⇧ picks the mirror action: ⌘M joins a selection into one clip, ⌘⇧M cuts one clip into
            // several. They share a key because they are the same idea in opposite directions, and
            // the two can never both apply, `splitPlan` standing down for a multi-selection.
            guard userPreferences.shortcutsEnabled else { return false }
            if keyEvent.modifierFlags.contains(.shift) {
                return splitSelectedItem()
            }
            return copyMergedSelection()
        case 45: // N key
            if keyEvent.modifierFlags.contains(.command) && userPreferences.shortcutsEnabled {
                if isNoteFocused {
                    if let item = selectedItem { saveNote(for: item) }
                    isNoteFocused = false
                } else {
                    unfocusSearch()
                    isNoteFocused = true
                }
                return true
            }
        case 51: // Backspace/Delete key
            if keyEvent.modifierFlags.contains(.command) && userPreferences.shortcutsEnabled {
                showClearConfirmation = true
                return true
            }
        case 48: // Tab
            if isSearchFocused {
                unfocusSearch()
            } else {
                isSearchFocused = true
            }
            return true
        default:
            return false
        }
        return false
    }

    /// Hands the keyboard back to the list. Both flags move together and immediately: the field
    /// gives up first responder a pass or two later, and a key typed in between belongs to a new
    /// search rather than to a field that is on its way out.
    private func unfocusSearch() {
        isSearchFocused = false
        searchFieldHasKeyboard = false
    }

    /// Typing that belongs to the search field, applied. `ClipboardSearchTyping` holds the rule and
    /// the reasoning; nil means the key was not typing and the shortcut table should have it.
    private func claimTypingForSearch(_ keyEvent: NSEvent) -> Bool? {
        let outcome = ClipboardSearchTyping.outcome(
            characters: keyEvent.characters,
            keyCode: keyEvent.keyCode,
            modifiers: keyEvent.modifierFlags,
            state: ClipboardSearchTyping.State(
                fieldHasKeyboard: searchFieldHasKeyboard,
                noteHasKeyboard: isNoteFocused,
                searchIsFocused: isSearchFocused,
                searchIsEmpty: searchText.isEmpty
            )
        )

        switch outcome {
        case .shortcut:
            return nil
        case .start(let characters):
            searchText = characters
            isSearchFocused = true
        case .extend(let characters):
            searchText += characters
        case .deleteLast:
            searchText.removeLast()
        }
        return true
    }

    /// Whether an arrow key should grow the selection rather than move the cursor.
    ///
    /// Not gated on `shortcutsEnabled`, for the same reason the bare arrows are not: this is
    /// navigating the list, which is the one thing the popover cannot be asked to stop doing.
    private func extendsSelection(_ keyEvent: NSEvent) -> Bool {
        keyEvent.modifierFlags.contains(.command) || keyEvent.modifierFlags.contains(.shift)
    }

    /// Keys handled while the editor is open. Everything not claimed here falls through to the
    /// text view, so ⌘A, ⌘C, ⌘V, ⌘X and ⌘Z all do what they do in any other text field.
    private func handleEditorKeyEvent(_ keyEvent: NSEvent) -> Bool {
        let hasCommand = keyEvent.modifierFlags.contains(.command)

        switch keyEvent.keyCode {
        case 53: // Escape
            requestCancelEdit()
            return true
        case 1 where hasCommand: // S key
            if canSaveEdit { saveEdit(thenPaste: false) }
            return true
        case 36 where hasCommand: // Return/Enter
            // Enter on its own belongs to the text view: it adds a line. Only ⌘⏎ saves and pastes,
            // which is what Enter means everywhere else in the popover.
            if canSaveEdit { saveEdit(thenPaste: true) }
            return true
        default:
            return false
        }
    }
}

struct ClipboardDeletionConfirmationContent {
    static func deleteTitle(selectedCount: Int) -> String {
        selectedCount == 0 ? "Delete Items" : "Delete Selected Items?"
    }

    static func deleteMessage(selectedCount: Int) -> String {
        if selectedCount == 0 {
            return "Choose to delete the currently previewed item or clear all history."
        }

        return "This will permanently delete \(selectedCount) selected item\(selectedCount == 1 ? "" : "s"). This action cannot be undone."
    }

    static func selectedDeleteButtonTitle(selectedCount: Int) -> String {
        "Delete \(selectedCount) Item\(selectedCount == 1 ? "" : "s")"
    }

    static func deleteAllChoiceTitle(itemCount: Int) -> String {
        "Delete All \(itemCount) Items..."
    }

    static func deleteAllTitle(itemCount: Int) -> String {
        "Delete All \(itemCount) Items?"
    }

    static func deleteAllMessage(itemCount: Int) -> String {
        "Are you sure? This will permanently delete \(itemCount) item\(itemCount == 1 ? "" : "s") from your clipboard history. Favorites are kept, so unstar anything you also want removed. This action cannot be undone."
    }
}

struct ClipboardMergedCopyContent {
    /// The context menu entry, which is the one place the action can describe itself *before* it
    /// runs. So it carries all three things a user needs to predict the result: how many items,
    /// which order, and how many of the ones they picked are being left out.
    ///
    /// With nothing mergeable it stays visible and says how to make a selection instead of
    /// disappearing. A ⌘-click on a second row is not a gesture anyone finds by accident, and a
    /// greyed entry that explains itself is the cheapest place in a menu bar app to teach it.
    static func actionTitle(for plan: ClipboardMergedCopy.Plan?) -> String {
        guard let plan else { return "Copy Merged (⌘-Click Two or More Text Items)" }

        let base = "Copy \(plan.mergedCount) Merged, Top to Bottom"
        guard plan.skippedCount > 0 else { return base }
        return "\(base) (\(plan.skippedCount) Skipped)"
    }
}

struct ClipboardTextSplitContent {
    /// The context menu entry. Like Copy Merged's it states the count before the action runs, and
    /// with nothing to split it says what would make it available rather than disappearing.
    ///
    /// It names the *selected* item because a right click does not move the cursor, so the row under
    /// the pointer and the row this would take are not always the same one.
    static func actionTitle(for plan: ClipboardTextSplit.Plan?) -> String {
        guard let plan else { return "Split into Lines (Select a Multi-Line Text Item)" }
        return "Split Selected Item into \(plan.pieceCount) Items"
    }

    static func confirmationTitle(pieceCount: Int) -> String {
        "Split into \(pieceCount) Items?"
    }

    /// The one action in the popover that multiplies rows, so the confirmation says what that costs
    /// rather than only how many there are. The history limit is named only when the split would
    /// actually reach it: an accurate warning that does not apply is how a confirmation stops being
    /// read at all.
    static func confirmationMessage(pieceCount: Int, historyLimit: Int) -> String {
        var message = "This adds \(pieceCount) items to your history, one per line, and leaves the original item as it is."
        if pieceCount >= historyLimit {
            message += " Your history keeps \(historyLimit) items, so the oldest non-favorites will be pushed out."
        }
        return message
    }

    static func confirmButtonTitle(pieceCount: Int) -> String {
        "Split into \(pieceCount) Items"
    }
}

private struct ClipboardDeletionConfirmationModifier: ViewModifier {
    let selectedItem: ClipboardItem?
    @Binding var selectedItemIds: Set<UUID>
    let itemCount: Int
    @Binding var showDeleteConfirmation: Bool
    @Binding var showDeleteAllConfirmation: Bool
    let onDeleteCurrent: (ClipboardItem) -> Void
    let onDeleteSelected: (Set<UUID>) -> Void
    let onDeleteAll: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                ClipboardDeletionConfirmationContent.deleteTitle(selectedCount: selectedItemIds.count),
                isPresented: $showDeleteConfirmation
            ) {
                if selectedItemIds.isEmpty {
                    Button("Cancel", role: .cancel) { }
                    if let selectedItem {
                        Button("Delete Current Item", role: .destructive) {
                            onDeleteCurrent(selectedItem)
                        }
                    }
                    Button(ClipboardDeletionConfirmationContent.deleteAllChoiceTitle(itemCount: itemCount)) {
                        showDeleteAllConfirmation = true
                    }
                } else {
                    Button("Cancel", role: .cancel) { }
                    Button(ClipboardDeletionConfirmationContent.selectedDeleteButtonTitle(selectedCount: selectedItemIds.count), role: .destructive) {
                        // The anchor is dropped by `onDeleteSelected`: this modifier holds the set
                        // and nothing else about the selection.
                        onDeleteSelected(selectedItemIds)
                        selectedItemIds.removeAll()
                    }
                }
            } message: {
                Text(ClipboardDeletionConfirmationContent.deleteMessage(selectedCount: selectedItemIds.count))
            }
            .alert(
                ClipboardDeletionConfirmationContent.deleteAllTitle(itemCount: itemCount),
                isPresented: $showDeleteAllConfirmation
            ) {
                Button("Cancel", role: .cancel) { }
                Button("Yes, Delete All", role: .destructive) {
                    onDeleteAll()
                }
            } message: {
                Text(ClipboardDeletionConfirmationContent.deleteAllMessage(itemCount: itemCount))
            }
    }
}

private extension View {
    func clipboardDeletionConfirmation(
        selectedItem: ClipboardItem?,
        selectedItemIds: Binding<Set<UUID>>,
        itemCount: Int,
        showDeleteConfirmation: Binding<Bool>,
        showDeleteAllConfirmation: Binding<Bool>,
        onDeleteCurrent: @escaping (ClipboardItem) -> Void,
        onDeleteSelected: @escaping (Set<UUID>) -> Void,
        onDeleteAll: @escaping () -> Void
    ) -> some View {
        modifier(
            ClipboardDeletionConfirmationModifier(
                selectedItem: selectedItem,
                selectedItemIds: selectedItemIds,
                itemCount: itemCount,
                showDeleteConfirmation: showDeleteConfirmation,
                showDeleteAllConfirmation: showDeleteAllConfirmation,
                onDeleteCurrent: onDeleteCurrent,
                onDeleteSelected: onDeleteSelected,
                onDeleteAll: onDeleteAll
            )
        )
    }
}

struct ClipboardCompactPreviewView: View {
    let item: ClipboardItem
    let isRevealed: Bool
    let loadedImage: NSImage?
    let isLoadingImage: Bool
    @Binding var editingNote: String
    @FocusState.Binding var isNoteFocused: Bool
    @Binding var showImageModal: Bool
    let onCopy: () -> Void
    /// Pastes the item without the formatting it was copied with. Only offered for an item that
    /// has any, so it never appears as a choice with no second half.
    let onCopyPlain: () -> Void
    let onToggleFavorite: () -> Void
    let onToggleSensitive: () -> Void
    let onToggleReveal: () -> Void
    let onReveal: () -> Void
    let onLoadImage: () -> Void
    /// False for a masked image, so the button explains itself rather than disappearing: reading a
    /// hidden image would write out text the user never got to see.
    let canRecognizeText: Bool
    let isRecognizingText: Bool
    let onRecognizeText: () -> Void
    let onSaveNote: () -> Void
    /// Opens the editor. The offset is where in the text the caret should land, nil for the start.
    let onEdit: (Int?) -> Void
    /// Narrows the list to the clips copied out of this item's source app, by bundle identifier.
    let onSearchSource: (String) -> Void
    /// Escape while the preview text has the keyboard: hand it back to the list.
    let onReleaseKeyboard: () -> Void

    private var isMasked: Bool {
        item.isSensitive && !isRevealed
    }

    private var displayImage: NSImage? {
        (item.content as? NSImage) ?? loadedImage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            toolbar
            metadataRow
            previewContent

            Spacer()

            noteField
        }
        .padding(6)
        .background(Color(NSColor.controlBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            editingNote = item.note ?? ""
        }
        .onChange(of: item.id) { _ in
            editingNote = item.note ?? ""
        }
    }

    private var toolbar: some View {
        HStack {
            Text("Preview")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.primary)

            Spacer()

            // Tighter than the default spacing: with a sensitive text item this row carries four
            // icons and the Copy button in 259pt.
            HStack(spacing: 6) {
                Button(action: onToggleFavorite) {
                    Image(systemName: item.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 12))
                        .foregroundColor(item.isFavorite ? .yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(item.isFavorite ? "Remove from favorites" : "Add to favorites")
                .help(item.isFavorite ? "Remove from favorites (⌘D)" : "Add to favorites (⌘D)")

                Button(action: onToggleSensitive) {
                    Image(systemName: item.isSensitive ? "lock.fill" : "lock.open")
                        .font(.system(size: 12))
                        .foregroundColor(item.isSensitive ? .orange : .secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(item.isSensitive ? "Remove sensitive flag" : "Mark as sensitive")
                .help(item.isSensitive ? "Remove sensitive flag (⌘H)" : "Mark as sensitive (⌘H)")

                if item.isSensitive {
                    Button(action: onToggleReveal) {
                        Image(systemName: isMasked ? "eye" : "eye.slash")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isMasked ? "Reveal content" : "Hide content")
                    .help(isMasked ? "Reveal content (⌘V)" : "Hide content (⌘V)")
                }

                if item.type == .text {
                    Button(action: { onEdit(nil) }) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isMasked)
                    .accessibilityLabel("Edit a copy")
                    .help(isMasked ? "Reveal this item before editing it (⌘V)" : "Edit a copy, saved as a new item (⌘E)")
                }

                if item.type == .image {
                    recognizeTextButton
                }
            }

            Button("Copy ⏎", action: onCopy)
                .buttonStyle(.bordered)
                .font(.caption)
                .controlSize(.small)
        }
    }

    /// Reading the text in an image, which is the one action here that takes long enough to need a
    /// state of its own: the spinner replaces the button in the same 12pt slot, so the row does not
    /// resize while it runs. The on-device claim is in the tooltip rather than in the row, because it
    /// is the answer to "where does this image go", and that question is asked before pressing it.
    @ViewBuilder private var recognizeTextButton: some View {
        if isRecognizingText {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 14, height: 14)
                .accessibilityLabel("Reading the text in this image")
                .help("Reading the text in this image, on this Mac")
        } else {
            Button(action: onRecognizeText) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!canRecognizeText)
            .accessibilityLabel("Read the text in this image")
            .help(canRecognizeText
                ? "Read the text in this image on this Mac, saved as a new item (⌘R)"
                : "Reveal this item before reading its text (⌘V)")
        }
    }

    private var metadataRow: some View {
        HStack(spacing: 8) {
            // Ahead of the type-specific counts, and shared by all three of them: an image and a
            // set of files were copied out of an app just as text was.
            if let sourceBundleIdentifier = item.sourceBundleIdentifier {
                sourceApp(bundleIdentifier: sourceBundleIdentifier)
            }

            switch item.type {
            case .text:
                textMetadata
            case .image:
                imageMetadata
            case .file:
                fileMetadata
            }

            Spacer(minLength: 4)

            // Pinned to the trailing edge, ahead of the counts, and never compressed. Packed in
            // beside them it was squeezed as the numbers grew: a 5,510 character clip rendered the
            // separators at zero width, wrapped the badge onto two lines and shrank the button
            // below its own label, so the action appeared on some items and not others. The counts
            // are what may truncate here; the action is not.
            if item.carriesFormatting {
                formattingActions
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
        .padding(.top, 2)
    }

    /// The formatting marker and the paste that drops it, which only exist together: the marker
    /// says a paste keeps the styling, and the button beside it is how to get the other outcome.
    private var formattingActions: some View {
        HStack(spacing: 6) {
            Image(systemName: "textformat")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .accessibilityLabel("Keeps its formatting")
                .help("Pasting this item keeps the formatting it was copied with")

            Button("Plain ⇧⏎", action: onCopyPlain)
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                .accessibilityLabel("Paste without formatting")
                .help("Paste without formatting (⇧⏎)")
        }
    }

    /// The name beside the icon, and the second way into the source filter: the first is the menu
    /// in the search bar, and this is the same filter reached from the item that prompted the
    /// thought. It sets the filter rather than typing the name, so it is exact.
    private func sourceApp(bundleIdentifier: String) -> some View {
        let app = ClipboardSourceAppCatalog.app(for: bundleIdentifier)

        return Button {
            onSearchSource(bundleIdentifier)
        } label: {
            HStack(spacing: 3) {
                ClipboardSourceAppIcon(bundleIdentifier: bundleIdentifier, size: 12)
                Text(app.name)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .accessibilityLabel("Show clips copied from \(app.name)")
        .help("Show the clips copied from \(app.name)")
    }

    @ViewBuilder private var textMetadata: some View {
        let charCount = item.fullText.count
        let lineCount = item.fullText.components(separatedBy: .newlines).count
        // First, and shown whether or not the item is masked, like the formatting marker: where a
        // clip came from is not its content. It matters most on the items nobody watched arrive.
        if item.isRecognizedText {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize()
                .accessibilityLabel("Read from an image")
                .help("This text was read from an image, on this Mac")
            Text("•")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.6))
                .fixedSize()
        }
        // Ahead of the counts, because it is the one thing here that says what the clip *is*. Behind
        // the mask, for the reason the row's swatch is.
        if !isMasked, let swatch = ClipboardColorSwatch.swatch(for: item) {
            ClipboardColorSwatchView(swatch: swatch, size: 12)
                .fixedSize()
            if swatch.addsHexLabel {
                Text(swatch.hexLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .fixedSize()
                    .textSelection(.enabled)
            }
            Text("•")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.6))
                .fixedSize()
        }
        Text("\(charCount) chars")
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .lineLimit(1)
        if lineCount > 1 {
            Text("•")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.6))
                .fixedSize()
            Text("\(lineCount) lines")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var imageMetadata: some View {
        if let displayImage {
            let width = Int(displayImage.size.width)
            let height = Int(displayImage.size.height)
            Text("\(width) × \(height) px")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder private var fileMetadata: some View {
        if let urls = item.content as? [URL] {
            Text("\(urls.count) file\(urls.count == 1 ? "" : "s")")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder private var previewContent: some View {
        if isMasked {
            ScrollView {
                maskedContent
            }
        } else if item.type == .text {
            // A click here becomes a caret in the editor, which needs a real text view.
            ClipboardTextView(
                text: .constant(item.fullText),
                isEditable: false,
                fontSize: 11,
                onPlainClick: { offset in onEdit(offset) },
                onEscape: onReleaseKeyboard
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .help("Click the text to edit a copy of it (⌘E). Drag to select without editing.")
        } else {
            ScrollView {
                unmaskedContent
            }
        }
    }

    private var maskedContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 32))
                .foregroundColor(.secondary)

            Text("Sensitive content hidden")
                .font(.caption)
                .foregroundColor(.secondary)

            Button("Click to reveal", action: onReveal)
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 20)
    }

    @ViewBuilder private var unmaskedContent: some View {
        switch item.type {
        case .text:
            // Handled in `previewContent`, which gives text its own text view.
            EmptyView()
        case .image:
            imagePreview
            imageAssociatedText
        case .file:
            Text(item.fullText)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(nil)
        }
    }

    @ViewBuilder private var imagePreview: some View {
        if let displayImage {
            ZStack {
                Image(nsImage: displayImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 120)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(4)

                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.primary.opacity(0.7)))
                    }
                    Spacer()
                }
                .padding(6)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                showImageModal = true
            }
            .help("Click to view full size with zoom")
            .sheet(isPresented: $showImageModal) {
                ImageModalView(image: displayImage)
            }
        } else if isLoadingImage {
            VStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Loading image...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: 120)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                Text("Click to load image")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: 120)
            .contentShape(Rectangle())
            .onTapGesture(perform: onLoadImage)
            .onAppear(perform: onLoadImage)
        }
    }

    @ViewBuilder private var imageAssociatedText: some View {
        if let associatedText = item.associatedText,
           !associatedText.isEmpty {
            Divider()
                .padding(.vertical, 4)
            Text("Text representation")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Text(associatedText)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(nil)
        }
    }

    private var noteField: some View {
        HStack(spacing: 4) {
            Image(systemName: "note.text")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            TextField("Add note...", text: $editingNote)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.caption)
                .foregroundColor(.secondary)
                .focused($isNoteFocused)
                .onChange(of: editingNote) { newValue in
                    if newValue.count > 100 {
                        editingNote = String(newValue.prefix(100))
                    }
                }
                .onSubmit {
                    onSaveNote()
                    isNoteFocused = false
                }
                .onChange(of: isNoteFocused) { focused in
                    if !focused {
                        onSaveNote()
                    }
                }

            if editingNote.count > 70 {
                Text("\(editingNote.count)/100")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(editingNote.count >= 100 ? .orange : .secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
        .cornerRadius(4)
    }
}

/// The one line the popover gets to explain what an action just did to the history.
///
/// Shared by the editor, Copy Merged, Split and text recognition because each writes a row the user
/// did not watch arrive, and they share the "that text was already here" case: the merger dedupes by
/// content, so anything matching an existing clip moves it to the top instead of adding a second one.
enum ClipboardActionStatus: Equatable {
    case savedNew
    case alreadyInHistory
    case merged(count: Int, skipped: Int)
    /// `moved` counts the pieces that matched a clip already in history, which moved to the top
    /// instead of being added again. Without it a list with a repeated line produces fewer rows
    /// than it has lines, with nothing on screen to say why.
    case split(count: Int, moved: Int)
    /// Text was read out of an image. The one action whose result the user could not see coming, so
    /// the line says how much arrived and that nothing left the Mac to get it.
    case recognizedText(lines: Int)
    /// The recognition ran and found nothing readable, which is the ordinary answer for a photo or a
    /// diagram. Not a failure, and worded so it does not read as one.
    case noTextRecognized
    case textRecognitionFailed
    /// The Homebrew upgrade command was put on the pasteboard from the update banner. It belongs
    /// here rather than in an alert because it *is* a clipboard action: the row is about to appear
    /// at the top of the history like any other copy.
    case copiedUpgradeCommand

    var icon: String {
        switch self {
        case .savedNew:
            return "checkmark.circle"
        case .alreadyInHistory:
            return "arrow.up.circle"
        case .merged:
            return "arrow.triangle.merge"
        case .split:
            return "arrow.triangle.branch"
        case .recognizedText:
            return "text.viewfinder"
        case .noTextRecognized:
            return "questionmark.circle"
        case .textRecognitionFailed:
            return "exclamationmark.triangle"
        case .copiedUpgradeCommand:
            return "terminal"
        }
    }

    var message: LocalizedStringKey {
        switch self {
        case .savedNew:
            return "Saved as a new item. The original is unchanged."
        case .alreadyInHistory:
            return "That text was already in your history, so it moved to the top."
        case .merged(let count, let skipped):
            // The order is repeated here, not only in the action's title: the row that just
            // appeared shows its first line alone, so top to bottom is the claim being made.
            guard skipped > 0 else {
                return "Merged \(count) items top to bottom. The originals are unchanged."
            }
            return "Merged \(count) items top to bottom. \(skipped) with no text were skipped."
        case .split(let count, let moved):
            // Where the pieces went is the claim being made: the first line is at the top, so the
            // list now reads in the source's own order and pasting them in turn works.
            guard moved > 0 else {
                return "Split into \(count) items, first line at the top. The original is unchanged."
            }
            return "Split into \(count) items, first line at the top. \(moved) were already in your history."
        case .recognizedText(let lines):
            guard lines > 1 else {
                return "Read 1 line of text on this Mac. The image is unchanged."
            }
            return "Read \(lines) lines of text on this Mac. The image is unchanged."
        case .noTextRecognized:
            return "No readable text in that image, so nothing was added."
        case .textRecognitionFailed:
            return "That image could not be read. Nothing was added."
        case .copiedUpgradeCommand:
            return "Copied. Paste it into Terminal to upgrade."
        }
    }
}

private struct ClipboardActionStatusBanner: View {
    let status: ClipboardActionStatus

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.icon)
                .font(.system(size: 10))
                .foregroundColor(.accentColor)
            Text(status.message)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }
}

/// Edits a copy of a text item. Takes over the whole popover: the preview pane is 259pt wide, and
/// the list, the search field and the filter tabs all do nothing useful while an edit is open.
private struct ClipboardTextEditorView: View {
    let source: ClipboardItem
    @Binding var text: String
    let focusToken: Int
    let caretOffset: Int?
    let isRestoredDraft: Bool
    let canSave: Bool
    let onCancel: () -> Void
    let onSave: () -> Void
    let onSaveAndPaste: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if isRestoredDraft {
                restoredNotice
            }
            editor
            footer
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Escape reaches the text view, not the popover's key handler: the handler sits in a
        // sibling branch of the view tree, so it only sees key equivalents. This is the path that
        // actually cancels an edit; the handler's Escape case covers the case where it does see it.
        .onExitCommand(perform: onCancel)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text("Editing a copy")
                .font(.caption)
                .fontWeight(.semibold)

            if source.isSensitive {
                HStack(spacing: 3) {
                    Image(systemName: "lock.fill")
                    Text("Stays hidden")
                }
                .font(.system(size: 10))
                .foregroundColor(.orange)
            }

            Spacer()

            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.caption)
                .help("Discard this edit (Esc)")

            Button("Save & Paste ⌘⏎", action: onSaveAndPaste)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.caption)
                .disabled(!canSave)
                .help("Save as a new item, then paste it into the app you came from")

            Button("Save ⌘S", action: onSave)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .font(.caption)
                .disabled(!canSave)
                .help(canSave ? "Save as a new item" : "Change the text to save it as a new item")
        }
    }

    private var restoredNotice: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.uturn.backward.circle")
                .foregroundColor(.orange)
            Text("Unsaved edit restored")
            Spacer()
        }
        .font(.system(size: 10))
        .foregroundColor(.secondary)
    }

    private var editor: some View {
        ClipboardTextView(
            text: $text,
            isEditable: true,
            fontSize: 12,
            focusToken: focusToken,
            caretOffset: caretOffset,
            onEscape: onCancel
        )
        .padding(2)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("\(text.count) chars")
            Text("•")
                .foregroundColor(.secondary.opacity(0.6))
            Text("Enter adds a line. Saving keeps the original and adds a new item.")
            Spacer()
        }
        .font(.system(size: 10))
        .foregroundColor(.secondary)
        .lineLimit(1)
    }
}

/// The colour itself, drawn at whatever size the row or the preview has room for.
///
/// The border is not decoration: a swatch of `#FFFFFF` in light mode, or of `#1E1E1E` in dark, is
/// otherwise the background with nothing to say where it starts and stops, and those are two of the
/// colours people copy most. It is a semantic colour for the same reason everything else here is,
/// so it stays visible in both appearances.
struct ClipboardColorSwatchView: View {
    let swatch: ClipboardColorSwatch
    let size: CGFloat

    private var corner: CGFloat { size <= 12 ? 2 : 3 }

    var body: some View {
        ZStack {
            if swatch.isTranslucent {
                checkerboard
            }
            swatch.color
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay(
            RoundedRectangle(cornerRadius: corner)
                .stroke(Color.secondary.opacity(0.5), lineWidth: 0.5)
        )
        .accessibilityLabel("Colour \(swatch.hexLabel)")
        .help("This clip is the colour \(swatch.hexLabel)")
    }

    /// Four squares, which at this size is all a checkerboard needs to be. Without it a colour at
    /// 20% alpha and the same colour at 100% are the same swatch on a light background, and the
    /// alpha is the part of `#RRGGBBAA` that a hex string is least readable about.
    private var checkerboard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color(NSColor.textBackgroundColor)
                Color.secondary.opacity(0.35)
            }
            HStack(spacing: 0) {
                Color.secondary.opacity(0.35)
                Color(NSColor.textBackgroundColor)
            }
        }
    }
}

/// The icon of the app a clip was copied out of, resolved from the stored bundle identifier.
///
/// Only drawn for an item that recorded one, so an empty source costs no pixels at all. An app that
/// is no longer installed keeps its place with a placeholder glyph rather than dropping out, for
/// the reason `ExcludedAppRow` keeps its entry: the row still knows where the clip came from.
struct ClipboardSourceAppIcon: View {
    let bundleIdentifier: String
    let size: CGFloat

    private var app: ClipboardSourceApp {
        ClipboardSourceAppCatalog.app(for: bundleIdentifier)
    }

    var body: some View {
        Group {
            if let icon = ClipboardSourceAppCatalog.icon(for: bundleIdentifier) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "questionmark.app.dashed")
                    .font(.system(size: size))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Copied from \(app.name)")
        .help(sourceHelp)
    }

    /// The polling limit is stated here rather than only in Settings, because this is where a user
    /// meets the guess. A wrong app on a row is the failure this whole marker introduces, and a
    /// tooltip that pretends otherwise would make it look like a bug in the app instead.
    private var sourceHelp: String {
        let name = app.name
        if app.isInstalled {
            return "Copied from \(name), as far as MacClipboard could tell: the app in front when the clipboard changed"
        }
        return "Copied from \(name), which is no longer installed"
    }
}

struct ClipboardItemRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    let isMultiSelected: Bool
    let isRevealed: Bool
    let onSelect: () -> Void
    let onCopy: () -> Void
    let onToggleFavorite: () -> Void
    let onToggleMultiSelect: () -> Void
    let onToggleReveal: () -> Void
    let timeAgoText: String
    /// Describes the whole multi-selection, not this row: right-clicking anywhere in the list is
    /// how the action is reached, and the title says which items it would take.
    let mergeActionTitle: String
    let canCopyMerged: Bool
    let onCopyMerged: () -> Void
    /// Describes the selected item, not this row, for the same reason `mergeActionTitle` describes
    /// the selection: a right click does not move the cursor, and the title says which item it
    /// would take.
    let splitActionTitle: String
    let canSplit: Bool
    let onSplit: () -> Void

    private var shouldMask: Bool {
        item.isSensitive && !isRevealed
    }

    private var displayText: String {
        if shouldMask {
            // Show note as hint for hidden items (first 40 chars)
            if let note = item.note, !note.isEmpty {
                let hint = String(note.prefix(40))
                return "••• \(hint)"
            }
            return "••••••••••••"
        }
        return item.previewText
    }

    /// Derived here rather than carried on the item: the parse is bounded by
    /// `ClipboardColorSwatch.maxLength`, and the list is a `LazyVStack`, so only the rows on screen
    /// ever run it.
    private var colorSwatch: ClipboardColorSwatch? {
        ClipboardColorSwatch.swatch(for: item)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Every row shows what it holds. The first ten used to show their position instead,
            // which was the label on the 0-9 shortcut; with that gone the digit said nothing, and it
            // cost the ten newest images the thumbnail every other image row gets.
            if item.type == .image, !shouldMask, item.isImageLoaded, let image = item.content as? NSImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                    )
            } else if shouldMask {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                    .frame(width: 20, height: 20)
            } else if let colorSwatch {
                // After the mask, never before it: the swatch is content, and a hidden clip gives
                // away nothing about what it holds until it is revealed.
                ClipboardColorSwatchView(swatch: colorSwatch, size: 14)
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 12))
                    .foregroundColor(iconColor)
                    .frame(width: 20, height: 20)
            }

            // Content preview
            VStack(alignment: .leading, spacing: 1) {
                Text(displayText)
                    .font(.system(.callout, design: .default))
                    .lineLimit(1)
                    .foregroundColor(shouldMask ? .secondary : .primary)

                HStack(spacing: 4) {
                    // First, and ahead of the time: scanning a long history for "the thing I copied
                    // out of Slack" is what this is for, and an icon answers that before any text
                    // in the row does. Shown whether or not the item is masked, like the formatting
                    // and read-from-an-image markers beside it, because where a clip came from is
                    // not its content and gives nothing about it away.
                    if let sourceBundleIdentifier = item.sourceBundleIdentifier {
                        ClipboardSourceAppIcon(bundleIdentifier: sourceBundleIdentifier, size: 10)
                    }
                    Text(timeAgoText)
                    if item.note != nil && !(item.note?.isEmpty ?? true) {
                        Image(systemName: "note.text")
                            .font(.system(size: 8))
                    }
                    // Shown whether or not the item is masked: formatting is a property of how the
                    // clip was copied, not of its content, so it gives nothing away.
                    if item.carriesFormatting {
                        Image(systemName: "textformat")
                            .font(.system(size: 8))
                            .accessibilityLabel("Keeps its formatting")
                    }
                    // Same rule, and the same reason it is in the row rather than only in the
                    // preview: a clip nobody copied should say so where it is first seen.
                    if item.isRecognizedText {
                        Image(systemName: "text.viewfinder")
                            .font(.system(size: 8))
                            .accessibilityLabel("Read from an image")
                    }
                    // Show Auto/PWD badges only when item is masked
                    if item.isAutoSensitive && shouldMask {
                        Text("Auto")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15))
                            .cornerRadius(2)
                    }
                    if item.isPasswordLike && shouldMask {
                        Text("PWD")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.purple)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.15))
                            .cornerRadius(2)
                    }
                }
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Star button (visible when favorited or selected)
            Button(action: onToggleFavorite) {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundColor(item.isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .opacity(item.isFavorite || isSelected ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: isSelected)
            .animation(.easeInOut(duration: 0.2), value: item.isFavorite)
            .accessibilityLabel(item.isFavorite ? "Remove from favorites" : "Add to favorites")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Group {
                if isMultiSelected {
                    Color.orange.opacity(0.3)
                } else if isSelected {
                    Color.accentColor.opacity(0.2)
                } else {
                    Color.clear
                }
            }
        )
        .overlay(
            // Show checkmark for multi-selected items
            Group {
                if isMultiSelected {
                    HStack {
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                            .padding(.trailing, 4)
                    }
                }
            }
        )
        .cornerRadius(3)
        .contentShape(Rectangle())
        .onTapGesture {
            // Cmd+Click for multi-select, regular click for single select
            if NSEvent.modifierFlags.contains(.command) {
                onToggleMultiSelect()
            } else {
                onSelect()
            }
        }
        .onTapGesture(count: 2) {
            // Double click: select and paste
            onSelect()
            onCopy()
        }
        .contextMenu {
            // Deliberately not a right-click menu of everything a row can do. The list is driven
            // by keys and the preview pane already carries the per-item actions; these two are here
            // because they have no other home, and because both belong to what is selected rather
            // than to the row that was clicked. Their titles say so, and only one of them is ever
            // available: a multi-selection is Copy Merged's, anything else is Split's.
            //
            // The shortcuts are here to be *read*. A key equivalent on a contextual menu item is
            // only live while that menu is open, so what makes ⌘M and ⌘⇧M work over the list is
            // `handleKeyEvent`, as it is for every other key in the popover: do not delete that
            // case in the belief that these two lines have taken it over. They earn their place
            // because a menu entry is where a user meets the action, and an action nobody knows has
            // a shortcut is an action nobody stops using the menu for.
            Button(mergeActionTitle, action: onCopyMerged)
                .keyboardShortcut("m", modifiers: .command)
                .disabled(!canCopyMerged)
            Button(splitActionTitle, action: onSplit)
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!canSplit)
        }
    }
    
    private var iconName: String {
        switch item.type {
        case .text:
            return "doc.text"
        case .image:
            return "photo"
        case .file:
            return "doc"
        }
    }
    
    private var iconColor: Color {
        switch item.type {
        case .text:
            return .blue
        case .image:
            return .green
        case .file:
            return .orange
        }
    }
}

// MARK: - Key Event Handler

/// Plain monospaced text, read-only for the preview and editable for the copy editor.
///
/// AppKit rather than `Text` and `TextEditor` because a click in the preview has to become a caret
/// at the same character in the editor, and neither SwiftUI view can report or set a caret.
struct ClipboardTextView: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let fontSize: CGFloat
    /// Bump to take first responder. Applied together with `caretOffset`, so opening the editor and
    /// returning to it after the discard alert both put the caret where they should.
    var focusToken: Int = 0
    /// UTF-16 offset for the caret, or nil to leave the selection alone.
    var caretOffset: Int?
    /// Read-only mode: a click that selected nothing, with the character index it landed on.
    var onPlainClick: ((Int) -> Void)?
    var onEscape: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CallbackTextView()
        textView.delegate = context.coordinator
        textView.string = text
        // Wired here as well as in `updateNSView`: a click can arrive before SwiftUI's first update.
        textView.onPlainClick = onPlainClick
        textView.onEscape = onEscape
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = isEditable
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 2, height: 3)

        // A clip is data. Curly quotes, an em dash, or a corrected spelling would change what the
        // user pastes, so every automatic substitution stays off.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CallbackTextView else { return }

        textView.onPlainClick = onPlainClick
        textView.onEscape = onEscape
        textView.isEditable = isEditable

        if textView.string != text {
            textView.string = text
        }

        guard context.coordinator.appliedFocusToken != focusToken else { return }
        context.coordinator.appliedFocusToken = focusToken
        guard isEditable else { return }

        let offset = caretOffset
        func takeFocus() {
            textView.window?.makeFirstResponder(textView)
            guard let offset else { return }
            let clamped = min(max(0, offset), (textView.string as NSString).length)
            textView.setSelectedRange(NSRange(location: clamped, length: 0))
            textView.scrollRangeToVisible(NSRange(location: clamped, length: 0))
        }

        DispatchQueue.main.async { takeFocus() }
        // A popover that has just opened hands first responder around for a moment (the key handler
        // claims it in `viewDidMoveToWindow`), so a restored draft needs a second go. Skipped once
        // the editor holds it, which also means a caret the user has since moved is left alone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard textView.window?.firstResponder !== textView else { return }
            takeFocus()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        var appliedFocusToken: Int?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

/// Whether a finished click in the read-only preview should open the editor.
struct ClipboardPreviewClick {
    /// An empty selection is what separates a plain click from a drag, a double click (selects a
    /// word) and a triple click (selects a paragraph); all of those are someone selecting text to
    /// copy, so they stay in the preview. A modified click is a selection gesture too.
    ///
    /// The click count is deliberately not part of this: a synthetic click can report 0.
    static func opensEditor(selectionLength: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard selectionLength == 0 else { return false }
        return modifiers.isDisjoint(with: [.command, .shift, .option, .control])
    }
}

final class CallbackTextView: NSTextView {
    var onPlainClick: ((Int) -> Void)?
    var onEscape: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // NSTextView tracks the drag inside super, so this returns once the click is finished and
        // `selectedRange` tells us whether it was a click or a selection.
        super.mouseDown(with: event)

        guard let onPlainClick,
              ClipboardPreviewClick.opensEditor(
                selectionLength: selectedRange().length,
                modifiers: event.modifierFlags
              ) else { return }

        let index = characterIndexForInsertion(at: point)
        DispatchQueue.main.async { onPlainClick(index) }
    }

    override func keyDown(with event: NSEvent) {
        // Escape is bound to `complete:` in a text view, not to `cancelOperation:`, so it has to be
        // caught here to mean "leave the editor".
        if event.keyCode == 53, let onEscape {
            onEscape()
            return
        }
        super.keyDown(with: event)
    }
}

/// The search field, as an `NSTextField` of the app's own rather than SwiftUI's `TextField`.
///
/// Two things are needed that `TextField` plus `@FocusState` cannot give, and both are about the gap
/// between asking for focus and having it. `@FocusState` flips the instant it is assigned while
/// AppKit moves first responder a runloop pass later, and `KeyEventView.performKeyEquivalent` sees
/// every key in the window throughout that gap:
///
/// - **It says when it actually holds the keyboard** (`onKeyboardChange`), so `handleKeyEvent` knows
///   whether a key is still its to claim. Reading the *intent* instead is what dropped a letter out
///   of every fast-typed search.
/// - **It takes focus with the caret at the end**, where `NSTextField` would select its whole
///   contents. Selecting was why the old code had to write the first character 20 ms *after*
///   focusing, and that delayed write then overwrote whatever the field had received by then.
///
/// Everything else about the keyboard stays where it was: Enter, Escape, Tab and the arrows all
/// reach `handleKeyEvent` through `performKeyEquivalent` whether this field has focus or not, so it
/// deliberately implements none of them.
struct ClipboardSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    /// What the app wants. The field takes first responder to match it, and gives it up when it
    /// goes false and the field is still the one holding it.
    let isFocused: Bool
    let onKeyboardChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> FocusReportingTextField {
        let field = FocusReportingTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .preferredFont(forTextStyle: .body)
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: FocusReportingTextField, context: Context) {
        context.coordinator.text = $text
        field.placeholderString = placeholder
        field.onKeyboardChange = onKeyboardChange

        if field.stringValue != text {
            field.stringValue = text
            // Only a write from outside the field reaches here: the key handler appending to a
            // search being typed, or a reset. Both belong at the end. What the user types into the
            // field arrives through the delegate, where `stringValue` already matches.
            moveCaretToEnd(field)
        }

        syncFirstResponder(field)
    }

    private func syncFirstResponder(_ field: FocusReportingTextField) {
        // Recorded on the field, not just captured below: this struct is rebuilt on every update, so
        // a block scheduled by an earlier one would otherwise act on a wish that has since changed
        // and take the keyboard away from a search that has started again in the meantime.
        field.desiredFocus = isFocused

        guard (field.currentEditor() != nil) != isFocused else { return }

        // Asynchronously, because a responder change during a SwiftUI update is a change to the view
        // tree in the middle of building it.
        DispatchQueue.main.async {
            guard let window = field.window else { return }

            if field.desiredFocus {
                guard field.currentEditor() == nil else { return }
                window.makeFirstResponder(field)
                moveCaretToEnd(field)
            } else if field.currentEditor() != nil {
                // Only while this field is still the one holding the keyboard. The note field may
                // have taken it in the meantime, and resigning then would pull it back out from
                // under the note. Handing it to nobody is enough: the list's keys arrive through
                // `performKeyEquivalent`, which does not care who the first responder is.
                window.makeFirstResponder(nil)
            }
        }
    }

    private func moveCaretToEnd(_ field: FocusReportingTextField) {
        guard let editor = field.currentEditor() else { return }
        editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// An `NSTextField` that reports holding and losing the keyboard.
///
/// `becomeFirstResponder` is the earliest point at which the field is the one being typed into, and
/// `textDidEndEditing` the point at which it stops being: between them the field editor is installed
/// and every key goes there. The reports are dispatched rather than sent inline because both are
/// called from inside AppKit's responder machinery, and their readers are SwiftUI state.
class FocusReportingTextField: NSTextField {
    var onKeyboardChange: ((Bool) -> Void)?
    /// Whether the view above wants this field focused, as of its last update.
    var desiredFocus = false

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { scheduleKeyboardReport() }
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        scheduleKeyboardReport()
    }

    /// Reports what is true when the report runs rather than what was true when it was scheduled.
    /// One responder change can overtake another, and a stale report would put the keyboard back in
    /// a field the user has already left.
    private func scheduleKeyboardReport() {
        let report = onKeyboardChange
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            report?(self.currentEditor() != nil)
        }
    }
}

struct KeyEventHandler: NSViewRepresentable {
    /// Bump to make the handler take first responder back. Needed when a text editor that held it
    /// has been removed from the hierarchy, which leaves nothing listening for arrows or Enter.
    let focusToken: Int
    let onKeyEvent: (NSEvent) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = KeyEventView()
        view.onKeyEvent = onKeyEvent
        view.focusToken = focusToken
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let keyView = nsView as? KeyEventView else { return }
        keyView.onKeyEvent = onKeyEvent

        guard keyView.focusToken != focusToken else { return }
        keyView.focusToken = focusToken
        DispatchQueue.main.async {
            keyView.window?.makeFirstResponder(keyView)
        }
    }
}

class KeyEventView: NSView {
    var onKeyEvent: ((NSEvent) -> Bool)?
    var focusToken = 0

    override var acceptsFirstResponder: Bool { 
        return true 
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        
        // Ensure this view can receive key events
        DispatchQueue.main.async {
            self.window?.makeFirstResponder(self)
        }
    }
    
    override func becomeFirstResponder() -> Bool {
        return super.becomeFirstResponder()
    }
    
    override func keyDown(with event: NSEvent) {
        if let handler = onKeyEvent, handler(event) {
            return
        }
        super.keyDown(with: event)
    }
    
    // Handle events that might not reach keyDown
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
    }
    
    // Ensure we can handle key events
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let handler = onKeyEvent, handler(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct ImageModalView: View {
    let image: NSImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var lastScale: CGFloat = 1.0
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with controls
            HStack {
                Text("Image Preview - Zoom: \(String(format: "%.1f", scale))x")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Button("Zoom In") {
                    withAnimation(.spring()) {
                        scale = min(scale * 1.5, 10.0)
                    }
                }
                .buttonStyle(.bordered)
                
                Button("Zoom Out") {
                    withAnimation(.spring()) {
                        scale = max(scale / 1.5, 0.1)
                    }
                }
                .buttonStyle(.bordered)
                
                Button("Reset") {
                    withAnimation(.spring()) {
                        scale = 1.0
                        offset = .zero
                        lastOffset = .zero
                        lastScale = 1.0
                    }
                }
                .buttonStyle(.bordered)
                
                Button("Fit") {
                    withAnimation(.spring()) {
                        let maxWidth: CGFloat = 500
                        let maxHeight: CGFloat = 350
                        let imageAspect = image.size.width / image.size.height
                        let viewAspect = maxWidth / maxHeight
                        
                        if imageAspect > viewAspect {
                            scale = maxWidth / image.size.width
                        } else {
                            scale = maxHeight / image.size.height
                        }
                        offset = .zero
                        lastOffset = .zero
                        lastScale = scale
                    }
                }
                .buttonStyle(.bordered)
                
                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            // Image view with improved zoom
            GeometryReader { geometry in
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(scale)
                        .offset(offset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .contentShape(Rectangle()) // Constrain gesture area to frame bounds
                .background(Color.gray.opacity(0.1))
                .gesture(
                        SimultaneousGesture(
                            // Magnification gesture
                            MagnificationGesture()
                                .onChanged { value in
                                    let newScale = lastScale * value
                                    scale = max(0.1, min(newScale, 10.0))
                                }
                                .onEnded { value in
                                    lastScale = scale
                                },
                            
                            // Drag gesture
                            DragGesture()
                                .onChanged { value in
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                                .onEnded { _ in
                                    lastOffset = offset
                                }
                        )
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring()) {
                            if scale > 1.0 {
                                scale = 1.0
                                offset = .zero
                                lastOffset = .zero
                                lastScale = 1.0
                            } else {
                                scale = 2.0
                                lastScale = 2.0
                            }
                        }
                    }
                    .onTapGesture(count: 1) {
                        Logging.debug("Image tapped - current scale: \(scale)")
                    }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

private struct ProjectTitleLink: View {
    @State private var hovering = false
    var body: some View {
        Button(action: {
            if let url = URL(string: "https://github.com/rakodev/mac-clipboard") {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 4) {
                Text("MacClipboard")
                    .font(.headline)
                    .foregroundColor(.primary)
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(hovering ? Color.accentColor.opacity(0.1) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open project page on GitHub")
    }
}

extension Character {
    var isPrintableASCII: Bool {
        guard let asciiValue = self.asciiValue else { return false }
        return asciiValue >= 32 && asciiValue <= 126
    }
}

private struct ClipboardEmptyStateView: View {
    let selectedFilter: FilterTab
    /// "Copy something to get started" is wrong advice while capture is off: copying something
    /// would change nothing. The banner above says the same thing, but this is the part of the
    /// popover a user with no history is actually reading.
    let isCapturePaused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: iconName)
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text(titleKey)
                .font(.title2)
                .foregroundColor(.secondary)

            Text(subtitleKey)
                .font(.body)
                .foregroundColor(Color.secondary)

            if let shortcutKey {
                Text(shortcutKey)
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var iconName: String {
        if isCapturePaused, selectedFilter == .all {
            return "pause.circle"
        }

        switch selectedFilter {
        case .all:
            return "doc.on.clipboard"
        case .favorites:
            return "star"
        case .images:
            return "photo"
        case .hidden:
            return "eye.slash"
        }
    }

    private var titleKey: LocalizedStringKey {
        if isCapturePaused, selectedFilter == .all {
            return "Capture is paused"
        }

        switch selectedFilter {
        case .all:
            return "No clipboard history"
        case .favorites:
            return "No favorites"
        case .images:
            return "No images"
        case .hidden:
            return "No hidden items"
        }
    }

    private var subtitleKey: LocalizedStringKey {
        if isCapturePaused, selectedFilter == .all {
            return "Resume capture to start saving copies again"
        }

        switch selectedFilter {
        case .all:
            return "Copy something to get started"
        case .favorites:
            return "Star items to keep them permanently — favorites are never auto-deleted"
        case .images:
            return "Copy an image to see it here"
        case .hidden:
            return "Mark items as sensitive to hide them"
        }
    }

    private var shortcutKey: LocalizedStringKey? {
        switch selectedFilter {
        case .all:
            return nil
        case .favorites:
            return "⌘D to toggle favorite"
        case .images:
            return "⌘Z to zoom images"
        case .hidden:
            return "⌘H to toggle sensitive"
        }
    }
}

private struct ShortcutReferenceView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ShortcutReferenceSection(title: "Global", shortcuts: [
                    (UserPreferencesManager.shared.globalHotkey.compactDisplayString, "Open clipboard"),
                ])

                ShortcutReferenceSection(title: "Navigation", shortcuts: [
                    ("↑ / ↓", "Navigate items"),
                    ("⌥↑", "Scroll to top"),
                    ("← / →", "Switch filter tabs"),
                    ("Tab", "Focus search"),
                    ("Any letter or digit", "Start searching"),
                ])

                ShortcutReferenceSection(title: "Actions", shortcuts: [
                    ("Enter", "Paste selected item"),
                    ("⇧⏎", "Paste without formatting"),
                    ("⌘E", "Edit a copy of a text item"),
                    ("⌘D", "Toggle favorite"),
                    ("⌘H", "Toggle sensitive"),
                    ("⌘V", "Reveal sensitive item"),
                    ("⌘N", "Focus note field"),
                    ("⌘R", "Read the text in an image, on this Mac"),
                    ("⌘Z", "Full-size image preview"),
                    ("⌘-click", "Add an item to the selection"),
                    ("⌘↑↓ / ⇧↑↓", "Extend the selection up or down"),
                    ("⌘M", "Copy the selection merged, top to bottom"),
                    ("⌘⇧M", "Split the selected item into one item per line"),
                    ("⌘⌫", "Delete item(s)"),
                    ("⌘F", "Toggle favorites filter"),
                    ("⌘/", "Show shortcuts"),
                    ("Esc", "Close / unfocus"),
                ])

                ShortcutReferenceSection(title: "While editing a copy", shortcuts: [
                    ("⌘S", "Save as a new item"),
                    ("⌘⏎", "Save as a new item and paste it"),
                    ("Esc", "Cancel the edit"),
                ])
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

private struct ShortcutReferenceSection: View {
    let title: LocalizedStringKey
    let shortcuts: [(key: String, action: LocalizedStringKey)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            ForEach(shortcuts, id: \.key) { key, action in
                HStack {
                    Text(key)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.accentColor)
                        .frame(width: 100, alignment: .trailing)

                    Text(action)
                        .font(.caption)
                        .foregroundColor(.primary)

                    Spacer()
                }
            }
        }
    }
}

#Preview {
    ContentView(
        clipboardMonitor: ClipboardMonitor(),
        menuBarController: MenuBarController(clipboardMonitor: ClipboardMonitor())
    )
}