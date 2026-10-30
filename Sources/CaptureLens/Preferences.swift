import AppKit
import CaptureLensKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// What happens on screen once a capture is saved.
enum AfterCapture: String, Codable, CaseIterable {
    case preview, previewAndLibrary, openLibrary, nothing

    var title: String {
        switch self {
        case .preview: "Show a preview in the corner"
        case .previewAndLibrary: "Show a preview and open it in the library"
        case .openLibrary: "Open it in the library"
        case .nothing: "Nothing (just play the sound)"
        }
    }

    var showsPreview: Bool { self == .preview || self == .previewAndLibrary }
    var opensLibrary: Bool { self == .openLibrary || self == .previewAndLibrary }

    /// The same choice with the library opening too (holding ⌥), keeping a preview if it had one.
    var openingLibrary: AfterCapture { showsPreview ? .previewAndLibrary : .openLibrary }
}

/// Where the library syncs through. The same on every Mac (a synced setting), so a capture
/// removed from one service by one Mac can't take another Mac's copy with it.
/// How the markup tools are offered: a floating toolbar over the picture, or a dial that
/// opens around the pointer.
enum ToolStyle: String, CaseIterable {
    case toolbar, dial

    var title: String {
        switch self {
        case .toolbar: "Toolbar"
        case .dial: "Radial dial"
        }
    }
}

/// What opens the radial dial over the picture.
enum DialTrigger: String, CaseIterable {
    case rightClick, commandOption, either

    var title: String {
        switch self {
        case .rightClick: "Right-click the picture"
        case .commandOption: "Hold ⌘⌥ over the picture"
        case .either: "Either"
        }
    }

    var rightClick: Bool { self != .commandOption }
    var commandOption: Bool { self != .rightClick }
}

/// Where double-clicking a capture opens it.
enum OpenPlace: String, CaseIterable {
    case sidePane, ownWindow

    var title: String {
        switch self {
        case .sidePane: "Beside the captures"
        case .ownWindow: "In its own window"
        }
    }
}

enum LibraryBackend: String, CaseIterable {
    case iCloud, folder

    var title: String {
        switch self {
        case .iCloud: "iCloud"
        case .folder: "Dropbox, OneDrive or Google Drive"
        }
    }
}

/// How a capture is taken.
enum CaptureMode: String, Codable, CaseIterable {
    /// Point at a window and click it, or drag out an area.
    case allInOne
    case region
    case window
    case screen
    /// A frame of a set size that follows the pointer; click to place it.
    case fixedSize
    /// Pick an area or window, then scroll it: the frames are stitched into one tall picture.
    case scrolling
    /// Pick an area, window or screen, then record a video of it.
    case recording

    var title: String {
        switch self {
        case .allInOne: "Window or area"
        case .region: "Area"
        case .window: "Window"
        case .screen: "Full screen"
        case .fixedSize: "Exact size"
        case .scrolling: "Scrolling area"
        case .recording: "Video recording"
        }
    }

    var symbol: String {
        switch self {
        case .allInOne: "viewfinder"
        case .region: "rectangle.dashed"
        case .window: "macwindow"
        case .screen: "display"
        case .fixedSize: "aspectratio"
        case .scrolling: "arrow.down.doc"
        case .recording: "record.circle"
        }
    }
}

/// Whether a preset copies its capture, or follows the setting.
enum ClipboardChoice: String, Codable, CaseIterable {
    case setting, always, never

    var title: String {
        switch self {
        case .setting: "As in Capture settings"
        case .always: "Always copy"
        case .never: "Never copy"
        }
    }
}

/// A saved way to capture, with its own shortcut: "Window, after 3 seconds".
struct CapturePreset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var mode: CaptureMode
    /// Seconds to count down before capturing.
    var delay: Int
    /// The frame for `.fixedSize`, in points.
    var width: Int
    var height: Int
    var clipboard: ClipboardChoice
    /// What happens once it's saved; nil follows Capture settings.
    var afterCapture: AfterCapture?
    var hotKey: HotKey?

    init(id: UUID = UUID(), name: String, mode: CaptureMode, delay: Int = 0, width: Int = 1280, height: Int = 720,
         clipboard: ClipboardChoice = .setting, afterCapture: AfterCapture? = nil, hotKey: HotKey? = nil) {
        self.id = id
        self.name = name
        self.mode = mode
        self.delay = delay
        self.width = width
        self.height = height
        self.clipboard = clipboard
        self.afterCapture = afterCapture
        self.hotKey = hotKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Capture"
        mode = (try? c.decodeIfPresent(String.self, forKey: .mode)).flatMap { $0.flatMap(CaptureMode.init) } ?? .allInOne
        delay = try c.decodeIfPresent(Int.self, forKey: .delay) ?? 0
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 1280
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 720
        clipboard = try c.decodeIfPresent(ClipboardChoice.self, forKey: .clipboard) ?? .setting
        afterCapture = try c.decodeIfPresent(AfterCapture.self, forKey: .afterCapture)
        hotKey = try c.decodeIfPresent(HotKey.self, forKey: .hotKey)
    }

    /// "Window · 3 s delay", for menus and lists.
    var summary: String {
        var parts = [mode == .fixedSize ? "\(width) × \(height)" : mode.title]
        if delay > 0 { parts.append("\(delay) s delay") }
        switch clipboard {
        case .always: parts.append("copies")
        case .never: parts.append("doesn't copy")
        case .setting: break
        }
        switch afterCapture {
        case .openLibrary: parts.append("opens in library")
        case .previewAndLibrary: parts.append("preview + library")
        case .preview: parts.append("shows preview")
        case .nothing: parts.append("no preview")
        case nil: break
        }
        return parts.joined(separator: " · ")
    }

    private static let optionShiftCommand = UInt32(optionKey | shiftKey | cmdKey)

    /// The presets a new install starts with. Fixed IDs, so two Macs adopting each
    /// other's settings never end up with two copies.
    static let defaults: [CapturePreset] = [
        CapturePreset(id: UUID(uuidString: "6C1D0E2A-0001-4C6E-9C1A-CA9701E50001")!, name: "Capture", mode: .allInOne,
                      hotKey: HotKey(keyCode: UInt32(kVK_ANSI_4), modifiers: optionShiftCommand, display: "⌥⇧⌘4")),
        CapturePreset(id: UUID(uuidString: "6C1D0E2A-0002-4C6E-9C1A-CA9701E50002")!, name: "Full Screen", mode: .screen,
                      hotKey: HotKey(keyCode: UInt32(kVK_ANSI_3), modifiers: optionShiftCommand, display: "⌥⇧⌘3")),
        CapturePreset(id: UUID(uuidString: "6C1D0E2A-0003-4C6E-9C1A-CA9701E50003")!, name: "Window", mode: .window,
                      hotKey: HotKey(keyCode: UInt32(kVK_ANSI_5), modifiers: optionShiftCommand, display: "⌥⇧⌘5")),
        CapturePreset(id: UUID(uuidString: "6C1D0E2A-0004-4C6E-9C1A-CA9701E50004")!, name: "Area After 5 Seconds",
                      mode: .region, delay: 5),
        CapturePreset(id: UUID(uuidString: "6C1D0E2A-0005-4C6E-9C1A-CA9701E50005")!, name: "1280 × 720",
                      mode: .fixedSize, width: 1280, height: 720),
        CapturePreset(id: UUID(uuidString: "6C1D0E2A-0006-4C6E-9C1A-CA9701E50006")!, name: "Scrolling Capture", mode: .scrolling,
                      hotKey: HotKey(keyCode: UInt32(kVK_ANSI_6), modifiers: optionShiftCommand, display: "⌥⇧⌘6")),
        CapturePreset(id: UUID(uuidString: "6C1D0E2A-0007-4C6E-9C1A-CA9701E50007")!, name: "Record Video", mode: .recording,
                      hotKey: HotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: optionShiftCommand, display: "⌥⇧⌘R")),
    ]
}

/// Every setting, persisted to UserDefaults as it changes. Settings that belong to one Mac
/// (encryption at rest, the library lock) live with `LibraryStore`/`LibraryLock` instead.
@Observable
@MainActor
final class Preferences {
    static let shared = Preferences()

    // MARK: Capture
    /// Each new capture also goes on the clipboard.
    var copyToClipboard = true { didSet { save(copyToClipboard, "copyToClipboard") } }
    var afterCapture = AfterCapture.preview { didSet { save(afterCapture.rawValue, "afterCapture") } }
    /// Keep the mouse pointer as a separate layer (hidden or shown later).
    var captureCursor = true { didSet { save(captureCursor, "captureCursor") } }
    /// New captures start with the pointer showing.
    var showCursorByDefault = false { didSet { save(showCursorByDefault, "showCursorByDefault") } }
    var windowShadow = true { didSet { save(windowShadow, "windowShadow") } }
    var playSound = true { didSet { save(playSound, "playSound") } }
    var showNotice = true { didSet { save(showNotice, "showNotice") } }

    // MARK: Naming and source
    /// Name each capture from what's in it, with on-device Apple Intelligence.
    var autoName = true { didSet { save(autoName, "autoName") } }
    /// Read the text in each capture, so the library can search it.
    var recognizeText = true { didSet { save(recognizeText, "recognizeText") } }
    /// Ask the front browser for the page's address.
    var recordWebAddress = true { didSet { save(recordWebAddress, "recordWebAddress") } }

    // MARK: Library
    /// The library travels between Macs too, while sync is on.
    var librarySync = true { didSet { save(librarySync, "librarySync"); librarySyncChanged() } }
    /// What the library syncs through when `librarySync` is on.
    var libraryBackend = LibraryBackend.iCloud { didSet { save(libraryBackend.rawValue, "libraryBackend"); librarySyncChanged() } }

    // MARK: Recording
    var recordMicrophone = false { didSet { save(recordMicrophone, "recordMicrophone") } }
    /// The Mac's own sound (apps playing audio).
    var recordSystemAudio = true { didSet { save(recordSystemAudio, "recordSystemAudio") } }
    /// The camera in a round bubble over the recording.
    var recordCamera = false { didSet { save(recordCamera, "recordCamera") } }
    /// A ring wherever the mouse is clicked.
    var showClicks = true { didSet { save(showClicks, "showClicks") } }
    /// Keyboard shortcuts and special keys pressed, shown at the bottom of the recording.
    var showKeys = false { didSet { save(showKeys, "showKeys") } }
    var recordFrameRate = 30 { didSet { save(recordFrameRate, "recordFrameRate") } }
    /// Seconds counted down before a recording starts (0: none). A preset's own delay wins.
    var recordCountdown = 3 { didSet { save(recordCountdown, "recordCountdown") } }
    static let countdowns = [0, 3, 5]
    /// The microphone and camera to use, by ID; empty for the Mac's default. Each Mac has its own.
    var microphoneID = "" { didSet { save(microphoneID, "microphoneID") } }
    var cameraID = "" { didSet { save(cameraID, "cameraID") } }
    /// The frame rates offered, with what each is good for. Fewer frames make smaller videos.
    static let frameRates: [(rate: Int, title: String)] = [
        (10, "10 frames a second (smallest; fine for apps and documents)"),
        (15, "15 frames a second"),
        (24, "24 frames a second"),
        (30, "30 frames a second"),
        (60, "60 frames a second (smoothest; largest)"),
    ]
    /// Movie files go to other Macs too (their details always do).
    var syncVideos = false { didSet { save(syncVideos, "syncVideos"); if syncVideos != oldValue { syncVideosChanged() } } }

    // MARK: Annotations
    /// The style new annotations get (the last one chosen).
    var annotationStyle = AnnotationStyle.standard { didSet { saveCodable(annotationStyle, "annotationStyle") } }
    /// Saved styles, one click away in the annotation toolbar.
    var quickStyles = AnnotationStyle.quickDefaults { didSet { saveCodable(quickStyles, "quickStyles") } }
    /// The markup tools as a floating toolbar or a radial dial.
    var toolStyle = ToolStyle.toolbar { didSet { save(toolStyle.rawValue, "toolStyle") } }
    /// What opens the dial, when the tools are a dial.
    var dialTrigger = DialTrigger.rightClick { didSet { save(dialTrigger.rawValue, "dialTrigger") } }
    var doubleClickOpens = OpenPlace.sidePane { didSet { save(doubleClickOpens.rawValue, "doubleClickOpens") } }

    // MARK: General
    /// Quitting asks first, so a stray ⌘Q doesn't stop the capture shortcuts.
    var confirmQuit = true { didSet { save(confirmQuit, "confirmQuit") } }

    // MARK: Presets and shortcuts
    var presets: [CapturePreset] = CapturePreset.defaults { didSet { saveCodable(presets, "presets") } }
    var libraryHotKey: HotKey? = Defaults.libraryHotKey { didSet { saveCodable(libraryHotKey, "libraryHotKey") } }
    /// "Capture Again" repeats the last area without selecting.
    var captureAgainHotKey: HotKey? = nil { didSet { saveCodable(captureAgainHotKey, "captureAgainHotKey") } }

    enum Defaults {
        static let libraryHotKey: HotKey? = HotKey(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(optionKey | shiftKey | cmdKey),
                                                   display: "⌥⇧⌘L")
    }

    /// Every key this class writes, so a reset can clear them all. All but `perMacKeys` sync.
    static let keys = [
        "copyToClipboard", "afterCapture", "captureCursor", "showCursorByDefault", "windowShadow", "playSound", "showNotice",
        "autoName", "recognizeText", "recordWebAddress", "librarySync", "libraryBackend", "annotationStyle", "quickStyles", "presets", "libraryHotKey", "captureAgainHotKey",
        "recordMicrophone", "recordSystemAudio", "recordCamera", "showClicks", "showKeys", "recordFrameRate", "syncVideos",
        "toolStyle", "dialTrigger", "doubleClickOpens", "recordCountdown", "microphoneID", "cameraID", "confirmQuit",
    ]
    /// Of those, the ones each Mac chooses for itself: whether, and how, it syncs the library,
    /// and its own microphone and camera.
    static let perMacKeys: Set<String> = ["librarySync", "libraryBackend", "microphoneID", "cameraID"]

    @ObservationIgnored private var loading = false

    private init() {
        load()
        // Not from here: saving presets updates the shortcuts, which read `shared`, which is
        // still being made.
        DispatchQueue.main.async { MainActor.assumeIsolated { Preferences.shared.addNewDefaultPresets() } }
    }

    /// Presets added to the defaults after a version shipped join existing lists once (by
    /// their fixed IDs, so Macs syncing settings can't end up with two). Deleting one later
    /// is respected.
    private func addNewDefaultPresets() {
        let key = "presets.addedDefaults"
        var added = Set(AppDefaults.store.stringArray(forKey: key) ?? [])
        let newer = CapturePreset.defaults.filter { $0.mode == .scrolling || $0.mode == .recording }
        for preset in newer where !added.contains(preset.id.uuidString) {
            added.insert(preset.id.uuidString)
            guard !presets.contains(where: { $0.id == preset.id }) else { continue }
            // Without a shortcut if another preset already uses those keys.
            var copy = preset
            if let key = copy.hotKey, presets.contains(where: { $0.hotKey == key }) || libraryHotKey == key { copy.hotKey = nil }
            presets.append(copy)
        }
        AppDefaults.store.set(Array(added), forKey: key)
    }

    /// Puts every setting back to how a new install starts. Where the app appears,
    /// open-at-login and update checks are left alone.
    func resetToDefaults() {
        for key in Self.keys { AppDefaults.store.removeObject(forKey: key) }
        load()
        SettingsSync.shared.localDidChange()
    }

    /// Every setting's current value, in the form UserDefaults stores it, defaults included.
    var snapshot: [String: Any] {
        func data<T: Encodable>(_ value: T) -> Data { (try? JSONEncoder().encode(value)) ?? Data() }
        return [
            "copyToClipboard": copyToClipboard, "afterCapture": afterCapture.rawValue, "captureCursor": captureCursor,
            "showCursorByDefault": showCursorByDefault, "windowShadow": windowShadow, "playSound": playSound,
            "showNotice": showNotice, "autoName": autoName, "recognizeText": recognizeText,
            "recordWebAddress": recordWebAddress, "librarySync": librarySync, "libraryBackend": libraryBackend.rawValue,
            "annotationStyle": data(annotationStyle), "quickStyles": data(quickStyles), "presets": data(presets),
            "libraryHotKey": data(libraryHotKey), "captureAgainHotKey": data(captureAgainHotKey),
            "recordMicrophone": recordMicrophone, "recordSystemAudio": recordSystemAudio, "recordCamera": recordCamera,
            "showClicks": showClicks, "showKeys": showKeys, "recordFrameRate": recordFrameRate, "syncVideos": syncVideos,
            "toolStyle": toolStyle.rawValue, "dialTrigger": dialTrigger.rawValue, "doubleClickOpens": doubleClickOpens.rawValue,
            "recordCountdown": recordCountdown, "microphoneID": microphoneID, "cameraID": cameraID,
            "confirmQuit": confirmQuit,
        ]
    }

    /// Re-reads every setting after another Mac's settings were written into UserDefaults.
    func reload() {
        load()
        librarySyncChanged(force: true)
    }

    /// Turning on video sync sends this Mac's movies and fetches the others'.
    private func syncVideosChanged() {
        guard !loading else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                LibrarySync.shared.videoSyncChanged()
                FolderSync.shared.videoSyncChanged()
            }
        }
    }

    /// Library sync follows its own switch and service. Deferred, since it reads Preferences.
    private func librarySyncChanged(force: Bool = false) {
        guard !loading || force else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                LibrarySync.shared.start()
                FolderSync.shared.start()
            }
        }
    }

    private func load() {
        loading = true
        defer { loading = false }
        let d = AppDefaults.store
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
        func string(_ key: String) -> String { d.string(forKey: key) ?? "" }
        func codable<T: Decodable>(_ key: String, _ fallback: T) -> T {
            guard let data = d.data(forKey: key) else { return fallback }
            return (try? JSONDecoder().decode(T.self, from: data)) ?? fallback
        }

        copyToClipboard = bool("copyToClipboard", true)
        afterCapture = AfterCapture(rawValue: string("afterCapture")) ?? .preview
        captureCursor = bool("captureCursor", true)
        showCursorByDefault = bool("showCursorByDefault", false)
        windowShadow = bool("windowShadow", true)
        playSound = bool("playSound", true)
        showNotice = bool("showNotice", true)
        autoName = bool("autoName", true)
        recognizeText = bool("recognizeText", true)
        recordWebAddress = bool("recordWebAddress", true)
        librarySync = bool("librarySync", true)
        libraryBackend = LibraryBackend(rawValue: string("libraryBackend")) ?? .iCloud
        annotationStyle = codable("annotationStyle", AnnotationStyle.standard).drawable
        quickStyles = codable("quickStyles", AnnotationStyle.quickDefaults).map(\.drawable)
        presets = codable("presets", CapturePreset.defaults)
        libraryHotKey = codable("libraryHotKey", Defaults.libraryHotKey)
        captureAgainHotKey = codable("captureAgainHotKey", nil as HotKey?)
        recordMicrophone = bool("recordMicrophone", false)
        recordSystemAudio = bool("recordSystemAudio", true)
        recordCamera = bool("recordCamera", false)
        showClicks = bool("showClicks", true)
        showKeys = bool("showKeys", false)
        recordFrameRate = d.object(forKey: "recordFrameRate") as? Int ?? 30
        syncVideos = bool("syncVideos", false)
        toolStyle = ToolStyle(rawValue: string("toolStyle")) ?? .toolbar
        dialTrigger = DialTrigger(rawValue: string("dialTrigger")) ?? .rightClick
        doubleClickOpens = OpenPlace(rawValue: string("doubleClickOpens")) ?? .sidePane
        recordCountdown = d.object(forKey: "recordCountdown") as? Int ?? 3
        microphoneID = string("microphoneID")
        cameraID = string("cameraID")
        confirmQuit = bool("confirmQuit", true)
    }

    private func save(_ value: Any, _ key: String) {
        guard !loading else { return }
        store(value as? NSObject, key)
    }

    private func saveCodable<T: Encodable>(_ value: T, _ key: String) {
        guard !loading else { return }
        store((try? JSONEncoder().encode(value)) as NSObject?, key)
    }

    /// Writes only real changes, and reports them for iCloud sync. SwiftUI controls write
    /// their current value back when settings arrive from another Mac; counting those as
    /// edits would send the same settings back and forth between Macs forever.
    private func store(_ value: NSObject?, _ key: String) {
        let defaults = AppDefaults.store
        if let old = defaults.object(forKey: key) as? NSObject, let value, old.isEqual(value) { return }
        defaults.set(value, forKey: key)
        SettingsSync.shared.localDidChange()
        if key == "presets" || key.hasSuffix("HotKey") { HotKeyCenter.shared.apply() }
    }

    // MARK: Presets

    func preset(_ id: UUID) -> CapturePreset? { presets.first { $0.id == id } }

    func update(_ preset: CapturePreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
    }
}
