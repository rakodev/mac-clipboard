import SwiftUI
import CoreGraphics
import ApplicationServices

struct ContentView: View {
    @ObservedObject var clipboardMonitor: ClipboardMonitor
    let menuBarController: MenuBarController
    @State private var selectedItem: ClipboardItem?
    @State private var searchText = ""
    @State private var selectedIndex: Int = 0
    @State private var showImageModal = false
    @State private var showFavoritesOnly = false
    @State private var showClearConfirmation = false
    @State private var showDeleteAllConfirmation = false  // Second confirmation for delete all
    @State private var selectedItemIds: Set<UUID> = []  // For multi-selection
    @FocusState private var isSearchFocused: Bool
    @State private var timeAgoCache: [UUID: String] = [:]

    @ObservedObject private var permissionManager: PermissionManager
    @ObservedObject private var userPreferences = UserPreferencesManager.shared
    
    init(clipboardMonitor: ClipboardMonitor, menuBarController: MenuBarController) {
        self.clipboardMonitor = clipboardMonitor
        self.menuBarController = menuBarController
        self.permissionManager = menuBarController.permissionManager
    }
    
    private var filteredItems: [ClipboardItem] {
        var items = clipboardMonitor.clipboardHistory

        // Filter by favorites if enabled
        if showFavoritesOnly {
            items = items.filter { $0.isFavorite }
        }

        // Then filter by search text
        if !searchText.isEmpty {
            items = items.filter { item in
                let previewMatch = item.previewText.localizedCaseInsensitiveContains(searchText)
                let fullTextMatch = item.fullText.localizedCaseInsensitiveContains(searchText)
                return previewMatch || fullTextMatch
            }
        }

        return items
    }
    
    private var dynamicHeight: CGFloat {
        let baseHeight: CGFloat = 78  // header + search + filter picker + minimal padding
        let itemHeight: CGFloat = 32  // Compact row height
        
        // Calculate items to show based on available content
        let itemCount = filteredItems.count
        let minItemsToShow: Int = min(itemCount, 5)  // Show at least 5 items if available
        let maxItemsToShow = min(itemCount, 12)     // Reduced max items for horizontal layout
        let itemsToShow = max(minItemsToShow, min(maxItemsToShow, itemCount))
        
        let listHeight = CGFloat(itemsToShow) * itemHeight
        
        // Permission banner height (when shown)
        let permissionHeight: CGFloat = !permissionManager.isAccessibilityGranted ? 80 : 0
        
        // Calculate total height (no additional preview height since it's now horizontal)
        let totalHeight = baseHeight + permissionHeight + listHeight
        
        // Set a minimum height to ensure preview is always visible
        // This is especially important when there's only 1 item
        let minimumHeight: CGFloat = 250  // Enough space for header + search + list + preview
        
        // Get screen height and limit to reasonable size
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 1000
        let maxAllowedHeight = screenHeight * 0.6 // Reduced to 60% for cleaner look
        
        let finalHeight = max(minimumHeight, min(totalHeight, maxAllowedHeight))
        
        return finalHeight
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            if !permissionManager.isAccessibilityGranted {
                permissionBanner
            }
            searchBarView
            filterPickerView

            if filteredItems.isEmpty {
                emptyStateView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if let selectedItem = selectedItem {
                    // Horizontal layout with list and preview side by side
                    HStack(spacing: 0) {
                        clipboardListView
                            .frame(width: 200)
                        Divider()
                        compactPreviewView(for: selectedItem)
                            .frame(width: 199)
                    }
                } else {
                    // Full width list when no preview
                    clipboardListView
                }
            }
        }
        .frame(width: 400, height: dynamicHeight, alignment: .top)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            // Initialize time cache when popover opens
            initializeTimeCache()
            
            // Ensure we have items and properly select the first one
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if !filteredItems.isEmpty {
                    selectedIndex = 0
                    updateSelectedItem()
                }
                // Update popover size after selection is set
                updatePopoverSize()
            }
        }
        .onChange(of: dynamicHeight) { newHeight in
            updatePopoverSize()
        }
        .onChange(of: filteredItems) { newItems in
            // Reset selection when filter changes
            selectedIndex = 0
            updateSelectedItem()
            // Update size when items change
            updatePopoverSize()
        }
        .onChange(of: clipboardMonitor.clipboardHistory) { _ in
            // Reset selection when clipboard history changes
            if !filteredItems.isEmpty && selectedIndex >= filteredItems.count {
                selectedIndex = 0
                updateSelectedItem()
            }
        }
        .background(KeyEventHandler { keyEvent in
            handleKeyEvent(keyEvent)
        })
        .alert(
            selectedItemIds.isEmpty ? "Delete Items" : "Delete Selected Items?",
            isPresented: $showClearConfirmation
        ) {
            if selectedItemIds.isEmpty {
                // No multi-selection: offer to delete current item or all
                Button("Cancel", role: .cancel) { }
                if let currentItem = selectedItem {
                    Button("Delete Current Item", role: .destructive) {
                        clipboardMonitor.deleteItems(withIds: [currentItem.id])
                    }
                }
                Button("Delete All \(clipboardMonitor.clipboardHistory.count) Items...") {
                    // Show second confirmation for delete all
                    showDeleteAllConfirmation = true
                }
            } else {
                // Multi-selection: delete selected items
                Button("Cancel", role: .cancel) { }
                Button("Delete \(selectedItemIds.count) Item\(selectedItemIds.count == 1 ? "" : "s")", role: .destructive) {
                    clipboardMonitor.deleteItems(withIds: selectedItemIds)
                    selectedItemIds.removeAll()
                }
            }
        } message: {
            if selectedItemIds.isEmpty {
                Text("Choose to delete the currently previewed item or clear all history.")
            } else {
                Text("This will permanently delete \(selectedItemIds.count) selected item\(selectedItemIds.count == 1 ? "" : "s"). This action cannot be undone.")
            }
        }
        .alert(
            "Delete All \(clipboardMonitor.clipboardHistory.count) Items?",
            isPresented: $showDeleteAllConfirmation
        ) {
            Button("Cancel", role: .cancel) { }
            Button("Yes, Delete All", role: .destructive) {
                clipboardMonitor.clearHistory()
            }
        } message: {
            Text("Are you sure? This will permanently delete ALL \(clipboardMonitor.clipboardHistory.count) items from your clipboard history. This action cannot be undone.")
        }
    }

    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Accessibility permission required for auto‑paste")
                    .font(.caption).bold()
                Text("Enable MacClipboard in System Settings > Privacy & Security > Accessibility. You can still copy items.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Button("Open Settings") {
                        permissionManager.openAccessibilitySettings()
                    }
                    .buttonStyle(.borderless)
                    Button("Retry") {
                        permissionManager.refreshPermission()
                    }
                    .buttonStyle(.borderless)
                    Button("Force Reset") {
                        permissionManager.forcePermissionPrompt()
                    }
                    .buttonStyle(.borderless)
                    .help("Force macOS to show accessibility permission prompt")
                }
            }
            Spacer()
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
        .overlay(Divider(), alignment: .bottom)
    }
    
    private var headerView: some View {
        HStack {
            Text("MacClipboard")
                .font(.headline)
                .foregroundColor(.primary)
            
            Spacer()
            
            Button(action: {
                menuBarController.showSettings()
            }) {
                Image(systemName: "gearshape")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Settings")
            
            Button(action: {
                showClearConfirmation = true
            }) {
                Image(systemName: "trash")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Clear History")
            
            Button(action: {
                menuBarController.hidePopover()
            }) {
                Image(systemName: "xmark")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Close")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private var searchBarView: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            
            TextField("Search clipboard... (or just start typing)", text: $searchText)
                .textFieldStyle(PlainTextFieldStyle())
                .focused($isSearchFocused)
                .onSubmit {
                    // When user presses enter in search, focus on list
                    isSearchFocused = false
                    if !filteredItems.isEmpty {
                        selectedIndex = 0
                        updateSelectedItem()
                    }
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var filterPickerView: some View {
        Picker("", selection: $showFavoritesOnly) {
            Text("All").tag(false)
            Text("Favorites").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("No clipboard history")
                .font(.title2)
                .foregroundColor(.secondary)
            
            Text("Copy something to get started")
                .font(.body)
                .foregroundColor(Color.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var clipboardListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<filteredItems.count, id: \.self) { index in
                        let item = filteredItems[index]
                        ClipboardItemRow(
                            item: item,
                            index: index,
                            isSelected: selectedIndex == index,
                            isMultiSelected: selectedItemIds.contains(item.id),
                            onSelect: {
                                selectedIndex = index
                                selectedItemIds.removeAll()  // Clear multi-selection on regular click
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
                            },
                            timeAgoText: timeAgoCache[item.id] ?? "unknown"
                        )
                        .id("filtered-\(item.id)-\(index)")
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .id("listview-\(searchText)") // Force refresh when search changes
            .onChange(of: selectedIndex) { newIndex in
                withAnimation(.easeInOut(duration: 0.2)) {
                    if newIndex < filteredItems.count {
                        proxy.scrollTo("filtered-\(filteredItems[newIndex].id)-\(newIndex)", anchor: .center)
                    }
                }
            }
        }
    }
    
    private func previewView(for item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preview")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Button("Copy") {
                    clipboardMonitor.copyToClipboard(item)
                    menuBarController.hidePopoverAndActivatePreviousApp()
                }
                .buttonStyle(.bordered)
                
                Button("×") {
                    selectedItem = nil
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(.secondary)
            }
            
            ScrollView {
                switch item.type {
                case .text:
                    Text(item.fullText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                case .image:
                    if let image = item.content as? NSImage {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 150)
                    }
                case .file:
                    Text(item.fullText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
            }
            .frame(maxHeight: 120)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .padding(.horizontal)
        .padding(.bottom)
    }
    
    private func compactPreviewView(for item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Preview")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Button("Copy") {
                    clipboardMonitor.copyToClipboard(item)
                    menuBarController.hidePopoverAndActivatePreviousApp()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .controlSize(.small)
            }
            
            ScrollView {
                switch item.type {
                case .text:
                    Text(item.fullText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(nil)
                case .image:
                    if let image = item.content as? NSImage {
                        ZStack {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 120)
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(4)
                            
                            // Zoom icon overlay - more visible
                            VStack {
                                HStack {
                                    Spacer()
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.white)
                                        .frame(width: 24, height: 24)
                                        .background(Circle().fill(Color.black.opacity(0.7)))
                                }
                                Spacer()
                            }
                            .padding(6)
                        }
                        .contentShape(Rectangle()) // Make entire area clickable
                        .onTapGesture {
                            showImageModal = true
                        }
                        .onHover { hovering in
                            // Add visual feedback on hover (hover state is handled by UI)
                        }
                        .help("Click to view full size with zoom")
                        .sheet(isPresented: $showImageModal) {
                            ImageModalView(image: image)
                        }
                    }
                case .file:
                    Text(item.fullText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(nil)
                }
            }
        }
        .padding(6)
        .background(Color(NSColor.controlBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    
    // MARK: - Navigation Functions
    
    private func navigateUp() {
        Logging.debug("Navigate up called - current selectedIndex: \(selectedIndex), isSearchFocused: \(isSearchFocused)")
        if isSearchFocused {
            // If search is focused, move to list
            isSearchFocused = false
            selectedIndex = max(0, filteredItems.count - 1)
        } else {
            selectedIndex = max(0, selectedIndex - 1)
        }
        Logging.debug("After navigate up - selectedIndex: \(selectedIndex)")
        updateSelectedItem()
    }
    
    private func navigateDown() {
        Logging.debug("Navigate down called - current selectedIndex: \(selectedIndex), isSearchFocused: \(isSearchFocused)")
        if isSearchFocused {
            // If search is focused, move to list
            isSearchFocused = false
            selectedIndex = 0
        } else {
            selectedIndex = min(filteredItems.count - 1, selectedIndex + 1)
        }
        Logging.debug("After navigate down - selectedIndex: \(selectedIndex)")
        updateSelectedItem()
    }
    
    private func updateSelectedItem() {
        guard !filteredItems.isEmpty else {
            selectedItem = nil
            Logging.debug("No filtered items - clearing selection")
            return
        }
        
        // Ensure selectedIndex is within bounds
        selectedIndex = max(0, min(selectedIndex, filteredItems.count - 1))
        
        // Update selected item
        if selectedIndex < filteredItems.count {
            selectedItem = filteredItems[selectedIndex]
            Logging.debug("Selected item updated to index \(selectedIndex): \(selectedItem?.previewText ?? "nil")")
        } else {
            selectedItem = nil
            Logging.debug("selectedIndex out of bounds - clearing selection")
        }
    }
    
    private func handleNumberKey(_ number: Int) {
        guard !filteredItems.isEmpty else { return }
        
        // Number 0 is the most recent (index 0), number 9 is the 10th most recent (index 9)
        let targetIndex = number
        
        if targetIndex < filteredItems.count {
            selectedIndex = targetIndex
            isSearchFocused = false // Ensure we're not in search mode
            updateSelectedItem()
            Logging.debug("Number \(number) pressed - jumped to index \(targetIndex)")
        } else {
            Logging.debug("Number \(number) pressed but not enough items (only \(filteredItems.count) available)")
        }
    }
    
    private func initializeTimeCache() {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let now = Date()
        
        timeAgoCache.removeAll()
        for item in clipboardMonitor.clipboardHistory {
            let timeString = formatter.localizedString(for: item.timestamp, relativeTo: now)
            timeAgoCache[item.id] = timeString
        }
    }
    
    private func updatePopoverSize() {
        DispatchQueue.main.async {
            self.menuBarController.updatePopoverSize(to: NSSize(width: 400, height: self.dynamicHeight))
        }
    }
    
    private func pasteSelectedItem() {
        guard let item = selectedItem else { return }
        pasteItem(item)
    }
    
    private func pasteItem(_ item: ClipboardItem) {
        // Copy item to clipboard
        clipboardMonitor.copyToClipboard(item)
        
        // Hide popover & activate previous app
        menuBarController.hidePopoverAndActivatePreviousApp()
        // Ask controller to schedule paste once previous app regains focus
        menuBarController.schedulePasteAfterActivation()
    }
    
    // MARK: - Key Event Handling
    
    private func handleKeyEvent(_ keyEvent: NSEvent) -> Bool {
        Logging.debug("Key event received: keyCode = \(keyEvent.keyCode)")
        
        switch keyEvent.keyCode {
        case 126: // Up arrow
            Logging.debug("Up arrow pressed")
            navigateUp()
            return true
        case 125: // Down arrow
            Logging.debug("Down arrow pressed")
            navigateDown()
            return true
        case 123: // Left arrow
            if !isSearchFocused {
                Logging.debug("Left arrow pressed - switching to All")
                showFavoritesOnly = false
                return true
            }
        case 124: // Right arrow
            if !isSearchFocused {
                Logging.debug("Right arrow pressed - switching to Favorites")
                showFavoritesOnly = true
                return true
            }
        case 36: // Return/Enter
            if !isSearchFocused {
                Logging.debug("Enter pressed - pasting selected item")
                pasteSelectedItem()
                return true
            }
        case 53: // Escape
            Logging.debug("Escape pressed - hiding popover and restoring focus")
            menuBarController.hidePopoverAndActivatePreviousApp()
            return true
        case 3: // F key
            if keyEvent.modifierFlags.contains(.command) && userPreferences.shortcutsEnabled {
                Logging.debug("Cmd+F pressed - toggling favorites filter")
                showFavoritesOnly.toggle()
                return true
            }
        case 2: // D key
            if keyEvent.modifierFlags.contains(.command) && userPreferences.shortcutsEnabled {
                if let item = selectedItem {
                    Logging.debug("Cmd+D pressed - toggling favorite for selected item")
                    clipboardMonitor.toggleFavorite(item)
                    return true
                }
            }
        case 6: // Z key
            if keyEvent.modifierFlags.contains(.command) && userPreferences.shortcutsEnabled {
                if let item = selectedItem, item.type == .image {
                    Logging.debug("Cmd+Z pressed - opening image preview")
                    showImageModal = true
                    return true
                }
            }
        case 48: // Tab
            Logging.debug("Tab pressed - toggling search focus")
            isSearchFocused.toggle()
            return true
        case 29: // 0
            if !isSearchFocused { handleNumberKey(0); return true }
        case 18: // 1
            if !isSearchFocused { handleNumberKey(1); return true }
        case 19: // 2
            if !isSearchFocused { handleNumberKey(2); return true }
        case 20: // 3
            if !isSearchFocused { handleNumberKey(3); return true }
        case 21: // 4
            if !isSearchFocused { handleNumberKey(4); return true }
        case 23: // 5
            if !isSearchFocused { handleNumberKey(5); return true }
        case 22: // 6
            if !isSearchFocused { handleNumberKey(6); return true }
        case 26: // 7
            if !isSearchFocused { handleNumberKey(7); return true }
        case 28: // 8
            if !isSearchFocused { handleNumberKey(8); return true }
        case 25: // 9
            if !isSearchFocused { handleNumberKey(9); return true }
        default:
            // Check if this is a printable character that should trigger search
            if let characters = keyEvent.characters, 
               !characters.isEmpty,
               !isSearchFocused,
               isPrintableCharacter(keyEvent) {
                Logging.debug("Printable character '\(characters)' - focusing search and adding to search text")
                // Focus first, then add the character to prevent text selection
                DispatchQueue.main.async {
                    self.isSearchFocused = true
                    // Add a small delay to ensure focus is set before adding text
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                        self.searchText = characters
                    }
                }
                return true
            }
            Logging.debug("Unhandled key: \(keyEvent.keyCode)")
            return false
        }
        return false
    }
    
    private func isPrintableCharacter(_ keyEvent: NSEvent) -> Bool {
        // Check if it's a printable character (letters, symbols, space)
        // Exclude special keys and number keys (used for navigation)
        guard let characters = keyEvent.characters, !characters.isEmpty else { return false }
        
        let char = characters.first!
        let keyCode = keyEvent.keyCode
        
        // Exclude special keys by keycode
        let specialKeyCodes: Set<UInt16> = [
            36,  // Enter
            48,  // Tab
            49,  // Space (we'll handle this specially)
            51,  // Delete
            53,  // Escape
            117, // Forward Delete
            123, 124, 125, 126, // Arrow keys
            96, 97, 98, 99, 100, 101, 103, 111, // Function keys F1-F8
            // Number keys (used for navigation)
            29, 18, 19, 20, 21, 23, 22, 26, 28, 25 // 0-9
        ]
        
        if specialKeyCodes.contains(keyCode) && keyCode != 49 { // Allow space (49)
            return false
        }
        
        // Check if character is printable (letters, symbols, space, but not digits)
        return (char.isPrintableASCII || char.isLetter || char.isSymbol || char == " ") && !char.isNumber
    }
}

struct ClipboardItemRow: View {
    let item: ClipboardItem
    let index: Int
    let isSelected: Bool
    let isMultiSelected: Bool
    let onSelect: () -> Void
    let onCopy: () -> Void
    let onToggleFavorite: () -> Void
    let onToggleMultiSelect: () -> Void
    let timeAgoText: String

    var body: some View {
        HStack(spacing: 8) {
            // Show number for first 10 items, icon for others
            if index < 10 {
                // Show number (0-9)
                Text("\(index)")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                    )
            } else if item.type == .image, let image = item.content as? NSImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                    )
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 12))
                    .foregroundColor(iconColor)
                    .frame(width: 20, height: 20)
            }

            // Content preview
            VStack(alignment: .leading, spacing: 1) {
                Text(item.previewText)
                    .font(.system(.callout, design: .default))
                    .lineLimit(1)
                    .foregroundColor(.primary)

                Text(timeAgoText)
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

            // Copy button (only visible on hover)
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .opacity(isSelected ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: isSelected)
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

struct KeyEventHandler: NSViewRepresentable {
    let onKeyEvent: (NSEvent) -> Bool
    
    func makeNSView(context: Context) -> NSView {
        let view = KeyEventView()
        view.onKeyEvent = onKeyEvent
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if let keyView = nsView as? KeyEventView {
            keyView.onKeyEvent = onKeyEvent
        }
    }
}

class KeyEventView: NSView {
    var onKeyEvent: ((NSEvent) -> Bool)?
    
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
                .background(Color.black.opacity(0.1))
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
                        // Single tap for debugging
                        print("Image tapped - current scale: \(scale)")
                    }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

extension Character {
    var isPrintableASCII: Bool {
        guard let asciiValue = self.asciiValue else { return false }
        return asciiValue >= 32 && asciiValue <= 126
    }
}

#Preview {
    ContentView(
        clipboardMonitor: ClipboardMonitor(),
        menuBarController: MenuBarController(clipboardMonitor: ClipboardMonitor())
    )
}