import AppKit
import Observation

/// Folding this app's menu bar item into ToolHUD's.
///
/// While ToolHUD runs with "Gather my apps' menus" on, it shows this app's menu as a
/// submenu of its own menu bar item, and this app hides its icon. ToolHUD reads the menu
/// over a Mach message port: it asks for a snapshot each time the submenu opens and sends
/// back the path of the item the user picked, which runs here exactly as a click would.
/// When ToolHUD quits, crashes or turns the hub off, the icon comes back.
///
/// ToolHUD's presence is its own message port: it exists only while ToolHUD is running
/// with the hub on and its menu bar icon showing. This app's port exists only while the
/// user lets the app fold in, so ToolHUD lists exactly the apps that have a port.
///
/// The same file is copied into every app, ToolHUD included (it uses the snapshot types).
@Observable
@MainActor
final class MenuHub {
    static let shared = MenuHub()

    /// Posted by ToolHUD, with no payload, when its port opens or closes.
    static let changed = Notification.Name("com.smanke.ToolHUD.menuHubChanged")
    /// Message ids: the row's icon, the whole menu, and running an item, sent to the app;
    /// and, sent back to ToolHUD's port, a request to bring the app forward.
    enum Message: Int32 { case icon = 1, menu = 2, invoke = 3, activate = 10 }
    static let foldKey = "foldIntoToolHUD"

    private static let prefix = "32CWL275JJ.com.smanke.menuhub."
    static let hostPortName = prefix + "host"
    static func appPortName(_ bundleID: String) -> String { prefix + bundleID }

    /// The user's choice: put this app's menu in ToolHUD's while ToolHUD is running. On by
    /// default; synced with the app's other settings.
    var foldIntoToolHUD: Bool = UserDefaults.standard.object(forKey: MenuHub.foldKey) as? Bool ?? true {
        didSet {
            guard foldIntoToolHUD != oldValue else { return }
            UserDefaults.standard.set(foldIntoToolHUD, forKey: Self.foldKey)
            onChange?()
            refresh()
        }
    }

    /// ToolHUD is showing this app's menu right now, so the app's own icon stays hidden.
    private(set) var isHosted = false

    /// Whether the app's own menu bar icon should show.
    var showsOwnIcon: Bool { AppPresence.showInMenuBar && !isHosted }

    /// For apps whose sync must be told about a changed setting.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var makeMenu: (@MainActor () -> NSMenu)?
    @ObservationIgnored private var makeIcon: (@MainActor () -> NSImage?)?
    /// The menu last sent to ToolHUD, kept so a picked item runs on the very item shown.
    @ObservationIgnored private var lastMenu: NSMenu?
    @ObservationIgnored private var port: CFMessagePort?
    /// ToolHUD's port, held while hosted: it goes invalid the moment ToolHUD quits or
    /// crashes. (NSWorkspace sends no launch or quit notices for menu bar apps like ToolHUD.)
    @ObservationIgnored private var hostWatch: CFMessagePort?

    private init() {}

    /// Starts serving. `menu` builds the menu as the status item would show it (for most
    /// apps: a fresh NSMenu run through the status item's `menuNeedsUpdate`); `icon` is the
    /// status item's current image, so ToolHUD's row shows the same state.
    func start(menu: @escaping @MainActor () -> NSMenu, icon: @escaping @MainActor () -> NSImage?) {
        makeMenu = menu
        makeIcon = icon
        DistributedNotificationCenter.default().addObserver(forName: Self.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MenuHub.shared.refresh() }
        }
        refresh()
    }

    /// Re-reads the setting after another Mac's settings were adopted.
    func reload() {
        let stored = UserDefaults.standard.object(forKey: Self.foldKey) as? Bool ?? true
        if stored != foldIntoToolHUD { foldIntoToolHUD = stored } else { refresh() }
    }

    /// Opens or closes this app's port to match the setting, and hides or shows the icon to
    /// match ToolHUD.
    func refresh() {
        guard makeMenu != nil else { return }
        if foldIntoToolHUD { openPort() } else { closePort() }
        let hosted = foldIntoToolHUD && port != nil && watchHost()
        guard hosted != isHosted else { return }
        isHosted = hosted
        NotificationCenter.default.post(name: AppPresence.menuBarDidChange, object: nil)
    }

    /// Whether ToolHUD's port is there, keeping hold of it so its end is noticed.
    private func watchHost() -> Bool {
        if let hostWatch, CFMessagePortIsValid(hostWatch) { return true }
        hostWatch = nil
        guard foldIntoToolHUD, let remote = CFMessagePortCreateRemote(nil, Self.hostPortName as CFString) else { return false }
        CFMessagePortSetInvalidationCallBack(remote) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { MenuHub.shared.refresh() } }
        }
        hostWatch = remote
        return true
    }

    static func portExists(_ name: String) -> Bool {
        guard let remote = CFMessagePortCreateRemote(nil, name as CFString) else { return false }
        CFMessagePortInvalidate(remote)
        return true
    }

    // MARK: - Serving

    private func openPort() {
        guard port == nil, let id = Bundle.main.bundleIdentifier else { return }
        var context = CFMessagePortContext()
        var shouldFree: DarwinBoolean = false
        let local = CFMessagePortCreateLocal(nil, Self.appPortName(id) as CFString, { _, id, data, _ in
            let request = data.map { $0 as Data } ?? Data()
            let reply = MainActor.assumeIsolated { MenuHub.shared.handle(id, request) }
            return reply.map { Unmanaged.passRetained($0 as CFData) }
        }, &context, &shouldFree)
        // Another copy of the app (a test build) already holds the name.
        guard let local else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMessagePortCreateRunLoopSource(nil, local, 0), .commonModes)
        port = local
    }

    private func closePort() {
        guard let port else { return }
        CFMessagePortInvalidate(port)
        self.port = nil
        lastMenu = nil
    }

    private func handle(_ id: Int32, _ request: Data) -> Data? {
        switch Message(rawValue: id) {
        case .icon:
            return makeIcon?().flatMap(HubImage.init).flatMap { try? JSONEncoder().encode($0) }
        case .menu:
            guard let menu = makeMenu?() else { return nil }
            menu.update()
            lastMenu = menu
            return try? JSONEncoder().encode(HubItem.items(of: menu))
        case .invoke:
            guard let path = String(data: request, encoding: .utf8), let item = lastMenu.flatMap({ Self.item(at: path, in: $0) }),
                  item.isEnabled, let action = item.action else { return nil }
            let before = Self.windowState
            NSApp.sendAction(action, to: item.target, from: item)
            // The click happened in ToolHUD, so macOS won't let this app come forward on its
            // own. If the item opened or raised a window, ToolHUD passes activation over.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                MainActor.assumeIsolated {
                    let after = Self.windowState
                    guard !NSApp.isActive, !after.visible.isEmpty,
                          !after.visible.isSubset(of: before.visible) || after.front != before.front else { return }
                    Self.askToolHUDToActivate()
                }
            }
            return nil
        case .activate, nil:
            return nil
        }
    }

    /// The windows that could take focus, and which of them is in front. (Panels are not
    /// in `orderedWindows`, hence both.)
    private static var windowState: (visible: Set<ObjectIdentifier>, front: ObjectIdentifier?) {
        let visible = NSApp.windows.filter { $0.isVisible && $0.canBecomeKey }
        return (Set(visible.map(ObjectIdentifier.init)),
                NSApp.orderedWindows.first { $0.isVisible && $0.canBecomeKey }.map(ObjectIdentifier.init))
    }

    private static func askToolHUDToActivate() {
        guard let remote = CFMessagePortCreateRemote(nil, hostPortName as CFString),
              let id = Bundle.main.bundleIdentifier else { return }
        defer { CFMessagePortInvalidate(remote) }
        CFMessagePortSendRequest(remote, Message.activate.rawValue, Data(id.utf8) as CFData, 0.5, 0, nil, nil)
    }

    private static func item(at path: String, in menu: NSMenu) -> NSMenuItem? {
        var menu: NSMenu? = menu
        var item: NSMenuItem?
        for part in path.split(separator: ".") {
            guard let index = Int(part), let items = menu?.items, items.indices.contains(index) else { return nil }
            item = items[index]
            menu = item?.submenu
        }
        return item
    }
}

/// One menu item as sent to ToolHUD. `path` is its index in each enclosing menu, joined by
/// dots, which is how ToolHUD names the item to run.
struct HubItem: Codable, Sendable {
    var title: String
    var path: String
    var isSeparator: Bool
    var isEnabled: Bool
    var state: Int
    var key: String
    var modifiers: UInt
    var isAlternate: Bool
    var indentation: Int
    var toolTip: String?
    var image: HubImage?
    var children: [HubItem]?

    @MainActor
    static func items(of menu: NSMenu, path: String = "") -> [HubItem] {
        menu.items.enumerated().compactMap { index, item in
            guard !item.isHidden else { return nil }
            // A custom view (a chart, say) travels as a picture of itself.
            let picture = item.view.flatMap(HubImage.init(view:))
            guard item.view == nil || picture != nil || !item.title.isEmpty else { return nil }
            let path = path.isEmpty ? "\(index)" : "\(path).\(index)"
            item.submenu?.update()
            return HubItem(title: picture == nil ? item.title : "", path: path, isSeparator: item.isSeparatorItem, isEnabled: item.isEnabled,
                           state: item.state.rawValue, key: item.keyEquivalent,
                           modifiers: item.keyEquivalentModifierMask.rawValue, isAlternate: item.isAlternate,
                           indentation: item.indentationLevel, toolTip: item.toolTip,
                           image: picture ?? item.image.flatMap(HubImage.init),
                           children: item.submenu.map { items(of: $0, path: path) })
        }
    }
}

/// An image drawn to PNG at 2x, keeping its size and whether it is a template.
struct HubImage: Codable, Sendable {
    var png: Data
    var width: Double
    var height: Double
    var isTemplate: Bool

    @MainActor
    init?(_ image: NSImage) {
        var size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        // Menu images are 16 points or so; anything bigger is scaled to fit.
        if size.height > 22 { size = NSSize(width: size.width * 22 / size.height, height: 22) }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        self.png = png
        width = size.width
        height = size.height
        isTemplate = image.isTemplate
    }

    /// A menu item's custom view, drawn as it would show in the menu.
    @MainActor
    init?(view: NSView) {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds.size == .zero ? NSRect(origin: .zero, size: view.fittingSize) : view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        if view.bounds.size == .zero { view.frame = bounds; view.layoutSubtreeIfNeeded() }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        self.png = png
        width = bounds.width
        height = bounds.height
        isTemplate = false
    }

    @MainActor
    var image: NSImage? {
        guard let image = NSImage(data: png) else { return nil }
        image.size = NSSize(width: width, height: height)
        image.isTemplate = isTemplate
        return image
    }
}
