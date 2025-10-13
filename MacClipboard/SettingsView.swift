import SwiftUI

struct SettingsView: View {
    @ObservedObject private var preferences = UserPreferencesManager.shared
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("MacClipboard Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Configure clipboard history and behavior")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            // Clipboard History Settings
            VStack(alignment: .leading, spacing: 12) {
                Text("Clipboard History")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Maximum items:")
                            .frame(width: 120, alignment: .leading)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Slider(
                                value: Binding(
                                    get: { Double(preferences.maxClipboardItems) },
                                    set: { preferences.maxClipboardItems = Int($0) }
                                ),
                                in: Double(UserPreferencesManager.minClipboardItems)...Double(UserPreferencesManager.maxClipboardItems),
                                step: 10
                            ) {
                                Text("Max Items")
                            } minimumValueLabel: {
                                Text("\(UserPreferencesManager.minClipboardItems)")
                                    .font(.caption)
                            } maximumValueLabel: {
                                Text("\(UserPreferencesManager.maxClipboardItems)")
                                    .font(.caption)
                            }
                            
                            Text("\(preferences.maxClipboardItems) items")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Text("Older items will be automatically removed when the limit is reached.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 120)
                }
            }
            
            Divider()
            
            // Additional Settings (for future expansion)
            VStack(alignment: .leading, spacing: 12) {
                Text("Global Hotkey")
                    .font(.headline)
                
                HStack {
                    Toggle("Enable global hotkey (⌘⇧V)", isOn: $preferences.hotKeyEnabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                if !preferences.hotKeyEnabled {
                    Text("Global hotkey is disabled. You can still access clipboard via menu bar.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Bottom buttons
            HStack {
                Button("Reset to Defaults") {
                    preferences.resetToDefaults()
                }
                .buttonStyle(.borderless)
                
                Spacer()
                
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400, height: 300)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

#Preview {
    SettingsView()
}