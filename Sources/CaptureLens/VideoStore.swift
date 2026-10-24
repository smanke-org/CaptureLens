import AppKit
@preconcurrency import AVFoundation
import CaptureLensKit
import CryptoKit
import Observation

/// Recordings' movie files, kept beside the library in Videos/: `<id>.mp4`, or sealed with
/// the library's key as `<id>.clvideo` while the library is encrypted. The capture itself
/// (name, tags, poster frame…) lives in the library like any other.
///
/// A sealed movie is opened into this Mac's caches to play it; those copies are cleared at
/// launch and quit.
@Observable
@MainActor
final class VideoStore {
    static let shared = VideoStore()

    /// Bumped when a movie arrives or goes, so views showing "not on this Mac" update.
    private(set) var revision = 0
    /// Movies being opened to play.
    private(set) var opening: Set<UUID> = []

    var folder: URL { LibraryStore.shared.folder.appending(path: "Videos", directoryHint: .isDirectory) }

    /// Unsealed copies for playing.
    let playbackFolder: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "com.smanke.CaptureLens/Playback", directoryHint: .isDirectory)

    private init() {
        clearPlayback()
    }

    private func plainURL(_ id: UUID) -> URL { externalURL(id) ?? folder.appending(path: "\(id.uuidString).mp4") }

    /// Imported videos stay where they were copied (a folder of the user's), not in Videos/.
    private func externalURL(_ id: UUID) -> URL? {
        LibraryStore.shared.db?.string(forKey: "video.external.\(id.uuidString)").map { URL(fileURLWithPath: $0) }
    }

    /// Keeps a movie the library doesn't hold itself, for the capture `id`.
    func attach(_ movie: URL, to id: UUID) {
        try? LibraryStore.shared.db?.set(movie.path, forKey: "video.external.\(id.uuidString)")
        revision += 1
    }
    private func sealedURL(_ id: UUID) -> URL { folder.appending(path: "\(id.uuidString).clvideo") }

    /// Whether this Mac has the movie.
    func has(_ id: UUID) -> Bool {
        _ = revision
        let fm = FileManager.default
        return fm.fileExists(atPath: plainURL(id).path) || fm.fileExists(atPath: sealedURL(id).path)
    }

    /// The stored file (sealed or not), for syncing.
    func storedFile(_ id: UUID) -> (url: URL, sealed: Bool)? {
        let fm = FileManager.default
        if fm.fileExists(atPath: sealedURL(id).path) { return (sealedURL(id), true) }
        if fm.fileExists(atPath: plainURL(id).path) { return (plainURL(id), false) }
        return nil
    }

    var diskSize: Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Moves a finished movie into the library (sealing it if the library is encrypted).
    func store(_ movie: URL, for id: UUID) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let key = LibraryStore.shared.db?.sealKey {
            try ChunkedSeal.seal(movie, to: sealedURL(id), key: key)
            try? FileManager.default.removeItem(at: movie)
        } else {
            try? FileManager.default.removeItem(at: plainURL(id))
            try FileManager.default.moveItem(at: movie, to: plainURL(id))
        }
        revision += 1
    }

    /// A movie that arrived from another Mac, sealed with the sync key.
    func receive(_ id: UUID, sealedWith key: SymmetricKey, from file: URL) async {
        guard !has(id) else { return }
        let plain = FileManager.default.temporaryDirectory.appending(path: "CaptureLens-\(UUID().uuidString).mp4")
        do {
            try await Task.detached(priority: .utility) { try ChunkedSeal.open(file, to: plain, key: key) }.value
            try store(plain, for: id)
            NSLog("CaptureLens: a video arrived from another Mac")
        } catch {
            try? FileManager.default.removeItem(at: plain)
            NSLog("CaptureLens: couldn't open a synced video: \(error.localizedDescription)")
        }
    }

    /// The movie sealed with the sync key, in a temporary file, for sending to other Macs.
    nonisolated static func sealedForSync(_ stored: (url: URL, sealed: Bool), libraryKey: SymmetricKey?, syncKey: SymmetricKey) throws -> URL {
        let out = FileManager.default.temporaryDirectory.appending(path: "CaptureLens-\(UUID().uuidString).clvideo")
        if stored.sealed {
            guard let libraryKey else { throw ChunkedSeal.Failure.damaged }
            let plain = FileManager.default.temporaryDirectory.appending(path: "CaptureLens-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: plain) }
            try ChunkedSeal.open(stored.url, to: plain, key: libraryKey)
            try ChunkedSeal.seal(plain, to: out, key: syncKey)
        } else {
            try ChunkedSeal.seal(stored.url, to: out, key: syncKey)
        }
        return out
    }

    /// A file that plays: the movie itself, or an unsealed copy of it.
    func playableURL(_ id: UUID) async -> URL? {
        if FileManager.default.fileExists(atPath: plainURL(id).path) { return plainURL(id) }
        guard FileManager.default.fileExists(atPath: sealedURL(id).path), let key = LibraryStore.shared.db?.sealKey else { return nil }
        let copy = playbackFolder.appending(path: "\(id.uuidString).mp4")
        if FileManager.default.fileExists(atPath: copy.path) { return copy }
        opening.insert(id)
        defer { opening.remove(id) }
        let sealed = sealedURL(id), folder = playbackFolder
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let partial = folder.appending(path: "\(id.uuidString).partial")
                try ChunkedSeal.open(sealed, to: partial, key: key)
                try FileManager.default.moveItem(at: partial, to: copy)
            }.value
            return copy
        } catch {
            NSLog("CaptureLens: couldn't open the video: \(error.localizedDescription)")
            return nil
        }
    }

    func remove(_ ids: some Sequence<UUID>) {
        for id in ids {
            // An imported video's copy belongs to its capture, so it goes too.
            for url in [plainURL(id), sealedURL(id), playbackFolder.appending(path: "\(id.uuidString).mp4")] {
                try? FileManager.default.removeItem(at: url)
            }
            try? LibraryStore.shared.db?.set(nil as String?, forKey: "video.external.\(id.uuidString)")
        }
        revision += 1
    }

    func clearPlayback() {
        try? FileManager.default.removeItem(at: playbackFolder)
    }

    /// Seals or unseals every movie after the library's encryption was turned on or off.
    func reseal(from old: SymmetricKey?, to new: SymmetricKey?) async {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        await Task.detached(priority: .userInitiated) {
            for url in urls {
                let name = url.deletingPathExtension().lastPathComponent
                let base = url.deletingLastPathComponent()
                do {
                    if url.pathExtension == "clvideo", new == nil, let old {
                        try ChunkedSeal.open(url, to: base.appending(path: "\(name).mp4"), key: old)
                        try FileManager.default.removeItem(at: url)
                    } else if url.pathExtension == "mp4", let new {
                        try ChunkedSeal.seal(url, to: base.appending(path: "\(name).clvideo"), key: new)
                        try FileManager.default.removeItem(at: url)
                    }
                } catch {
                    NSLog("CaptureLens: couldn't rewrite a video: \(error.localizedDescription)")
                }
            }
        }.value
        clearPlayback()
        revision += 1
    }

    // MARK: - Looking at a movie

    /// A frame of the movie, at full size.
    nonisolated static func frame(of asset: AVAsset, at seconds: Double, exact: Bool = true) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if exact {
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// Text read from a few frames through the recording, for searching it.
    nonisolated static func text(of asset: AVAsset, duration: Double) async -> String {
        var lines: [String] = []
        var seen = Set<String>()
        for fraction in [0.1, 0.5, 0.9] {
            guard let frame = await frame(of: asset, at: duration * fraction, exact: false),
                  let text = try? await Recognizer.text(in: frame) else { continue }
            for line in text.split(separator: "\n").map(String.init) where seen.insert(line).inserted { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }
}

extension LibraryStore {
    /// Saves a new recording: its poster frame as the picture, the movie beside it.
    @discardableResult
    func addVideo(movie: URL, poster: CGImage, scale: Double, info: VideoInfo, source: CaptureItem.Source,
                  created: Date = Date()) -> CaptureItem? {
        guard let item = add(image: poster, kind: .video, scale: scale, source: source, cursor: nil, created: created, video: info)
        else { return nil }
        do {
            try VideoStore.shared.store(movie, for: item.id)
        } catch {
            NSLog("CaptureLens: couldn't keep the video: \(error.localizedDescription)")
            delete([item.id])
            return nil
        }
        // Text from through the recording, not just its first frame.
        Task {
            guard Preferences.shared.recognizeText, let url = await VideoStore.shared.playableURL(item.id) else { return }
            let text = await VideoStore.text(of: AVURLAsset(url: url), duration: info.duration)
            guard var current = entry(item.id), !text.isEmpty else { return }
            let known = Set(current.recognizedText.split(separator: "\n").map(String.init))
            let added = text.split(separator: "\n").map(String.init).filter { !known.contains($0) }
            guard !added.isEmpty else { return }
            current.recognizedText = ([current.recognizedText] + added).filter { !$0.isEmpty }.joined(separator: "\n")
            update(current)
        }
        return item
    }
}
