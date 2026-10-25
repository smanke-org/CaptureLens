import AppKit
import CaptureLensKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The library: every capture, searchable by name, date, tags, notes and the text in it,
/// with filters one click away.
@MainActor
final class LibraryWindow: NSObject, NSWindowDelegate {
    static let shared = LibraryWindow()

    let state = LibraryState()
    private(set) var window: NSWindow?

    var isKey: Bool { window?.isKeyWindow == true }

    func show(select id: UUID? = nil) {
        if window == nil {
            let hosting = NSHostingController(rootView: LibraryView(state: state))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "CaptureLens"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.setContentSize(NSScreen.fitting(NSSize(width: 1180, height: 760)))
            window.minSize = NSSize(width: 860, height: 520)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("CaptureLensLibrary")
            if window.frame.origin == .zero { window.center() }
            self.window = window
        }
        if let id {
            state.reveal(id)
        }
        LibrarySync.shared.scan()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) { LibraryLock.shared.touch() }
    func windowDidResignKey(_ notification: Notification) { LibraryLock.shared.touch() }
    func windowWillClose(_ notification: Notification) { LibraryLock.shared.libraryClosed() }
}

/// What the library shows: the sidebar choice, the filters, the selection.
@Observable
@MainActor
final class LibraryState {
    enum Section: Hashable {
        case all, favorites, recent, notes
        case tag(String)
        case app(String)
        case site(String)
    }

    var section: Section = .all
    var filter = LibraryFilter()
    var sort: LibrarySort = LibrarySort(rawValue: AppDefaults.store.string(forKey: "library.sort") ?? "") ?? .newest {
        didSet { AppDefaults.store.set(sort.rawValue, forKey: "library.sort") }
    }
    var selection: Set<UUID> = []
    /// The item last clicked, for Shift-click ranges and the keyboard.
    var anchor: UUID?
    /// The width of a thumbnail in the grid, set with the slider below it.
    var thumbnailSize: Double = LibraryState.clampSize(AppDefaults.store.object(forKey: "library.thumbnailSize") as? Double ?? 190) {
        didSet { AppDefaults.store.set(thumbnailSize, forKey: "library.thumbnailSize") }
    }
    static let thumbnailRange: ClosedRange<Double> = 100...420

    static func clampSize(_ size: Double) -> Double {
        min(max(size, thumbnailRange.lowerBound), thumbnailRange.upperBound)
    }

    /// One step of the size buttons and ⌘+ / ⌘−.
    func stepThumbnails(bigger: Bool) {
        thumbnailSize = Self.clampSize(thumbnailSize + (bigger ? 40 : -40))
    }
    var showInspector = AppDefaults.store.object(forKey: "library.inspector") as? Bool ?? true {
        didSet {
            AppDefaults.store.set(showInspector, forKey: "library.inspector")
            // Asking for the selected capture brings it back from a slim bar too.
            if showInspector && foldedSide == .editor { foldedSide = nil }
        }
    }

    /// The side folded down to a slim bar, so the other fills the window: the captures, or
    /// the selected capture (its picture and details).
    enum Side: String { case captures, editor }
    var foldedSide = Side(rawValue: AppDefaults.store.string(forKey: "library.foldedSide") ?? "") {
        didSet { AppDefaults.store.set(foldedSide?.rawValue ?? "", forKey: "library.foldedSide") }
    }

    func fold(_ side: Side?) {
        withAnimation(.easeInOut(duration: 0.2)) { foldedSide = side }
    }
    /// Asks the grid to scroll to an item.
    var scrollTarget: UUID?
    var confirmDelete: Set<UUID> = []
    /// A guide being made, and captures being exported together (their sheets show).
    var guide: GuideRequest?
    var export: ExportRequest?

    /// Opens the guide sheet on these captures, oldest first.
    func makeGuide(from items: [CaptureItem]) {
        let ordered = items.sorted { $0.created < $1.created }
        // A tag they all share (a step recording's, say) makes a good title.
        let shared = ordered.dropFirst().reduce(Set(ordered.first?.tags ?? [])) { $0.intersection($1.tags) }
        let title = shared.sorted().first ?? "Guide · " + Date().formatted(date: .abbreviated, time: .omitted)
        guide = GuideRequest(items: ordered.map(\.id), title: title, template: .steps)
    }
    var renaming: UUID?

    /// The filter with the sidebar's choice folded in.
    var effectiveFilter: LibraryFilter {
        var f = filter
        switch section {
        case .all: break
        case .favorites: f.favoritesOnly = true
        case .recent: if f.dateRange == .any { f.dateRange = .lastWeek }
        case .notes: f.withNotesOnly = true
        case .tag(let tag): f.tags.insert(tag)
        case .app(let key): f.apps = [key]
        case .site(let site): f.websites = [site]
        }
        return f
    }

    /// The captures shown, in order. The header, the grid and the status bar all ask for them
    /// each time they redraw, so the list is kept until the library, filter, sort or minute
    /// (for date ranges) changes.
    var results: [CaptureItem] {
        let store = LibraryStore.shared
        let items = store.items
        let key = ResultsKey(revision: store.revision, filter: effectiveFilter, sort: sort,
                             minute: Int(Date().timeIntervalSince1970 / 60))
        if let cached = resultsCache, cached.key == key { return cached.items }
        let list = LibraryQuery.filter(items, with: key.filter, sort: sort)
        resultsCache = (key, list)
        return list
    }
    private struct ResultsKey: Equatable {
        let revision: Int
        let filter: LibraryFilter
        let sort: LibrarySort
        let minute: Int
    }
    @ObservationIgnored private var resultsCache: (key: ResultsKey, items: [CaptureItem])?

    var selectedItems: [CaptureItem] {
        LibraryStore.shared.items.filter { selection.contains($0.id) }
    }

    /// Shows an item, clearing whatever would hide it.
    func reveal(_ id: UUID) {
        if !results.contains(where: { $0.id == id }) {
            section = .all
            filter = LibraryFilter()
        }
        selection = [id]
        anchor = id
        scrollTarget = id
    }

    func click(_ id: UUID, in list: [CaptureItem]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else if flags.contains(.shift), let anchor, let a = list.firstIndex(where: { $0.id == anchor }),
                  let b = list.firstIndex(where: { $0.id == id }) {
            selection = Set(list[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [id]
            anchor = id
        }
    }

    /// Arrow keys: move through the grid, `columns` items to a row.
    func move(_ direction: MoveCommandDirection, columns: Int, in list: [CaptureItem]) {
        guard !list.isEmpty else { return }
        let current = anchor.flatMap { id in list.firstIndex { $0.id == id } }
        var index: Int
        switch direction {
        case .left: index = (current ?? 1) - 1
        case .right: index = (current ?? -1) + 1
        case .up: index = (current ?? columns) - columns
        case .down: index = (current ?? -columns) + columns
        default: return
        }
        index = min(max(index, 0), list.count - 1)
        let id = list[index].id
        selection = [id]
        anchor = id
        scrollTarget = id
    }
}

// MARK: - The window's content

struct LibraryView: View {
    @Bindable var state: LibraryState
    @State private var store = LibraryStore.shared
    @State private var lock = LibraryLock.shared
    /// Always .all: dragging the sidebar narrower than its icons would hide it, with nothing
    /// left to bring it back, so it springs back to the icons instead.
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        if lock.isLocked {
            LockedView()
        } else {
            NavigationSplitView(columnVisibility: $columns) {
                LibrarySidebar(state: state)
                    .navigationSplitViewColumnWidth(min: LibrarySidebar.railWidth, ideal: 210, max: 300)
            } detail: {
                HStack(spacing: 0) {
                    // Either side can fold to a slim bar, so the other fills the window.
                    if state.showInspector && state.foldedSide == .captures {
                        CollapsedSideBar(title: "Captures", symbol: "square.grid.2x2", edge: .leading) { state.fold(nil) }
                    } else {
                        VStack(spacing: 0) {
                            LibraryHeader(state: state)
                            FilterBar(state: state)
                            Divider()
                            CaptureGrid(state: state)
                            Divider()
                            GridStatusBar(state: state)
                        }
                        .frame(minWidth: 360)
                    }
                    if state.showInspector {
                        Divider()
                        if state.foldedSide == .editor {
                            CollapsedSideBar(title: "Picture", symbol: "photo", edge: .trailing) { state.fold(nil) }
                        } else {
                            CaptureDetail(state: state)
                                .frame(minWidth: 360, idealWidth: 520)
                        }
                    }
                }
                // The tool dial floats over the grid and the picture.
                .overlay { DialOverlay() }
            }
            .background(SidebarStaysOpen())
            .onChange(of: columns) { _, shown in
                guard shown != .all else { return }
                DispatchQueue.main.async {
                    columns = .all
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        SidebarStaysOpen.Finder.showIcons(in: LibraryWindow.shared.window)
                    }
                }
            }
            .searchable(text: $state.filter.text, placement: .toolbar,
                        prompt: "Name, text, tag:, app:, site:, or a date")
            .toolbar { LibraryToolbar(state: state) }
            .sheet(item: $state.guide) { GuideSheet(request: $0) }
            .sheet(item: $state.export) { BatchExportSheet(request: $0) }
            .confirmationDialog(deleteTitle, isPresented: Binding(get: { !state.confirmDelete.isEmpty },
                                                                   set: { if !$0 { state.confirmDelete = [] } })) {
                Button("Delete", role: .destructive) {
                    store.delete(state.confirmDelete)
                    state.selection.subtract(state.confirmDelete)
                    state.confirmDelete = []
                }
            } message: {
                Text(LibrarySync.shared.isActive
                     ? "They're deleted from this Mac and your other Macs. This can't be undone."
                     : "They're deleted from this Mac. This can't be undone.")
            }
        }
    }

    private var deleteTitle: String {
        state.confirmDelete.count == 1 ? "Delete this capture?" : "Delete \(state.confirmDelete.count) captures?"
    }
}

/// A folded-away side of the library: a slim column with its name; a click anywhere on it
/// brings it back.
private struct CollapsedSideBar: View {
    let title: String
    let symbol: String
    let edge: HorizontalEdge
    let restore: () -> Void

    var body: some View {
        Button(action: restore) {
            VStack(spacing: 10) {
                Image(systemName: edge == .leading ? "chevron.right.circle" : "chevron.left.circle")
                    .font(.system(size: SingleCaptureView.barFontSize))
                    .foregroundStyle(Color.accentColor)
                Image(systemName: symbol).foregroundStyle(.secondary)
                // Reads bottom to top, like a book's spine.
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(width: 20, height: 110)
                Spacer(minLength: 0)
            }
            .padding(.top, 14)
            .frame(width: 34)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
        .help("Show the \(title.lowercased()) again")
    }
}

struct LibraryToolbar: ToolbarContent {
    @Bindable var state: LibraryState

    var body: some ToolbarContent {
        // One button per capture preset, in their order in Settings › Presets.
        ToolbarItemGroup(placement: .navigation) {
            ForEach(Preferences.shared.presets) { preset in
                Button {
                    LibraryWindow.shared.window?.orderOut(nil)
                    CaptureEngine.shared.run(preset)
                } label: {
                    Label(preset.name, systemImage: preset.delay > 0 ? "timer" : preset.mode.symbol)
                }
                .help("\(preset.name)\(preset.hotKey.map { " (\($0.display))" } ?? "") — \(preset.summary)")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            // A toolbar button like its neighbors (an AppKit one sits smaller and off-center
            // there); the share menu opens at the click, just under it.
            Button { ShareButton.shareAtPointer(state.selectedItems) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                .disabled(state.selection.isEmpty)
                .help(state.selection.count > 1 ? "Share the selected captures" : "Share the selected capture")
            Button { importFiles() } label: { Label("Import", systemImage: "tray.and.arrow.down") }
                .help("Add pictures from files to the library")
            Menu {
                Picker("Sort", selection: $state.sort) {
                    ForEach(LibrarySort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Bigger Thumbnails") { state.stepThumbnails(bigger: true) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Smaller Thumbnails") { state.stepThumbnails(bigger: false) }
                    .keyboardShortcut("-", modifiers: .command)
            } label: {
                Label("View", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort, and thumbnail size")
            Button { state.showInspector.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
                .help(state.showInspector ? "Hide the selected capture" : "Show the selected capture")
            Button { SettingsWindow.shared.show() } label: { Label("Settings", systemImage: "gearshape") }
                .help("CaptureLens Settings")
        }
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose pictures to add to the library"
        guard panel.runModal() == .OK else { return }
        let count = LibraryStore.shared.importFiles(panel.urls)
        if count == 0 { NSSound.beep() }
    }
}

// MARK: - Sidebar

/// Stops the sidebar from being dragged out of sight: past its narrowest it stays as icons.
/// SwiftUI's split view lets a column collapse (and turns that back on as it updates), so
/// this turns it off on the AppKit split view underneath whenever a resize starts.
private struct SidebarStaysOpen: NSViewRepresentable {
    final class Finder: NSView {
        private var observer: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
            DispatchQueue.main.async { [weak self] in
                guard let self, let split = Self.splitView(in: self.window?.contentView) else { return }
                Self.pin(split)
                self.observer = NotificationCenter.default.addObserver(forName: NSSplitView.willResizeSubviewsNotification,
                                                                       object: split, queue: nil) { _ in
                    MainActor.assumeIsolated { Self.pin(split) }
                }
            }
        }

        private static func pin(_ split: NSSplitView) {
            (split.delegate as? NSSplitViewController)?.splitViewItems.first?.canCollapse = false
        }

        /// If the sidebar hid anyway, it comes back as icons rather than at its old width.
        static func showIcons(in window: NSWindow?) {
            guard let split = splitView(in: window?.contentView) else { return }
            split.setPosition(LibrarySidebar.railWidth, ofDividerAt: 0)
        }

        static func splitView(in view: NSView?) -> NSSplitView? {
            guard let view else { return nil }
            if let split = view as? NSSplitView, split.isVertical { return split }
            for sub in view.subviews { if let hit = splitView(in: sub) { return hit } }
            return nil
        }
    }

    func makeNSView(context: Context) -> Finder { Finder() }
    func updateNSView(_ view: Finder, context: Context) {}
}

/// A sidebar heading that folds its list away or opens it again: click anywhere on it.
/// Folded, it says how many entries are hidden.
private struct FoldingHeader: View {
    let title: String
    let count: Int
    @Binding var open: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { open.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if !open { Text("\(count)").foregroundStyle(.tertiary).monospacedDigit() }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(open ? "Hide the \(title.lowercased()) list" : "Show the \(title.lowercased()) list")
        .accessibilityLabel("\(title), \(open ? "expanded" : "collapsed")")
    }
}

struct LibrarySidebar: View {
    @Bindable var state: LibraryState
    @State private var store = LibraryStore.shared
    @State private var renamingTag: String?
    @State private var newTagName = ""
    /// Each list can be folded away from its heading; they start open.
    @AppStorage("library.sidebar.tagsOpen", store: AppDefaults.store) private var tagsOpen = true
    @AppStorage("library.sidebar.appsOpen", store: AppDefaults.store) private var appsOpen = true
    @AppStorage("library.sidebar.sitesOpen", store: AppDefaults.store) private var sitesOpen = true
    /// Narrower than this, the sidebar is a column of icons.
    @State private var compact = false

    /// The narrowest the sidebar goes: room for its icons and the window's buttons above them.
    static let railWidth: CGFloat = 72
    private static let compactBelow: CGFloat = 130

    var body: some View {
        Group {
            if compact { rail } else { list }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.compactBelow } action: { compact = $0 }
    }

    private var list: some View {
        let items = store.items
        return List(selection: Binding(get: { state.section }, set: { state.section = $0 ?? .all; state.selection = [] })) {
            Section("Library") {
                row("All Captures", "photo.on.rectangle", items.count).tag(LibraryState.Section.all)
                row("Favorites", "star", items.filter(\.favorite).count).tag(LibraryState.Section.favorites)
                row("Last 7 Days", "calendar", nil).tag(LibraryState.Section.recent)
                row("With Notes", "note.text", items.filter { !$0.notes.isEmpty }.count).tag(LibraryState.Section.notes)
            }
            let tags = store.facets.tags
            if !tags.isEmpty {
                Section {
                    // Tags as chips: many fit in little room. Click one to show its captures,
                    // again to go back; right-click to rename or remove it.
                    if tagsOpen {
                        FlowLayout(spacing: 6) {
                            ForEach(tags, id: \.tag) { entry in
                                let on = state.section == .tag(entry.tag)
                                Button {
                                    state.section = on ? .all : .tag(entry.tag)
                                    state.selection = []
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(entry.tag).lineLimit(1)
                                        Text("\(entry.count)").foregroundStyle(on ? Color.white.opacity(0.75) : Color.secondary).monospacedDigit()
                                    }
                                    .font(.callout)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.08)))
                                    .foregroundStyle(on ? Color.white : Color.primary)
                                    .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .help("Show captures tagged “\(entry.tag)”")
                                .contextMenu {
                                    Button("Rename Tag…") { renamingTag = entry.tag; newTagName = entry.tag }
                                    Button("Remove Tag from All Captures") {
                                        store.setTags(Set(items.map(\.id)), remove: [entry.tag])
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                        .selectionDisabled()
                    }
                } header: {
                    FoldingHeader(title: "Tags", count: tags.count, open: $tagsOpen)
                }
            }
            let apps = store.facets.apps
            if !apps.isEmpty {
                Section {
                    if appsOpen { ForEach(apps.prefix(30), id: \.key) { app in
                        Label {
                            HStack { Text(app.name); Spacer(); Text("\(app.count)").foregroundStyle(.secondary).monospacedDigit() }
                        } icon: {
                            AppIcon(bundleID: app.key)
                        }
                        .tag(LibraryState.Section.app(app.key))
                    } }
                } header: {
                    FoldingHeader(title: "Apps", count: apps.count, open: $appsOpen)
                }
            }
            let sites = store.facets.websites
            if !sites.isEmpty {
                Section {
                    if sitesOpen { ForEach(sites.prefix(30), id: \.site) { site in
                        row(site.site, "globe", site.count).tag(LibraryState.Section.site(site.site))
                    } }
                } header: {
                    FoldingHeader(title: "Websites", count: sites.count, open: $sitesOpen)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { WeekCard().padding(.horizontal, 10).padding(.bottom, 10) }
        .alert("Rename Tag", isPresented: Binding(get: { renamingTag != nil }, set: { if !$0 { renamingTag = nil } })) {
            TextField("Tag", text: $newTagName)
            Button("Rename") {
                if let old = renamingTag, !newTagName.trimmingCharacters(in: .whitespaces).isEmpty {
                    store.renameTag(old, to: newTagName)
                    if state.section == .tag(old) { state.section = .tag(newTagName) }
                }
                renamingTag = nil
            }
            Button("Cancel", role: .cancel) { renamingTag = nil }
        } message: {
            Text("Every capture tagged “\(renamingTag ?? "")” gets the new name. A name that's already a tag merges the two.")
        }
    }

    // MARK: Icons only

    /// The sidebar dragged narrow: one icon per place, with the name and count in its
    /// tooltip. Tags, apps and websites are each one icon with a menu of their entries.
    /// Drag the edge out again for the full list.
    private var rail: some View {
        let items = store.items
        let tags = store.facets.tags
        let apps = store.facets.apps
        let sites = store.facets.websites
        return ScrollView(.vertical) {
            VStack(spacing: 6) {
                railButton("All Captures", "photo.on.rectangle", items.count, .all)
                railButton("Favorites", "star", items.filter(\.favorite).count, .favorites)
                railButton("Last 7 Days", "calendar", nil, .recent)
                railButton("With Notes", "note.text", items.filter { !$0.notes.isEmpty }.count, .notes)
                if !tags.isEmpty || !apps.isEmpty || !sites.isEmpty { Divider().frame(width: 32).padding(.vertical, 4) }
                if !tags.isEmpty {
                    railMenu("Tags", "tag", picked: { if case .tag = $0 { true } else { false } }) {
                        ForEach(tags, id: \.tag) { entry in
                            Button("\(entry.tag) (\(entry.count))") { pick(.tag(entry.tag)) }
                        }
                    }
                }
                if !apps.isEmpty {
                    railMenu("Apps", "app", picked: { if case .app = $0 { true } else { false } }) {
                        ForEach(apps.prefix(30), id: \.key) { app in
                            Button { pick(.app(app.key)) } label: {
                                Label { Text("\(app.name) (\(app.count))") } icon: { AppIcon(bundleID: app.key) }
                            }
                        }
                    }
                }
                if !sites.isEmpty {
                    railMenu("Websites", "globe", picked: { if case .site = $0 { true } else { false } }) {
                        ForEach(sites.prefix(30), id: \.site) { site in
                            Button("\(site.site) (\(site.count))") { pick(.site(site.site)) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.never)
    }

    private func pick(_ section: LibraryState.Section) {
        state.section = section
        state.selection = []
    }

    private func railButton(_ title: String, _ symbol: String, _ count: Int?, _ section: LibraryState.Section) -> some View {
        let picked = state.section == section
        return Button { pick(section) } label: {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .frame(width: 40, height: 32)
                .foregroundStyle(picked ? Color.white : Color.accentColor)
                .background(picked ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(count.map { "\(title) (\($0))" } ?? title)
        .accessibilityLabel(title)
    }

    private func railMenu<Content: View>(_ title: String, _ symbol: String, picked isPicked: (LibraryState.Section) -> Bool,
                                         @ViewBuilder _ content: () -> Content) -> some View {
        let picked = isPicked(state.section)
        return Menu { content() } label: {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .frame(width: 40, height: 32)
                .foregroundStyle(picked ? Color.white : Color.accentColor)
                .background(picked ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(title): pick one to show its captures")
        .accessibilityLabel(title)
    }

    private func row(_ title: String, _ symbol: String, _ count: Int?) -> some View {
        Label {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                if let count { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
            }
        } icon: {
            Image(systemName: symbol)
        }
    }
}

/// At the foot of the sidebar: how much was captured and recorded this week, from Activity.
private struct WeekCard: View {
    @State private var activity = ActivityStore.shared

    var body: some View {
        let start = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        let totals = activity.log.totals(since: start)
        let captures = ActivityKey.captureKinds.reduce(0) { $0 + (totals[$1] ?? 0) } + (totals[ActivityKey.imported] ?? 0)
        let minutes = (totals[ActivityKey.recordingSeconds] ?? 0) / 60
        Button { SettingsWindow.shared.show(tab: "Activity") } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("This week").font(.callout.weight(.semibold))
                Text("\(captures) capture\(captures == 1 ? "" : "s")\(minutes > 0 ? " · \(minutes) min recorded" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("See more in Settings › Activity")
    }
}

/// An app's icon, from its bundle ID.
struct AppIcon: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: "app.dashed")
        }
    }
}

// MARK: - Header

/// Above the filters: what's showing, in big type, and how many captures that is.
struct LibraryHeader: View {
    @Bindable var state: LibraryState
    @State private var store = LibraryStore.shared

    private var title: String {
        switch state.section {
        case .all: "All Captures"
        case .favorites: "Favorites"
        case .recent: "Last 7 Days"
        case .notes: "With Notes"
        case .tag(let tag): "#\(tag)"
        case .app(let key): store.facets.apps.first { $0.key == key }?.name ?? "App"
        case .site(let site): site
        }
    }

    var body: some View {
        let shown = state.results.count
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.title2.weight(.bold)).lineLimit(1)
            Text("\(shown) capture\(shown == 1 ? "" : "s")").font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

// MARK: - Filter chips

struct FilterBar: View {
    @Bindable var state: LibraryState
    @State private var store = LibraryStore.shared
    @State private var customDates = false
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @State private var customEnd = Date()

    var body: some View {
        // Pills wrap onto more lines when the window is too narrow for one.
        FlowLayout(spacing: 6) {
                Chip(title: state.filter.dateRange == .any ? "Date" : state.filter.dateRange.title,
                     symbol: "calendar", active: state.filter.dateRange != .any,
                     clear: { state.filter.dateRange = .any }) {
                    LibraryFilter.DateRange.presets.map { range in
                        .action(range.title, checked: state.filter.dateRange == range) { state.filter.dateRange = range }
                    } + [.separator, .action("Choose Dates…") { customDates = true }]
                }
                .popover(isPresented: $customDates) {
                    VStack(alignment: .leading, spacing: 10) {
                        DatePicker("From", selection: $customStart, displayedComponents: .date)
                        DatePicker("To", selection: $customEnd, displayedComponents: .date)
                        HStack {
                            Spacer()
                            Button("Show") {
                                state.filter.dateRange = .custom(start: customStart, end: customEnd)
                                customDates = false
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding()
                    .frame(width: 260)
                }

                Chip(title: chipTitle(state.filter.kinds.map(\.title), fallback: "Type"), symbol: "rectangle.dashed",
                     active: !state.filter.kinds.isEmpty, clear: { state.filter.kinds = [] }) {
                    CaptureItem.Kind.allCases.map { kind in toggle(\.kinds, kind, title: kind.title) }
                }

                // The lists are made when a menu opens, from counts the library keeps.
                Chip(title: chipTitle(Array(state.filter.tags), fallback: "Tags"), symbol: "tag",
                     active: !state.filter.tags.isEmpty, clear: { state.filter.tags = [] }) {
                    let tags = store.facets.tags
                    return tags.isEmpty ? [.note("No tags yet")]
                        : tags.map { toggle(\.tags, $0.tag, title: "\($0.tag) (\($0.count))") }
                }

                Chip(title: chipTitle(store.facets.apps.filter { state.filter.apps.contains($0.key) }.map(\.name), fallback: "App"),
                     symbol: "app", active: !state.filter.apps.isEmpty, clear: { state.filter.apps = [] }) {
                    let apps = store.facets.apps
                    return apps.isEmpty ? [.note("No apps yet")]
                        : apps.map { toggle(\.apps, $0.key, title: "\($0.name) (\($0.count))") }
                }

                if !store.facets.websites.isEmpty {
                    Chip(title: chipTitle(Array(state.filter.websites), fallback: "Website"), symbol: "globe",
                         active: !state.filter.websites.isEmpty, clear: { state.filter.websites = [] }) {
                        store.facets.websites.map { toggle(\.websites, $0.site, title: "\($0.site) (\($0.count))") }
                    }
                }

                ToggleChip(title: "Favorites", symbol: "star", isOn: $state.filter.favoritesOnly)
                ToggleChip(title: "Has Notes", symbol: "note.text", isOn: $state.filter.withNotesOnly)

                if !state.filter.isEmpty {
                    Button("Clear All") { state.filter = LibraryFilter() }
                        .buttonStyle(.link)
                        .padding(.leading, 4)
                        .padding(.vertical, 4)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func chipTitle(_ values: [String], fallback: String) -> String {
        switch values.count {
        case 0: fallback
        case 1: values[0]
        default: "\(values[0]) +\(values.count - 1)"
        }
    }

    /// A menu entry, ticked while its value is in the filter, that adds or removes it.
    private func toggle<T: Hashable>(_ path: WritableKeyPath<LibraryFilter, Set<T>>, _ value: T, title: String) -> ChipMenu.Item {
        let on = state.filter[keyPath: path].contains(value)
        return .action(title, checked: on) {
            if on { state.filter[keyPath: path].remove(value) } else { state.filter[keyPath: path].insert(value) }
        }
    }
}

/// A filter as a rounded button with a menu, tinted while it narrows the list, with an ×
/// to clear it.
struct Chip: View {
    let title: String
    let symbol: String
    let active: Bool
    let clear: () -> Void
    /// The menu's entries, made when it opens.
    let items: () -> [ChipMenu.Item]
    @State private var anchor = ChipMenu.Anchor()

    var body: some View {
        HStack(spacing: 2) {
            // All of the pill but the × opens the menu.
            Button { ChipMenu.show(items(), below: anchor.view) } label: {
                HStack(spacing: 2) {
                    Label(title, systemImage: symbol).lineLimit(1)
                    if !active { Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary) }
                }
                .padding(.leading, 10)
                .padding(.trailing, active ? 0 : 10)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            if active {
                Button(action: clear) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .help("Clear this filter")
                    .padding(.trailing, 10)
            }
        }
        .font(.callout)
        .background(active ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(active ? Color.accentColor.opacity(0.5) : .clear))
        .background(ChipMenu.AnchorView(anchor: anchor))
    }
}

/// The filters' menus, made in AppKit when one is clicked: a SwiftUI menu with hundreds of
/// tags or websites took a moment to build, and waited for the window to finish redrawing.
@MainActor
enum ChipMenu {
    enum Item {
        case action(String, checked: Bool = false, () -> Void)
        case note(String)
        case separator
    }

    /// The chip's place in the window, for opening the menu under it.
    final class Anchor { weak var view: NSView? }

    struct AnchorView: NSViewRepresentable {
        let anchor: Anchor
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            anchor.view = view
            return view
        }
        func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
    }

    private final class Handler: NSObject {
        let perform: () -> Void
        init(_ perform: @escaping () -> Void) { self.perform = perform }
        @objc func run(_ sender: Any?) { perform() }
    }

    static func show(_ items: [Item], below view: NSView?) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case .note(let text):
                let entry = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                entry.isEnabled = false
                menu.addItem(entry)
            case .action(let title, let checked, let perform):
                let handler = Handler(perform)
                let entry = NSMenuItem(title: title, action: #selector(Handler.run(_:)), keyEquivalent: "")
                entry.target = handler
                entry.representedObject = handler // the target is weak; this keeps it
                entry.state = checked ? .on : .off
                menu.addItem(entry)
            }
        }
        if let view {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}

struct ToggleChip: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Label(title, systemImage: isOn ? symbol + ".fill" : symbol)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isOn ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10), in: Capsule())
                .overlay(Capsule().strokeBorder(isOn ? Color.accentColor.opacity(0.5) : .clear))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Grid

struct CaptureGrid: View {
    @Bindable var state: LibraryState
    @State private var store = LibraryStore.shared
    @FocusState private var focused: Bool
    @State private var width: CGFloat = 600

    private var columns: Int { max(1, Int((width - 24) / (state.thumbnailSize + 16))) }

    var body: some View {
        let list = state.results
        Group {
            if list.isEmpty {
                ContentUnavailableView {
                    Label(store.items.isEmpty ? "No Captures Yet" : "No Matches",
                          systemImage: store.items.isEmpty ? "camera.viewfinder" : "magnifyingglass")
                } description: {
                    if store.items.isEmpty {
                        Text("Press \(Preferences.shared.presets.first?.hotKey?.display ?? "a capture shortcut") or choose Capture in the menu bar. Every capture lands here.")
                    } else {
                        Text("Nothing matches the search and filters.")
                    }
                } actions: {
                    if !state.filter.isEmpty { Button("Clear Filters") { state.filter = LibraryFilter(); state.section = .all } }
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(state.thumbnailSize), spacing: 16), count: columns),
                                  alignment: .leading, spacing: 18) {
                            ForEach(list) { item in
                                CaptureCell(item: item, size: state.thumbnailSize, selected: state.selection.contains(item.id),
                                            analyzing: store.analyzing.contains(item.id))
                                    .id(item.id)
                                    .onTapGesture(count: 2) { state.selection = [item.id]; state.showInspector = true }
                                    .simultaneousGesture(TapGesture().onEnded { state.click(item.id, in: list); focused = true })
                                    .onDrag { dragProvider(item) }
                                    .contextMenu { CaptureMenu(state: state, item: item) }
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: state.scrollTarget) { _, id in
                        guard let id else { return }
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                        state.scrollTarget = nil
                    }
                }
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onMoveCommand { state.move($0, columns: columns, in: list) }
                .onDeleteCommand { if !state.selection.isEmpty { state.confirmDelete = state.selection } }
                .onKeyPress(.return) {
                    guard let id = state.selection.first else { return .ignored }
                    state.renaming = id
                    return .handled
                }
            }
        }
        // Measure the room the grid is given, not the grid: its fixed columns would otherwise
        // hold on to a wider pane's width (after Details is hidden and shown again) and spill
        // under the sidebar and the picture.
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background(GeometryReader { geo in Color.clear.onAppear { width = geo.size.width }.onChange(of: geo.size.width) { _, w in width = w } })
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in _ = LibraryStore.shared.importFiles([url]) }
                }
            }
            return true
        }
    }

    private func dragProvider(_ item: CaptureItem) -> NSItemProvider {
        guard let url = Flattener.temporaryFile(item) else { return NSItemProvider() }
        ActivityStore.shared.record(ActivityKey.drags)
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }
}

/// Below the grid: how many captures are showing, and the thumbnail size slider.
struct GridStatusBar: View {
    @Bindable var state: LibraryState

    var body: some View {
        let shown = state.results.count
        HStack(spacing: 8) {
            Text(state.selection.count > 1 ? "\(state.selection.count) of \(shown) selected"
                 : "\(shown) capture\(shown == 1 ? "" : "s")")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Button { state.stepThumbnails(bigger: false) } label: { Image(systemName: "photo").font(.caption) }
                .buttonStyle(.borderless)
                .help("Smaller thumbnails (⌘−)")
            Slider(value: $state.thumbnailSize, in: LibraryState.thumbnailRange)
                .controlSize(.small)
                .frame(width: 140)
                .help("Thumbnail size")
            Button { state.stepThumbnails(bigger: true) } label: { Image(systemName: "photo").font(.body) }
                .buttonStyle(.borderless)
                .help("Bigger thumbnails (⌘+)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

struct CaptureCell: View {
    let item: CaptureItem
    let size: Double
    let selected: Bool
    let analyzing: Bool
    @State private var store = LibraryStore.shared

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08))
                if let image = store.thumbnail(item) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                        .padding(8)
                } else {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(.tertiary)
                }
            }
            .frame(width: size, height: size * 0.68)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3))
            .overlay {
                if item.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: max(18, size * 0.16)))
                        .foregroundStyle(.white, .black.opacity(0.45))
                        .shadow(radius: 2)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let video = item.video {
                    Text(VideoModel.format(video.resultDuration).replacingOccurrences(of: #"\.\d$"#, with: "", options: .regularExpression))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if item.favorite {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).shadow(radius: 1).padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !item.tags.isEmpty {
                    Text(item.tags.prefix(2).joined(separator: " · ") + (item.tags.count > 2 ? " +\(item.tags.count - 2)" : ""))
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                        .padding(6)
                }
            }
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    if analyzing { ProgressView().controlSize(.mini) }
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                }
                .font(.callout.weight(selected ? .semibold : .regular))
                Text(item.created.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: size)
        }
        .contentShape(Rectangle())
        .help(item.name)
    }
}

/// The actions for a capture, for its right-click menu.
struct CaptureMenu: View {
    let state: LibraryState
    let item: CaptureItem

    private var targets: Set<UUID> { state.selection.contains(item.id) ? state.selection : [item.id] }

    var body: some View {
        let store = LibraryStore.shared
        if targets.count == 1 {
            Button("Copy") {
                if item.kind == .video { return VideoExport.copy(item) }
                if let png = Flattener.png(item) { Clipboard.copy(png: png); ActivityStore.shared.record(ActivityKey.copies) }
            }
            Button("Copy Text") { Clipboard.copy(text: item.recognizedText) }.disabled(item.recognizedText.isEmpty)
            Button("Save As…") { Exporter.save(item) }
            Button("Share…") { ShareButton.shareAtPointer([item]) }
            Divider()
            Button("Rename…") { state.selection = [item.id]; state.renaming = item.id; state.showInspector = true }
            Button("Suggest a Name") { store.suggestName(item.id) }
            if let url = item.source.url.flatMap(URL.init(string:)) {
                Button("Open Web Page") { NSWorkspace.shared.open(url) }
            }
            Divider()
        }
        if targets.count > 1 {
            Button("Share \(targets.count) Captures…") { ShareButton.shareAtPointer(store.items.filter { targets.contains($0.id) }) }
        }
        Button(store.entry(item.id)?.favorite == true && targets.count == 1 ? "Remove from Favorites" : "Add to Favorites") {
            store.toggleFavorite(targets)
        }
        let tags = store.facets.tags
        if !tags.isEmpty {
            Menu("Tag") {
                ForEach(tags, id: \.tag) { entry in
                    let all = targets.allSatisfy { id in store.entry(id)?.tags.contains { LibraryQuery.fold($0) == LibraryQuery.fold(entry.tag) } == true }
                    Button {
                        if all { store.setTags(targets, remove: [entry.tag]) } else { store.setTags(targets, add: [entry.tag]) }
                    } label: {
                        if all { Label(entry.tag, systemImage: "checkmark") } else { Text(entry.tag) }
                    }
                }
            }
        }
        Divider()
        if targets.count > 1 {
            Button("Make a Guide from \(targets.count) Captures…") { state.makeGuide(from: store.items.filter { targets.contains($0.id) }) }
            Button("Export \(targets.count) Captures…") { state.export = ExportRequest(items: store.items.filter { targets.contains($0.id) }.map(\.id)) }
            Divider()
        }
        Button(targets.count == 1 ? "Delete…" : "Delete \(targets.count) Captures…", role: .destructive) {
            state.confirmDelete = targets
        }
    }
}

/// Shown instead of the library while it's locked.
struct LockedView: View {
    @State private var lock = LibraryLock.shared

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Your library is locked").font(.title2.weight(.semibold))
            Text("Captures keep landing here while it's locked.").foregroundStyle(.secondary)
            Button("Unlock with \(lock.biometryName)") { Task { await lock.unlock() } }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            if let error = lock.lastError { Text(error).font(.callout).foregroundStyle(.red) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await lock.unlock() }
    }
}

/// The macOS Share button: Mail, Messages, AirDrop, Notes and the rest, with the
/// captures as they look in the library (annotations and pointer drawn in).
struct ShareButton: NSViewRepresentable {
    let items: () -> [CaptureItem]
    /// The symbol's size, to match bigger buttons beside it; standard when nil.
    var pointSize: CGFloat?

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// From a menu: the share sheet opens where the pointer is.
    @MainActor static func shareAtPointer(_ items: [CaptureItem]) {
        guard let window = LibraryWindow.shared.window, let view = window.contentView else { return }
        let files = items.compactMap(Flattener.temporaryFile)
        guard !files.isEmpty else { return NSSound.beep() }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        SharePicker.show(files, relativeTo: CGRect(origin: point, size: CGSize(width: 1, height: 1)), of: view, edge: .maxY)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")!,
                              target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        if let pointSize { button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular) }
        context.coordinator.items = items
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.items = items
        button.isEnabled = context.environment.isEnabled
    }

    @MainActor
    final class Coordinator: NSObject {
        var items: () -> [CaptureItem] = { [] }

        @objc func share(_ sender: NSButton) {
            let files = items().compactMap(Flattener.temporaryFile)
            guard !files.isEmpty else { return NSSound.beep() }
            SharePicker.show(files, relativeTo: sender.bounds, of: sender, edge: .minY)
        }
    }
}
