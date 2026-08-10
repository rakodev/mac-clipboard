import Foundation
import AppKit

// MARK: - Sensitive Content Detection

struct SensitiveContentDetector {
    // Pasteboard types that indicate sensitive content (from password managers, etc.)
    private static let sensitivePasteboardTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType"
    ]

    // Maximum text size for pattern matching (100KB)
    private static let maxPatternMatchSize = 100 * 1024

    // Regex patterns for detecting sensitive content
    private static let sensitivePatterns: [(pattern: String, description: String)] = [
        // OpenAI/Stripe API keys
        ("sk-[a-zA-Z0-9]{20,}", "API key"),
        // AWS Access Key ID
        ("AKIA[0-9A-Z]{16}", "AWS Access Key"),
        // JWT tokens
        ("eyJ[A-Za-z0-9-_]+\\.[A-Za-z0-9-_]+\\.[A-Za-z0-9-_]*", "JWT token"),
        // Private keys
        ("-----BEGIN[A-Z ]*PRIVATE KEY-----", "Private key"),
        // GitHub tokens
        ("ghp_[A-Za-z0-9]{36,}", "GitHub PAT"),
        ("gho_[A-Za-z0-9]{36,}", "GitHub OAuth token"),
        ("ghs_[A-Za-z0-9]{36,}", "GitHub server token"),
        ("github_pat_[A-Za-z0-9_]{22,}", "GitHub fine-grained PAT"),
        // Generic secrets with assignment
        ("(?i)(password|passwd|secret|api_?key|auth_?token|access_?token)\\s*[=:]\\s*['\"]?[A-Za-z0-9+/=_-]{8,}['\"]?", "Generic secret"),
        // Database connection strings with credentials
        ("(?i)(mysql|postgres|postgresql|mongodb|redis)://[^:]+:[^@]+@", "Database connection string"),
        // Slack tokens
        ("xox[baprs]-[0-9A-Za-z-]+", "Slack token"),
        // Google API key
        ("AIza[0-9A-Za-z-_]{35}", "Google API key"),
        // Heroku API key
        ("[hH][eE][rR][oO][kK][uU].{0,30}[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}", "Heroku API key")
    ]

    /// Check if pasteboard contains sensitive type indicators
    static func hasSensitivePasteboardType(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        let typeStrings = Set(types.map { $0.rawValue })
        return !typeStrings.isDisjoint(with: sensitivePasteboardTypes)
    }

    /// Check if text content matches any sensitive patterns
    static func matchesSensitivePattern(_ text: String) -> Bool {
        // Skip pattern matching for very large text
        guard text.utf8.count <= maxPatternMatchSize else { return false }

        for (pattern, _) in sensitivePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil {
                Logging.debug("🔐 Detected sensitive pattern in clipboard content")
                return true
            }
        }
        return false
    }

    /// Comprehensive check for sensitive content
    static func isSensitive(pasteboard: NSPasteboard, text: String?) -> Bool {
        // Check pasteboard types first (instant)
        if hasSensitivePasteboardType(pasteboard) {
            Logging.debug("🔐 Detected sensitive pasteboard type")
            return true
        }

        // Check text patterns if text is available
        if let text = text, matchesSensitivePattern(text) {
            return true
        }

        return false
    }

    // Patterns that should NOT be considered passwords (common false positives)
    private static let nonPasswordPatterns: [(pattern: String, description: String)] = [
        // URLs
        ("^(https?|ftp|file|ssh|git)://", "URL"),
        // Email addresses (loose pattern - anything with @ and a dot after)
        ("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z0-9]{2,}", "Email"),
        // File paths (Unix and Windows)
        ("^[~/]|^[A-Za-z]:\\\\", "File path"),
        // UUIDs (standard format)
        ("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", "UUID"),
        // IPv4 addresses (with optional port)
        ("^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}(:\\d+)?$", "IPv4"),
        // IPv6 addresses
        ("^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$", "IPv6"),
        // MAC addresses
        ("^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$", "MAC address"),
        // ISO 8601 dates and timestamps
        ("^\\d{4}-\\d{2}-\\d{2}(T\\d{2}:\\d{2}:\\d{2})?", "ISO date"),
        // Semantic versions
        ("^v?\\d+\\.\\d+\\.\\d+(-[A-Za-z0-9.]+)?(\\+[A-Za-z0-9.]+)?$", "Version"),
        // Domain names (with subdomains)
        ("^([A-Za-z0-9-]+\\.)+[A-Za-z]{2,}$", "Domain"),
        // Phone numbers (various formats)
        ("^\\+?[0-9]{1,4}[-. ]?\\(?[0-9]{1,4}\\)?[-. ]?[0-9]{1,4}[-. ]?[0-9]{1,9}$", "Phone number"),
    ]

    /// Check if text matches any non-password pattern (URLs, emails, etc.)
    private static func matchesNonPasswordPattern(_ text: String) -> Bool {
        for (pattern, _) in nonPasswordPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil {
                return true
            }
        }
        return false
    }

    /// Check if text looks like a password (high entropy string)
    /// Criteria: 8-64 chars, no spaces, contains all of: uppercase, lowercase, digit, special char
    static func looksLikePassword(_ text: String) -> Bool {
        // Length check
        guard text.count >= 8 && text.count <= 64 else { return false }

        // No spaces allowed
        guard !text.contains(" ") else { return false }

        // No newlines (multi-line text is not a password)
        guard !text.contains(where: { $0.isNewline }) else { return false }

        // Exclude common non-password patterns (URLs, emails, file paths, etc.)
        if matchesNonPasswordPattern(text) {
            return false
        }

        // Count character types present
        var hasUppercase = false
        var hasLowercase = false
        var hasDigit = false
        var hasSpecial = false

        for char in text {
            if char.isUppercase { hasUppercase = true }
            else if char.isLowercase { hasLowercase = true }
            else if char.isNumber { hasDigit = true }
            else if !char.isLetter && !char.isNumber { hasSpecial = true }
        }

        let typeCount = [hasUppercase, hasLowercase, hasDigit, hasSpecial].filter { $0 }.count

        if typeCount >= 4 {
            Logging.debug("🔑 Detected password-like string")
            return true
        }

        return false
    }
}

struct ClipboardSensitivityFlags: Equatable {
    let isSensitive: Bool
    let isAutoSensitive: Bool
    let isPasswordLike: Bool
}

struct ClipboardSensitivityPolicy {
    static func flags(for text: String?, hasSensitivePasteboardType: Bool, autoDetectSensitiveData: Bool, autoHidePasswordLikeStrings: Bool) -> ClipboardSensitivityFlags {
        let isAutoSensitive = hasSensitivePasteboardType || (text.map { SensitiveContentDetector.matchesSensitivePattern($0) } ?? false)
        let isPasswordLike = text.map { SensitiveContentDetector.looksLikePassword($0) } ?? false
        let isSensitive = (isAutoSensitive && autoDetectSensitiveData) ||
                          (isPasswordLike && autoHidePasswordLikeStrings)

        return ClipboardSensitivityFlags(
            isSensitive: isSensitive,
            isAutoSensitive: isAutoSensitive,
            isPasswordLike: isPasswordLike
        )
    }
}

/// Whether a pasteboard change is recorded at all.
///
/// Deliberately separate from `ClipboardSensitivityPolicy`, which decides how an item that *is*
/// recorded gets displayed. A skip here means the clip never reaches memory or disk, so there is
/// nothing to reveal with Cmd+V and nothing to delete later; that is the whole point of it. Masking
/// and skipping are independent: a user can mask confidential clips, drop them, both, or neither.
struct ClipboardCapturePolicy {
    enum Decision: Equatable {
        case capture
        /// The source app marked the clip confidential (`org.nspasteboard.ConcealedType` or
        /// `org.nspasteboard.TransientType`) and the user asked for those to be dropped.
        case skipConcealed
        case skipExcludedApp(bundleIdentifier: String)
    }

    static func decision(
        hasSensitivePasteboardType: Bool,
        skipConcealedClips: Bool,
        sourceBundleIdentifier: String?,
        excludedBundleIdentifiers: Set<String>
    ) -> Decision {
        // The source app's own marker is checked first: it is a statement of intent by the app that
        // owns the secret, not a guess about which app the clip came from.
        if skipConcealedClips && hasSensitivePasteboardType {
            return .skipConcealed
        }

        if let sourceBundleIdentifier, excludedBundleIdentifiers.contains(sourceBundleIdentifier) {
            return .skipExcludedApp(bundleIdentifier: sourceBundleIdentifier)
        }

        return .capture
    }
}

/// Capture switched off by the user, until they switch it back on.
///
/// A third thing that stops a clip being recorded, and unlike `ClipboardCapturePolicy` it is not a
/// judgement about the clip: nothing is read from the pasteboard at all while capture is paused,
/// so there is nothing to decide about. The one rule with teeth is on the way back.
enum ClipboardCapturePause {
    /// The change count capture adopts the moment it resumes.
    ///
    /// Skipping this is the whole trap: `changeCount` still holds whatever was last captured, so
    /// the first tick after resuming would see a different count, read the pasteboard, and record
    /// the very clip the user paused in order not to record. Adopting the current count means
    /// resuming starts from what is on the pasteboard now, and only the *next* copy is captured.
    static func changeCountOnResume(pasteboardChangeCount: Int) -> Int {
        pasteboardChangeCount
    }

    /// Whether the pasteboard holds a change capture has not seen yet.
    static func hasUnseenClip(pasteboardChangeCount: Int, lastSeenChangeCount: Int) -> Bool {
        pasteboardChangeCount != lastSeenChangeCount
    }
}

/// The formatting a text clip carries beside its plain text.
///
/// Two extra flavours, RTF and HTML, and only for text items. Both are needed because apps split
/// cleanly down the middle: Word, Notes, Pages, Mail and TextEdit write RTF, while Chrome, Slack,
/// VS Code and everything else built on a web view write HTML and no RTF at all. Measured on a
/// Chrome copy: `public.html` at 12,993 bytes, plain text at 674, no `public.rtf`. Storing only one
/// of the two leaves half of what a user copies arriving plain.
///
/// The plain text stays the item's content, which is what `contentEquals`, search, the preview and
/// the editor all work over; the other flavours ride along and are written back on paste unless the
/// user asks for plain text.
///
/// Nothing here decides *whether* a clip is captured. A clip whose formatting is refused is still
/// recorded as text, so refusing formatting never loses the clip.
enum ClipboardRichText {
    /// The largest payload stored for one flavour.
    ///
    /// The same bound the plain text gets, and for the same reason: a clip is held in memory for
    /// the length of the session. It applies per flavour, so oversized HTML does not cost a clip
    /// the RTF that came with it. Unlike an image, neither is stored as an external binary, so they
    /// cannot leave the orphans that priority task 3 is about, and they are not reachable by the
    /// image eviction that storage pressure runs.
    static let maxBytes = 1 * 1024 * 1024

    /// The RTF worth storing for a clip, or nil.
    ///
    /// The shape check is what keeps the marker in the row honest: the row says an item keeps its
    /// formatting, and it may only say so about bytes a reader can actually parse. A pasteboard can
    /// carry anything under any type, and storing bytes nothing can read would put a promise on
    /// screen that pasting cannot keep.
    static func storableRTF(_ data: Data?) -> Data? {
        storable(data, named: "rich text", shapedRight: isRTF)
    }

    /// The HTML worth storing for a clip, or nil. The same rules as `storableRTF`.
    static func storableHTML(_ data: Data?) -> Data? {
        storable(data, named: "HTML", shapedRight: looksLikeHTML)
    }

    private static func storable(_ data: Data?, named name: String, shapedRight: (Data) -> Bool) -> Data? {
        guard let data, !data.isEmpty else { return nil }
        guard data.count <= maxBytes else {
            Logging.debug("⚠️ Dropped \(name) (\(data.count / 1024)KB) - exceeds \(maxBytes / 1024)KB limit; the clip is kept without it")
            return nil
        }
        guard shapedRight(data) else { return nil }
        return data
    }

    /// Whether `data` opens with the RTF signature. Cheap enough to run on every capture, unlike
    /// parsing the document.
    static func isRTF(_ data: Data) -> Bool {
        let signature = Array("{\\rtf".utf8)
        guard data.count >= signature.count else { return false }
        return data.prefix(signature.count).elementsEqual(signature)
    }

    /// Whether `data` opens a tag somewhere near its start.
    ///
    /// HTML has no signature the way RTF does: what a browser writes is a fragment, and Chrome's
    /// begins `<meta charset='utf-8'>` while another app's may begin `<!DOCTYPE`, `<html>` or a bare
    /// `<span>`. So this looks for the one thing all of them have, a `<` followed by the start of a
    /// tag name, and it scans bytes rather than decoding a string: the payload is up to 1 MB and
    /// this runs on every capture. A zero byte after the `<` is tolerated so UTF-16 is recognised,
    /// and prose containing `a < b` is not, because a space cannot start a tag.
    static func looksLikeHTML(_ data: Data) -> Bool {
        let head = Array(data.prefix(4096))
        var index = 0
        while index < head.count {
            guard head[index] == UInt8(ascii: "<") else {
                index += 1
                continue
            }
            var next = index + 1
            if next < head.count && head[next] == 0 { next += 1 }
            guard next < head.count else { return false }
            let byte = head[next]
            let isLetter = (byte | 0x20) >= UInt8(ascii: "a") && (byte | 0x20) <= UInt8(ascii: "z")
            if isLetter || byte == UInt8(ascii: "!") || byte == UInt8(ascii: "/") { return true }
            index = next
        }
        return false
    }

    /// What a paste of a text clip puts on the pasteboard, richest flavour first.
    ///
    /// Every flavour the clip carries is written, rather than one being chosen here. The choice is
    /// not the sender's to make: `NSPasteboard.availableType(from:)` answers with the first type in
    /// the *receiving* app's own order of preference, so a rich text editor takes the RTF and a web
    /// view takes the HTML from the same pasteboard. Writing one flavour would be deciding for both
    /// of them. The ordering here is what an app writing both would use, and is otherwise cosmetic.
    ///
    /// Split out from `ClipboardMonitor.copyToClipboard` so a paste can be tested without a
    /// pasteboard, which is shared machine state no test may write to.
    static func flavours(text: String, rtfData: Data?, htmlData: Data?, asPlainText: Bool) -> [ClipboardTextFlavour] {
        guard !asPlainText else { return [.plainText(text)] }

        var flavours: [ClipboardTextFlavour] = []
        if let rtfData, isRTF(rtfData) { flavours.append(.rtf(rtfData)) }
        if let htmlData, looksLikeHTML(htmlData) { flavours.append(.html(htmlData)) }
        flavours.append(.plainText(text))
        return flavours
    }
}

/// One representation of a text clip on the pasteboard.
enum ClipboardTextFlavour: Equatable {
    case rtf(Data)
    case html(Data)
    case plainText(String)
}

struct ClipboardHistoryInsertionResult {
    let history: [ClipboardItem]
    let removedItemIDs: Set<UUID>
    let shouldPersistInsertedItem: Bool
}

struct ClipboardHistoryMerger {
    static func inserting(_ item: ClipboardItem, into history: [ClipboardItem]) -> ClipboardHistoryInsertionResult {
        var itemToInsert = item
        let isLargeContent = item.type == .image ||
            (item.type == .text && ((item.content as? String)?.count ?? 0) >= 10_000)
        let itemsToCheck = isLargeContent ? Array(history.prefix(10)) : history

        var updatedHistory = history
        var removedItemIDs: Set<UUID> = []

        if let matchIndex = itemsToCheck.firstIndex(where: { $0.contentEquals(item) }),
           let actualIndex = history.firstIndex(where: { $0.id == itemsToCheck[matchIndex].id }) {
            // Already at the top, so there is nothing to move and nothing to write: re-copying the
            // clip that is already the most recent one must not add a second row.
            //
            // Formatting is the exception, and it is the only part of a text clip that can differ
            // while `contentEquals` still calls the two the same clip. Copying a sentence out of
            // Word and then the same sentence out of Terminal would otherwise leave the item
            // pasting as rich text, which is not what the user last copied. Falling through
            // replaces the row instead, which is what a match anywhere else in the history does.
            // Both flavours are compared: the same words copied from Chrome and then from Word are
            // the same clip with different formatting, and either one changing has to get through.
            //
            // The source app is compared for exactly the same reason. Copying the same sentence out
            // of Slack after copying it out of Mail is the user's most recent copy having come from
            // Slack, and a row that kept saying Mail would be recording something that did not
            // happen. `copyToClipboard` adopts the pasteboard's change count, so MacClipboard's own
            // writes never come back through here and cannot make an item claim it came from us.
            if actualIndex == 0
                && history[0].rtfData == item.rtfData
                && history[0].htmlData == item.htmlData
                && history[0].sourceBundleIdentifier == item.sourceBundleIdentifier {
                return ClipboardHistoryInsertionResult(history: history, removedItemIDs: [], shouldPersistInsertedItem: false)
            }

            let existingItem = history[actualIndex]
            itemToInsert.isFavorite = existingItem.isFavorite
            itemToInsert.isSensitive = existingItem.isSensitive
            itemToInsert.isAutoSensitive = existingItem.isAutoSensitive || itemToInsert.isAutoSensitive
            itemToInsert.isPasswordLike = existingItem.isPasswordLike || itemToInsert.isPasswordLike
            itemToInsert.isManuallyUnsensitive = existingItem.isManuallyUnsensitive
            itemToInsert.note = existingItem.note
            itemToInsert.associatedText = itemToInsert.associatedText ?? existingItem.associatedText
            // `rtfData`, `htmlData` and `sourceBundleIdentifier` are deliberately *not* inherited,
            // unlike everything above them. The others are decisions the user made about this clip
            // and a re-copy must not undo them; formatting and the source app are properties of the
            // copy itself. Falling back to the old item's flavours would paste styling the user's
            // most recent copy did not have, and would keep the row's formatting marker up after
            // they deliberately re-copied the same text plain; falling back to its source would say
            // the clip came from an app the user has not copied out of since.

            removedItemIDs.insert(existingItem.id)
            updatedHistory.remove(at: actualIndex)
        }

        updatedHistory.insert(itemToInsert, at: 0)
        return ClipboardHistoryInsertionResult(history: updatedHistory, removedItemIDs: removedItemIDs, shouldPersistInsertedItem: true)
    }
}

/// Deriving a new text item from an edited copy of an existing one.
///
/// The source row is never touched, so history stays a log of what was actually on the pasteboard
/// plus the copies the user deliberately made.
struct ClipboardTextEdit {
    /// What saving an edit should do, decided before any history is touched so it can be tested
    /// on its own and so the Save buttons can be disabled for the cases that do nothing.
    enum Intent: Equatable {
        case empty
        case unchanged
        case save
    }

    static func intent(newText: String, sourceText: String) -> Intent {
        if newText.isEmpty { return .empty }
        if newText == sourceText { return .unchanged }
        return .save
    }

    /// Builds the new item.
    ///
    /// Whitespace is preserved exactly. Unlike a note, leading and trailing whitespace in a clip
    /// is often the point of it, so nothing is trimmed here.
    ///
    /// Masking can only be gained: `sensitivity` is the policy's verdict on the edited text, and
    /// it is or-ed with the source's own flag. So editing a hidden item cannot produce a visible
    /// copy of it, and editing an innocent one into a secret still hides the result. Favorite and
    /// note are deliberately not inherited: this is not the item the user starred or annotated.
    static func editedItem(
        from source: ClipboardItem,
        text: String,
        sensitivity: ClipboardSensitivityFlags,
        id: UUID = UUID(),
        timestamp: Date = Date()
    ) -> ClipboardItem {
        ClipboardItem(
            id: id,
            content: text,
            type: .text,
            timestamp: timestamp,
            isFavorite: false,
            isSensitive: sensitivity.isSensitive || source.isSensitive,
            isAutoSensitive: sensitivity.isAutoSensitive,
            isPasswordLike: sensitivity.isPasswordLike,
            isManuallyUnsensitive: false,
            note: nil
        )
    }
}

/// What `ClipboardMonitor.saveEditedText` actually did. The popover has to be able to say that an
/// edit which already existed was moved to the top rather than added again, otherwise Save looks
/// like it dropped the edit.
enum ClipboardTextEditOutcome: Equatable {
    case empty
    case unchanged
    case saved(id: UUID)
    case alreadyInHistory(id: UUID)
}

/// Joining several selected text items into one new clip.
///
/// The same shape as `ClipboardTextEdit`: the source rows are never touched and the join lands as
/// an ordinary new item, so history stays a log of what was on the pasteboard plus the copies the
/// user deliberately made. It is one action on a selection the user already has, rather than a
/// paste stack with a mode and an indicator to keep in step; see `docs/FOLLOWUPS.md`.
struct ClipboardMergedCopy {
    /// A newline, and only a newline. A configurable separator would be a preference whose effect
    /// is invisible until after the merge, and a blank line between the pieces is one keystroke in
    /// the editor afterwards.
    static let separator = "\n"

    /// What merging a selection would produce, worked out before any history is touched so it can
    /// be tested on its own and so the action's own title can state the counts before it is used.
    struct Plan: Equatable {
        let text: String
        /// How many items were joined. Always at least 2, or there is no plan.
        let mergedCount: Int
        /// How many selected items carry no text of their own. Left out rather than represented by
        /// a placeholder, and reported in the UI, so a merge never silently drops part of what the
        /// user picked.
        let skippedCount: Int
        /// Whether any of the *joined* items is masked. A skipped image contributes nothing to the
        /// text, so its own flag has nothing to say about the result.
        let includesSensitiveSource: Bool
    }

    /// `items` is the list as it is shown, top to bottom, and that is the order the pieces are
    /// joined in. The order is read off the list rather than off `selectedIds` on purpose: a
    /// `Set<UUID>` has none, and matching what the user can see is the whole of what makes the
    /// result predictable.
    static func plan(forSelectionIn items: [ClipboardItem], selectedIds: Set<UUID>) -> Plan? {
        // The list asks for this on every rebuild, and no multi-selection is the ordinary state, so
        // the cheap answer comes before the scan and the join.
        guard selectedIds.count >= 2 else { return nil }

        let selected = items.filter { selectedIds.contains($0.id) }
        let texts = selected.filter { $0.type == .text }

        // One item is not a merge and none is not a selection: below two there is nothing this
        // action does that pasting the item itself does not already do.
        guard texts.count >= 2 else { return nil }

        return Plan(
            text: texts.map(\.fullText).joined(separator: separator),
            mergedCount: texts.count,
            skippedCount: selected.count - texts.count,
            includesSensitiveSource: texts.contains { $0.isSensitive }
        )
    }

    /// Builds the new item.
    ///
    /// Whitespace is preserved exactly, as in the editor: the leading tab on a clip is often the
    /// point of it. Formatting is deliberately dropped, so a merged clip pastes plain: RTF and HTML
    /// are whole documents, and splicing several together would produce a flavour claiming to be
    /// what the user copied while being something this app assembled.
    ///
    /// Masking can only be gained, again as in the editor: `sensitivity` is the policy's verdict on
    /// the joined text, or-ed with the sources' own flags, so a merge that includes one hidden clip
    /// cannot produce a visible copy of it. Favorite and note are not inherited: this is not the
    /// item the user starred or annotated, and with several sources there is no single one to
    /// inherit from anyway.
    static func mergedItem(
        from plan: Plan,
        sensitivity: ClipboardSensitivityFlags,
        id: UUID = UUID(),
        timestamp: Date = Date()
    ) -> ClipboardItem {
        ClipboardItem(
            id: id,
            content: plan.text,
            type: .text,
            timestamp: timestamp,
            isFavorite: false,
            isSensitive: sensitivity.isSensitive || plan.includesSensitiveSource,
            isAutoSensitive: sensitivity.isAutoSensitive,
            isPasswordLike: sensitivity.isPasswordLike,
            isManuallyUnsensitive: false,
            note: nil
        )
    }
}

/// What `ClipboardMonitor.copyMerged` actually did, for the same reason
/// `ClipboardTextEditOutcome` exists: a join whose text was already in history moves that row to
/// the top instead of adding a second copy, and the popover has to be able to say so.
enum ClipboardMergedCopyOutcome: Equatable {
    case merged(id: UUID)
    case alreadyInHistory(id: UUID)
}

/// Splitting one multi-line text item into a clip per line.
///
/// The mirror of `ClipboardMergedCopy`, and it follows the editor's model for the same reason: the
/// source row is never touched and every piece lands as an ordinary new item, so history stays a log
/// of what was on the pasteboard plus the copies the user deliberately made. Copy a column of names
/// out of a spreadsheet, split, then paste them one at a time.
struct ClipboardTextSplit {
    /// Above this many pieces the user is asked first.
    ///
    /// A stray copy of a log file is one keystroke away from becoming thousands of rows, and unlike
    /// every other action in the popover this one multiplies. The number is a judgement rather than
    /// a measurement: a hundred lines is more than anyone splits on purpose without noticing.
    static let confirmationThreshold = 100

    /// What splitting an item would produce, worked out before any history is touched so it can be
    /// tested on its own and so the action's own title can state the count before it is used.
    struct Plan: Equatable {
        /// The pieces in the order they are read in the source, top to bottom. They are *inserted*
        /// in the reverse of this, so the first line ends up newest; see `items(from:sensitivity:)`.
        let pieces: [String]
        /// Lines that carried nothing but whitespace and were left out. Not shown to the user
        /// anywhere: it is here so the count in the title can be checked against the source.
        let droppedBlankLineCount: Int
        /// Whether the source is masked. Every piece inherits it, so a hidden clip cannot be split
        /// into visible ones.
        let sourceIsSensitive: Bool

        var pieceCount: Int { pieces.count }

        var needsConfirmation: Bool { pieces.count > ClipboardTextSplit.confirmationThreshold }
    }

    /// Nil when there is nothing to split: a non-text item, or text that yields fewer than two
    /// pieces. One piece is not a split, it is the item the user already has.
    ///
    /// The type check is not redundant with `fullText`, which answers for every kind of item: an
    /// image carrying multi-line `associatedText` would otherwise offer to be split into clips of
    /// text the row never claimed to hold.
    static func plan(for item: ClipboardItem?) -> Plan? {
        guard let item, item.type == .text else { return nil }

        // Line endings only, so a clip is cut where the user can see it is cut. `.newlines` covers
        // CR, LF and the Unicode line and paragraph separators; a CRLF pair splits into two, with
        // an empty piece between them that the filter below drops.
        let lines = item.fullText.components(separatedBy: .newlines)

        // A line of tabs between two blocks is a blank line, not a clip. It is dropped by the same
        // rule as an empty one, and the lines that survive are never trimmed: a leading tab is
        // often exactly what the user wants pasted, as it is in the editor.
        let pieces = lines.filter { $0.contains(where: { !$0.isWhitespace }) }

        guard pieces.count >= 2 else { return nil }

        return Plan(
            pieces: pieces,
            droppedBlankLineCount: lines.count - pieces.count,
            sourceIsSensitive: item.isSensitive
        )
    }

    /// Builds the new items, in reading order.
    ///
    /// `sensitivity` is the policy's verdict on each piece, asked for one piece at a time rather
    /// than once for the whole clip: a password on line 4 masks the clip it becomes and leaves the
    /// nine ordinary lines around it readable. It is or-ed with the source's own flag, so masking
    /// can only be gained, exactly as in the editor and in Copy Merged. Favorite and note are not
    /// inherited: these are not the item the user starred or annotated. Formatting is dropped for
    /// the reason a merge drops it, from the other end: a line out of the middle of an RTF or HTML
    /// document is not a document, and the row's marker promises the formatting a clip was copied
    /// with.
    ///
    /// The timestamps descend by a millisecond a piece so that the first line is the newest. The
    /// order in `clipboardHistory` comes from the order they are inserted in, but the order they
    /// come back in after a relaunch comes from these, and the two have to agree.
    static func items(
        from plan: Plan,
        sensitivity: (String) -> ClipboardSensitivityFlags,
        timestamp base: Date = Date()
    ) -> [ClipboardItem] {
        plan.pieces.enumerated().map { index, piece in
            let flags = sensitivity(piece)
            return ClipboardItem(
                id: UUID(),
                content: piece,
                type: .text,
                timestamp: base.addingTimeInterval(-0.001 * Double(index)),
                isFavorite: false,
                isSensitive: flags.isSensitive || plan.sourceIsSensitive,
                isAutoSensitive: flags.isAutoSensitive,
                isPasswordLike: flags.isPasswordLike,
                isManuallyUnsensitive: false,
                note: nil
            )
        }
    }
}

/// What `ClipboardMonitor.splitIntoItems` actually did.
///
/// The counts are separated for the same reason `ClipboardTextEditOutcome` has an
/// `alreadyInHistory` case: the merger dedupes by content, so splitting a list with a repeated line
/// produces fewer rows than it has pieces, and without saying so that reads as dropped text.
struct ClipboardTextSplitOutcome: Equatable {
    /// The row to select afterwards: the first line of the source, or whatever it merged into.
    let topItemId: UUID?
    /// Pieces that became a new row.
    let addedCount: Int
    /// Pieces that matched a clip already in the history, which moved to the top instead.
    let movedCount: Int
}

class ClipboardMonitor: ObservableObject {
    @Published var clipboardHistory: [ClipboardItem] = []

    /// Mirrors `UserPreferencesManager.capturePaused` so the menu bar icon and the popover can
    /// observe it. Changed only through `setCapturePaused`.
    @Published private(set) var isCapturePaused: Bool
    private var changeCount: Int = 0
    private var timer: Timer?
    private var isPausing = false
    private var userPreferences: UserPreferencesManager
    private var persistenceManager: PersistenceManager
    /// Injected so a test can exercise `recognizeText` without Vision and without a fixture image
    /// that happens to contain legible text.
    private let textRecognizer: ImageTextRecognizing
    private var maintenanceTimer: Timer?
    private var pendingChangeCount: Int?
    /// The frontmost app read when the change was first noticed, held for the retry. Re-reading it
    /// when the retry finally succeeds would name whichever app the user has switched to since.
    private var pendingSourceBundleIdentifier: String?
    private var pendingCaptureAttempts: Int = 0
    private var pendingCaptureRetryScheduled = false
    private let maxPendingCaptureAttempts = 20
    private let pendingCaptureRetryDelay: TimeInterval = 0.25
    
    init(userPreferences: UserPreferencesManager = UserPreferencesManager.shared,
         persistenceManager: PersistenceManager = PersistenceManager.shared,
         textRecognizer: ImageTextRecognizing = VisionImageTextRecognizer()) {
        self.userPreferences = userPreferences
        self.persistenceManager = persistenceManager
        self.textRecognizer = textRecognizer
        self.isCapturePaused = userPreferences.capturePaused

        // Load persisted history first. A pause survives a relaunch, so a paused app comes back
        // paused: the timer is never started, and the popover and the menu bar icon say so.
        self.loadPersistedHistory { [weak self] in
            guard let self, !self.isCapturePaused else { return }
            self.startMonitoring()
        }

        startMaintenanceTimer()
        compactImageStorageIfNeeded()
        
        // Listen for preferences changes to trim history if needed
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )

        // Listen for auto-sensitive setting being enabled
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(autoSensitiveSettingEnabled),
            name: .autoSensitiveSettingEnabled,
            object: nil
        )

        // Listen for password-like setting being enabled
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(passwordLikeSettingEnabled),
            name: .passwordLikeSettingEnabled,
            object: nil
        )
    }
    
    deinit {
        stopMonitoring()
        stopMaintenanceTimer()
        NotificationCenter.default.removeObserver(self)
    }
    
    private func startMonitoring() {
        // Idempotent: resuming and the initial history load can both reach this, and two timers
        // would poll the pasteboard twice a tick for ever.
        stopMonitoring()

        // Check clipboard every 0.8 seconds (balanced between responsiveness and CPU usage)
        let monitoringTimer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
        RunLoop.main.add(monitoringTimer, forMode: .common)
        timer = monitoringTimer
        
        // Initial check
        checkClipboard()
    }
    
    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
    
    
    /// Re-encodes a pre-existing history's uncompressed images, once per install.
    ///
    /// New clips are stored as PNG from here on, but an installed copy upgrading into this can be
    /// holding a gigabyte of TIFF that no retention setting would ever have explained. Runs at
    /// utility priority so it stays out of the way of the first paste after launch.
    private func compactImageStorageIfNeeded() {
        guard userPreferences.persistenceEnabled, !userPreferences.imageStorageCompacted else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let reclaimed = self.persistenceManager.compactImageStorage()

            DispatchQueue.main.async {
                // Set only after a completed pass, so an interrupted one runs again next launch.
                self.userPreferences.imageStorageCompacted = true
                if reclaimed > 0 {
                    Logging.info("💾 Reclaimed \(reclaimed / 1_048_576) MB by re-encoding stored images")
                }
            }
        }
    }

    private func startMaintenanceTimer() {
        // Run maintenance every hour
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.performMaintenance()
        }
    }
    
    private func stopMaintenanceTimer() {
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
    }
    
    private func loadPersistedHistory(completion: @escaping () -> Void) {
        guard userPreferences.persistenceEnabled else {
            completion()
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let persistedItems = self.persistenceManager.loadClipboardHistory(limit: self.userPreferences.maxClipboardItems)

            DispatchQueue.main.async {
                self.clipboardHistory = persistedItems
                completion()
            }
        }
    }
    
    /// Saves `item`, then removes any rows it replaces. Both run on the same queue, in that
    /// order, so there is no moment where neither the old row nor the new one is on disk.
    private func saveItemToPersistence(_ item: ClipboardItem, superseding supersededIDs: Set<UUID> = []) {
        guard userPreferences.persistenceEnabled else { return }

        DispatchQueue.global(qos: .utility).async {
            self.persistenceManager.saveClipboardItem(item, saveImages: self.userPreferences.saveImages)

            if !supersededIDs.isEmpty {
                self.persistenceManager.deleteItems(withIds: supersededIDs)
            }
        }
    }
    
    private func performMaintenance() {
        guard userPreferences.persistenceEnabled else { return }
        
        DispatchQueue.global(qos: .utility).async {
            self.persistenceManager.cleanupOldItems(olderThan: self.userPreferences.persistenceDays)

            // Images age out on their own, shorter clock. Keeping a text clip costs a few hundred
            // bytes and it is often something you come back to; keeping an image costs thousands
            // of times more and it has usually been pasted once and forgotten.
            self.persistenceManager.cleanupOldItems(
                olderThan: self.userPreferences.imagePersistenceDays,
                scope: .images
            )

            // Then, if the store is still over budget, drop oldest images until it fits. This used
            // to halve the retention window once instead, which could never get under the limit:
            // it just kept history at half the age the user asked for, every hour, for ever.
            let limit = Int64(self.userPreferences.maxStorageSize) * 1024 * 1024
            self.persistenceManager.evictImagesUntilWithin(byteLimit: limit)
        }
    }
    
    private func checkClipboard() {
        // Capture the user switched off. The timer is stopped as well, so this mainly guards the
        // calls that do not come from it: `refreshClipboardNow` on every popover open, and the
        // initial check when monitoring starts.
        guard !isCapturePaused else { return }

        // Skip monitoring if we're currently pasting
        guard !isPausing else { return }

        let pasteboard = NSPasteboard.general

        // Check if clipboard content changed
        if ClipboardCapturePause.hasUnseenClip(pasteboardChangeCount: pasteboard.changeCount, lastSeenChangeCount: changeCount) {
            changeCount = pasteboard.changeCount
            cancelPendingCapture()

            // Decided before the pasteboard is read, and never queued for a retry: a skipped clip
            // is meant to leave no trace at all. `changeCount` has already moved, so a skip is
            // final rather than reconsidered on the next tick.
            let read = captureRead(for: pasteboard)
            guard read.decision == .capture else {
                logSkippedCapture(read.decision)
                return
            }

            // Get clipboard content
            if let content = getClipboardContent(sourceBundleIdentifier: read.sourceBundleIdentifier) {
                addToHistory(content)
            } else {
                pendingChangeCount = changeCount
                pendingSourceBundleIdentifier = read.sourceBundleIdentifier
                schedulePendingCaptureRetry()
            }
        }
    }

    /// What one look at the frontmost app answered: whether to record the clip, and which app to
    /// record it against.
    ///
    /// Both come out of the same read on purpose. Asking `NSWorkspace` a second time for the source
    /// would let the guard and the recorded app disagree, so a clip could be kept because Slack was
    /// not excluded and then be labelled as coming from Mail.
    private struct CaptureRead {
        let decision: ClipboardCapturePolicy.Decision
        let sourceBundleIdentifier: String?
    }

    /// The capture guard's inputs, gathered at the moment a change is noticed.
    ///
    /// `frontmostApplication` is read here and nowhere else on this path. With 0.8 s polling it is
    /// a good guess at the source of the clip rather than a fact, which is the known limit stated in
    /// the Settings copy and the reason `ClipboardSource` says not to sharpen it with activation
    /// history; the concealed-type check beside it is exact, because the source app sets that
    /// marker itself.
    private func captureRead(for pasteboard: NSPasteboard) -> CaptureRead {
        let frontmostBundleIdentifier = ClipboardSource.storableBundleIdentifier(
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )

        return CaptureRead(
            decision: ClipboardCapturePolicy.decision(
                hasSensitivePasteboardType: SensitiveContentDetector.hasSensitivePasteboardType(pasteboard),
                skipConcealedClips: userPreferences.skipConcealedClips,
                sourceBundleIdentifier: frontmostBundleIdentifier,
                excludedBundleIdentifiers: userPreferences.excludedBundleIdentifierSet
            ),
            sourceBundleIdentifier: frontmostBundleIdentifier
        )
    }

    private func logSkippedCapture(_ decision: ClipboardCapturePolicy.Decision) {
        switch decision {
        case .capture:
            break
        case .skipConcealed:
            Logging.debug("🔒 Skipped a clip the source app marked confidential")
        case .skipExcludedApp(let bundleIdentifier):
            Logging.debug("🚫 Skipped a clip from excluded app \(bundleIdentifier)")
        }
    }

    private func cancelPendingCapture() {
        pendingChangeCount = nil
        pendingSourceBundleIdentifier = nil
        pendingCaptureAttempts = 0
    }

    private func schedulePendingCaptureRetry() {
        guard !pendingCaptureRetryScheduled else { return }
        guard let pending = pendingChangeCount, pending == changeCount else { return }
        guard pendingCaptureAttempts < maxPendingCaptureAttempts else {
            Logging.debug("ℹ️ Gave up deferred clipboard capture for changeCount \(changeCount)")
            pendingChangeCount = nil
            return
        }

        pendingCaptureRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + pendingCaptureRetryDelay) { [weak self] in
            guard let self = self else { return }
            self.pendingCaptureRetryScheduled = false
            self.attemptPendingCapture(expectedChangeCount: pending)
        }
    }

    private func attemptPendingCapture(expectedChangeCount: Int) {
        // A pause drops the clip that was mid-flight rather than holding it until capture is back
        // on: it was still on the pasteboard when the user said stop recording.
        guard !isCapturePaused else {
            cancelPendingCapture()
            return
        }

        guard !isPausing else {
            schedulePendingCaptureRetry()
            return
        }

        let pasteboard = NSPasteboard.general
        // Clipboard changed again; pending capture is obsolete.
        guard pasteboard.changeCount == expectedChangeCount, expectedChangeCount == changeCount else {
            cancelPendingCapture()
            return
        }

        // The excluded-app check is deliberately not repeated here: it was made when the change was
        // detected, and by now the user may well have switched apps, so re-reading the frontmost app
        // would answer a different question. The source recorded on the item comes from that same
        // first read, carried in `pendingSourceBundleIdentifier`, for the same reason. The concealed
        // type is worth another look, because an app that writes its clip in stages (which is why
        // this retry path exists) can declare that type after the change count has already moved.
        if userPreferences.skipConcealedClips,
           SensitiveContentDetector.hasSensitivePasteboardType(pasteboard) {
            Logging.debug("🔒 Skipped a clip the source app marked confidential")
            cancelPendingCapture()
            return
        }

        pendingCaptureAttempts += 1

        if let content = getClipboardContent(sourceBundleIdentifier: pendingSourceBundleIdentifier) {
            addToHistory(content)
            cancelPendingCapture()
            return
        }

        schedulePendingCaptureRetry()
    }

    func refreshClipboardNow() {
        checkClipboard()
    }

    // MARK: - Pausing Capture

    func toggleCapturePaused() {
        setCapturePaused(!isCapturePaused)
    }

    /// Switches capture off or back on, and remembers it.
    ///
    /// The single writer of `UserPreferencesManager.capturePaused`, because resuming has to
    /// resynchronise `changeCount` before polling starts again and a second writer would skip it.
    /// Main thread only: it owns the timer and publishes the state the menu bar icon draws from.
    func setCapturePaused(_ paused: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard paused != isCapturePaused else { return }

        isCapturePaused = paused
        userPreferences.capturePaused = paused

        if paused {
            stopMonitoring()
            // Anything the deferred-capture path was still holding on to belongs to the moment
            // before the pause, and it is not worth recording a clip the user asked to stop
            // recording just because an app wrote it in stages.
            cancelPendingCapture()
            Logging.info("⏸️ Clipboard capture paused")
        } else {
            // Before the timer, never after: the first tick would otherwise see a change count
            // that moved while capture was off and record the clip the pause existed to keep out.
            changeCount = ClipboardCapturePause.changeCountOnResume(
                pasteboardChangeCount: NSPasteboard.general.changeCount
            )
            cancelPendingCapture()
            startMonitoring()
            Logging.info("▶️ Clipboard capture resumed")
        }
    }

    private struct PasteboardImagePayload {
        let image: NSImage
        let byteCount: Int
        let sourceType: String
    }

    private let supportedImageTypes: [NSPasteboard.PasteboardType] = [
        .png,
        .tiff,
        .pdf,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.heic"),
        NSPasteboard.PasteboardType("public.heif"),
        NSPasteboard.PasteboardType("com.compuserve.gif")
    ]

    private func decodeImagePayload(from item: NSPasteboardItem) -> PasteboardImagePayload? {
        for type in supportedImageTypes {
            if let data = item.data(forType: type), let image = NSImage(data: data) {
                return PasteboardImagePayload(image: image, byteCount: data.count, sourceType: "item:\(type.rawValue)")
            }
        }
        return nil
    }

    private func estimatedPixelCount(for image: NSImage) -> Int {
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            return rep.pixelsWide * rep.pixelsHigh
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let widthPixels = Int(image.size.width * scale)
        let heightPixels = Int(image.size.height * scale)
        return max(0, widthPixels * heightPixels)
    }

    private func shouldSkipImageForSize(image: NSImage, payload: PasteboardImagePayload?) -> Bool {
        let maxImageBytes = 10 * 1024 * 1024
        let maxFallbackPixels = 40_000_000
        let imageBytes = payload?.byteCount ?? (image.tiffRepresentation?.count ?? 0)
        let sourceType = payload?.sourceType ?? "unknown"
        let isDirectEncodedPayload = sourceType.hasPrefix("public.") || sourceType.hasPrefix("item:") || sourceType == "com.compuserve.gif"

        if isDirectEncodedPayload {
            if imageBytes > maxImageBytes {
                Logging.debug("⚠️ Skipped large encoded image (\(imageBytes / 1024 / 1024)MB, source: \(sourceType)) - exceeds 10MB limit")
                return true
            }
            return false
        }

        let pixelCount = estimatedPixelCount(for: image)
        if pixelCount > maxFallbackPixels {
            Logging.debug("⚠️ Skipped very large fallback image (\(pixelCount) pixels, source: \(sourceType))")
            return true
        }

        return false
    }

    private func readImageFromPasteboard(_ pasteboard: NSPasteboard) -> PasteboardImagePayload? {
        for type in supportedImageTypes {
            if let data = pasteboard.data(forType: type), let image = NSImage(data: data) {
                return PasteboardImagePayload(image: image, byteCount: data.count, sourceType: type.rawValue)
            }
        }

        if let items = pasteboard.pasteboardItems {
            for item in items {
                if let payload = decodeImagePayload(from: item) {
                    return payload
                }
            }
        }

        if let image = NSImage(pasteboard: pasteboard) {
            let fallbackSize = image.tiffRepresentation?.count ?? 0
            return PasteboardImagePayload(image: image, byteCount: fallbackSize, sourceType: "NSImage(pasteboard:)")
        }

        if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
            let fallbackSize = image.tiffRepresentation?.count ?? 0
            return PasteboardImagePayload(image: image, byteCount: fallbackSize, sourceType: "NSImage-object")
        }

        return nil
    }
    
    /// `sourceBundleIdentifier` comes from the caller rather than from another `NSWorkspace` read:
    /// see `captureRead(for:)`. Every item built here carries it, images and files included.
    private func getClipboardContent(sourceBundleIdentifier: String?) -> ClipboardItem? {
        let pasteboard = NSPasteboard.general

        // Check pasteboard types for sensitive indicators first (instant check)
        let hasSensitivePasteboardType = SensitiveContentDetector.hasSensitivePasteboardType(pasteboard)

        let textContent = pasteboard.string(forType: .string)
        let hasText = (textContent?.isEmpty == false)
        // Read once, and only when there is text to hang them on: `data(forType:)` copies the bytes,
        // and an item that is not text never carries formatting (see `ClipboardItem.init`).
        let rtfData = hasText ? ClipboardRichText.storableRTF(pasteboard.data(forType: .rtf)) : nil
        let htmlData = hasText ? ClipboardRichText.storableHTML(pasteboard.data(forType: .html)) : nil
        let imagePayload = readImageFromPasteboard(pasteboard)
        let imageContent = imagePayload?.image
        let hasImage = imageContent != nil

        // Prefer image item when both text and image are present, preserving text as secondary payload
        if hasImage, let image = imageContent {
            if shouldSkipImageForSize(image: image, payload: imagePayload) {
                // Fallback to text representation if available
                if hasText, let string = textContent {
                    let maxTextBytes = 1 * 1024 * 1024
                    if string.utf8.count <= maxTextBytes {
                        let sensitivity = ClipboardSensitivityPolicy.flags(
                            for: string,
                            hasSensitivePasteboardType: hasSensitivePasteboardType,
                            autoDetectSensitiveData: userPreferences.autoDetectSensitiveData,
                            autoHidePasswordLikeStrings: userPreferences.autoHidePasswordLikeStrings
                        )

                        return ClipboardItem(
                            id: UUID(),
                            content: string,
                            type: .text,
                            timestamp: Date(),
                            isSensitive: sensitivity.isSensitive,
                            isAutoSensitive: sensitivity.isAutoSensitive,
                            isPasswordLike: sensitivity.isPasswordLike,
                            sourceBundleIdentifier: sourceBundleIdentifier,
                            rtfData: rtfData,
                            htmlData: htmlData
                        )
                    }
                }
                return nil
            }

            let attachedText = hasText ? textContent : nil
            let sensitivity = ClipboardSensitivityPolicy.flags(
                for: attachedText,
                hasSensitivePasteboardType: hasSensitivePasteboardType,
                autoDetectSensitiveData: userPreferences.autoDetectSensitiveData,
                autoHidePasswordLikeStrings: userPreferences.autoHidePasswordLikeStrings
            )

            return ClipboardItem(
                id: UUID(),
                content: image,
                type: .image,
                timestamp: Date(),
                isSensitive: sensitivity.isSensitive,
                isAutoSensitive: sensitivity.isAutoSensitive,
                isPasswordLike: sensitivity.isPasswordLike,
                sourceBundleIdentifier: sourceBundleIdentifier,
                associatedText: attachedText
            )
        }

        // Check for text content first
        if let string = textContent, !string.isEmpty {
            // Skip extremely large text to prevent memory issues (max 1MB)
            let maxTextBytes = 1 * 1024 * 1024
            if string.utf8.count > maxTextBytes {
                Logging.debug("⚠️ Skipped large text (\(string.utf8.count / 1024)KB) - exceeds 1MB limit")
                return nil
            }

            let sensitivity = ClipboardSensitivityPolicy.flags(
                for: string,
                hasSensitivePasteboardType: hasSensitivePasteboardType,
                autoDetectSensitiveData: userPreferences.autoDetectSensitiveData,
                autoHidePasswordLikeStrings: userPreferences.autoHidePasswordLikeStrings
            )

            return ClipboardItem(
                id: UUID(),
                content: string,
                type: .text,
                timestamp: Date(),
                isSensitive: sensitivity.isSensitive,
                isAutoSensitive: sensitivity.isAutoSensitive,
                isPasswordLike: sensitivity.isPasswordLike,
                sourceBundleIdentifier: sourceBundleIdentifier,
                rtfData: rtfData,
                htmlData: htmlData
            )
        }

        // Check for file URLs
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            let fileNames = urls.map { $0.lastPathComponent }.joined(separator: ", ")

            // Files can also be sensitive based on pasteboard type
            let isAutoSensitive = hasSensitivePasteboardType
            let isSensitive = isAutoSensitive && userPreferences.autoDetectSensitiveData

            return ClipboardItem(
                id: UUID(),
                content: urls,
                type: .file,
                timestamp: Date(),
                displayText: fileNames,
                isSensitive: isSensitive,
                isAutoSensitive: isAutoSensitive,
                sourceBundleIdentifier: sourceBundleIdentifier
            )
        }

        return nil
    }
    
    private func addToHistory(_ item: ClipboardItem) {
        DispatchQueue.main.async {
            self.insertIntoHistory(item)
        }
    }

    /// Merges `item` into the history and persists it. Main thread only.
    ///
    /// Returns nil when the item was already at the top, so nothing was written.
    @discardableResult
    private func insertIntoHistory(_ item: ClipboardItem) -> ClipboardHistoryInsertionResult? {
        let result = ClipboardHistoryMerger.inserting(item, into: clipboardHistory)
        guard result.shouldPersistInsertedItem else { return nil }

        clipboardHistory = result.history

        // Write the replacement row before dropping the one it supersedes. The delete used to
        // run first, and committed synchronously, while the save was dispatched async: in
        // between, the item existed in memory only. A quit in that window lost it for good.
        // Re-copying something you already have is exactly what happens to a favorite
        // snippet, so favorites were the items most exposed to it.
        saveItemToPersistence(clipboardHistory[0], superseding: result.removedItemIDs)

        // Limit to max items
        trimHistoryToLimitPreservingFavorites()

        // Unload old images from memory to prevent memory bloat
        unloadOldImages()

        return result
    }

    /// Maximum number of images to keep loaded in memory
    private static let maxLoadedImages = 15

    /// Unload images beyond the first N to free memory
    private func unloadOldImages() {
        var loadedImageCount = 0

        for i in 0..<clipboardHistory.count {
            if clipboardHistory[i].type == .image && clipboardHistory[i].isImageLoaded {
                loadedImageCount += 1

                // Unload images beyond the limit
                if loadedImageCount > Self.maxLoadedImages {
                    clipboardHistory[i].content = NSNull()
                    clipboardHistory[i].isImageLoaded = false
                }
            }
        }
    }
    
    @objc private func preferencesChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Trim history if new limit is smaller than current count
            self.trimHistoryToLimitPreservingFavorites()
        }
    }

    private func trimHistoryToLimitPreservingFavorites() {
        let currentLimit = userPreferences.maxClipboardItems
        guard clipboardHistory.count > currentLimit else { return }

        var overflow = clipboardHistory.count - currentLimit
        var index = clipboardHistory.count - 1

        // Remove oldest non-favorites first
        while overflow > 0 && index >= 0 {
            if !clipboardHistory[index].isFavorite {
                clipboardHistory.remove(at: index)
                overflow -= 1
            }
            index -= 1
        }

        // If we still overflow, all remaining tail items are favorites.
        // Keep favorites rather than silently evicting them.
        if overflow > 0 {
            Logging.debug("⭐ Keeping \(overflow) favorites above max item limit (\(currentLimit))")
        }
    }

    @objc private func autoSensitiveSettingEnabled() {
        // When auto-detect setting is turned ON, apply isSensitive to all isAutoSensitive items
        // Skip items the user explicitly un-marked (isManuallyUnsensitive)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            var updatedIds: [UUID] = []
            for i in 0..<self.clipboardHistory.count {
                if self.clipboardHistory[i].isAutoSensitive && !self.clipboardHistory[i].isSensitive && !self.clipboardHistory[i].isManuallyUnsensitive {
                    self.clipboardHistory[i].isSensitive = true
                    updatedIds.append(self.clipboardHistory[i].id)
                }
            }

            // Update persistence
            if !updatedIds.isEmpty {
                DispatchQueue.global(qos: .utility).async {
                    self.persistenceManager.applyAutoSensitiveFlag()
                }
                Logging.debug("🔐 Applied sensitive flag to \(updatedIds.count) auto-detected items")
            }
        }
    }

    @objc private func passwordLikeSettingEnabled() {
        // When password-like setting is turned ON, apply isSensitive to all isPasswordLike items
        // Skip items the user explicitly un-marked (isManuallyUnsensitive)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            var updatedIds: [UUID] = []
            for i in 0..<self.clipboardHistory.count {
                if self.clipboardHistory[i].isPasswordLike && !self.clipboardHistory[i].isSensitive && !self.clipboardHistory[i].isManuallyUnsensitive {
                    self.clipboardHistory[i].isSensitive = true
                    updatedIds.append(self.clipboardHistory[i].id)
                }
            }

            // Update persistence
            if !updatedIds.isEmpty {
                DispatchQueue.global(qos: .utility).async {
                    self.persistenceManager.applyPasswordLikeFlag()
                }
                Logging.debug("🔑 Applied sensitive flag to \(updatedIds.count) password-like items")
            }
        }
    }
    
    /// Puts `item` on the pasteboard.
    ///
    /// `asPlainText` drops the formatting a text clip was copied with, which is the ⇧⏎ action in
    /// the popover. It is a property of this paste rather than of the item: the RTF stays stored,
    /// so the same clip can be pasted with its formatting next time.
    func copyToClipboard(_ item: ClipboardItem, asPlainText: Bool = false) {
        // Pause monitoring to prevent duplicate entries
        isPausing = true

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.type {
        case .text:
            if let text = item.content as? String {
                // Every flavour the clip carries, richest first. Which one is used is the receiving
                // app's choice, not ours: see `ClipboardRichText.flavours`.
                let flavours = ClipboardRichText.flavours(
                    text: text,
                    rtfData: item.rtfData,
                    htmlData: item.htmlData,
                    asPlainText: asPlainText
                )
                for flavour in flavours {
                    switch flavour {
                    case .rtf(let data):
                        pasteboard.setData(data, forType: .rtf)
                    case .html(let data):
                        pasteboard.setData(data, forType: .html)
                    case .plainText(let string):
                        pasteboard.setString(string, forType: .string)
                    }
                }
            }
        case .image:
            // Handle lazy-loaded images
            if let image = item.content as? NSImage {
                pasteboard.writeObjects([image])
                if let associatedText = item.associatedText, !associatedText.isEmpty {
                    pasteboard.setString(associatedText, forType: .string)
                }
            } else if item.needsImageLoad {
                // Load image synchronously for copy operation
                if let image = persistenceManager.loadImageData(for: item.id) {
                    pasteboard.writeObjects([image])
                    if let associatedText = item.associatedText, !associatedText.isEmpty {
                        pasteboard.setString(associatedText, forType: .string)
                    }
                    // Also update the item in history
                    if let index = clipboardHistory.firstIndex(where: { $0.id == item.id }) {
                        clipboardHistory[index].content = image
                        clipboardHistory[index].isImageLoaded = true
                    }
                }
            }
        case .file:
            if let urls = item.content as? [URL] {
                pasteboard.writeObjects(urls as [NSURL])
            }
        }
        
        // Update change count to match current state
        changeCount = pasteboard.changeCount
        
        // Move item to top of history
        DispatchQueue.main.async {
            if let index = self.clipboardHistory.firstIndex(where: { $0.id == item.id }) {
                let movedItem = self.clipboardHistory.remove(at: index)
                self.clipboardHistory.insert(movedItem, at: 0)
            }
        }

        // Persist last-used time so this "most recently used at top" ordering
        // survives an app restart, not just the current session.
        let usedItemId = item.id
        DispatchQueue.global(qos: .utility).async {
            self.persistenceManager.markItemUsed(itemId: usedItemId)
        }

        // Resume monitoring after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.isPausing = false
        }
    }
    
    func clearHistory() {
        DispatchQueue.main.async {
            // Keep favorites. Clear History clears the history, not the items the user pinned;
            // `clearAllData` spares the same rows, so memory and store stay in step.
            self.clipboardHistory.removeAll { !$0.isFavorite }
        }

        DispatchQueue.global(qos: .utility).async {
            self.persistenceManager.clearAllData()
        }
    }

    /// Clears the history on the way out, if the user asked for that.
    ///
    /// Synchronous, and deliberately not `clearHistory()`: that hops to a utility queue, and the
    /// process is about to exit, so the delete would be abandoned halfway and the setting would
    /// quietly do nothing. `PersistenceManager.performOnContext` uses `performAndWait`, so the
    /// rows and the external image files are gone before this returns. Favorites are spared, by
    /// the same `clearAllData` every other clear goes through.
    ///
    /// Only covers an orderly quit: Quit, the hotkey-driven relaunch after an in-place upgrade,
    /// a logout, and the SIGTERM the Homebrew cask sends, which
    /// `AppDelegate.installTerminationSignalHandler` turns into one. A force quit or a power cut
    /// kills the process with the history still on disk, and the Settings copy says so.
    func clearHistoryOnQuitIfRequested() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard userPreferences.clearHistoryOnQuit else { return }

        Logging.info("💾 Clearing saved history on quit, as requested in Settings")
        persistenceManager.clearAllData()
        clipboardHistory.removeAll { !$0.isFavorite }
    }

    /// What clearing the saved history would remove, read off the store rather than off memory.
    ///
    /// `clipboardHistory` holds at most `maxClipboardItems`, while the store can hold everything
    /// inside the retention window, so counting in memory would understate what is on disk in
    /// exactly the case where the number matters. Runs on a utility queue and answers on the main
    /// one, because it counts rows and stats the store directory.
    func summariseSavedHistory(completion: @escaping (PersistenceManager.SavedHistorySummary) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let summary = self.persistenceManager.savedHistorySummary()
            DispatchQueue.main.async { completion(summary) }
        }
    }

    func toggleFavorite(_ item: ClipboardItem) {
        DispatchQueue.main.async {
            if let index = self.clipboardHistory.firstIndex(where: { $0.id == item.id }) {
                self.clipboardHistory[index].isFavorite.toggle()

                // Update persistence
                let itemId = item.id
                DispatchQueue.global(qos: .utility).async {
                    _ = self.persistenceManager.toggleFavorite(itemId: itemId)
                }
            }
        }
    }

    func updateNote(_ item: ClipboardItem, note: String?) {
        DispatchQueue.main.async {
            if let index = self.clipboardHistory.firstIndex(where: { $0.id == item.id }) {
                self.clipboardHistory[index].note = note

                // Update persistence
                let itemId = item.id
                DispatchQueue.global(qos: .utility).async {
                    self.persistenceManager.updateNote(itemId: itemId, note: note)
                }
            }
        }
    }

    /// Saves `text` as a new text item derived from `source`, leaving `source` untouched.
    ///
    /// Main thread only: it mutates `clipboardHistory` and returns what happened, because the
    /// caller has to be able to report it. The pasteboard is deliberately not written here, so
    /// saving an edit does not silently replace whatever the user has copied.
    @discardableResult
    func saveEditedText(_ text: String, basedOn source: ClipboardItem) -> ClipboardTextEditOutcome {
        dispatchPrecondition(condition: .onQueue(.main))

        switch ClipboardTextEdit.intent(newText: text, sourceText: source.fullText) {
        case .empty:
            return .empty
        case .unchanged:
            return .unchanged
        case .save:
            break
        }

        let sensitivity = ClipboardSensitivityPolicy.flags(
            for: text,
            hasSensitivePasteboardType: false,
            autoDetectSensitiveData: userPreferences.autoDetectSensitiveData,
            autoHidePasswordLikeStrings: userPreferences.autoHidePasswordLikeStrings
        )
        let edited = ClipboardTextEdit.editedItem(from: source, text: text, sensitivity: sensitivity)

        // The merger dedupes by content, so an edit that happens to match something already in
        // history moves that row to the top instead of adding a second copy of it.
        guard let result = insertIntoHistory(edited) else {
            return .alreadyInHistory(id: clipboardHistory.first?.id ?? source.id)
        }

        return result.removedItemIDs.isEmpty ? .saved(id: edited.id) : .alreadyInHistory(id: edited.id)
    }

    /// Joins a selection into one new text item and puts it on the pasteboard.
    ///
    /// Main thread only: it mutates `clipboardHistory` and returns what happened, because the
    /// caller has to be able to report the counts. Unlike `saveEditedText` this *does* write the
    /// pasteboard, and the difference is the request rather than an inconsistency: saving an edit
    /// must not silently replace whatever the user has copied, while putting the join somewhere it
    /// can be pasted is the entire point of an action called Copy.
    @discardableResult
    func copyMerged(_ plan: ClipboardMergedCopy.Plan) -> ClipboardMergedCopyOutcome {
        dispatchPrecondition(condition: .onQueue(.main))

        let sensitivity = ClipboardSensitivityPolicy.flags(
            for: plan.text,
            hasSensitivePasteboardType: false,
            autoDetectSensitiveData: userPreferences.autoDetectSensitiveData,
            autoHidePasswordLikeStrings: userPreferences.autoHidePasswordLikeStrings
        )
        let merged = ClipboardMergedCopy.mergedItem(from: plan, sensitivity: sensitivity)

        // The merger dedupes by content, so a join that happens to match something already in
        // history moves that row to the top instead of adding a second copy of it.
        guard let result = insertIntoHistory(merged) else {
            // The join is already the item at the top, so there is nothing to insert. It still has
            // to reach the pasteboard: the user asked for a copy, not for a row.
            let existing = clipboardHistory.first ?? merged
            copyToClipboard(existing)
            return .alreadyInHistory(id: existing.id)
        }

        copyToClipboard(merged)
        return result.removedItemIDs.isEmpty ? .merged(id: merged.id) : .alreadyInHistory(id: merged.id)
    }

    /// Splits a multi-line text item into one new item per line, leaving the source untouched.
    ///
    /// Main thread only, as `saveEditedText` and `copyMerged` are, and for the same reason: it
    /// mutates `clipboardHistory` and returns what happened so the caller can report the counts.
    ///
    /// The pasteboard is deliberately not written, unlike `copyMerged`. A split has no single
    /// result to copy, and the point of it is to paste the pieces one at a time from the popover
    /// afterwards; replacing what the user has copied to do that would be taking something away.
    @discardableResult
    func splitIntoItems(_ plan: ClipboardTextSplit.Plan) -> ClipboardTextSplitOutcome {
        dispatchPrecondition(condition: .onQueue(.main))

        let pieces = ClipboardTextSplit.items(from: plan) { piece in
            ClipboardSensitivityPolicy.flags(
                for: piece,
                hasSensitivePasteboardType: false,
                autoDetectSensitiveData: userPreferences.autoDetectSensitiveData,
                autoHidePasswordLikeStrings: userPreferences.autoHidePasswordLikeStrings
            )
        }

        var addedCount = 0
        var movedCount = 0

        // Last line first. Every insert goes in at position 0, so inserting in reverse is what
        // leaves the list reading top to bottom in the source's own order, which is the order the
        // user will paste them in.
        for piece in pieces.reversed() {
            guard let result = insertIntoHistory(piece) else {
                // The piece is already the item at the top, so nothing was written.
                movedCount += 1
                continue
            }
            if result.removedItemIDs.isEmpty {
                addedCount += 1
            } else {
                movedCount += 1
            }
        }

        return ClipboardTextSplitOutcome(
            topItemId: clipboardHistory.first?.id,
            addedCount: addedCount,
            movedCount: movedCount
        )
    }

    /// Reads the text in an image item and saves it as a new text item, leaving the image untouched.
    ///
    /// Asked for on the main thread, as the other derive-a-new-item actions are, but unlike them it
    /// finishes later: the image may have to come off disk first, and the recognition itself is long
    /// enough that nothing can wait for it. `completion` is called on the main queue, and the work
    /// belongs here rather than in the popover so that closing the popover mid-recognition still
    /// leaves the new row in history.
    ///
    /// The pasteboard is deliberately not written, as in `splitIntoItems`: the user asked to read an
    /// image, not to replace what they have copied. The new row is selected instead, so ⏎ pastes it.
    func recognizeText(
        _ plan: ClipboardImageTextRecognition.Plan,
        completion: @escaping (ClipboardImageTextRecognitionOutcome) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))

        guard let item = clipboardHistory.first(where: { $0.id == plan.itemId }) else {
            completion(.failed)
            return
        }

        // The same load the preview does: an image beyond the newest few is not in memory.
        loadImageIfNeeded(item) { [weak self] image in
            guard let self else { return }
            guard let image else {
                Logging.info("🔍 No image to read text from for item \(plan.itemId)")
                completion(.failed)
                return
            }

            self.textRecognizer.recognizeText(in: image) { result in
                switch result {
                case .failure(let error):
                    Logging.info("🔍 Text recognition failed: \(error.localizedDescription)")
                    completion(.failed)
                case .success(let lines):
                    let text = ClipboardImageTextRecognition.text(from: lines)
                    completion(self.saveRecognizedText(text, for: plan))
                }
            }
        }
    }

    private func saveRecognizedText(
        _ text: String,
        for plan: ClipboardImageTextRecognition.Plan
    ) -> ClipboardImageTextRecognitionOutcome {
        dispatchPrecondition(condition: .onQueue(.main))

        guard !text.isEmpty else { return .noTextFound }

        let sensitivity = ClipboardSensitivityPolicy.flags(
            for: text,
            hasSensitivePasteboardType: false,
            autoDetectSensitiveData: userPreferences.autoDetectSensitiveData,
            autoHidePasswordLikeStrings: userPreferences.autoHidePasswordLikeStrings
        )
        let recognized = ClipboardImageTextRecognition.recognizedItem(
            from: plan,
            text: text,
            sensitivity: sensitivity
        )
        let lineCount = text.components(separatedBy: "\n").count

        // The merger dedupes by content, so text that was recognised before, or that the user has
        // since copied by hand, moves that row to the top instead of adding a second copy of it.
        guard let result = insertIntoHistory(recognized) else {
            return .alreadyInHistory(id: clipboardHistory.first?.id ?? plan.itemId)
        }

        return result.removedItemIDs.isEmpty
            ? .recognized(id: recognized.id, lineCount: lineCount)
            : .alreadyInHistory(id: recognized.id)
    }

    func toggleSensitive(_ item: ClipboardItem) {
        DispatchQueue.main.async {
            if let index = self.clipboardHistory.firstIndex(where: { $0.id == item.id }) {
                let wasAutoDetected = self.clipboardHistory[index].isAutoSensitive || self.clipboardHistory[index].isPasswordLike
                let willBeUnsensitive = self.clipboardHistory[index].isSensitive // currently sensitive → toggling OFF
                self.clipboardHistory[index].isSensitive.toggle()

                // Mark as manually unsensitive when user un-hides an auto-detected item
                // Clear the flag when user re-hides it
                if wasAutoDetected {
                    self.clipboardHistory[index].isManuallyUnsensitive = willBeUnsensitive
                }

                // Update persistence
                let itemId = item.id
                let manuallyUnsensitive = self.clipboardHistory[index].isManuallyUnsensitive
                DispatchQueue.global(qos: .utility).async {
                    _ = self.persistenceManager.toggleSensitive(itemId: itemId, isManuallyUnsensitive: manuallyUnsensitive)
                }
            }
        }
    }

    func deleteItems(withIds ids: Set<UUID>) {
        DispatchQueue.main.async {
            self.clipboardHistory.removeAll { ids.contains($0.id) }
        }

        // Also delete from persistent storage
        DispatchQueue.global(qos: .utility).async {
            self.persistenceManager.deleteItems(withIds: ids)
        }
    }

    /// Load image data for a lazy-loaded item (call when user selects the item)
    func loadImageIfNeeded(_ item: ClipboardItem, completion: @escaping (NSImage?) -> Void) {
        guard item.needsImageLoad else {
            // Already loaded
            completion(item.content as? NSImage)
            return
        }

        // Load from disk on background thread
        DispatchQueue.global(qos: .userInitiated).async {
            let image = self.persistenceManager.loadImageData(for: item.id)

            DispatchQueue.main.async {
                // Update the item in history with loaded image
                if let image = image,
                   let index = self.clipboardHistory.firstIndex(where: { $0.id == item.id }) {
                    self.clipboardHistory[index].content = image
                    self.clipboardHistory[index].isImageLoaded = true
                }
                completion(image)
            }
        }
    }
}

struct ClipboardItem: Identifiable, Equatable {
    let id: UUID
    var content: Any  // Can be nil for lazy-loaded images
    let type: ClipboardContentType
    let timestamp: Date
    let displayText: String?
    var isFavorite: Bool
    var isSensitive: Bool
    var isAutoSensitive: Bool  // True if auto-detected as sensitive (API keys, tokens, etc.)
    var isPasswordLike: Bool   // True if detected as password-like string
    var isManuallyUnsensitive: Bool  // True if user explicitly un-marked as sensitive (prevents re-apply)
    var note: String?
    /// Whether this text was read out of an image rather than copied. See
    /// `ClipboardImageTextRecognition`: a stored flag rather than a note, because the note belongs
    /// to the user, and rather than a display-time derivation, because provenance is not content.
    let isRecognizedText: Bool
    /// The app that was in front when this clip was noticed, as a bundle identifier. nil for every
    /// clip captured before the attribute existed, for a process with no identifier, and for an
    /// item the user made themselves. See `ClipboardSource`.
    let sourceBundleIdentifier: String?
    var associatedText: String?  // Optional text representation when clipboard item is image + text
    var rtfData: Data?   // The source app's RTF for a text item, written back on paste. See ClipboardRichText.
    var htmlData: Data?  // The source app's HTML, for the apps that write that instead of RTF.
    var isImageLoaded: Bool  // For lazy loading: false means image needs to be loaded from disk

    init(id: UUID, content: Any, type: ClipboardContentType, timestamp: Date, displayText: String? = nil, isFavorite: Bool = false, isSensitive: Bool = false, isAutoSensitive: Bool = false, isPasswordLike: Bool = false, isManuallyUnsensitive: Bool = false, note: String? = nil, isRecognizedText: Bool = false, sourceBundleIdentifier: String? = nil, associatedText: String? = nil, rtfData: Data? = nil, htmlData: Data? = nil, isImageLoaded: Bool = true) {
        self.id = id
        self.content = content
        self.type = type
        self.timestamp = timestamp
        self.displayText = displayText
        self.isFavorite = isFavorite
        self.isSensitive = isSensitive
        self.isAutoSensitive = isAutoSensitive
        self.isPasswordLike = isPasswordLike
        self.isManuallyUnsensitive = isManuallyUnsensitive
        self.note = note
        // Text only, for the reason the flavours below are: the marker says this text was read out
        // of an image, and only a text item holds text.
        self.isRecognizedText = (type == .text) && isRecognizedText
        // Every kind of clip has a source, unlike the flavours and the recognition marker below and
        // above it: an image and a set of files were copied out of an app just as text was.
        self.sourceBundleIdentifier = ClipboardSource.storableBundleIdentifier(sourceBundleIdentifier)
        self.associatedText = associatedText
        // Formatting belongs to text. An image or a file carrying RTF or HTML would be a marker in
        // the row that no paste could honour, since neither writes a text flavour.
        self.rtfData = (type == .text) ? rtfData : nil
        self.htmlData = (type == .text) ? htmlData : nil
        self.isImageLoaded = (type != .image) || isImageLoaded  // Non-images are always "loaded"
    }

    /// Returns true if this is an image that needs to be loaded from disk
    var needsImageLoad: Bool {
        return type == .image && !isImageLoaded
    }

    /// Whether pasting this item can reproduce the formatting it was copied with.
    ///
    /// What the row marker and the plain-text action are both driven by, so the marker cannot
    /// appear on an item that would paste as plain text anyway.
    var carriesFormatting: Bool {
        return type == .text && (rtfData != nil || htmlData != nil)
    }
    
    var previewText: String {
        if let displayText = displayText {
            return displayText
        }
        
        switch type {
        case .text:
            if let text = content as? String {
                // Limit preview to first line and 100 characters
                let firstLine = text.components(separatedBy: .newlines).first ?? ""
                let preview = String(firstLine.prefix(100))
                return preview
            }
        case .image:
            return "📷 Image"
        case .file:
            if let urls = content as? [URL] {
                let preview = "📁 \(urls.count) file(s)"
                return preview
            }
        }
        return "Unknown content"
    }
    
    var fullText: String {
        switch type {
        case .text:
            return content as? String ?? ""
        case .image:
            return associatedText?.isEmpty == false ? associatedText! : "📷 Image content"
        case .file:
            if let urls = content as? [URL] {
                return urls.map { $0.path }.joined(separator: "\n")
            }
        }
        return ""
    }
    
    func contentEquals(_ other: ClipboardItem) -> Bool {
        guard self.type == other.type else { return false }
        
        switch type {
        case .text:
            // Plain text alone, deliberately: `rtfData` is not part of what makes two clips the
            // same clip. Copying the same sentence out of Word and then out of Terminal is one
            // entry that has stopped carrying formatting, not two entries, and dropping the
            // comparison here is also what keeps the RTF out of the byte comparison this runs on
            // every capture.
            guard let text1 = content as? String,
                  let text2 = other.content as? String else { return false }
            // Quick rejection: different lengths = different content
            if text1.count != text2.count { return false }
            return text1 == text2
        case .image:
            // For images, use dimension comparison first, then exact data match.
            // A sampled-prefix/suffix comparison caused false duplicates for similar screenshots.
            guard let image1 = content as? NSImage,
                  let image2 = other.content as? NSImage else { return false }

            // Quick rejection: different dimensions = different images
            if image1.size != image2.size {
                return false
            }

            // For same dimensions, compare full normalized TIFF data to avoid false positives.
            guard let data1 = image1.tiffRepresentation,
                  let data2 = image2.tiffRepresentation else { return false }
            return data1 == data2
        case .file:
            let urls1 = content as? [URL] ?? []
            let urls2 = other.content as? [URL] ?? []
            return urls1 == urls2
        }
    }
    
    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        return lhs.id == rhs.id &&
               lhs.isSensitive == rhs.isSensitive &&
               lhs.isFavorite == rhs.isFavorite &&
               lhs.isAutoSensitive == rhs.isAutoSensitive &&
               lhs.isPasswordLike == rhs.isPasswordLike &&
               lhs.isManuallyUnsensitive == rhs.isManuallyUnsensitive &&
               lhs.note == rhs.note &&
               lhs.isRecognizedText == rhs.isRecognizedText &&
               lhs.sourceBundleIdentifier == rhs.sourceBundleIdentifier &&
               lhs.associatedText == rhs.associatedText &&
               lhs.rtfData == rhs.rtfData &&
               lhs.htmlData == rhs.htmlData &&
               lhs.isImageLoaded == rhs.isImageLoaded
    }
}

enum ClipboardContentType: Int {
    case text = 0
    case image = 1
    case file = 2
}