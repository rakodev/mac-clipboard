import SwiftUI

struct SettingsView: View {
    @ObservedObject private var preferences = UserPreferencesManager.shared
    let onDismiss: () -> Void
    let onCheckForUpdates: () -> Void

    init(onDismiss: @escaping () -> Void = {}, onCheckForUpdates: @escaping () -> Void = {}) {
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

                        Toggle("Save clipboard history", isOn: $preferences.persistenceEnabled)

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
                                in: 100...5000,
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

                        Text("Favorites are kept indefinitely.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // Shortcuts Settings
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Shortcuts")
                            .font(.headline)

                        Toggle("Global hotkey (⌘ ⇧ V)", isOn: $preferences.hotKeyEnabled)

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
                }
            }

            Divider()

            // Footer
            HStack {
                Text("MacClipboard v\(appVersion)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("·")
                    .foregroundColor(.secondary)

                Button("GitHub") {
                    if let url = URL(string: "https://github.com") {
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
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    private func formatStorageSize(_ mb: Int) -> String {
        if mb >= 1000 {
            return String(format: "%.1fGB", Double(mb) / 1000.0)
        } else {
            return "\(mb)MB"
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
