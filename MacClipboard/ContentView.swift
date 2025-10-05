import SwiftUI
import CoreGraphics
import ApplicationServices

struct ContentView: View {
    @ObservedObject var clipboardMonitor: ClipboardMonitor
    let menuBarController: MenuBarController
    @State private var selectedItem: ClipboardItem?
    @State private var searchText = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var isSearchFocused: Bool
    
    @ObservedObject private var permissionManager: PermissionManager
    
    init(clipboardMonitor: ClipboardMonitor, menuBarController: MenuBarController) {
        self.clipboardMonitor = clipboardMonitor
        self.menuBarController = menuBarController
        self.permissionManager = menuBarController.permissionManager
    }
    
    private var filteredItems: [ClipboardItem] {
        if searchText.isEmpty {
            return clipboardMonitor.clipboardHistory
        } else {
            return clipboardMonitor.clipboardHistory.filter { item in
                item.previewText.localizedCaseInsensitiveContains(searchText) ||
                item.fullText.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    private var dynamicHeight: CGFloat {
        let baseHeight: CGFloat = 80  // Header + search + padding (reduced)
        let itemHeight: CGFloat = 32  // Even more compact row height
        
        // Show many more items - aim for 15-25 items visible
        let minItemsToShow: Int = 15
        let maxItemsToShow = max(minItemsToShow, min(filteredItems.count, 25))
        let listHeight = CGFloat(maxItemsToShow) * itemHeight
        
        // Get screen height and be much more generous
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 1000
        let maxAllowedHeight = screenHeight * 0.9 // Use up to 90% of screen height
        
        let calculatedHeight = baseHeight + listHeight
        let finalHeight = min(calculatedHeight, maxAllowedHeight)
        
        // Ensure minimum height to show at least 10 items
        let minimumHeight = baseHeight + (CGFloat(10) * itemHeight)
        return max(finalHeight, minimumHeight)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            if !permissionManager.isAccessibilityGranted {
                permissionBanner
            }
            searchBarView
            
            if filteredItems.isEmpty {
                emptyStateView
            } else {
                clipboardListView
            }
            
            if let selectedItem = selectedItem {
                previewView(for: selectedItem)
            }
        }
        .frame(width: 400, height: dynamicHeight)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            // Reset selection when popover appears
            selectedIndex = 0
            updateSelectedItem()
            // Focus search on appear
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isSearchFocused = true
            }
        }
        .onChange(of: filteredItems) { _ in
            // Reset selection when filter changes
            selectedIndex = 0
            updateSelectedItem()
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
                clipboardMonitor.clearHistory()
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
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private var searchBarView: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            
            TextField("Search clipboard...", text: $searchText)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
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
                    ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                        ClipboardItemRow(
                            item: item,
                            isSelected: selectedIndex == index,
                            onSelect: { 
                                selectedIndex = index
                                updateSelectedItem()
                            },
                            onCopy: {
                                pasteItem(item)
                            }
                        )
                        .id("item-\(index)")
                    }
                }
            }
            .frame(maxHeight: selectedItem == nil ? .infinity : 250)
            .onChange(of: selectedIndex) { newIndex in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo("item-\(newIndex)", anchor: .center)
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
    
    // MARK: - Navigation Functions
    
    private func navigateUp() {
        print("Navigate up called - current selectedIndex: \(selectedIndex), isSearchFocused: \(isSearchFocused)")
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
        print("Navigate down called - current selectedIndex: \(selectedIndex), isSearchFocused: \(isSearchFocused)")
        Logging.debug("Navigate down called - current selectedIndex: \(selectedIndex), isSearchFocused: \(isSearchFocused)")
        if isSearchFocused {
            // If search is focused, move to list
            isSearchFocused = false
            selectedIndex = 0
        } else {
            selectedIndex = min(max(0, filteredItems.count - 1), selectedIndex + 1)
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
        print("Key event received: keyCode = \(keyEvent.keyCode)")
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
        case 36: // Return/Enter
            if !isSearchFocused {
                Logging.debug("Enter pressed - pasting selected item")
                pasteSelectedItem()
                return true
            }
        case 53: // Escape
            Logging.debug("Escape pressed - hiding popover")
            menuBarController.hidePopover()
            return true
        default:
            Logging.debug("Unhandled key: \(keyEvent.keyCode)")
            return false
        }
        return false
    }
}

struct ClipboardItemRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onCopy: () -> Void
    
    private var timeAgoText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: item.timestamp, relativeTo: Date())
    }
    
    var body: some View {
        HStack(spacing: 8) {
            // Content type icon
            Image(systemName: iconName)
                .font(.system(size: 12))
                .foregroundColor(iconColor)
                .frame(width: 14)
            
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
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(3)
        .contentShape(Rectangle())
        .onTapGesture {
            // Single click: select and paste immediately
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
        print("KeyEventView acceptsFirstResponder called")
        return true 
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        print("KeyEventView moved to window")
        
        // Ensure this view can receive key events
        DispatchQueue.main.async {
            self.window?.makeFirstResponder(self)
            print("Made KeyEventView first responder: \(self.window?.firstResponder == self)")
        }
    }
    
    override func becomeFirstResponder() -> Bool {
        print("KeyEventView becomeFirstResponder called")
        return super.becomeFirstResponder()
    }
    
    override func keyDown(with event: NSEvent) {
        print("KeyEventView keyDown called with keyCode: \(event.keyCode)")
        if let handler = onKeyEvent, handler(event) {
            print("Key event handled by custom handler")
            return
        }
        print("Key event passed to super")
        super.keyDown(with: event)
    }
    
    // Handle events that might not reach keyDown
    override func flagsChanged(with event: NSEvent) {
        print("KeyEventView flagsChanged called")
        super.flagsChanged(with: event)
    }
    
    // Ensure we can handle key events
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        print("KeyEventView performKeyEquivalent called with keyCode: \(event.keyCode)")
        if let handler = onKeyEvent, handler(event) {
            print("Key equivalent handled by custom handler")
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

#Preview {
    ContentView(
        clipboardMonitor: ClipboardMonitor(),
        menuBarController: MenuBarController()
    )
}