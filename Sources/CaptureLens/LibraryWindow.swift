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
            window.setContentSize(NSSize(width: 1180, height: 760))
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
    var thumbnailSize: Double = AppDefaults.store.object(forKey: "library.thumbnailSize") as? Double ?? 190 {
        didSet { AppDefaults.store.set(thumbnailSize, forKey: "library.thumbnailSize") }
    }
    var showInspector = AppDefaults.store.object(forKey: "library.inspector") as? Bool ?? true {
        didSet { AppDefaults.store.set(showInspector, forKey: "library.inspector") }
    }
    /// Asks the grid to scroll to an item.
    var scrollTarget: UUID?
    var confirmDelete: Set<UUID> = []
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

    var results: [CaptureItem] {
        LibraryQuery.filter(LibraryStore.shared.items, with: effectiveFilter, sort: sort)
    }

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

    var body: some View {
        if lock.isLocked {
            LockedView()
        } else {
            NavigationSplitView {
                LibrarySidebar(state: state)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
            } detail: {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        FilterBar(state: state)
                        Divider()
                        CaptureGrid(state: state)
                    }
                    .frame(minWidth: 360)
                    if state.showInspector {
                        Divider()
                        CaptureDetail(state: state)
                            .frame(minWidth: 360, idealWidth: 520)
                    }
                }
            }
            .searchable(text: $state.filter.text, placement: .toolbar,
                        prompt: "Name, text, tag:, app:, site:, or a date")
            .toolbar { LibraryToolbar(state: state) }
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

struct LibraryToolbar: ToolbarContent {
    @Bindable var state: LibraryState

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                ForEach(Preferences.shared.presets) { preset in
                    Button {
                        LibraryWindow.shared.window?.orderOut(nil)
                        CaptureEngine.shared.run(preset)
                    } label: {
                        Label(preset.name, systemImage: preset.mode.symbol)
                    }
                }
            } label: {
                Label("Capture", systemImage: "camera.viewfinder")
            } primaryAction: {
                if let first = Preferences.shared.presets.first {
                    LibraryWindow.shared.window?.orderOut(nil)
                    CaptureEngine.shared.run(first)
                }
            }
            .help("Take a capture. Hold the button for your presets.")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { importFiles() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                .help("Add pictures from files to the library")
            Menu {
                Picker("Sort", selection: $state.sort) {
                    ForEach(LibrarySort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("Thumbnail Size", selection: $state.thumbnailSize) {
                    Text("Small").tag(140.0)
                    Text("Medium").tag(190.0)
                    Text("Large").tag(260.0)
                }
                .pickerStyle(.inline)
            } label: {
                Label("View", systemImage: "square.grid.2x2")
            }
            .help("Sort and thumbnail size")
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

struct LibrarySidebar: View {
    @Bindable var state: LibraryState
    @State private var store = LibraryStore.shared
    @State private var renamingTag: String?
    @State private var newTagName = ""

    var body: some View {
        let items = store.items
        List(selection: Binding(get: { state.section }, set: { state.section = $0 ?? .all; state.selection = [] })) {
            Section("Library") {
                row("All Captures", "photo.on.rectangle", items.count).tag(LibraryState.Section.all)
                row("Favorites", "star", items.filter(\.favorite).count).tag(LibraryState.Section.favorites)
                row("Last 7 Days", "calendar", nil).tag(LibraryState.Section.recent)
                row("With Notes", "note.text", items.filter { !$0.notes.isEmpty }.count).tag(LibraryState.Section.notes)
            }
            let tags = LibraryQuery.tagCounts(items)
            if !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags, id: \.tag) { entry in
                        row(entry.tag, "tag", entry.count)
                            .tag(LibraryState.Section.tag(entry.tag))
                            .contextMenu {
                                Button("Rename Tag…") { renamingTag = entry.tag; newTagName = entry.tag }
                                Button("Remove Tag from All Captures") {
                                    store.setTags(Set(items.map(\.id)), remove: [entry.tag])
                                }
                            }
                    }
                }
            }
            let apps = LibraryQuery.appCounts(items)
            if !apps.isEmpty {
                Section("Apps") {
                    ForEach(apps.prefix(30), id: \.key) { app in
                        Label {
                            HStack { Text(app.name); Spacer(); Text("\(app.count)").foregroundStyle(.secondary).monospacedDigit() }
                        } icon: {
                            AppIcon(bundleID: app.key)
                        }
                        .tag(LibraryState.Section.app(app.key))
                    }
                }
            }
            let sites = LibraryQuery.websiteCounts(items)
            if !sites.isEmpty {
                Section("Websites") {
                    ForEach(sites.prefix(30), id: \.site) { site in
                        row(site.site, "globe", site.count).tag(LibraryState.Section.site(site.site))
                    }
                }
            }
        }
        .listStyle(.sidebar)
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

// MARK: - Filter chips

struct FilterBar: View {
    @Bindable var state: LibraryState
    @State private var store = LibraryStore.shared
    @State private var customDates = false
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @State private var customEnd = Date()

    var body: some View {
        let items = store.items
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Chip(title: state.filter.dateRange == .any ? "Date" : state.filter.dateRange.title,
                     symbol: "calendar", active: state.filter.dateRange != .any,
                     clear: { state.filter.dateRange = .any }) {
                    ForEach(LibraryFilter.DateRange.presets, id: \.self) { range in
                        Button(range.title) { state.filter.dateRange = range }
                    }
                    Divider()
                    Button("Choose Dates…") { customDates = true }
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
                    ForEach(CaptureItem.Kind.allCases, id: \.self) { kind in
                        Toggle(kind.title, isOn: toggle(\.kinds, kind))
                    }
                }

                let tags = LibraryQuery.tagCounts(items)
                Chip(title: chipTitle(Array(state.filter.tags), fallback: "Tags"), symbol: "tag",
                     active: !state.filter.tags.isEmpty, clear: { state.filter.tags = [] }) {
                    if tags.isEmpty { Text("No tags yet") }
                    ForEach(tags, id: \.tag) { entry in
                        Toggle("\(entry.tag) (\(entry.count))", isOn: toggle(\.tags, entry.tag))
                    }
                }

                let apps = LibraryQuery.appCounts(items)
                Chip(title: chipTitle(apps.filter { state.filter.apps.contains($0.key) }.map(\.name), fallback: "App"),
                     symbol: "app", active: !state.filter.apps.isEmpty, clear: { state.filter.apps = [] }) {
                    if apps.isEmpty { Text("No apps yet") }
                    ForEach(apps, id: \.key) { app in
                        Toggle("\(app.name) (\(app.count))", isOn: toggle(\.apps, app.key))
                    }
                }

                let sites = LibraryQuery.websiteCounts(items)
                if !sites.isEmpty {
                    Chip(title: chipTitle(Array(state.filter.websites), fallback: "Website"), symbol: "globe",
                         active: !state.filter.websites.isEmpty, clear: { state.filter.websites = [] }) {
                        ForEach(sites, id: \.site) { site in
                            Toggle("\(site.site) (\(site.count))", isOn: toggle(\.websites, site.site))
                        }
                    }
                }

                ToggleChip(title: "Favorites", symbol: "star", isOn: $state.filter.favoritesOnly)
                ToggleChip(title: "Has Notes", symbol: "note.text", isOn: $state.filter.withNotesOnly)

                if !state.filter.isEmpty {
                    Button("Clear All") { state.filter = LibraryFilter() }
                        .buttonStyle(.link)
                        .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func chipTitle(_ values: [String], fallback: String) -> String {
        switch values.count {
        case 0: fallback
        case 1: values[0]
        default: "\(values[0]) +\(values.count - 1)"
        }
    }

    private func toggle<T: Hashable>(_ path: WritableKeyPath<LibraryFilter, Set<T>>, _ value: T) -> Binding<Bool> {
        Binding(get: { state.filter[keyPath: path].contains(value) },
                set: { on in if on { state.filter[keyPath: path].insert(value) } else { state.filter[keyPath: path].remove(value) } })
    }
}

/// A filter as a rounded button with a menu, tinted while it narrows the list, with an ×
/// to clear it.
struct Chip<Content: View>: View {
    let title: String
    let symbol: String
    let active: Bool
    let clear: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                content()
            } label: {
                Label(title, systemImage: symbol).lineLimit(1)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            if active {
                Button(action: clear) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .help("Clear this filter")
            } else {
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(active ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(active ? Color.accentColor.opacity(0.5) : .clear))
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
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
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
            Button("Copy") { if let png = Flattener.png(item) { Clipboard.copy(png: png) } }
            Button("Copy Text") { Clipboard.copy(text: item.recognizedText) }.disabled(item.recognizedText.isEmpty)
            Button("Save As…") { Exporter.save(item) }
            Divider()
            Button("Rename…") { state.selection = [item.id]; state.renaming = item.id; state.showInspector = true }
            Button("Suggest a Name") { store.suggestName(item.id) }
            if let url = item.source.url.flatMap(URL.init(string:)) {
                Button("Open Web Page") { NSWorkspace.shared.open(url) }
            }
            Divider()
        }
        Button(store.entry(item.id)?.favorite == true && targets.count == 1 ? "Remove from Favorites" : "Add to Favorites") {
            store.toggleFavorite(targets)
        }
        let tags = LibraryQuery.tagCounts(store.items)
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
