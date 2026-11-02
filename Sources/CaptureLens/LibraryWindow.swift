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
            window.title = "SnagAnything"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.setContentSize(NSScreen.fitting(NSSize(width: 1180, height: 760)))
            window.minSize = NSSize(width: 860, height: 520)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("CaptureLensLibrary")
            if window.frame.origin == .zero { window.center() }
            self.window = window
            watchEscape()
        }
        window?.title = state.title
        window?.subtitle = state.subtitle
        if let id {
            state.reveal(id)
        }
        LibrarySync.shared.scan()
        // Another Mac's layout is taken up as the window opens, never while it's in use.
        let opening = window?.isVisible != true
        if opening {
            LibraryLayout.prepareSidebar()
            LibraryLayout.applyIfNew(to: state, window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if opening { LibraryLayout.placeSidebar(in: window) }
    }

    /// Esc leaves a full-width picture once nothing else wants it: the dial closes first, a
    /// selected mark is let go and a tool goes back to Select, and typing keeps it.
    private func watchEscape() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, let window = self.window, event.window === window,
                  self.state.picturesFirst, DialPresenter.shared.request == nil,
                  !(window.firstResponder is NSText), !(window.firstResponder is NSTextField) else { return event }
            let editor = AnnotationEditor.shared
            guard editor.selection == nil, editor.selectedCut == nil, editor.tool == .select else { return event }
            self.state.leaveFullWidth()
            return nil
        }
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
        case all, pinned, favorites, recent, notes, text
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
    /// The selected capture's picture, beside the captures.
    var showInspector = AppDefaults.store.object(forKey: "library.inspector") as? Bool ?? true {
        didSet {
            AppDefaults.store.set(showInspector, forKey: "library.inspector")
            // Asking for the selected capture brings it back from a slim bar too.
            if showInspector && foldedSide == .editor { foldedSide = nil }
        }
    }

    /// A toolbar button for each preset, after Capture (View › Show Preset Buttons).
    var showPresetButtons = AppDefaults.store.bool(forKey: "library.presetButtons") {
        didSet { AppDefaults.store.set(showPresetButtons, forKey: "library.presetButtons") }
    }

    /// The details (name, tags, notes, where it came from) in the inspector at the window's
    /// right edge.
    var showInfo = AppDefaults.store.object(forKey: "library.info") as? Bool ?? true {
        didSet { AppDefaults.store.set(showInfo, forKey: "library.info") }
    }

    /// The picture is out of sight: hidden, or folded to a slim bar.
    var pictureHidden: Bool { !showInspector || foldedSide == .editor }

    /// The picture fills the width, with the captures folded to a filmstrip under it: chosen
    /// with View › Picture Full Width, the toolbar, a right-click, or as what a click does.
    var picturesFirst: Bool { !pictureHidden && foldedSide == .captures }

    /// The filmstrip under a full-width picture, with the button that brings the grid back.
    var showsFilmstrip: Bool { picturesFirst }

    /// Leaving full width goes back to the layout it was entered from: the picture beside the
    /// captures, or the captures alone.
    private var fullWidthFromGrid = AppDefaults.store.bool(forKey: "library.fullWidthFromGrid") {
        didSet { AppDefaults.store.set(fullWidthFromGrid, forKey: "library.fullWidthFromGrid") }
    }

    func showFullWidth() {
        guard !picturesFirst else { return }
        fullWidthFromGrid = pictureHidden
        // Out of its own window, back into the library.
        if EditorWindow.shared.isOpen { EditorWindow.shared.close() }
        showInspector = true
        fold(.captures)
    }

    func leaveFullWidth() {
        guard picturesFirst else { return }
        fold(fullWidthFromGrid ? .editor : nil)
        fullWidthFromGrid = false
        scrollTarget = anchor ?? selection.first
    }

    func toggleFullWidth() {
        if picturesFirst { leaveFullWidth() } else { showFullWidth() }
    }

    /// The grid is on screen, so the thumbnail commands apply.
    var gridVisible: Bool { !picturesFirst }

    /// View › Hide Picture and Show Picture.
    func setPictureHidden(_ hidden: Bool) {
        if hidden {
            fold(.editor)
        } else {
            showInspector = true
            fold(nil)
        }
    }

    /// The window's title: the place picked in the sidebar.
    var title: String {
        switch section {
        case .all: "All Captures"
        case .pinned: "Pinned"
        case .favorites: "Favorites"
        case .recent: "Last 7 Days"
        case .notes: "With Notes"
        case .text: "Text Captures"
        case .tag(let tag): tag
        case .app(let key): LibraryStore.shared.facets.apps.first { $0.key == key }?.name ?? "App"
        case .site(let site): site
        }
    }

    /// Under the title: how many captures are showing, and how many of them are selected.
    var subtitle: String {
        let shown = results.count
        if selection.count > 1 { return "\(selection.count) of \(shown) selected" }
        return "\(shown) capture\(shown == 1 ? "" : "s")"
    }

    /// The side folded down to a slim bar, so the other fills the window: the captures, or
    /// the selected capture (its picture and details).
    enum Side: String { case captures, editor }
    var foldedSide = Side(rawValue: AppDefaults.store.string(forKey: "library.foldedSide") ?? "") {
        didSet { AppDefaults.store.set(foldedSide?.rawValue ?? "", forKey: "library.foldedSide") }
    }

    func fold(_ side: Side?) {
        withAnimation(Motion.ui) { foldedSide = side }
    }
    /// A capture double-clicked: shown beside the captures, or in a window of its own, as
    /// Settings › Library says.
    /// `place`, from the right-click menu, overrides the setting, and with `remember` becomes it.
    func open(_ id: UUID, in place: OpenPlace? = nil, remember: Bool = false) {
        selection = [id]
        anchor = id
        let prefs = Preferences.shared
        if let place, remember { prefs.doubleClickOpens = place }
        switch place ?? prefs.doubleClickOpens {
        case .ownWindow:
            EditorWindow.shared.open()
        case .fullWidth:
            showFullWidth()
        case .sidePane:
            // Out of its own window or full width, back beside the captures.
            if EditorWindow.shared.isOpen { EditorWindow.shared.close() }
            showInspector = true
            if foldedSide != nil { fold(nil) }
            fullWidthFromGrid = false
        }
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
        case .pinned: f.pinnedOnly = true
        case .favorites: f.favoritesOnly = true
        case .recent: if f.dateRange == .any { f.dateRange = .lastWeek }
        case .notes: f.withNotesOnly = true
        case .text: f.kinds = [.text]
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

    /// A click on a thumbnail in the grid: selects it, and with Settings › Library set to
    /// show clicked captures full width, gives its picture the window.
    func clickInGrid(_ id: UUID, in list: [CaptureItem]) {
        click(id, in: list)
        let plain = NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty
        if plain, Preferences.shared.clickShows == .fullWidth, !EditorWindow.shared.isOpen { showFullWidth() }
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
    /// The selected capture's share of the room beside the sidebar, set by dragging the line
    /// beside it. A share rather than points, so it carries to a Mac with another screen.
    @AppStorage(LibraryLayout.detailKey, store: AppDefaults.store) private var detailShare = LibraryLayout.defaultDetail

    /// The narrowest the captures or the picture go: 360 points, or half the room in a small
    /// window, so the two always fit side by side.
    static func paneMinimum(_ room: CGFloat) -> Double { min(360, max(0, Double(room) / 2 - 1)) }

    /// Room for the selected capture, leaving the captures at least as much as it needs.
    static func detailRange(_ room: CGFloat) -> ClosedRange<Double> {
        let minimum = paneMinimum(room)
        return minimum...max(minimum, Double(room) - minimum - 1)
    }

    /// The selected capture's width in points, from its share.
    private func detailWidth(_ room: CGFloat) -> Binding<Double> {
        Binding(get: { Self.detailRange(room).clamp(detailShare * Double(room)) },
                set: { detailShare = room > 0 ? $0 / Double(room) : LibraryLayout.defaultDetail })
    }

    var body: some View {
        if lock.isLocked {
            LockedView()
        } else {
            NavigationSplitView(columnVisibility: $columns) {
                LibrarySidebar(state: state)
                    .navigationSplitViewColumnWidth(min: LibrarySidebar.railWidth, ideal: 210, max: 300)
            } detail: {
                // The room the window gives, not what the columns ask for, sets how wide the line can go.
                GeometryReader { room in
                let first = state.picturesFirst
                VStack(spacing: 0) {
                HStack(spacing: 0) {
                    // Each part is its own child of the stack, and the picture is always the
                    // same one: moving it elsewhere in the layout would make a new picture view,
                    // which loads its capture into the markup editor afresh.
                    if !first {
                        // The title and count are the window's; the thumbnail size is in View.
                        VStack(spacing: 0) {
                            FilterBar(state: state)
                            Divider()
                            CaptureGrid(state: state)
                        }
                        .frame(minWidth: Self.paneMinimum(room.size.width))
                    }
                    if state.showInspector && state.foldedSide == .editor {
                        Divider()
                        CollapsedSideBar(title: "Picture", symbol: "photo", edge: .trailing) { state.fold(nil) }
                    }
                    if !first && !state.pictureHidden {
                        // Drag the line between them to share the room differently.
                        PaneDivider(axis: .columns, length: detailWidth(room.size.width), range: Self.detailRange(room.size.width),
                                    reset: { detailShare = LibraryLayout.defaultDetail })
                    }
                    if !state.pictureHidden {
                        CaptureDetail(state: state)
                            .frame(width: first ? nil : detailWidth(room.size.width).wrappedValue)
                            .frame(maxWidth: first ? .infinity : nil)
                    }
                }
                if state.showsFilmstrip {
                    Divider()
                    Filmstrip(state: state)
                }
                }
                .frame(width: room.size.width, height: room.size.height)
                }
                // The tool dial floats over the grid and the picture.
                .overlay { DialOverlay() }
            }
            .background(SidebarStaysOpen())
            // The details get a full-height column of their own at the right edge, with the
            // button that shows and hides them over it.
            .inspector(isPresented: $state.showInfo) {
                InfoInspector(state: state)
                    .inspectorColumnWidth(min: 240, ideal: LibraryLayout.infoWidth, max: 420)
                    .toolbar {
                        ToolbarSpacer(.flexible)
                        ToolbarItem(placement: .primaryAction) {
                            Button { state.showInfo.toggle() } label: {
                                Label(state.showInfo ? "Hide Details" : "Show Details", systemImage: "sidebar.trailing")
                            }
                            .help("\(state.showInfo ? "Hide" : "Show") the details: name, tags, notes and where it came from (⌃⌘I)")
                        }
                    }
            }
            .navigationTitle(state.title)
            .navigationSubtitle(state.subtitle)
            .onAppear { DispatchQueue.main.async { showTitle() } }
            .onChange(of: state.title) { showTitle() }
            .onChange(of: state.subtitle) { showTitle() }
            .onChange(of: columns) { _, shown in
                guard shown != .all else { return }
                DispatchQueue.main.async {
                    columns = .all
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        SidebarStaysOpen.Finder.showIcons(in: LibraryWindow.shared.window)
                    }
                }
            }
            .searchable(text: $state.filter.text, tokens: filterTokens, placement: .toolbar,
                        prompt: "Name, text, tag:, app:, site:, or a date") { token in
                Text(token.title)
            }
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

    /// The title names the place picked in the sidebar; the subtitle counts what's in it.
    private func showTitle() {
        guard let window = LibraryWindow.shared.window else { return }
        window.title = state.title
        window.subtitle = state.subtitle
    }

    /// The filters in use, as tokens in the search field; removing one there clears it.
    private var filterTokens: Binding<[FilterToken]> {
        Binding(get: { FilterToken.tokens(for: state.filter, apps: store.facets.apps) },
                set: { kept in
                    let ids = Set(kept.map(\.id))
                    for token in FilterToken.tokens(for: state.filter, apps: store.facets.apps) where !ids.contains(token.id) {
                        token.clear(&state.filter)
                    }
                })
    }
}

/// A filter in use, shown as a token in the search field.
struct FilterToken: Identifiable, Hashable {
    enum Kind: Hashable { case date, kind(CaptureItem.Kind), tag(String), app(String), site(String), notes, favorites }
    let kind: Kind
    let title: String
    var id: Kind { kind }

    static func tokens(for filter: LibraryFilter, apps: [(key: String, name: String, count: Int)]) -> [FilterToken] {
        var list: [FilterToken] = []
        if filter.dateRange != .any { list.append(.init(kind: .date, title: filter.dateRange.title)) }
        for kind in CaptureItem.Kind.allCases where filter.kinds.contains(kind) { list.append(.init(kind: .kind(kind), title: kind.title)) }
        for tag in filter.tags.sorted() { list.append(.init(kind: .tag(tag), title: tag)) }
        for key in filter.apps.sorted() { list.append(.init(kind: .app(key), title: apps.first { $0.key == key }?.name ?? key)) }
        for site in filter.websites.sorted() { list.append(.init(kind: .site(site), title: site)) }
        if filter.withNotesOnly { list.append(.init(kind: .notes, title: "Has Notes")) }
        if filter.favoritesOnly { list.append(.init(kind: .favorites, title: "Favorites")) }
        return list
    }

    func clear(_ filter: inout LibraryFilter) {
        switch kind {
        case .date: filter.dateRange = .any
        case .kind(let kind): filter.kinds.remove(kind)
        case .tag(let tag): filter.tags.remove(tag)
        case .app(let key): filter.apps.remove(key)
        case .site(let site): filter.websites.remove(site)
        case .notes: filter.withNotesOnly = false
        case .favorites: filter.favoritesOnly = false
        }
    }
}

/// A line between two panes that can be dragged to share the room differently: between the
/// captures and the selected capture (columns), or the picture and its details (rows).
/// Double-click it to go back to the usual share.
struct PaneDivider: View {
    enum Axis { case columns, rows }
    let axis: Axis
    /// The size of the pane it resizes: the one on the right of columns, above rows.
    @Binding var length: Double
    let range: ClosedRange<Double>
    let reset: () -> Void
    @State private var start: Double?

    var body: some View {
        Divider()
            .overlay {
                // A wider grip than the line itself.
                Color.clear
                    .frame(width: axis == .columns ? 9 : nil, height: axis == .rows ? 9 : nil)
                    .contentShape(Rectangle())
                    .pointerStyle(axis == .columns ? .columnResize : .rowResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let from = start ?? range.clamp(length)
                                start = from
                                // Columns: the pane is on the right, so dragging left widens it.
                                // Rows: the pane is above, so dragging down makes it taller.
                                length = range.clamp(axis == .columns ? from - drag.translation.width : from + drag.translation.height)
                            }
                            .onEnded { _ in start = nil }
                    )
                    .onTapGesture(count: 2, perform: reset)
                    .help(axis == .columns ? "Drag to make the captures wider or narrower"
                                           : "Drag to make the picture taller or shorter")
            }
            // Above the panes on both sides, so all of the grip takes the drag.
            .zIndex(1)
    }
}

extension ClosedRange where Bound == Double {
    func clamp(_ value: Double) -> Double { Swift.min(Swift.max(value, lowerBound), upperBound) }
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

/// The library's toolbar: the ways to capture over the captures, the selected capture's
/// actions over its picture. View › Show Preset Buttons adds a button for each preset.
struct LibraryToolbar: ToolbarContent {
    @Bindable var state: LibraryState

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            CaptureMenuButton()
            RecordButton()
            Button { CaptureActions.captureText() } label: { Label("Capture Text", systemImage: "text.viewfinder") }
                .help("Capture Text: drag over text on screen to copy it\(CaptureActions.keys(Preferences.shared.captureTextHotKey))")
        }
        if state.showPresetButtons {
            ToolbarItemGroup(placement: .navigation) {
                ForEach(Preferences.shared.presets) { preset in
                    Button { CaptureActions.run(preset) } label: {
                        Label(preset.name, systemImage: preset.delay > 0 ? "timer" : preset.mode.symbol)
                    }
                    .help("\(preset.name): \(preset.summary)\(CaptureActions.keys(preset.hotKey))")
                }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            SelectionActions.FullWidthToggle(state: state)
            SelectionActions.MarkupToggle(state: state)
            SelectionActions.FavoriteButton(state: state)
            SelectionActions.ShareToolbarButton(state: state)
        }
        // Settings in a glass button of its own, apart from the buttons that act on a capture.
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button { SettingsWindow.shared.show() } label: { Label("Settings", systemImage: "gearshape") }
                .help("Open SnagAnything Settings (⌘,)")
        }
    }
}

/// Starting a capture from the library: the window steps aside first, so it isn't in the way.
@MainActor
enum CaptureActions {
    static func run(_ preset: CapturePreset) {
        LibraryWindow.shared.window?.orderOut(nil)
        CaptureEngine.shared.run(preset)
    }

    static func captureText() {
        LibraryWindow.shared.window?.orderOut(nil)
        CaptureEngine.shared.captureText()
    }

    /// " (⌥⇧⌘4)" to end a tooltip with, or nothing without a shortcut.
    static func keys(_ hotKey: HotKey?) -> String {
        hotKey.map { " (\($0.display))" } ?? ""
    }
}

/// What the menu bar's library commands act on.
@MainActor
enum LibraryCommands {
    /// The library, or the selected capture in its own window, is in front.
    static var libraryInFront: Bool {
        guard let key = NSApp.keyWindow else { return false }
        return key === LibraryWindow.shared.window || EditorWindow.shared.isKey
    }

    /// ⌘+ and ⌘− zoom the picture (rather than size the thumbnails) when it's what's being
    /// worked on: in its own window, filling the library, or the last thing clicked.
    static var zoomsPicture: Bool {
        guard let item = single, item.kind != .video else { return false }
        if EditorWindow.shared.isKey { return true }
        let state = LibraryWindow.shared.state
        guard !state.pictureHidden, !EditorWindow.shared.isOpen else { return false }
        if !state.gridVisible { return true }
        var view = NSApp.keyWindow?.firstResponder as? NSView
        while let current = view {
            if current is ZoomingScrollView || (current as? NSScrollView)?.documentView is CheckerImageView { return true }
            view = current.superview
        }
        return false
    }

    /// The one selected capture, if just one is.
    static var single: CaptureItem? {
        let selected = LibraryWindow.shared.state.selectedItems
        return selected.count == 1 ? selected[0] : nil
    }

    /// Edit › Copy with captures selected: one picture as itself, marks drawn in, so it pastes
    /// anywhere; a video or several captures as files.
    static func copyProviders(_ items: [CaptureItem]) -> [NSItemProvider] {
        guard !items.isEmpty else { return [] }
        ActivityStore.shared.record(ActivityKey.copies, count: items.count)
        if items.count == 1, items[0].kind != .video, let png = Flattener.png(items[0]) {
            Notice.shared.show("Copied")
            return [NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)]
        }
        Notice.shared.show(items.count == 1 ? "Copied" : "Copied \(items.count) captures")
        return items.compactMap(Flattener.temporaryFile).compactMap { NSItemProvider(contentsOf: $0) }
    }
}

/// Capture: a click takes the first preset; the arrow lists every way to capture.
private struct CaptureMenuButton: View {
    @State private var prefs = Preferences.shared

    var body: some View {
        let first = prefs.presets.first { $0.mode != .recording } ?? prefs.presets.first
        Menu {
            ForEach(prefs.presets.filter { $0.mode != .recording }) { preset in
                Button { CaptureActions.run(preset) } label: {
                    Label(preset.name + CaptureActions.keys(preset.hotKey), systemImage: preset.delay > 0 ? "timer" : preset.mode.symbol)
                }
            }
            Divider()
            Button { CaptureActions.captureText() } label: {
                Label("Capture Text" + CaptureActions.keys(prefs.captureTextHotKey), systemImage: "text.viewfinder")
            }
            Button("Capture Same Area Again" + CaptureActions.keys(prefs.captureAgainHotKey)) {
                LibraryWindow.shared.window?.orderOut(nil)
                CaptureEngine.shared.captureAgain()
            }
            .disabled(CaptureEngine.shared.lastRegion == nil)
            Button("Record Steps…") { StepRecorder.shared.start() }
        } label: {
            // The same symbol as the capture bar's Capture button and the menu bar icon.
            Label("Capture", systemImage: "camera.viewfinder")
                .labelStyle(.titleAndIcon)
        } primaryAction: {
            if let first { CaptureActions.run(first) }
        }
        .help(first.map { "\($0.name)\(CaptureActions.keys($0.hotKey)). Click the arrow for every way to capture." }
              ?? "Every way to capture")
    }
}

/// Record: the first recording preset; with several, the arrow lists them all.
private struct RecordButton: View {
    @State private var prefs = Preferences.shared

    var body: some View {
        let recordings = prefs.presets.filter { $0.mode == .recording }
        if recordings.count > 1 {
            Menu {
                ForEach(recordings) { preset in
                    Button(preset.name + CaptureActions.keys(preset.hotKey)) { CaptureActions.run(preset) }
                }
            } label: {
                Label("Record", systemImage: "record.circle")
            } primaryAction: {
                CaptureActions.run(recordings[0])
            }
            .help("\(recordings[0].name)\(CaptureActions.keys(recordings[0].hotKey)). Click the arrow for the other recordings.")
        } else {
            Button { if let preset = recordings.first { CaptureActions.run(preset) } } label: {
                Label("Record", systemImage: "record.circle")
            }
            .disabled(recordings.isEmpty)
            .help(recordings.first.map { "Record a video of the screen\(CaptureActions.keys($0.hotKey))" }
                  ?? "Add a Video recording preset in Settings › Presets to record from here")
        }
    }
}

/// What can be done to the selected capture from the toolbar: mark it up, favorite it,
/// share it. The rest is in the menus and its right-click menu.
enum SelectionActions {
    /// On: the markup tools, over the original. Off: the finished picture, as it's copied
    /// and saved.
    struct MarkupToggle: View {
        let state: LibraryState
        @State private var editor = AnnotationEditor.shared

        var body: some View {
            let item = state.selectedItems.count == 1 ? state.selectedItems.first : nil
            let usable = item != nil && item?.kind != .video
            Toggle(isOn: Binding(get: { usable && !editor.showResult }, set: { editor.showResult = !$0 })) {
                Label("Markup", systemImage: "pencil.tip.crop.circle")
            }
            .disabled(!usable)
            .help(editor.showResult ? "Show the markup tools, to annotate and adjust the picture (⇧⌘A)"
                                    : "Hide the markup tools and see the finished picture, as it's copied and saved (⇧⌘A)")
        }
    }

    /// The picture across the whole library, or back beside the captures (or the captures
    /// alone, if that's where it came from).
    struct FullWidthToggle: View {
        let state: LibraryState

        var body: some View {
            let on = state.picturesFirst
            Toggle(isOn: Binding(get: { on }, set: { _ in state.toggleFullWidth() })) {
                Label(on ? "Show Captures" : "Picture Full Width",
                      systemImage: on ? "square.grid.2x2" : "arrow.up.left.and.arrow.down.right")
            }
            .disabled(!on && state.selection.count != 1)
            .help(on ? "Show the captures again (Esc or ⌥⌘1)" : "Show the picture across the whole window, with the captures in a strip under it (⌥⌘1)")
        }
    }

    struct FavoriteButton: View {
        let state: LibraryState

        var body: some View {
            let items = state.selectedItems
            let all = !items.isEmpty && items.allSatisfy(\.favorite)
            Button { LibraryStore.shared.toggleFavorite(state.selection) } label: {
                Label(all ? "Remove from Favorites" : "Add to Favorites", systemImage: all ? "star.fill" : "star")
            }
            .disabled(items.isEmpty)
            .help(all ? "Remove from Favorites" : "Add to Favorites")
        }
    }

    struct ShareToolbarButton: View {
        let state: LibraryState

        var body: some View {
            // A toolbar button like its neighbors (an AppKit one sits smaller and off-center
            // there); the share menu opens at the click, just under it.
            Button { ShareButton.shareAtPointer(state.selectedItems) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                .disabled(state.selection.isEmpty)
                .help(state.selection.count > 1 ? "Share the selected captures" : "Share the selected capture")
        }
    }
}

// MARK: - Sidebar

/// Stops the sidebar from being dragged out of sight: past its narrowest it stays as icons.
/// SwiftUI's split view lets a column collapse (and turns that back on as it updates), so
/// this turns it off on the AppKit split view underneath whenever a resize starts.
struct SidebarStaysOpen: NSViewRepresentable {
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
            withAnimation(Motion.fold) { open.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if !open { Text("\(count)").foregroundStyle(.tertiary).monospacedDigit() }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
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
    /// Every tag, or just the most used.
    @AppStorage("library.sidebar.allTags", store: AppDefaults.store) private var showAllTags = false
    private static let tagsShown = 8

    /// The most used tags, still in A–Z order.
    private static func mostUsed(_ tags: [(tag: String, count: Int)]) -> [(tag: String, count: Int)] {
        guard tags.count > tagsShown else { return tags }
        let kept = Set(tags.sorted { $0.count > $1.count }.prefix(tagsShown).map(\.tag))
        return tags.filter { kept.contains($0.tag) }
    }
    /// Narrower than this, the sidebar is a column of icons.
    @State private var compact = false

    /// The narrowest the sidebar goes: room for its icons and the window's buttons above them.
    static let railWidth: CGFloat = 72
    private static let compactBelow: CGFloat = 130

    /// Showing just its icons now.
    @MainActor static var isCompact: Bool { LibraryLayout.sidebarWidth > 0 && LibraryLayout.sidebarWidth < compactBelow }
    /// The width to go back to from the icons.
    @MainActor private static var fullWidth: CGFloat = 210

    /// View › Show Sidebar as Icons, and back (⌃⌘S). The sidebar never hides altogether:
    /// with nothing left on screen, there'd be nothing to bring it back with.
    @MainActor static func toggleCompact(in window: NSWindow?) {
        guard let split = SidebarStaysOpen.Finder.splitView(in: window?.contentView) else { return }
        if isCompact {
            split.setPosition(fullWidth, ofDividerAt: 0)
        } else {
            fullWidth = max(CGFloat(LibraryLayout.sidebarWidth), compactBelow + 40)
            split.setPosition(railWidth, ofDividerAt: 0)
        }
    }

    var body: some View {
        Group {
            if compact { rail } else { list }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.compactBelow } action: { compact = $0 }
        // Noted for the layout other Macs follow.
        .onGeometryChange(for: Double.self) { Double($0.size.width.rounded()) } action: { LibraryLayout.sidebarWidth = $0 }
    }

    private var list: some View {
        let items = store.items
        return List(selection: Binding(get: { state.section }, set: { state.section = $0 ?? .all; state.selection = [] })) {
            Section("Library") {
                row("All Captures", "photo.on.rectangle", items.count).tag(LibraryState.Section.all)
                row("Pinned", "pin", items.filter(\.pinned).count).tag(LibraryState.Section.pinned)
                row("Favorites", "star", items.filter(\.favorite).count).tag(LibraryState.Section.favorites)
                row("Last 7 Days", "calendar", nil).tag(LibraryState.Section.recent)
                row("With Notes", "note.text", items.filter { !$0.notes.isEmpty }.count).tag(LibraryState.Section.notes)
                row("Text Captures", "text.viewfinder", items.filter { $0.kind == .text }.count).tag(LibraryState.Section.text)
            }
            let tags = store.facets.tags
            if !tags.isEmpty {
                Section {
                    // Rows like Apps and Websites: the most used first, the rest a click away.
                    // Right-click one to rename or remove it.
                    if tagsOpen {
                        ForEach(showAllTags ? tags : Self.mostUsed(tags), id: \.tag) { entry in
                            row(entry.tag, "tag", entry.count, quiet: true)
                                .tag(LibraryState.Section.tag(entry.tag))
                                .contextMenu {
                                    Button("Rename Tag…") { renamingTag = entry.tag; newTagName = entry.tag }
                                    Button("Remove Tag from All Captures") {
                                        store.setTags(Set(items.map(\.id)), remove: [entry.tag])
                                    }
                                }
                        }
                        if tags.count > Self.tagsShown {
                            Button {
                                withAnimation(Motion.fold) { showAllTags.toggle() }
                            } label: {
                                Label(showAllTags ? "Show Fewer" : "\(tags.count - Self.tagsShown) More", systemImage: "ellipsis")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .selectionDisabled()
                        }
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
                        row(site.site, "globe", site.count, quiet: true).tag(LibraryState.Section.site(site.site))
                    } }
                } header: {
                    FoldingHeader(title: "Websites", count: sites.count, open: $sitesOpen)
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
                railButton("Pinned", "pin", items.filter(\.pinned).count, .pinned)
                railButton("Favorites", "star", items.filter(\.favorite).count, .favorites)
                railButton("Last 7 Days", "calendar", nil, .recent)
                railButton("With Notes", "note.text", items.filter { !$0.notes.isEmpty }.count, .notes)
                railButton("Text Captures", "text.viewfinder", items.filter { $0.kind == .text }.count, .text)
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
                .background(picked ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: Radius.control))
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
                .background(picked ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: Radius.control))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(title): pick one to show its captures")
        .accessibilityLabel(title)
    }

    /// A place: its symbol, name and count. Tags, apps and websites have quieter symbols than
    /// the library's own places, and an empty place shows no count.
    private func row(_ title: String, _ symbol: String, _ count: Int?, quiet: Bool = false) -> some View {
        Label {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                if let count, count > 0 { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
            }
        } icon: {
            if quiet { Image(systemName: symbol).foregroundStyle(.secondary) } else { Image(systemName: symbol) }
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
        // Every filter as its own pill when they fit; in a narrower pane, one Filters pill
        // with each of them inside. Filters in use show as tokens in the search field either way.
        HStack(spacing: Space.sm) {
            ViewThatFits(in: .horizontal) {
                pills
                filtersMenu
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .popover(isPresented: $customDates) { datePopover }
            SortMenu(state: state)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
    }

    private var pills: some View {
        HStack(spacing: Space.sm) {
            Chip(title: state.filter.dateRange == .any ? "Date" : state.filter.dateRange.title,
                 symbol: "calendar", active: state.filter.dateRange != .any,
                 clear: { state.filter.dateRange = .any }) { dateItems }
            Chip(title: chipTitle(state.filter.kinds.map(\.title), fallback: "Type"), symbol: "rectangle.dashed",
                 active: !state.filter.kinds.isEmpty, clear: { state.filter.kinds = [] }) { typeItems }
            // The lists are made when a menu opens, from counts the library keeps.
            Chip(title: chipTitle(Array(state.filter.tags), fallback: "Tags"), symbol: "tag",
                 active: !state.filter.tags.isEmpty, clear: { state.filter.tags = [] }) { tagItems }
            Chip(title: chipTitle(store.facets.apps.filter { state.filter.apps.contains($0.key) }.map(\.name), fallback: "App"),
                 symbol: "app", active: !state.filter.apps.isEmpty, clear: { state.filter.apps = [] }) { appItems }
            if !store.facets.websites.isEmpty {
                Chip(title: chipTitle(Array(state.filter.websites), fallback: "Website"), symbol: "globe",
                     active: !state.filter.websites.isEmpty, clear: { state.filter.websites = [] }) { siteItems }
            }
            // Favorites is a place in the sidebar, so it isn't a filter here too.
            ToggleChip(title: "Has Notes", symbol: "note.text", isOn: $state.filter.withNotesOnly)
            if !state.filter.isEmpty {
                Button("Clear All") { state.filter = LibraryFilter() }
                    .buttonStyle(.link)
                    .padding(.leading, Space.xs)
            }
        }
        .fixedSize()
    }

    /// All the filters behind one pill, when the pills don't fit.
    private var filtersMenu: some View {
        let inUse = FilterToken.tokens(for: state.filter, apps: store.facets.apps).count
        return Chip(title: inUse == 0 ? "Filters" : "Filters (\(inUse))", symbol: "line.3.horizontal.decrease",
                    active: inUse > 0, clear: { state.filter = LibraryFilter() }) {
            var items: [ChipMenu.Item] = [
                .submenu("Date", dateItems), .submenu("Type", typeItems), .submenu("Tags", tagItems), .submenu("App", appItems),
            ]
            if !store.facets.websites.isEmpty { items.append(.submenu("Website", siteItems)) }
            items.append(.action("Has Notes", checked: state.filter.withNotesOnly) { state.filter.withNotesOnly.toggle() })
            return items
        }
        .fixedSize()
    }

    private var dateItems: [ChipMenu.Item] {
        LibraryFilter.DateRange.presets.map { range in
            .action(range.title, checked: state.filter.dateRange == range) { state.filter.dateRange = range }
        } + [.separator, .action("Choose Dates…") { customDates = true }]
    }

    private var typeItems: [ChipMenu.Item] {
        CaptureItem.Kind.allCases.map { kind in toggle(\.kinds, kind, title: kind.title) }
    }

    private var tagItems: [ChipMenu.Item] {
        let tags = store.facets.tags
        return tags.isEmpty ? [.note("No tags yet")] : tags.map { toggle(\.tags, $0.tag, title: "\($0.tag) (\($0.count))") }
    }

    private var appItems: [ChipMenu.Item] {
        let apps = store.facets.apps
        return apps.isEmpty ? [.note("No apps yet")] : apps.map { toggle(\.apps, $0.key, title: "\($0.name) (\($0.count))") }
    }

    private var siteItems: [ChipMenu.Item] {
        store.facets.websites.map { toggle(\.websites, $0.site, title: "\($0.site) (\($0.count))") }
    }

    private var datePopover: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
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
        .padding(Space.lg)
        .frame(width: 260)
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

/// At the end of the filter bar: the order the captures are in.
private struct SortMenu: View {
    @Bindable var state: LibraryState

    var body: some View {
        Menu {
            Picker("Sort", selection: $state.sort) {
                ForEach(LibrarySort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Text(state.sort.title)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.callout)
        .foregroundStyle(.secondary)
        .help("The order the captures are in")
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
        case submenu(String, [Item])
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
        let menu = build(items)
        if let view {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    private static func build(_ items: [Item]) -> NSMenu {
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
            case .submenu(let title, let entries):
                let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                entry.submenu = build(entries)
                menu.addItem(entry)
            }
        }
        return menu
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

    /// What an empty Pinned or Text Captures list says instead of "No Matches".
    private var emptyList: (title: String, symbol: String, hint: String)? {
        switch state.section {
        case .pinned:
            ("No Pinned Captures", "pin", "Right-click a capture and choose Pin Image to keep it here.")
        case .text:
            ("No Text Captures", "text.viewfinder",
             "Press \(Preferences.shared.captureTextHotKey?.display ?? "the Capture Text button") and drag over text on screen. The text is copied, and the capture is kept here.")
        default: nil
        }
    }

    var body: some View {
        let list = state.results
        Group {
            if list.isEmpty, !store.items.isEmpty, state.filter.isEmpty, let empty = emptyList {
                // A sidebar list with nothing in it yet says how things get there.
                ContentUnavailableView(empty.title, systemImage: empty.symbol, description: Text(empty.hint))
            } else if list.isEmpty {
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
                                    .onTapGesture(count: 2) { state.open(item.id) }
                                    .simultaneousGesture(TapGesture().onEnded { state.clickInGrid(item.id, in: list); focused = true })
                                    .onDrag { CaptureGrid.dragProvider(item) }
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
                // Edit › Copy (⌘C): the selected captures as they look, marks drawn in.
                .onCopyCommand { LibraryCommands.copyProviders(state.selectedItems) }
                .onKeyPress(.return) {
                    guard let id = state.selection.first else { return .ignored }
                    state.showInfo = true
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

    /// A capture dragged out (to Finder, Mail, anywhere): a file of it as it looks.
    static func dragProvider(_ item: CaptureItem) -> NSItemProvider {
        guard let url = Flattener.temporaryFile(item) else { return NSItemProvider() }
        ActivityStore.shared.record(ActivityKey.drags)
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }
}

/// Under the picture while it's marked up: the same captures as the grid (the same place,
/// search and filters) in one row, so the picture gets the window. Click one to mark it up,
/// or use ← and →.
struct Filmstrip: View {
    @Bindable var state: LibraryState
    @State private var store = LibraryStore.shared
    @FocusState private var focused: Bool

    /// A 64-pt picture with its selection ring, and 16 pt above and below.
    static let height: CGFloat = 96

    var body: some View {
        let list = state.results
        HStack(spacing: 0) {
            // The way back from full width, always in sight at the strip's start.
            Button { state.leaveFullWidth() } label: {
                VStack(spacing: Space.xs) {
                    Image(systemName: "square.grid.2x2").font(.title3)
                    Text("Captures").font(.caption)
                }
                .frame(width: 72, height: 64)
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .padding(.leading, Space.lg)
            .help("Show the captures again (Esc or ⌥⌘1)")
            filmstrip(list)
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    @ViewBuilder private func filmstrip(_ list: [CaptureItem]) -> some View {
        Group {
            if list.isEmpty {
                Text(store.items.isEmpty ? "No captures yet" : "Nothing matches the search and filters")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: Space.md) {
                            ForEach(list) { item in
                                FilmstripCell(item: item, selected: state.selection.contains(item.id))
                                    .id(item.id)
                                    .onTapGesture(count: 2) { state.open(item.id) }
                                    .simultaneousGesture(TapGesture().onEnded { state.click(item.id, in: list); focused = true })
                                    .onDrag { CaptureGrid.dragProvider(item) }
                                    .contextMenu { CaptureMenu(state: state, item: item) }
                            }
                        }
                        .padding(.horizontal, Space.lg)
                        .frame(maxHeight: .infinity)
                    }
                    .scrollIndicators(.automatic)
                    // It opens on the capture being marked up.
                    .onAppear { if let id = state.anchor ?? state.selection.first { proxy.scrollTo(id, anchor: .center) } }
                    .onChange(of: state.scrollTarget) { _, id in
                        guard let id else { return }
                        withAnimation(Motion.ui) { proxy.scrollTo(id, anchor: .center) }
                        state.scrollTarget = nil
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            guard direction == .left || direction == .right else { return }
            state.move(direction, columns: 1, in: list)
        }
        .onDeleteCommand { if !state.selection.isEmpty { state.confirmDelete = state.selection } }
        .onCopyCommand { LibraryCommands.copyProviders(state.selectedItems) }
    }
}

/// A capture in the filmstrip: its picture, ringed in the accent color when selected.
private struct FilmstripCell: View {
    let item: CaptureItem
    let selected: Bool
    @State private var store = LibraryStore.shared
    @Environment(\.appearsActive) private var active

    private static let pictureHeight: CGFloat = 64

    var body: some View {
        let image = store.thumbnail(item)
        let aspect = image.map { $0.size.width / max($0.size.height, 1) } ?? 1.5
        // Very wide or tall pictures keep a sensible shape.
        let width = (Self.pictureHeight * min(max(aspect, 0.6), 3)).rounded()
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .frame(width: width, height: Self.pictureHeight)
        .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
        .overlay {
            if item.kind == .video {
                Image(systemName: "play.circle.fill").font(.title3).foregroundStyle(.white, .black.opacity(0.45))
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        .padding(Space.xs)
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: Radius.control)
                    .strokeBorder(active ? Color.accentColor : Color.secondary, lineWidth: 3)
            }
        }
        .contentShape(Rectangle())
        .help(item.name)
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct CaptureCell: View {
    let item: CaptureItem
    let size: Double
    let selected: Bool
    let analyzing: Bool
    @State private var store = LibraryStore.shared
    @Environment(\.appearsActive) private var active

    var body: some View {
        VStack(spacing: Space.sm) {
            // Pictures stand on the cell's bottom edge, so every name starts the same distance
            // under its picture.
            ZStack(alignment: .bottom) {
                // Selected, a gray backing like Finder's, so nothing covers the picture itself.
                RoundedRectangle(cornerRadius: Radius.control).fill(selected ? Color.secondary.opacity(0.22) : .clear)
                if let image = store.thumbnail(item) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                        .padding(Space.sm)
                } else {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(.tertiary)
                }
            }
            .frame(width: size, height: size * 0.68)
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
            .overlay(alignment: .bottom) {
                if item.kind == .text { TextPreviewStrip(text: item.recognizedText, size: size) }
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    if item.pinned {
                        // On a dark dot, so it shows on light pictures too.
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    if item.favorite {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).shadow(radius: 1)
                    }
                }
                .padding(6)
            }
            VStack(spacing: Space.xxs) {
                HStack(spacing: 4) {
                    if analyzing { ProgressView().controlSize(.mini) }
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                }
                .font(.callout)
                // Selected, the name sits in a capsule: the accent while the window is in
                // front, gray behind, as in Finder.
                .padding(.horizontal, selected ? 6 : 0)
                .padding(.vertical, 1)
                .foregroundStyle(selected && active ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: Radius.xs)
                            .fill(active ? Color.accentColor : Color.secondary.opacity(0.3))
                    }
                }
                .frame(maxWidth: size)
                Text(item.created.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                // Tags under the date, off the picture; a line kept even without tags, so
                // the rows stay even.
                Label(item.tags.isEmpty ? " " : item.tags.joined(separator: ", "), systemImage: "tag")
                    .labelStyle(TagLineStyle(showsIcon: !item.tags.isEmpty))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: size)
            }
            .frame(width: size)
        }
        .contentShape(Rectangle())
        .help(item.name)
    }
}

/// A thumbnail's tag line: a small tag symbol before the tags, none without them.
private struct TagLineStyle: LabelStyle {
    let showsIcon: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.xs) {
            if showsIcon { configuration.icon.imageScale(.small) }
            configuration.title
        }
    }
}

/// Along the bottom of a Capture Text thumbnail: the first words that were copied, so it
/// reads as text at a glance.
struct TextPreviewStrip: View {
    let text: String
    let size: Double

    private var preview: String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "text.quote").font(.caption2.weight(.semibold))
            Text(preview.isEmpty ? "Text" : preview)
                .font(.caption2)
                .lineLimit(size >= 220 ? 2 : 1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(.black.opacity(0.7))
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8))
        .help(text)
    }
}

/// The actions for a capture, for its right-click menu.
struct CaptureMenu: View {
    let state: LibraryState
    let item: CaptureItem

    private var targets: Set<UUID> { state.selection.contains(item.id) ? state.selection : [item.id] }

    /// Opening a capture from this menu also sets where double-clicking opens captures.
    @AppStorage("library.rememberOpen", store: AppDefaults.store) private var remember = false

    var body: some View {
        let store = LibraryStore.shared
        if targets.count == 1 {
            // Ticked: where double-clicking opens captures now.
            let place = Preferences.shared.doubleClickOpens
            Toggle("Open Beside the Captures", isOn: Binding(get: { place == .sidePane },
                                                             set: { _ in state.open(item.id, in: .sidePane, remember: remember) }))
            Toggle("Open Full Width", isOn: Binding(get: { place == .fullWidth },
                                                    set: { _ in state.open(item.id, in: .fullWidth, remember: remember) }))
            Toggle("Open in Its Own Window", isOn: Binding(get: { place == .ownWindow },
                                                           set: { _ in state.open(item.id, in: .ownWindow, remember: remember) }))
            Toggle("Remember for Double-Click", isOn: $remember)
            Divider()
            Button("Copy") {
                if item.kind == .video { return VideoExport.copy(item) }
                if let png = Flattener.png(item) { Clipboard.copy(png: png); ActivityStore.shared.record(ActivityKey.copies) }
            }
            Button("Copy Text") { Clipboard.copy(text: item.recognizedText) }.disabled(item.recognizedText.isEmpty)
            Button("Save As…") { Exporter.save(item) }
            Button("Share…") { ShareButton.shareAtPointer([item]) }
            Divider()
            Button("Rename…") { state.selection = [item.id]; state.showInfo = true; state.renaming = item.id }
            Button("Suggest a Name") { store.suggestName(item.id) }
            if let url = item.source.url.flatMap(URL.init(string:)) {
                Button("Open Web Page") { NSWorkspace.shared.open(url) }
            }
            Divider()
        }
        if targets.count > 1 {
            Button("Share \(targets.count) Captures…") { ShareButton.shareAtPointer(store.items.filter { targets.contains($0.id) }) }
        }
        let allPinned = targets.allSatisfy { store.entry($0)?.pinned == true }
        Button(allPinned ? (targets.count > 1 ? "Unpin Images" : "Unpin Image") : (targets.count > 1 ? "Pin Images" : "Pin Image")) {
            store.togglePinned(targets)
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
        // The pop-out picture's window when it's in front, else the library's.
        let front = EditorWindow.shared.isKey ? NSApp.keyWindow : nil
        guard let window = front ?? LibraryWindow.shared.window, let view = window.contentView else { return }
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
