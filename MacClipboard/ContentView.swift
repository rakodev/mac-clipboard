import SwiftUI
import CoreGraphics
import ApplicationServices

enum FilterTab: String, CaseIterable {
    case all = "All"
    case favorites = "Favorites"
    case images = "Images"
    case hidden = "Hidden"
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
            // Filter by selected tab
            var filtered: [ClipboardItem]
            switch filter {
            case .all:
                filtered = items
            case .favorites:
                filtered = items.filter { $0.isFavorite }
            case .images:
                filtered = items.filter { $0.type == .image }
            case .hidden:
                filtered = items.filter { $0.isSensitive }
            }

            // Then filter by search text
            if !searchQuery.isEmpty {
                filtered = filtered.filter { item in
                    let previewMatch = item.previewText.localizedCaseInsensitiveContains(searchQuery)
                    let fullTextMatch = item.fullText.localizedCaseInsensitiveContains(searchQuery)
                    let noteMatch = item.note?.localizedCaseInsensitiveContains(searchQuery) ?? false
                    return previewMatch || fullTextMatch || noteMatch
                }

                // Sort search results: favorites first, then items with notes, then rest
                filtered = filtered.sorted { item1, item2 in
                    let score1 = (item1.isFavorite ? 2 : 0) + ((item1.note?.isEmpty == false) ? 1 : 0)
                    let score2 = (item2.isFavorite ? 2 : 0) + ((item2.note?.isEmpty == false) ? 1 : 0)
                    return score1 > score2
                }
            }

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

            if filteredItems.isEmpty {
                emptyStateView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if let selectedItem = selectedItem {
                    // Horizontal layout with list and preview side by side
                    HStack(spacing: 0) {
                        clipboardListView
                            .frame(width: 260)
                        Divider()
                        compactPreviewView(for: selectedItem)
                            .frame(width: 259)
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
            // Reset selection when filter changes
            selectedIndex = 0
            updateSelectedItem()
            // Update size when items change
            updatePopoverSize()
        }
        .onChange(of: selectedFilter) { _ in
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
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: emptyStateIcon)
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text(emptyStateTitle)
                .font(.title2)
                .foregroundColor(.secondary)

            Text(emptyStateSubtitle)
                .font(.body)
                .foregroundColor(Color.secondary)

            if let shortcut = emptyStateShortcut {
                Text(shortcut)
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateIcon: String {
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

    private var emptyStateTitle: String {
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

    private var emptyStateSubtitle: String {
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

    private var emptyStateShortcut: String? {
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
        let isMasked = item.isSensitive && !revealedSensitiveIds.contains(item.id)

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Preview")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)

                Spacer()

                // Toggle favorite button
                Button(action: {
                    clipboardMonitor.toggleFavorite(item)
                    // Update selectedItem immediately to keep preview in sync
                    if var updatedItem = selectedItem {
                        updatedItem.isFavorite.toggle()
                        selectedItem = updatedItem
                    }
                }) {
                    Image(systemName: item.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 12))
                        .foregroundColor(item.isFavorite ? .yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .help(item.isFavorite ? "Remove from favorites (⌘D)" : "Add to favorites (⌘D)")

                // Toggle sensitive button
                Button(action: {
                    clipboardMonitor.toggleSensitive(item)
                    // Update selectedItem immediately to keep preview in sync
                    if var updatedItem = selectedItem {
                        updatedItem.isSensitive.toggle()
                        selectedItem = updatedItem
                    }
                }) {
                    Image(systemName: item.isSensitive ? "lock.fill" : "lock.open")
                        .font(.system(size: 12))
                        .foregroundColor(item.isSensitive ? .orange : .secondary)
                }
                .buttonStyle(.borderless)
                .help(item.isSensitive ? "Remove sensitive flag (⌘H)" : "Mark as sensitive (⌘H)")

                // Reveal/Hide button for sensitive items
                if item.isSensitive {
                    Button(action: {
                        if revealedSensitiveIds.contains(item.id) {
                            revealedSensitiveIds.remove(item.id)
                        } else {
                            revealedSensitiveIds.insert(item.id)
                        }
                    }) {
                        Image(systemName: isMasked ? "eye" : "eye.slash")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .help(isMasked ? "Reveal content (⌘V)" : "Hide content (⌘V)")
                }

                Button("Copy ⏎") {
                    clipboardMonitor.copyToClipboard(item)
                    menuBarController.hidePopoverAndActivatePreviousApp()
                }
                .buttonStyle(.bordered)
                .font(.caption)
                .controlSize(.small)
            }

            // Metadata row
            HStack(spacing: 8) {
                if item.type == .text {
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
                } else if item.type == .image {
                    if let image = (item.content as? NSImage) ?? loadedImages[item.id] {
                        let width = Int(image.size.width)
                        let height = Int(image.size.height)
                        Text("\(width) × \(height) px")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                } else if item.type == .file {
                    if let urls = item.content as? [URL] {
                        Text("\(urls.count) file\(urls.count == 1 ? "" : "s")")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.top, 2)

            ScrollView {
                if isMasked {
                    // Masked content view
                    VStack(spacing: 12) {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)

                        Text("Sensitive content hidden")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button("Click to reveal") {
                            revealedSensitiveIds.insert(item.id)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 20)
                } else {
                    switch item.type {
                    case .text:
                        Text(item.fullText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(nil)
                    case .image:
                        // Get image from item or from lazy-loaded cache
                        let displayImage = (item.content as? NSImage) ?? loadedImages[item.id]

                        if let image = displayImage {
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
                                            .background(Circle().fill(Color.primary.opacity(0.7)))
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
                        } else if loadingImageIds.contains(item.id) {
                            // Loading indicator
                            VStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Loading image...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: 120)
                        } else {
                            // Image needs to be loaded - trigger load
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
                            .onTapGesture {
                                loadLazyImage(item)
                            }
                            .onAppear {
                                // Auto-load when selected
                                loadLazyImage(item)
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

            Spacer()

            // Note field - muted appearance
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
                        // Limit to 100 characters
                        if newValue.count > 100 {
                            editingNote = String(newValue.prefix(100))
                        }
                    }
                    .onSubmit {
                        saveNote(for: item)
                        isNoteFocused = false
                    }
                    .onChange(of: isNoteFocused) { focused in
                        if !focused {
                            saveNote(for: item)
                        }
                    }

                // Character counter (shows when > 70 chars)
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
        .padding(6)
        .background(Color(NSColor.controlBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: selectedItem?.id) { _ in
            // Update editingNote when selected item changes
            editingNote = selectedItem?.note ?? ""
        }
        .onAppear {
            editingNote = item.note ?? ""
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
        case 53: // Escape
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
            } else if item.isSensitive {
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
                    // Show Auto/PWD badges only when item is hidden
                    if item.isAutoSensitive && item.isSensitive {
                        Text("Auto")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15))
                            .cornerRadius(2)
                    }
                    if item.isPasswordLike && item.isSensitive {
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