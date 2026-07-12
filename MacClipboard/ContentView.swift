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

struct ClipboardFilter {
    static func filteredItems(
        from items: [ClipboardItem],
        selectedFilter: FilterTab,
        searchText: String
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

        guard !searchText.isEmpty else { return filtered }

        filtered = filtered.filter { item in
            let previewMatch = item.previewText.localizedCaseInsensitiveContains(searchText)
            let fullTextMatch = item.fullText.localizedCaseInsensitiveContains(searchText)
            let noteMatch = item.note?.localizedCaseInsensitiveContains(searchText) ?? false
            return previewMatch || fullTextMatch || noteMatch
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

struct ContentView: View {
    @ObservedObject var clipboardMonitor: ClipboardMonitor
    let menuBarController: MenuBarController
    @State private var selectedItem: ClipboardItem?
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var filterTask: Task<Void, Never>?
    @State private var computedFilteredItems: [ClipboardItem] = []
    @State private var pendingSearchCharacter: String?
    @State private var selectedIndex: Int = 0
    @State private var showImageModal = false
    @State private var selectedFilter: FilterTab = .all
    @State private var showClearConfirmation = false
    @State private var showDeleteAllConfirmation = false  // Second confirmation for delete all
    @State private var selectedItemIds: Set<UUID> = []  // For multi-selection
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isNoteFocused: Bool
    @State private var timeAgoCache: [UUID: String] = [:]
    @State private var editingNote: String = ""
    @State private var revealedSensitiveIds: Set<UUID> = []  // Temporarily revealed sensitive items
    @State private var loadingImageIds: Set<UUID> = []  // Images currently being loaded from disk
    @State private var loadedImages: [UUID: NSImage] = [:]  // Cache for lazy-loaded images
    @State private var showShortcuts: Bool = false
    @State private var isScrolledDown: Bool = false
    @State private var shouldResetSelectionAfterFilterChange = false

    @ObservedObject private var permissionManager: PermissionManager
    @ObservedObject private var userPreferences = UserPreferencesManager.shared
    
    init(clipboardMonitor: ClipboardMonitor, menuBarController: MenuBarController) {
        self.clipboardMonitor = clipboardMonitor
        self.menuBarController = menuBarController
        self.permissionManager = menuBarController.permissionManager
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

        filterTask = Task.detached(priority: .userInitiated) {
            let filtered = ClipboardFilter.filteredItems(
                from: items,
                selectedFilter: filter,
                searchText: searchQuery
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
        let baseHeight: CGFloat = 78  // header + search + filter picker + minimal padding
        let itemHeight: CGFloat = 32  // Compact row height
        
        // Calculate items to show based on available content
        let itemCount = filteredItems.count
        let minItemsToShow: Int = min(itemCount, 6)  // Show at least 6 items if available
        let maxItemsToShow = min(itemCount, 16)     // Max items for horizontal layout
        let itemsToShow = max(minItemsToShow, min(maxItemsToShow, itemCount))
        
        let listHeight = CGFloat(itemsToShow) * itemHeight
        
        // Permission banner height (when shown)
        let permissionHeight: CGFloat = !permissionManager.isAccessibilityGranted ? 80 : 0
        
        // Calculate total height (no additional preview height since it's now horizontal)
        let totalHeight = baseHeight + permissionHeight + listHeight
        
        // Set a minimum height to ensure preview is always visible
        // This is especially important when there's only 1 item
        let minimumHeight: CGFloat = 325  // Enough space for header + search + list + preview
        
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

            if showShortcuts {
                ShortcutReferenceView()
            } else if filteredItems.isEmpty {
                ClipboardEmptyStateView(selectedFilter: selectedFilter)
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
                            onSaveNote: {
                                saveNote(for: selectedItem)
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

            // Initialize filtered items immediately
            computedFilteredItems = clipboardMonitor.clipboardHistory
            recomputeFilteredItems()

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
        .onDisappear {
            // Save any pending note when popover closes
            saveCurrentNote()
            // Cancel any pending tasks
            searchDebounceTask?.cancel()
            filterTask?.cancel()
            // Clear revealed sensitive items when popover closes
            revealedSensitiveIds.removeAll()
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
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce for smooth typing
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
            if shouldResetSelectionAfterFilterChange {
                shouldResetSelectionAfterFilterChange = false
                selectedIndex = 0
                selectedItemIds.removeAll()
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
            selectedItemIds.removeAll()
            isScrolledDown = false
            // Recompute when filter tab changes
            recomputeFilteredItems()
        }
        .onChange(of: clipboardMonitor.clipboardHistory) { _ in
            // Recompute when clipboard history changes
            recomputeFilteredItems()
            // Reset selection if needed
            if !filteredItems.isEmpty && selectedIndex >= filteredItems.count {
                selectedIndex = 0
                updateSelectedItem()
            }
        }
        .onChange(of: isSearchFocused) { focused in
            // Apply pending character after search field gains focus
            if focused, let char = pendingSearchCharacter {
                pendingSearchCharacter = nil
                // Small delay to ensure TextField is ready and any auto-selection has occurred
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    // Setting searchText replaces any selection
                    self.searchText = char
                }
            }
        }
        .background(KeyEventHandler { keyEvent in
            handleKeyEvent(keyEvent)
        })
        .clipboardDeletionConfirmation(
            selectedItem: selectedItem,
            selectedItemIds: $selectedItemIds,
            itemCount: clipboardMonitor.clipboardHistory.count,
            showDeleteConfirmation: $showClearConfirmation,
            showDeleteAllConfirmation: $showDeleteAllConfirmation,
            onDeleteCurrent: { item in
                clipboardMonitor.deleteItems(withIds: [item.id])
            },
            onDeleteSelected: { ids in
                clipboardMonitor.deleteItems(withIds: ids)
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
            ProjectTitleLink()

            Spacer()

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
            
            TextField("Search clipboard... (or just start typing)", text: $searchText)
                .textFieldStyle(PlainTextFieldStyle())
                .focused($isSearchFocused)
                .onSubmit {
                    // When user presses enter in search, paste the selected item immediately
                    isSearchFocused = false
                    pasteSelectedItem()
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color(NSColor.controlBackgroundColor))
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
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                            ClipboardItemRow(
                                item: item,
                                index: index,
                                isSelected: selectedIndex == index,
                                isMultiSelected: selectedItemIds.contains(item.id),
                                isRevealed: revealedSensitiveIds.contains(item.id),
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
                                onToggleReveal: {
                                    if revealedSensitiveIds.contains(item.id) {
                                        revealedSensitiveIds.remove(item.id)
                                    } else {
                                        revealedSensitiveIds.insert(item.id)
                                    }
                                },
                                timeAgoText: timeAgoCache[item.id] ?? "unknown"
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
                .id("listview-\(searchText)-\(selectedFilter.rawValue)") // Force refresh when search or filter changes
                .onChange(of: selectedIndex) { newIndex in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if newIndex < filteredItems.count {
                            proxy.scrollTo(filteredItems[newIndex].id, anchor: .center)
                        }
                    }
                }

                if isScrolledDown {
                    Button(action: {
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
                    .help("Scroll to top (⌘↑)")
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
    
    // MARK: - Navigation Functions
    
    private func navigateUp() {
        // Always navigate, unfocus search if needed
        if isSearchFocused {
            isSearchFocused = false
        }
        selectedIndex = max(0, selectedIndex - 1)
        updateSelectedItem()
    }

    private func navigateDown() {
        // Always navigate, unfocus search if needed
        if isSearchFocused {
            isSearchFocused = false
        }
        selectedIndex = min(filteredItems.count - 1, selectedIndex + 1)
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

    private func handleNumberKey(_ number: Int) {
        guard !filteredItems.isEmpty else { return }
        
        // Number 0 is the most recent (index 0), number 9 is the 10th most recent (index 9)
        let targetIndex = number
        
        if targetIndex < filteredItems.count {
            selectedIndex = targetIndex
            isSearchFocused = false
            updateSelectedItem()
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
            self.menuBarController.updatePopoverSize(to: NSSize(width: 520, height: self.dynamicHeight))
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
        switch keyEvent.keyCode {
        case 126: // Up arrow
            if keyEvent.modifierFlags.contains(.command) {
                selectedIndex = 0
                updateSelectedItem()
                return true
            }
            navigateUp()
            return true
        case 125: // Down arrow
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
                isSearchFocused = false
            }
            pasteSelectedItem()
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
                isSearchFocused = false
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
        case 45: // N key
            if keyEvent.modifierFlags.contains(.command) && userPreferences.shortcutsEnabled {
                if isNoteFocused {
                    if let item = selectedItem { saveNote(for: item) }
                    isNoteFocused = false
                } else {
                    isSearchFocused = false
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
            isSearchFocused.toggle()
            return true
        case 29: if !isSearchFocused { handleNumberKey(0); return true }
        case 18: if !isSearchFocused { handleNumberKey(1); return true }
        case 19: if !isSearchFocused { handleNumberKey(2); return true }
        case 20: if !isSearchFocused { handleNumberKey(3); return true }
        case 21: if !isSearchFocused { handleNumberKey(4); return true }
        case 23: if !isSearchFocused { handleNumberKey(5); return true }
        case 22: if !isSearchFocused { handleNumberKey(6); return true }
        case 26: if !isSearchFocused { handleNumberKey(7); return true }
        case 28: if !isSearchFocused { handleNumberKey(8); return true }
        case 25: if !isSearchFocused { handleNumberKey(9); return true }
        default:
            if let characters = keyEvent.characters,
               !characters.isEmpty,
               !isSearchFocused,
               !isNoteFocused,
               isPrintableCharacter(keyEvent) {
                // Store the character and focus the search field
                // The character will be applied after focus is confirmed
                pendingSearchCharacter = characters
                isSearchFocused = true
                return true
            }
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
        "Are you sure? This will permanently delete ALL \(itemCount) items from your clipboard history. This action cannot be undone."
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
    let onToggleFavorite: () -> Void
    let onToggleSensitive: () -> Void
    let onToggleReveal: () -> Void
    let onReveal: () -> Void
    let onLoadImage: () -> Void
    let onSaveNote: () -> Void

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

            Button("Copy ⏎", action: onCopy)
                .buttonStyle(.bordered)
                .font(.caption)
                .controlSize(.small)
        }
    }

    private var metadataRow: some View {
        HStack(spacing: 8) {
            switch item.type {
            case .text:
                textMetadata
            case .image:
                imageMetadata
            case .file:
                fileMetadata
            }
            Spacer()
        }
        .padding(.top, 2)
    }

    @ViewBuilder private var textMetadata: some View {
        let charCount = item.fullText.count
        let lineCount = item.fullText.components(separatedBy: .newlines).count
        Text("\(charCount) chars")
            .font(.system(size: 10))
            .foregroundColor(.secondary)
        if lineCount > 1 {
            Text("•")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.6))
            Text("\(lineCount) lines")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
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

    private var previewContent: some View {
        ScrollView {
            if isMasked {
                maskedContent
            } else {
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
            Text(item.fullText)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(nil)
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

struct ClipboardItemRow: View {
    let item: ClipboardItem
    let index: Int
    let isSelected: Bool
    let isMultiSelected: Bool
    let isRevealed: Bool
    let onSelect: () -> Void
    let onCopy: () -> Void
    let onToggleFavorite: () -> Void
    let onToggleMultiSelect: () -> Void
    let onToggleReveal: () -> Void
    let timeAgoText: String

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
            } else if item.type == .image, !shouldMask, item.isImageLoaded, let image = item.content as? NSImage {
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
                    Text(timeAgoText)
                    if item.note != nil && !(item.note?.isEmpty ?? true) {
                        Image(systemName: "note.text")
                            .font(.system(size: 8))
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
                    ("⌘⇧V", "Open clipboard"),
                ])

                ShortcutReferenceSection(title: "Navigation", shortcuts: [
                    ("↑ / ↓", "Navigate items"),
                    ("⌘↑", "Scroll to top"),
                    ("← / →", "Switch filter tabs"),
                    ("0–9", "Quick paste by position"),
                    ("Tab", "Focus search"),
                ])

                ShortcutReferenceSection(title: "Actions", shortcuts: [
                    ("Enter", "Paste selected item"),
                    ("⌘D", "Toggle favorite"),
                    ("⌘H", "Toggle sensitive"),
                    ("⌘V", "Reveal sensitive item"),
                    ("⌘N", "Focus note field"),
                    ("⌘Z", "Full-size image preview"),
                    ("⌘⌫", "Delete item(s)"),
                    ("⌘F", "Toggle favorites filter"),
                    ("⌘/", "Show shortcuts"),
                    ("Esc", "Close / unfocus"),
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