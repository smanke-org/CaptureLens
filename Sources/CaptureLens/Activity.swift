import AppKit
import CaptureLensKit
import CryptoKit
import Foundation
import Observation

/// What CaptureLens has done, per day, for Settings › Activity: captures by kind, imports,
/// time recorded, marks added, and captures copied, saved, exported, dragged and shared.
///
/// Kept apart from the library on purpose: deleting captures shouldn't rewrite how much
/// CaptureLens was used. Only numbers are stored, in Application Support/CaptureLens/
/// activity.json.
@Observable
@MainActor
final class ActivityStore {
    static let shared = ActivityStore()

    private(set) var log = ActivityLog()

    private var url: URL { LibraryStore.shared.folder.appending(path: "activity.json") }

    private init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(ActivityLog.self, from: data) {
            log = saved
        } else {
            seedFromLibrary()
        }
    }

    func record(_ key: String, count: Int = 1) {
        guard count > 0 else { return }
        log.record(key, count: count)
        log.trim()
        save()
        ActivitySync.shared.localDidChange()
    }

    /// A capture was saved: counted by its kind.
    func recordCapture(_ kind: CaptureItem.Kind, scrolling: Bool = false, steps: Bool = false) {
        let key: String = if steps { ActivityKey.steps } else if scrolling { ActivityKey.scrolling } else {
            switch kind {
            case .window: ActivityKey.window
            case .screen: ActivityKey.screen
            case .video: ActivityKey.video
            case .imported: ActivityKey.imported
            case .region: ActivityKey.area
            }
        }
        record(key)
    }

    /// The first time, start from the captures this Mac already took (synced ones are
    /// counted by the Mac that took them).
    private func seedFromLibrary() {
        let me = DeviceIdentity.deviceID
        for item in LibraryStore.shared.items where item.origin == nil || item.origin == me {
            let key: String = switch item.kind {
            case .window: ActivityKey.window
            case .screen: ActivityKey.screen
            case .video: ActivityKey.video
            case .imported: ActivityKey.imported
            case .region: ActivityKey.area
            }
            log.record(key, at: item.created)
            if let video = item.video { log.record(ActivityKey.recordingSeconds, count: Int(video.duration.rounded()), at: item.created) }
        }
        if !log.days.isEmpty { save() }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(log).write(to: url, options: .atomic)
        } catch {
            NSLog("CaptureLens: couldn't save activity: \(error.localizedDescription)")
        }
    }
}

/// Adds up Activity from every Mac that shares CaptureLens settings.
///
/// Each Mac writes only its own CloudKit record, `Device_<device>` (of the Capture record
/// type, so no new type has to be published; versions that don't know it skip it), sealed
/// with the sync key like everything else, and reads the others'. With one writer per
/// record there are no conflicts, and the counts are whole-day totals, so reading a record
/// twice never counts anything twice. Only numbers are shared. Turning settings sync off
/// removes this Mac's record.
@Observable
@MainActor
final class ActivitySync {
    static let shared = ActivitySync()

    /// The other Macs' latest records, by device ID.
    private(set) var remotes: [String: DeviceActivity] = [:]

    @ObservationIgnored private var started = false
    @ObservationIgnored private var publishTask: Task<Void, Never>?

    private static let cacheKey = "activitySync.remotes"

    private init() {
        // The other Macs' last-known counts, so All Macs is complete before the first fetch.
        if let data = AppDefaults.store.data(forKey: Self.cacheKey),
           let cached = try? DeviceActivity.decoder.decode([String: DeviceActivity].self, from: data) {
            remotes = cached
        }
        #if DEBUG
        // Made-up other Macs, for screenshots and tests.
        if let path = ProcessInfo.processInfo.environment["CAPTURELENS_DEBUG_ACTIVITY_REMOTES"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let list = try? DeviceActivity.decoder.decode([DeviceActivity].self, from: data) {
            remotes = Dictionary(list.map { ($0.deviceID, $0) }, uniquingKeysWith: { a, _ in a })
            debugRemotes = true
        }
        #endif
    }

    @ObservationIgnored private var debugRemotes = false

    /// Whether other Macs' counts are added in: settings sync is on and unlocked.
    var isActive: Bool { debugRemotes || SettingsSync.shared.isReady }

    var activeRemotes: [DeviceActivity] {
        isActive ? remotes.values.sorted { $0.deviceName.localizedStandardCompare($1.deviceName) == .orderedAscending } : []
    }

    var combinedLog: ActivityLog { ActivityLog.combined([ActivityStore.shared.log] + activeRemotes.map(\.log)) }

    private var ownName: String { CloudSync.Name.device(DeviceIdentity.deviceID) }

    // MARK: - Lifecycle

    /// When the sync engine starts, and whenever settings sync is turned off.
    func start() {
        guard SettingsSync.shared.isEnabled else { return stop() }
        guard CloudSync.shared.isRunning else { return }
        started = true
        CloudSync.shared.queueSave([ownName])
    }

    private func stop() {
        guard started else { return }
        started = false
        publishTask?.cancel()
        let name = ownName
        Task { await CloudSync.shared.deleteNow(name) }
    }

    /// Something was counted here; sent a few seconds later, so a burst sends once.
    func localDidChange() {
        guard started else { return }
        publishTask?.cancel()
        publishTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            publishTask = nil
            CloudSync.shared.queueSave([ownName])
        }
    }

    func refresh() { if started { CloudSync.shared.fetchNow() } }

    // MARK: - From CloudSync

    func sealedOwnRecord(using key: SymmetricKey) -> Data? {
        let record = DeviceActivity(deviceID: DeviceIdentity.deviceID, deviceName: DeviceIdentity.deviceName,
                                    updatedAt: Date(), appVersion: AppInfo.version, log: ActivityStore.shared.log)
        return try? SyncCrypto.seal(DeviceActivity.encoder.encode(record), using: key)
    }

    func received(_ sealed: Data) {
        guard let key = SettingsSync.shared.key, let plain = try? SyncCrypto.open(sealed, using: key),
              let record = try? DeviceActivity.decoder.decode(DeviceActivity.self, from: plain),
              record.deviceID != DeviceIdentity.deviceID else { return }
        var merged = remotes
        merged[record.deviceID] = record
        apply(merged)
    }

    func removed(deviceID: String) {
        guard remotes[deviceID] != nil else { return }
        var merged = remotes
        merged[deviceID] = nil
        apply(merged)
    }

    private func apply(_ merged: [String: DeviceActivity]) {
        if merged != remotes { remotes = merged }
        if let data = try? DeviceActivity.encoder.encode(remotes) { AppDefaults.store.set(data, forKey: Self.cacheKey) }
    }
}

/// The share menu, counting a share only once a service is picked.
@MainActor
enum SharePicker {
    private final class Counter: NSObject, NSSharingServicePickerDelegate {
        func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            guard service != nil else { return }
            MainActor.assumeIsolated { ActivityStore.shared.record(ActivityKey.shares) }
        }
    }

    private static let counter = Counter()

    static func show(_ files: [URL], relativeTo rect: CGRect, of view: NSView, edge: NSRectEdge) {
        let picker = NSSharingServicePicker(items: files)
        picker.delegate = counter
        picker.show(relativeTo: rect, of: view, preferredEdge: edge)
    }
}
