import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject private var preferences = UserPreferencesManager.shared
    @StateObject private var installation = InstallationHealth()
    @State private var exportState: ExportState = .idle
    @State private var purgeSummary: PersistenceManager.SavedHistorySummary?
    @State private var showPurgeOffer = false
    @State private var purgeMessage: String?
    /// Whatever the app is actually running over, so a purge reaches the same store the popover
    /// shows and the in-memory history is left in step with it. Optional because the SwiftUI
    /// preview builds this view without an app around it.
    private let clipboardMonitor: ClipboardMonitor?
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
        onDismiss: @escaping () -> Void = {},
        onCheckForUpdates: @escaping () -> Void = {}
    ) {
        self.clipboardMonitor = clipboardMonitor
        self.onDismiss = onDismiss
        self.onCheckForUpdates = onCheckForUpdates
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

                        Toggle("Global hotkey (\(GlobalHotkey.displayString))", isOn: $preferences.hotKeyEnabled)

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

                Button("Check for Updates") {
                    onCheckForUpdates()
                }
                .buttonStyle(.link)
                .font(.caption)

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
