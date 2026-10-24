import AppKit
import SwiftUI

// MARK: - Content

/// One page of Help. `Help.resolve` swaps `{…}` tokens for the user's own settings, such
/// as their shortcuts, so the text matches what they've set up.
struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let blocks: [HelpBlock]

    static func == (a: HelpTopic, b: HelpTopic) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
enum HelpBlock {
    case text(String)
    case heading(String)
    /// Keys on the left, what they do on the right.
    case keys([(String, String)])
    case tip(String)

    var searchText: String {
        switch self {
        case .text(let s), .heading(let s), .tip(let s): Help.resolve(s)
        case .keys(let rows): rows.map { Help.resolve($0.0) + " " + Help.resolve($0.1) }.joined(separator: " ")
        }
    }
}

@MainActor
enum Help {
    /// `{hotkey:<name>}` shows the user's own shortcut for that action.
    static func resolve(_ text: String) -> String {
        guard text.contains("{hotkey:") else { return text }
        let p = Preferences.shared
        func preset(_ index: Int) -> HotKey? { p.preset(CapturePreset.defaults[index].id)?.hotKey }
        let keys: [(String, HotKey?)] = [
            ("capture", preset(0)), ("screen", preset(1)), ("window", preset(2)),
            ("library", p.libraryHotKey), ("again", p.captureAgainHotKey),
        ]
        var out = text
        for (name, key) in keys { out = out.replacingOccurrences(of: "{hotkey:\(name)}", with: key?.display ?? "(no shortcut set)") }
        return out
    }

    static var debugTokens: String { resolve("{hotkey:capture} {hotkey:screen} {hotkey:window} {hotkey:library} {hotkey:again}") }

    /// The Settings tabs, for the Debug self-test.
    static let testTabs = ["Capture", "Presets", "Library", "Privacy", "General"]

    /// The topic each Settings tab's Help button opens.
    static func topic(forSettingsTab tab: String) -> String {
        switch tab {
        case "Capture": "capture"
        case "Presets": "presets"
        case "Library": "sync"
        case "Privacy": "privacy"
        case "General": "settings-sync"
        default: "getting-started"
        }
    }

    /// Every preset with its shortcut, as Help rows.
    private static var presetRows: [(String, String)] {
        Preferences.shared.presets.map { ($0.hotKey?.display ?? "(no shortcut)", "\($0.name): \($0.summary)") }
    }

    static var topics: [HelpTopic] { [
        HelpTopic(id: "getting-started", title: "Getting Started", symbol: "sparkles", blocks: [
            .text("CaptureLens takes pictures of your screen and keeps every one in a searchable library. Each capture is named from what's in it, and you can tag it, add notes, and select and copy the text right in the picture."),
            .keys([
                ("{hotkey:capture}", "Capture a window (click it) or an area (drag over it)"),
                ("{hotkey:screen}", "Capture the whole screen"),
                ("{hotkey:window}", "Capture a window"),
                ("{hotkey:library}", "Open the library"),
                ("Menu bar icon", "Every preset, the library, and Settings"),
                ("Dock icon or ⌘-Tab", "Open the library (turn on Show in Dock in Settings › General)"),
            ]),
            .heading("Allow Screen Recording"),
            .text("CaptureLens needs Screen Recording permission to see the screen. If the menu bar menu shows \"Allow Screen Recording…\", choose it, switch CaptureLens on, and open CaptureLens again."),
            .tip("The screen freezes while you pick, so a menu, tooltip or video frame stays put while you select it."),
            .tip("While ToolHUD is running, CaptureLens's menu moves into ToolHUD's menu bar menu as a submenu, and the icon here steps aside until ToolHUD quits. To keep the icon, turn off \"Put in ToolHUD's menu while ToolHUD is running\" in Settings."),
        ]),

        HelpTopic(id: "capture", title: "Capturing", symbol: "camera.viewfinder", blocks: [
            .text("Press {hotkey:capture}, then point at a window and click it, or drag over any area. Return captures the whole screen under the pointer, and Esc cancels."),
            .keys([
                ("Click", "Capture the highlighted window on its own, even where other windows cover it"),
                ("Drag", "Capture an area"),
                ("Return", "Capture the whole screen"),
                ("Hold ⌥ while clicking or dragging", "Open this capture in the library straight away"),
                ("Esc or right-click", "Cancel"),
                ("{hotkey:again}", "Capture the same area again, without selecting"),
            ]),
            .heading("What happens next"),
            .text("The capture goes into the library, and, if you like, onto the clipboard (Settings › Capture). A preview slides into the corner of the screen: click it to open the capture, or drag it straight into another app."),
            .text("To have every capture open in the library right away as well, choose \"Open Captures in Library\" in the menu bar menu, or pick in Settings › Capture › After capturing: a preview, a preview and the library, the library alone, or nothing. A preset can choose for itself, and holding ⌥ as you click or finish dragging opens just that one in the library."),
            .heading("The pointer"),
            .text("The mouse pointer is kept as a separate layer instead of being drawn into the picture. In the library, show or hide it, drag it somewhere else, or make it bigger. It's added when you copy, drag or save the capture."),
            .heading("Delayed and exact-size captures"),
            .text("Presets can count down before capturing (to open a menu first, say) or capture a frame of an exact size that follows the pointer. See Presets and Shortcuts."),
        ]),

        HelpTopic(id: "presets", title: "Presets and Shortcuts", symbol: "keyboard", blocks: [
            .text("A preset is a saved way to capture: what to capture, a countdown, an exact size, whether to copy, whether to open the capture in the library, and its own keyboard shortcut. Edit them in Settings › Presets."),
            .keys(presetRows),
            .keys([
                ("{hotkey:library}", "Open the library"),
                ("{hotkey:again}", "Capture the same area again"),
                ("⌘?", "This Help, from CaptureLens's menus"),
            ]),
            .text("Click a shortcut, then press the new keys. Delete clears it; shortcuts need ⌘, ⌥ or ⌃. Right-click a preset to duplicate, delete or try it."),
        ]),

        HelpTopic(id: "annotate", title: "Annotating", symbol: "pencil.and.outline", blocks: [
            .text("Select a capture in the library and mark it up right on the picture: boxes, ellipses, arrows, lines, text, callouts, numbered steps, a pen, a highlighter, a spotlight, a magnifier and stamps. Marks stay separate from the picture, so you can move, resize, restyle or delete them any time, and the original is never changed."),
            .keys([
                ("V", "Select: click a mark to select it, drag to move it, drag its handles to resize it"),
                ("R  O  A  L", "Box, ellipse, arrow, line: drag to draw (hold ⇧ for squares, circles and 45° lines)"),
                ("T  C", "Text and callout: click (or drag a box) and type; double-click or press Return to edit later"),
                ("S", "Numbered step: click; steps number themselves in the order you add them"),
                ("P  H", "Pen and highlighter: draw freehand"),
                ("F  M", "Spotlight (dims everything else) and magnifier: drag over the spot"),
                ("K", "Stamp: pick ✅, ⭐️, Approved and others from the toolbar, then click"),
                ("B  X  D", "Blur, pixelate or black out an area: drag over it"),
                ("Y", "Crop: drag out the part to keep, drag its corners to adjust, Return when done"),
                ("Delete", "Delete the selected mark"),
                ("Arrow keys", "Nudge the selected mark (with ⇧, 10 points at a time)"),
                ("⌘Z  ⇧⌘Z", "Undo and redo (also the arrows in the toolbar)"),
                ("Esc", "Deselect, then go back to the select tool"),
            ]),
            .heading("Color, size and style"),
            .text("The color button and the size menu set how new marks look, and change the selected mark. The size menu also has bold text, filled shapes and text, shadows, and Bring to Front / Send to Back. Quick styles (the palette button) keep favorite combinations one click away; Save Current Style adds yours."),
            .heading("Adjusting the picture"),
            .text("The Adjust button (the sliders) crops, rotates and resizes the picture, cuts strips out of it (drag across or down the strip; torn, wavy or straight seams), adds a border with rounded corners and a shadow, gives it torn, wavy or faded edges, and removes the background to keep just the subject. None of it changes the original: each adjustment can be changed, undone, or reset with Reset All Adjustments."),
            .text("Smart Redact (also in Adjust) finds email addresses, phone numbers, card numbers, ID numbers, IP addresses, street addresses and keys or tokens in the picture and covers each with a black box, blur or pixels. The covers are ordinary marks: move, resize or delete any of them."),
            .text("Edit and Result, below the picture, switch between marking up the original and seeing the finished picture as it will be copied and saved. Save As writes PNG, JPEG, HEIC, TIFF, GIF, BMP or PDF (and WebP where macOS can write it)."),
            .text("Copy, Save As, dragging a capture out and the thumbnails all include the marks. The eye button hides them to show the picture as captured. Marks sync with the capture to your other Macs."),
        ]),

        HelpTopic(id: "naming", title: "Automatic Names", symbol: "apple.intelligence", blocks: [
            .text("Each new capture is named from what's in it, like \"Quarterly Revenue Chart\" or \"Xcode Build Error\", using Apple Intelligence on this Mac. The name appears a moment after the capture; until then it's named after the app and window."),
            .text("To rename a capture, type in its Name field. Click the Apple Intelligence button beside the name (or choose Suggest a Name from the right-click menu) for a fresh suggestion."),
            .tip("Naming needs Apple Intelligence to be turned on in System Settings. Without it, captures keep the app and window name."),
        ]),

        HelpTopic(id: "library", title: "The Library", symbol: "photo.on.rectangle", blocks: [
            .text("The library shows every capture. Click one to see it with its details; ⌘-click and Shift-click pick several."),
            .heading("Search"),
            .text("The search field finds words in a capture's name, tags, notes, the text in the picture, and its app, window and web page. Every word must match."),
            .keys([
                ("tag:work", "Captures tagged work"),
                ("app:safari", "Captures from Safari"),
                ("site:apple.com", "Captures of pages on apple.com"),
                ("yesterday, March 3, 2026-10-01", "Captures from that day"),
            ]),
            .heading("Filters"),
            .text("The buttons above the captures narrow the list by date, type, tags, app and website; click × on one to clear it. The sidebar has quick lists for favorites, the last 7 days, captures with notes, and each tag, app and website."),
            .heading("Tags and notes"),
            .text("Type a tag and press Return to add it, or click one of your existing tags listed below the field; typing narrows the list (commas add several at once). Right-click a tag in the sidebar to rename it everywhere. More Info holds notes of any length; they're searchable too."),
            .heading("Text in a capture"),
            .text("Select text right in the picture and copy it, as in Preview. \"Text in the capture\" in the details lists all of it."),
            .keys([
                ("Arrow keys", "Move through the captures"),
                ("Return", "Rename the selected capture"),
                ("Delete", "Delete the selected captures (asks first)"),
                ("Drag a capture", "Into another app, or a pictures file onto the library to import it"),
                ("Pinch or ⌘-scroll", "Zoom the picture"),
                ("Slider below the captures, or ⌘+ / ⌘−", "Make the thumbnails bigger or smaller"),
            ]),
        ]),

        HelpTopic(id: "sync", title: "Sync and Security", symbol: "lock.icloud", blocks: [
            .text("Turn on \"Sync settings with your other Macs\" in Settings › General and choose a sync passphrase. Your presets, settings and library then follow you to every Mac with CaptureLens and sync on, end-to-end encrypted: neither Apple nor the developer can see them."),
            .heading("Syncing the library through Dropbox, OneDrive or Google Drive"),
            .text("In Settings › Library, set \"Sync the library through\" to \"Dropbox, OneDrive or Google Drive\", then choose where the folder is on this Mac: Dropbox, OneDrive and Google Drive are offered when they're installed, or pick any folder that a sync app keeps on all your Macs. CaptureLens puts a \"CaptureLens Library\" folder inside it. Settings and the sync passphrase still go through iCloud."),
            .text("The choice is shared, so every Mac uses the same one; each Mac picks its own folder location. On a Mac that hasn't yet, the menu bar menu shows \"Choose Sync Folder…\". Every file in the folder is encrypted with your sync passphrase, so the sync service can't see your captures."),
            .tip("Changes arrive once the sync app has synced the folder, usually within seconds. If two Macs change the same capture at once, the newest change wins and the sync app's \"conflicted copy\" files are tidied away. After moving the library to a folder, \"Remove from iCloud…\" frees the iCloud space; update CaptureLens on every Mac first."),
            .text("On each Mac, Settings › Library can encrypt the library file itself and require Touch ID or your password to open the library. The lock comes back after a while away, when the Mac sleeps, or when the screen locks. Capturing keeps working while it's locked."),
            .tip("The sync passphrase can't be recovered. If you forget it, choose \"Forgot It? Start Over…\"; your other Macs then ask for the new one."),
        ]),

        HelpTopic(id: "settings-sync", title: "Settings on Every Mac", symbol: "arrow.triangle.2.circlepath", blocks: [
            .text("Turn on \"Sync settings with your other Macs\" in Settings › General, choose a sync passphrase there, and enter the same passphrase on each of your Macs. From then on a change on one Mac shows up on the others."),
            .keys([
                ("Follow you", "Presets and their shortcuts, the library shortcut, Capture options, naming and search options, appearance, Show in Dock and menu bar, ToolHUD's menu, and update choices"),
                ("Stay on each Mac", "Open at login, encrypting the library, and the library lock"),
            ]),
            .text("Your library syncs too unless you turn off \"Sync the library with your other Macs\" in Settings › Library."),
        ]),

        HelpTopic(id: "updates", title: "Updates", symbol: "arrow.down.circle", blocks: [
            .text("Settings › General › Updates chooses what happens when a new version is out:"),
            .keys([
                ("Install automatically", "Downloads and checks it, then installs when no capture is under way, CaptureLens hasn't been used for 30 minutes, nothing is presenting, and your Mac has been idle for 2 minutes"),
                ("Ask me first", "Sends a notification; nothing installs until you choose to"),
                ("Don't check", "Only Check Now looks for updates"),
            ]),
            .text("\"Check every\" sets how often it looks: a number of hours, days, weeks or months (once a day to start). The menu bar menu shows \"Update to…\" when a new version is waiting. Every update must be signed by the same developer and notarized by Apple, or it isn't installed."),
        ]),

        HelpTopic(id: "privacy", title: "Privacy", symbol: "hand.raised", blocks: [
            .text("Naming and text reading run entirely on this Mac. CaptureLens only looks at the screen when you take a capture. With sync on, your settings and library travel through your iCloud account, encrypted with a passphrase only you know."),
            .text("You can remove CaptureLens's Screen Recording access at any time in System Settings › Privacy & Security; capturing then stops until you allow it again."),
        ]),

        HelpTopic(id: "automation", title: "Automation", symbol: "gearshape.2", blocks: [
            .keys([
                ("capturelens://capture", "Capture a window or an area"),
                ("capturelens://screen", "Capture the whole screen"),
                ("capturelens://window", "Capture a window"),
                ("capturelens://area", "Capture an area"),
                ("capturelens://recapture", "Capture the same area again"),
                ("capturelens://library", "Open the library"),
                ("capturelens://preset/<name>", "Run a preset by its name"),
            ]),
            .text("Use these links from Shortcuts, scripts or a launcher. ToolHUD's CaptureLens buttons use them. Pictures dropped on CaptureLens's Dock icon are added to the library."),
        ]),

        HelpTopic(id: "troubleshooting", title: "Troubleshooting", symbol: "wrench.and.screwdriver", blocks: [
            .heading("Capturing shows only the desktop, or nothing"),
            .text("CaptureLens needs Screen Recording permission. Choose \"Allow Screen Recording…\" in the menu bar menu, switch CaptureLens on, then quit and reopen CaptureLens."),
            .heading("Captures keep their app name instead of a real name"),
            .text("Turn on Apple Intelligence in System Settings, and check that \"Name captures from what's in them\" is on in Settings › Capture."),
            .heading("No web page address"),
            .text("macOS asks once per browser whether CaptureLens may control it. If you said no, allow it in System Settings › Privacy & Security › Automation."),
            .heading("A shortcut does nothing"),
            .text("Another app may use the same keys. Pick a different one in Settings › Presets."),
        ]),
    ] }
}

// MARK: - Window

@Observable
@MainActor
final class HelpState {
    var selection: String? = "getting-started"
    var query = ""
}

@MainActor
final class HelpWindow: NSObject, NSWindowDelegate {
    static let shared = HelpWindow()

    let state = HelpState()
    private(set) var window: NSWindow?

    /// Opens Help, on `topic` when given.
    func show(topic: String? = nil) {
        if let topic { state.query = ""; state.selection = topic }
        if window == nil {
            let hosting = NSHostingController(rootView: HelpView(state: state))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "\(AppInfo.name) Help"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            let screen = NSScreen.main?.visibleFrame.height ?? 800
            window.setContentSize(NSSize(width: 820, height: min(600, screen - 80)))
            window.contentMinSize = NSSize(width: 640, height: 400)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("CaptureLensHelp")
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HelpView: View {
    @Bindable var state: HelpState

    private var matches: [HelpTopic] {
        let query = state.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return Help.topics }
        return Help.topics.filter { topic in
            topic.title.lowercased().contains(query) || topic.blocks.contains { $0.searchText.lowercased().contains(query) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(matches, selection: $state.selection) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic.id)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .overlay {
                if matches.isEmpty { Text("No matches").foregroundStyle(.secondary) }
            }
        } detail: {
            if let topic = Help.topics.first(where: { $0.id == state.selection }) {
                HelpPage(topic: topic, query: state.query)
            } else {
                Text("Choose a topic").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $state.query, placement: .sidebar, prompt: "Search Help")
        .onChange(of: state.query) {
            // Keep a matching topic on screen while searching.
            if let first = matches.first, !matches.contains(where: { $0.id == state.selection }) { state.selection = first.id }
        }
    }
}

struct HelpPage: View {
    let topic: HelpTopic
    let query: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(topic.title, systemImage: topic.symbol)
                    .font(.largeTitle.weight(.semibold))
                    .padding(.bottom, 4)
                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func view(for block: HelpBlock) -> some View {
        switch block {
        case .text(let s):
            Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true)
        case .heading(let s):
            Text(Help.resolve(s)).font(.title3.weight(.semibold)).padding(.top, 8)
        case .tip(let s):
            Label { Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "lightbulb").foregroundStyle(.yellow)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .keys(let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let keys = Help.resolve(row.0), what = Help.resolve(row.1)
                    let hit = !query.isEmpty && (keys + " " + what).lowercased().contains(query.lowercased())
                    GridRow {
                        Text(keys)
                            .font(.body.monospaced().weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            // The same key column width in every table on every page.
                            .frame(width: 210, alignment: .leading)
                        Text(what).fixedSize(horizontal: false, vertical: true)
                    }
                    .background(hit ? Color.yellow.opacity(0.25) : .clear)
                }
            }
        }
    }
}

/// The round "?" button macOS puts in the corner of settings panes.
struct HelpButton: NSViewRepresentable {
    let topic: String

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.open))
        button.bezelStyle = .helpButton
        button.toolTip = "\(AppInfo.name) Help"
        button.setAccessibilityLabel("Help")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.topic = topic }

    func makeCoordinator() -> Coordinator { Coordinator(topic: topic) }

    @MainActor
    final class Coordinator: NSObject {
        var topic: String
        init(topic: String) { self.topic = topic }
        @objc func open() { HelpWindow.shared.show(topic: topic) }
    }
}
