import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject private var preferences = UserPreferencesManager.shared
    /// Falls back to the shared checker so the SwiftUI preview, which builds this view with no app
    /// around it, still has something to read.
    @ObservedObject private var updateChecker: UpdateChecker
    @StateObject private var installation = InstallationHealth()
    @State private var exportState: ExportState = .idle
    @State private var purgeSummary: PersistenceManager.SavedHistorySummary?
    @State private var showPurgeOffer = false
    @State private var purgeMessage: String?
    /// Whatever the app is actually running over, so a purge reaches the same store the popover
    /// shows and the in-memory history is left in step with it. Optional because the SwiftUI
    /// preview builds this view without an app around it.
    private let clipboardMonitor: ClipboardMonitor?
    /// Owns the hotkey registration: the recorder needs it out of the way while it listens, and
    /// whether the last registration was refused is the one thing Settings cannot work out for
    /// itself. Optional for the same reason as `clipboardMonitor`.
    private let menuBarController: MenuBarController?
    let onDismiss: () -> Void
    let onCheckForUpdates: () -> Void

    enum ExportState: Equatable {
        case idle
        case working
        case exported(count: Int)
        case failed(reason: String)

        var message: String? {
            switch self {
            case .idle, .working:
                return nil
            case .exported(let count):
                return count == 1
                    ? L10n.string("Exported 1 favorite.", comment: "Export confirmation")
                    : String(
                        format: L10n.string("Exported %d favorites.", comment: "Export confirmation"),
                        count
                    )
            case .failed(let reason):
                return reason
            }
        }

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    init(
        clipboardMonitor: ClipboardMonitor? = nil,
        menuBarController: MenuBarController? = nil,
        onDismiss: @escaping () -> Void = {},
        onCheckForUpdates: @escaping () -> Void = {}
    ) {
        self.clipboardMonitor = clipboardMonitor
        self.menuBarController = menuBarController
        self.onDismiss = onDismiss
        self.onCheckForUpdates = onCheckForUpdates
        self.updateChecker = menuBarController?.updateChecker ?? .shared
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // General Settings
                    VStack(alignment: .leading, spacing: 12) {
                        Text("General")
                            .font(.headline)

                        Toggle("Launch at login", isOn: $preferences.autoStartEnabled)

                        // The one thing MacClipboard does over the network without being asked, so
                        // it says exactly what it sends and can be switched off. The manual check in
                        // the footer keeps working either way.
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Check for updates automatically", isOn: $preferences.automaticUpdateChecksEnabled)

                            Text("Asks GitHub once a day for the latest release number and shows a banner if there is a newer one. Nothing is downloaded or installed on its own, and nothing about your clipboard is sent.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Divider()

                    // Clipboard History Settings
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Clipboard History")
                            .font(.headline)

                        HStack {
                            Text("Max items:")
                                .frame(width: 80, alignment: .leading)

                            Slider(
                                value: Binding(
                                    get: { Double(preferences.maxClipboardItems) },
                                    set: { preferences.maxClipboardItems = Int($0) }
                                ),
                                in: Double(UserPreferencesManager.minClipboardItems)...Double(UserPreferencesManager.maxClipboardItems),
                                step: 10
                            )

                            Text("\(preferences.maxClipboardItems)")
                                .frame(width: 40, alignment: .trailing)
                                .monospacedDigit()
                        }
                    }

                    Divider()

                    // Persistence Settings
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Persistence")
                            .font(.headline)

                        // One toggle decides whether the history is written at all, the next
                        // decides whether what was written survives a quit. Stacked bare they
                        // read as two ways of saying the same thing, so each carries its own
                        // caption, tight against it, rather than one paragraph under the pair.
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Save clipboard history", isOn: $preferences.persistenceEnabled)
                                .onChange(of: preferences.persistenceEnabled) { enabled in
                                    purgeMessage = nil
                                    guard !enabled else { return }
                                    offerToDeleteSavedHistory()
                                }

                            Text("Writes what you copy to disk, so your history is still there the next time you launch MacClipboard. With this off, only what you copy in the current session is kept, and nothing new is written to disk.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        // Deliberately not disabled while saving is off. Switching saving off
                        // deletes nothing on its own, so a store the user declined to purge is
                        // exactly the case where this still has work to do at the next quit.
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Clear history when MacClipboard quits", isOn: $preferences.clearHistoryOnQuit)

                            Text("Saves your history as usual while you work, then deletes it when you quit, including a quit from a logout or an update. Favorites are kept, as they are by Clear History. A force quit or a power cut leaves the history on disk, because nothing gets to run at that point.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if let purgeMessage {
                            Text(purgeMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Toggle("Save images to disk", isOn: $preferences.saveImages)
                            .disabled(!preferences.persistenceEnabled)

                        HStack {
                            Text("Storage:")
                                .frame(width: 80, alignment: .leading)

                            Slider(
                                value: Binding(
                                    get: { Double(preferences.maxStorageSize) },
                                    set: { preferences.maxStorageSize = Int($0) }
                                ),
                                in: Double(UserPreferencesManager.minStorageSize)...Double(UserPreferencesManager.maxStorageSize),
                                step: 100
                            )
                            .disabled(!preferences.persistenceEnabled)

                            Text(formatStorageSize(preferences.maxStorageSize))
                                .frame(width: 50, alignment: .trailing)
                                .monospacedDigit()
                        }

                        HStack {
                            Text("Keep for:")
                                .frame(width: 80, alignment: .leading)

                            Slider(
                                value: Binding(
                                    get: { Double(preferences.persistenceDays) },
                                    set: { preferences.persistenceDays = Int($0) }
                                ),
                                in: 1...365,
                                step: 1
                            )
                            .disabled(!preferences.persistenceEnabled)

                            Text("\(preferences.persistenceDays) days")
                                .frame(width: 70, alignment: .trailing)
                                .monospacedDigit()
                        }

                        HStack {
                            Text("Keep images:")
                                .frame(width: 80, alignment: .leading)

                            Slider(
                                value: Binding(
                                    get: { Double(preferences.imagePersistenceDays) },
                                    set: { preferences.imagePersistenceDays = Int($0) }
                                ),
                                in: 1...365,
                                step: 1
                            )
                            .disabled(!preferences.persistenceEnabled)

                            Text("\(preferences.imagePersistenceDays) days")
                                .frame(width: 70, alignment: .trailing)
                                .monospacedDigit()
                        }

                        Text("Images are given a shorter life than text because they take almost all the space: a thousand text clips take under a megabyte, while a hundred screenshots can take a gigabyte. Favorites are kept indefinitely, whatever their type.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack(spacing: 8) {
                            Button("Export Favorites…") {
                                exportFavorites()
                            }
                            .disabled(exportState == .working)

                            if exportState == .working {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            if let message = exportState.message {
                                Text(message)
                                    .font(.caption)
                                    .foregroundColor(exportState.isFailure ? .red : .secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    Divider()

                    // Privacy Settings
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Privacy")
                            .font(.headline)

                        Toggle("Never save clips marked confidential by the source app", isOn: $preferences.skipConcealedClips)

                        Text("Password managers mark what you copy as confidential to say it should not be recorded. With this on, those clips are not added to history and never written to disk from now on. They are gone rather than hidden, so a password you meant to keep for a minute is not there either. Clips already in your history stay until you delete them.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        ExcludedAppsSection(preferences: preferences)

                        Divider()

                        Toggle("Auto-hide sensitive content", isOn: $preferences.autoDetectSensitiveData)

                        Text("Automatically detect and hide API keys, tokens, and other sensitive data with known formats. Hidden items are still saved, and Cmd+V reveals them.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Toggle("Auto-hide password-like strings", isOn: $preferences.autoHidePasswordLikeStrings)

                        Text("Hide text that looks like a password (8-64 chars with mixed case, numbers, and symbols). May have false positives.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text("Note: Auto-detection may not catch all sensitive data or could flag non-sensitive content. You can manually toggle items as sensitive (⌘ H).")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .padding(.top, 4)
                    }

                    Divider()

                    // Shortcuts Settings
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Shortcuts")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Global hotkey", isOn: $preferences.hotKeyEnabled)

                            GlobalHotkeyRecorder(
                                preferences: preferences,
                                menuBarController: menuBarController
                            )
                            .disabled(!preferences.hotKeyEnabled)

                            Text("Opens MacClipboard from whatever app you are in. ⌘ ⇧ V is also \"Paste and Match Style\" in a lot of apps, so change it here if the two collide.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if BuildInfo.isDevBuild {
                                Text("This is a dev build, so it keeps its own shortcut and its own default. An installed release copy is unaffected by what you set here.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Toggle("In-app shortcuts", isOn: $preferences.shortcutsEnabled)

                        if preferences.shortcutsEnabled {
                            HStack(spacing: 16) {
                                ShortcutHint(keys: "⌘ D", label: "Favorite")
                                ShortcutHint(keys: "⌘ H", label: "Sensitive")
                                ShortcutHint(keys: "⌘ F", label: "Filter")
                            }
                            HStack(spacing: 16) {
                                ShortcutHint(keys: "⌘ N", label: "Note")
                                ShortcutHint(keys: "⌘ V", label: "Reveal")
                                ShortcutHint(keys: "⌘ Z", label: "Preview")
                            }
                            HStack(spacing: 16) {
                                ShortcutHint(keys: "⌘ ⌫", label: "Delete")
                                ShortcutHint(keys: "⌘+Click", label: "Multi-select")
                            }
                        }
                    }

                    if installation.hasIssue {
                        Divider()
                        InstallationHealthSection(installation: installation)
                    }
                }
            }

            Divider()

            // Footer
            HStack {
                Text("MacClipboard v\(appVersion)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Names the running build. Two copies can run side by side (an installed
                // release plus a dev build), and they are otherwise indistinguishable.
                BuildChannelBadge()

                Text("·")
                    .foregroundColor(.secondary)

                Button("GitHub") {
                    if let url = URL(string: "https://github.com/rakodev/mac-clipboard") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)

                Text("·")
                    .foregroundColor(.secondary)

                updateStatusControl

                Spacer()

                Button("Reset") {
                    preferences.resetToDefaults()
                }
                .buttonStyle(.borderless)

                Button("Done") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500, height: 480)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { installation.refresh() }
        .alert(
            "Delete the history already saved?",
            isPresented: $showPurgeOffer,
            presenting: purgeSummary
        ) { summary in
            Button("Keep It", role: .cancel) {
                purgeMessage = String(
                    format: L10n.string(
                        "%d saved items were kept. Clear History removes them whenever you want.",
                        comment: "Shown after declining to delete the saved history"
                    ),
                    summary.clearableCount
                )
            }
            Button("Delete", role: .destructive) {
                deleteSavedHistory(summary)
            }
        } message: { summary in
            Text(purgeExplanation(for: summary))
        }
    }

    private var appVersion: String {
        BuildInfo.versionString
    }

    /// The third passive surface, and the only one that can say when the app last looked.
    ///
    /// A bare "Check for Updates" button makes the answer something the user has to ask for, which
    /// is the problem this whole feature exists to fix. So when a release is known about, this row
    /// states it; otherwise it says the app is current as of the last check, and the tooltip carries
    /// the timestamp so the claim is falsifiable.
    @ViewBuilder
    private var updateStatusControl: some View {
        if updateChecker.isChecking {
            Text("Checking...")
                .font(.caption)
                .foregroundColor(.secondary)
        } else if let update = updateChecker.availableUpdate {
            Button("Update to v\(update.version)") {
                menuBarController?.showAvailableUpdate()
            }
            .buttonStyle(.link)
            .font(.caption)
            .help(Text("A newer release is available. Opens the details."))
        } else {
            Button("Check for Updates") {
                onCheckForUpdates()
            }
            .buttonStyle(.link)
            .font(.caption)
            .help(Text(lastUpdateCheckDescription))
        }
    }

    private var lastUpdateCheckDescription: String {
        guard let last = preferences.lastUpdateCheckDate else {
            return L10n.string("No update check has run yet.", comment: "Update check tooltip when none has run")
        }

        let format = L10n.string("Last checked %@.", comment: "Update check tooltip naming when the last check ran")
        return String(format: format, last.formatted(date: .abbreviated, time: .shortened))
    }

    // MARK: - Deleting What Saving Off Leaves Behind

    /// Offers to delete the saved history when the user switches saving off.
    ///
    /// `persistenceEnabled` only guards the writes and the load at launch, so switching it off
    /// stops the history growing and removes nothing: every clip from before that moment stays on
    /// disk, invisible in the popover, which is the opposite of what the toggle reads as. The
    /// offer is what closes that gap, and it is an offer rather than an automatic delete because
    /// someone may be turning saving off for a while and want their history back afterwards.
    ///
    /// Nothing is asked when there is nothing to delete: a store holding only favorites, or none
    /// at all, has no question worth putting in front of anyone.
    private func offerToDeleteSavedHistory() {
        guard let clipboardMonitor else { return }

        clipboardMonitor.summariseSavedHistory { summary in
            guard summary.clearableCount > 0 else { return }
            purgeSummary = summary
            showPurgeOffer = true
        }
    }

    /// What the alert says. Split out because it has to be exact rather than reassuring: it names
    /// the count, says what survives, and does not promise the number on disk drops to zero.
    private func purgeExplanation(for summary: PersistenceManager.SavedHistorySummary) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: summary.byteCount, countStyle: .file)
        var lines = [
            String(
                format: L10n.string(
                    "Turning saving off stops new clips being written. It does not remove the %d items already saved, which stay on disk, using %@, until something deletes them.",
                    comment: "Explains that disabling persistence leaves the existing store in place"
                ),
                summary.clearableCount,
                bytes
            )
        ]

        if summary.favoriteCount > 0 {
            lines.append(String(
                format: L10n.string(
                    "Deleting removes those %d items and the images behind them. Your %d favorites are kept, as they are by every other clear.",
                    comment: "Explains what the purge removes and that favorites survive"
                ),
                summary.clearableCount,
                summary.favoriteCount
            ))
        } else {
            lines.append(String(
                format: L10n.string(
                    "Deleting removes those %d items and the images behind them. Favorites are always kept; you have none.",
                    comment: "Explains what the purge removes when there are no favorites"
                ),
                summary.clearableCount
            ))
        }

        return lines.joined(separator: "\n\n")
    }

    /// Deletes the saved history through the same path as Clear History, so favorites are spared
    /// by the one `AND` in `bulkDeleteNonFavorites` rather than by a second rule that could drift.
    private func deleteSavedHistory(_ summary: PersistenceManager.SavedHistorySummary) {
        guard let clipboardMonitor else { return }

        clipboardMonitor.clearHistory()
        purgeMessage = summary.favoriteCount > 0
            ? String(
                format: L10n.string(
                    "Deleted %d saved items. %d favorites were kept.",
                    comment: "Shown after deleting the saved history"
                ),
                summary.clearableCount,
                summary.favoriteCount
            )
            : String(
                format: L10n.string(
                    "Deleted %d saved items.",
                    comment: "Shown after deleting the saved history when there are no favorites"
                ),
                summary.clearableCount
            )
    }

    private func formatStorageSize(_ mb: Int) -> String {
        if mb >= 1000 {
            return String(format: "%.1fGB", Double(mb) / 1000.0)
        } else {
            return "\(mb)MB"
        }
    }

    /// Favorites are the one thing in the history a user is told is permanent, so they get a way
    /// to take a copy out of the app. Reading the store and encoding happen off the main thread:
    /// image favorites are megabytes each.
    private func exportFavorites() {
        let panel = NSSavePanel()
        panel.title = L10n.string("Export Favorites", comment: "Save panel title")
        panel.nameFieldStringValue = FavoritesExport.suggestedFileName()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.zip]
        // Hidden favorites are included, so say so before anything is written to disk.
        panel.message = L10n.string(
            "Favorites are exported as readable text, including any that are hidden. Choose somewhere you trust.",
            comment: "Save panel message warning that the export is not encrypted"
        )

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        exportState = .working

        DispatchQueue.global(qos: .userInitiated).async {
            let favorites = PersistenceManager.shared.loadFavorites()
            let outcome: ExportState

            do {
                let count = try FavoritesExport.write(favorites, to: destination)
                outcome = .exported(count: count)
            } catch {
                Logging.info("Favorites export failed: \(error.localizedDescription)")
                outcome = .failed(reason: error.localizedDescription)
            }

            DispatchQueue.main.async {
                exportState = outcome
                if case .exported = outcome {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            }
        }
    }
}

/// Apps whose clips are never recorded.
///
/// The list holds bundle identifiers, because that is what a capture is matched against. Names and
/// icons are resolved for display only, so an app the user has since uninstalled still reads as
/// excluded instead of dropping off the list without explanation.
struct ExcludedAppsSection: View {
    @ObservedObject var preferences: UserPreferencesManager
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Never save clips from these apps")
                Spacer()
                Button("Add App…") {
                    chooseApp()
                }
                .controlSize(.small)
            }

            if preferences.excludedBundleIdentifiers.isEmpty {
                Text("No apps are excluded.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(preferences.excludedBundleIdentifiers, id: \.self) { bundleIdentifier in
                        ExcludedAppRow(bundleIdentifier: bundleIdentifier) {
                            preferences.removeExcludedApp(bundleIdentifier)
                            message = nil
                        }
                    }
                }
            }

            // The honest version of the limit rather than a claim the polling cannot support.
            Text("Copy while one of these apps is in front and the clip is not saved. MacClipboard checks the clipboard every 0.8 seconds, so the app in front when a change is noticed is a good guess at where the clip came from, not a certainty: copy and switch apps within the same moment and the clip is saved. The setting above does not depend on this guess, because the source app marks those clips itself.")
                .font(.caption)
                .foregroundColor(.secondary)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = L10n.string("Exclude an App", comment: "Open panel title for picking an app to exclude from capture")
        panel.message = L10n.string(
            "Choose an app whose clips should never be saved.",
            comment: "Open panel message for picking an app to exclude from capture"
        )
        panel.prompt = L10n.string("Exclude", comment: "Open panel confirm button for excluding an app")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let name = FileManager.default.displayName(atPath: url.path)

        guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier, !bundleIdentifier.isEmpty else {
            message = String(
                format: L10n.string(
                    "%@ has no bundle identifier, so its clips cannot be told apart from another app's.",
                    comment: "Shown when a chosen app cannot be excluded"
                ),
                name
            )
            return
        }

        if preferences.excludedBundleIdentifiers.contains(bundleIdentifier) {
            message = String(
                format: L10n.string("%@ is already excluded.", comment: "Shown when an app is picked twice"),
                name
            )
            return
        }

        preferences.addExcludedApp(bundleIdentifier)
        message = nil
    }
}

/// One row of the excluded apps list. Resolving the name and icon here keeps the stored preference
/// to the identifier that is actually matched at capture time.
struct ExcludedAppRow: View {
    let bundleIdentifier: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "questionmark.app.dashed")
                    .frame(width: 16, height: 16)
                    .foregroundColor(.secondary)
            }

            Text(displayName)
                .font(.caption)

            if applicationURL == nil {
                Text("not installed")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                onRemove()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(Text("Stop excluding this app"))
            .accessibilityLabel(Text("Stop excluding \(displayName)"))
        }
        .help(bundleIdentifier)
    }

    private var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    private var displayName: String {
        guard let applicationURL else { return bundleIdentifier }
        return FileManager.default.displayName(atPath: applicationURL.path)
    }

    private var icon: NSImage? {
        guard let applicationURL else { return nil }
        return NSWorkspace.shared.icon(forFile: applicationURL.path)
    }
}

/// Shown only when something about the install will break permissions: a second copy of the app,
/// or a copy running from somewhere macOS cannot keep a grant for.
///
/// The same problems are raised once at launch, but a user who clicked past that alert has no
/// other way to find out why auto-paste keeps failing, so the panel keeps offering the fix.
struct InstallationHealthSection: View {
    @ObservedObject var installation: InstallationHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Installation")
                    .font(.headline)
            }

            if let problem = installation.locationProblem {
                Text(AppInstallation.description(of: problem))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("Move to Applications") {
                    installation.moveToApplications()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if !installation.duplicates.isEmpty {
                Text("More than one copy of MacClipboard is installed. macOS grants Accessibility access to one specific copy, so extra copies make auto-paste stop working even while the switch stays on in System Settings.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Running: \(installation.ownPath)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    ForEach(installation.duplicates) { copy in
                        Text("Also installed: \(copy.displayPath) (\(copy.displayVersion))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }

                HStack(spacing: 8) {
                    Button("Show in Finder") {
                        installation.reveal()
                    }
                    .controlSize(.small)

                    Button("Move Others to Trash") {
                        installation.trashDuplicates()
                    }
                    .controlSize(.small)
                }
            }

            if let message = installation.actionMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
    }
}

/// Small "Dev" / "Release" tag so the running build is never in doubt.
struct BuildChannelBadge: View {
    var body: some View {
        Text(BuildInfo.channelName)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(BuildInfo.isDevBuild ? Color.orange.opacity(0.18) : Color.secondary.opacity(0.15))
            )
            .foregroundColor(BuildInfo.isDevBuild ? .orange : .secondary)
            .help(BuildInfo.diagnosticSummary)
            .accessibilityLabel(Text("Build channel: \(BuildInfo.channelName)"))
    }
}

/// Records the next key press as the global hotkey.
///
/// A local event monitor rather than a first-responder view: the combinations worth recording are
/// exactly the ones that are already key equivalents somewhere (⌘⇧V is Paste and Match Style, ⌥⌘C
/// is Copy Style), and a monitor sees a key event before `performKeyEquivalent` gets a chance to
/// act on it. Returning nil from the monitor is what stops the rest of the app from also
/// responding to the keys being recorded, including this window's own Done button.
struct GlobalHotkeyRecorder: View {
    @ObservedObject var preferences: UserPreferencesManager
    let menuBarController: MenuBarController?

    @State private var isRecording = false
    @State private var eventMonitor: Any?
    @State private var heldModifiers: UInt32 = 0
    @State private var rejection: GlobalHotkeyRejection?

    private static let escapeKeyCode: UInt16 = 53

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: toggleRecording) {
                    Text(fieldLabel)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 130)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.bordered)
                .help(isRecording
                      ? Text("Press the combination you want, or Escape to leave it as it was.")
                      : Text("Click, then press the combination you want."))
                .accessibilityLabel(Text("Global hotkey"))
                .accessibilityValue(Text(preferences.globalHotkey.displayString))

                if isRecording {
                    Button("Cancel") { stopRecording() }
                        .buttonStyle(.borderless)
                } else if preferences.globalHotkey != .defaultForCurrentBuild {
                    Button("Reset to \(GlobalHotkeyShortcut.defaultForCurrentBuild.displayString)") {
                        preferences.globalHotkey = .defaultForCurrentBuild
                        rejection = nil
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let rejection {
                Text(rejection.message)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let menuBarController {
                GlobalHotkeyAvailabilityNote(
                    menuBarController: menuBarController,
                    shortcut: preferences.globalHotkey
                )
            }
        }
        .onDisappear { stopRecording() }
        // Clicking into another app while recording would otherwise leave the hotkey suspended and
        // the field waiting for a key press nobody is about to make.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            stopRecording()
        }
        // The toggle above is not disabled while recording, and switching it off disables this
        // whole control, Cancel included. Stopping here is what keeps that from stranding a
        // monitor that would swallow the next key press.
        .onChange(of: preferences.hotKeyEnabled) { enabled in
            if !enabled { stopRecording() }
        }
    }

    private var fieldLabel: String {
        guard isRecording else { return preferences.globalHotkey.displayString }

        let held = GlobalHotkeyShortcut.modifierDisplayString(heldModifiers, spaced: true)
        return held.isEmpty
            ? L10n.string("Type a shortcut", comment: "Global hotkey recorder, waiting for a key press")
            : held + " …"
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard !isRecording, eventMonitor == nil else { return }

        rejection = nil
        heldModifiers = 0
        isRecording = true
        menuBarController?.setGlobalHotkeyRecording(true)

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event) ? nil : event
        }
    }

    private func stopRecording() {
        guard isRecording || eventMonitor != nil else { return }

        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        isRecording = false
        heldModifiers = 0
        menuBarController?.setGlobalHotkeyRecording(false)
    }

    /// True when the event was consumed by the recorder.
    private func handle(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }

        if event.type == .flagsChanged {
            heldModifiers = GlobalHotkeyShortcut.carbonModifiers(from: event.modifierFlags)
            return true
        }

        guard event.type == .keyDown else { return false }

        // Escape on its own is the way out. With a modifier held it is an ordinary candidate:
        // ⌃⌥⎋ is a perfectly good hotkey.
        let modifiers = GlobalHotkeyShortcut.carbonModifiers(from: event.modifierFlags)
        if event.keyCode == Self.escapeKeyCode, modifiers == 0 {
            stopRecording()
            return true
        }

        let candidate = GlobalHotkeyShortcut(event: event)
        if let reason = candidate.rejection {
            // Stay in recording mode: the user still has to type something, and the message says
            // what would make the next attempt work.
            rejection = reason
            return true
        }

        rejection = nil
        preferences.globalHotkey = candidate
        stopRecording()
        return true
    }
}

/// Says when macOS refused the shortcut, which it does when another app registered it first.
///
/// Split out so it can hold the `@ObservedObject`: the controller is optional in `SettingsView`,
/// which a property wrapper cannot be.
private struct GlobalHotkeyAvailabilityNote: View {
    @ObservedObject var menuBarController: MenuBarController
    let shortcut: GlobalHotkeyShortcut

    var body: some View {
        if menuBarController.isGlobalHotkeyUnavailable {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("\(shortcut.displayString) is already taken by another app, so it will not open MacClipboard. Record a different one, or quit the other app and switch the hotkey off and on again.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundColor(.orange)
        }
    }
}

struct ShortcutHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                )

            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    SettingsView(onDismiss: {}, onCheckForUpdates: {})
}
