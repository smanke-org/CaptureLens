import AppKit
import CaptureLensKit

/// The library window's layout, shared with your other Macs through settings sync: the
/// sidebar's width and which of its sections are open, how the window is shared between the
/// captures, the picture and its details, which panes are folded or hidden, thumbnail size,
/// sort order, and the tab under the picture. Sizes go as shares of the window rather than
/// points, so a pane that's half of a big screen is half of a small one. The window's own
/// size and place stay with each Mac. Another Mac's layout is taken up the next time the
/// library window opens, so nothing moves while you're working.
@MainActor
enum LibraryLayout {
    /// The synced record: everything below, plus a stamp that changes with each new layout.
    static let key = "libraryLayout"
    /// The stamp of the layout this Mac last took up or made.
    private static let appliedKey = "libraryLayout.applied"

    static let detailKey = "library.detailShare"
    static let pictureKey = "library.pictureShare"
    static let defaultDetail = 0.45
    static let defaultPicture = 0.55

    /// Settings kept as they are (no conversion between screens).
    private static let plainKeys = [
        "library.foldedSide", "library.collapsedPane", "library.inspector", "library.sort", "library.detailsTab",
        "library.details.sourceOpen", "library.sidebar.tagsOpen", "library.sidebar.appsOpen", "library.sidebar.sitesOpen",
        detailKey, pictureKey,
    ]

    /// The sidebar's width in points, as last laid out; kept, so the library opens with it.
    static var sidebarWidth = 0.0 {
        didSet {
            // Before the window is up, or while it opens, the layout isn't the user's choice.
            guard abs(sidebarWidth - oldValue) >= 1, !placing, LibraryWindow.shared.window?.isVisible == true else { return }
            AppDefaults.store.set(sidebarWidth, forKey: sidebarKey)
            noteChange()
        }
    }
    private static let sidebarKey = "library.sidebarWidth"

    private static var observer: NSObjectProtocol?
    private static var pending: Task<Void, Never>?
    /// Just took up another Mac's layout: until then, how the window settles into it (the
    /// sidebar placed, sizes rounded and clamped to this screen) is the new baseline, not a
    /// change of this Mac's own to send back.
    private static var settleUntil = Date.distantPast

    static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: AppDefaults.store,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated { noteChange() }
        }
    }

    // MARK: - This Mac's layout, out

    /// Something may have changed: a moment later, if the layout really did, it's recorded
    /// and goes to the other Macs. Not put off again by later changes: settings are written
    /// all the time (window frames among them), which would put it off for good.
    static func noteChange() {
        guard pending == nil else { return }
        pending = Task {
            try? await Task.sleep(for: .seconds(2))
            pending = nil
            record()
        }
    }

    /// The layout as this window last had it. Changes are measured against this, not the
    /// stored record, which may be another Mac's layout waiting for the window to reopen.
    private static var baseline: [String: Any]?

    private static func record() {
        guard let window = LibraryWindow.shared.window, window.isVisible, sidebarWidth > 0 else { return }
        var layout = measure(window)
        let stored = AppDefaults.store.dictionary(forKey: key)
        if Date() < settleUntil {
            baseline = layout
            return
        }
        guard let before = baseline else {
            // The first look this run: a layout of its own only if there's none yet.
            baseline = layout
            if stored != nil { return }
            return save(&layout)
        }
        if same(layout, before) { return }
        baseline = layout
        save(&layout)
    }

    private static func save(_ layout: inout [String: Any]) {
        let stamp = UUID().uuidString
        layout["stamp"] = stamp
        AppDefaults.store.set(layout, forKey: key)
        AppDefaults.store.set(stamp, forKey: appliedKey)
        SettingsSync.shared.localDidChange()
    }

    private static func settled() {
        guard let window = LibraryWindow.shared.window, window.isVisible else { return }
        baseline = measure(window)
    }

    /// The layout as it is on screen now.
    private static func measure(_ window: NSWindow) -> [String: Any] {
        let defaults = AppDefaults.store
        var layout: [String: Any] = [:]
        for key in plainKeys { if let value = defaults.object(forKey: key) { layout[key] = value } }
        let width = window.contentLayoutRect.width
        guard width > 0 else { return layout }
        layout["sidebar"] = sidebarWidth / width
        let state = LibraryWindow.shared.state
        let grid = gridWidth(room: width - sidebarWidth - 1, state: state)
        if grid > 0 { layout["thumbnail"] = state.thumbnailSize / grid }
        return layout
    }

    /// How wide the captures are with this much room beside the sidebar (0 when folded away).
    private static func gridWidth(room: Double, state: LibraryState) -> Double {
        guard state.showInspector else { return room }
        switch state.foldedSide {
        case .captures: return 0
        case .editor: return room - 35
        case nil:
            let detail = LibraryView.detailRange(room).clamp((AppDefaults.store.object(forKey: detailKey) as? Double ?? defaultDetail) * room)
            return room - detail - 1
        }
    }

    /// The same layout, give or take a point of rounding.
    private static func same(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        let keys = Set(a.keys).union(b.keys).subtracting(["stamp"])
        return keys.allSatisfy { key in
            switch (a[key], b[key]) {
            case let (x as Double, y as Double): abs(x - y) < 0.005
            case let (x as NSObject, y as NSObject): x == y
            case (nil, nil): true
            default: false
            }
        }
    }

    // MARK: - Another Mac's layout, in

    /// Takes up a layout another Mac made, if there's one this Mac hasn't yet.
    static func applyIfNew(to state: LibraryState, window: NSWindow?) {
        let defaults = AppDefaults.store
        guard let layout = defaults.dictionary(forKey: key), let stamp = layout["stamp"] as? String,
              stamp != defaults.string(forKey: appliedKey) else { return }
        defaults.set(stamp, forKey: appliedKey)
        settleUntil = Date().addingTimeInterval(3)
        // One last look once it has settled, to take the baseline from.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { MainActor.assumeIsolated { settled() } }
        for key in plainKeys { if let value = layout[key] { defaults.set(value, forKey: key) } }
        // The library's own copies of these.
        // Details first: showing them unfolds the right side, which the fold then sets again.
        if let shown = layout["library.inspector"] as? Bool { state.showInspector = shown }
        state.foldedSide = (layout["library.foldedSide"] as? String).flatMap(LibraryState.Side.init)
        if let sort = (layout["library.sort"] as? String).flatMap(LibrarySort.init) { state.sort = sort }
        // Shares become points on this Mac's window.
        let width = Double(window?.contentLayoutRect.width ?? 0)
        guard width > 0 else { return }
        if let share = layout["sidebar"] as? Double {
            pendingSidebar = min(max(share * width, LibrarySidebar.railWidth), 300)
            placing = true
        }
        if let share = layout["thumbnail"] as? Double {
            let grid = gridWidth(room: width - (pendingSidebar ?? sidebarWidth) - 1, state: state)
            if grid > 0 { state.thumbnailSize = LibraryState.clampSize(share * grid) }
        }
        NSLog("CaptureLens: took up the library layout from another Mac")
    }

    private static var pendingSidebar: Double?
    private static var placing = false
    #if DEBUG
    static var debugNotes: [String] = []
    #endif

    /// As the window opens: the sidebar gets the width it had here (unless another Mac's
    /// layout gives it one), read before the first layout can change it.
    static func prepareSidebar() {
        pendingSidebar = AppDefaults.store.object(forKey: sidebarKey) as? Double
        #if DEBUG
        debugNotes.append("opening, kept \(pendingSidebar ?? -1)")
        #endif
        placing = pendingSidebar != nil
    }

    /// The sidebar's width, once the window is up (the split view sets it, not SwiftUI, and
    /// only after it has laid itself out).
    static func placeSidebar(in window: NSWindow?) {
        guard let width = pendingSidebar else { return placing = false }
        pendingSidebar = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                let split = SidebarStaysOpen.Finder.splitView(in: window?.contentView)
                split?.setPosition(width, ofDividerAt: 0)
                #if DEBUG
                debugNotes.append("placed \(width): split \(split != nil), now \(split?.arrangedSubviews.first?.frame.width ?? -1)")
                #endif
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    MainActor.assumeIsolated {
                        placing = false
                        if let split = SidebarStaysOpen.Finder.splitView(in: window?.contentView), let side = split.arrangedSubviews.first {
                            sidebarWidth = Double(side.frame.width.rounded())
                        }
                    }
                }
            }
        }
    }
}
