import CryptoKit
import Foundation

/// A recording's length and how it's been trimmed and cut. The movie itself is kept apart
/// (see the app's `VideoStore`); its poster frame is the capture's picture.
public struct VideoInfo: Codable, Equatable, Sendable {
    /// Seconds, as recorded.
    public var duration: Double
    public var hasAudio: Bool
    public var edits: VideoEdits
    /// The movie stays on the Mac that has it, even with video sync on (imported videos).
    public var staysOnMac: Bool

    public init(duration: Double, hasAudio: Bool = false, edits: VideoEdits = VideoEdits(), staysOnMac: Bool = false) {
        self.duration = duration
        self.hasAudio = hasAudio
        self.edits = edits
        self.staysOnMac = staysOnMac
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? false
        edits = try c.decodeIfPresent(VideoEdits.self, forKey: .edits) ?? VideoEdits()
        staysOnMac = try c.decodeIfPresent(Bool.self, forKey: .staysOnMac) ?? false
    }

    /// How long the finished video runs.
    public var resultDuration: Double { edits.resultDuration(of: duration) }
}

/// What's left out of a recording: the ends trimmed off, and sections cut from the middle.
/// Times are seconds in the original recording; the movie itself is never changed.
public struct VideoEdits: Codable, Equatable, Sendable {
    public var trimStart: Double
    /// Where it stops; nil plays to the end.
    public var trimEnd: Double?
    public var cuts: [TimeCut]

    public init(trimStart: Double = 0, trimEnd: Double? = nil, cuts: [TimeCut] = []) {
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.cuts = cuts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trimStart = try c.decodeIfPresent(Double.self, forKey: .trimStart) ?? 0
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd)
        cuts = try c.decodeIfPresent([TimeCut].self, forKey: .cuts) ?? []
    }

    public var isEmpty: Bool { trimStart <= 0 && trimEnd == nil && cuts.isEmpty }

    /// The parts that stay, in order, none overlapping.
    public func kept(of duration: Double) -> [Range<Double>] {
        let start = min(max(0, trimStart), duration)
        let end = max(start, min(trimEnd ?? duration, duration))
        var parts: [Range<Double>] = [start..<end]
        for cut in cuts.sorted(by: { $0.start < $1.start }) {
            parts = parts.flatMap { part -> [Range<Double>] in
                guard cut.start < part.upperBound, cut.end > part.lowerBound else { return [part] }
                var pieces: [Range<Double>] = []
                if cut.start > part.lowerBound { pieces.append(part.lowerBound..<cut.start) }
                if cut.end < part.upperBound { pieces.append(cut.end..<part.upperBound) }
                return pieces
            }
        }
        // Slivers too short to show a frame are dropped.
        return parts.filter { $0.upperBound - $0.lowerBound > 0.01 }
    }

    public func resultDuration(of duration: Double) -> Double {
        kept(of: duration).reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    /// Where a moment of the original falls in the finished video; a moment that was left
    /// out maps to where the video picks up again.
    public func resultTime(forOriginal time: Double, duration: Double) -> Double {
        var elapsed = 0.0
        for part in kept(of: duration) {
            if time < part.lowerBound { return elapsed }
            if time < part.upperBound { return elapsed + time - part.lowerBound }
            elapsed += part.upperBound - part.lowerBound
        }
        return elapsed
    }

    /// The moment of the original shown at `time` in the finished video.
    public func originalTime(forResult time: Double, duration: Double) -> Double {
        var remaining = max(0, time)
        let parts = kept(of: duration)
        for part in parts {
            let length = part.upperBound - part.lowerBound
            if remaining < length { return part.lowerBound + remaining }
            remaining -= length
        }
        return parts.last?.upperBound ?? 0
    }

    /// Whether a moment of the original is left out.
    public func isRemoved(_ time: Double, duration: Double) -> Bool {
        !kept(of: duration).contains { $0.contains(time) }
    }
}

/// A section taken out of the middle of a recording.
public struct TimeCut: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double

    public init(id: UUID = UUID(), start: Double, end: Double) {
        self.id = id
        self.start = min(start, end)
        self.end = max(start, end)
    }
}

/// The moments to take frames from for an animated GIF: evenly spaced, at most `maxFrames`.
public enum GIFPlan {
    public static func frameTimes(duration: Double, fps: Double, maxFrames: Int = 600) -> [Double] {
        guard duration > 0, fps > 0 else { return [0] }
        let count = max(1, min(maxFrames, Int((duration * fps).rounded(.down))))
        let step = duration / Double(count)
        return (0..<count).map { Double($0) * step }
    }
}

/// Seals a big file a piece at a time, so a long recording never has to fit in memory:
/// "CLV1", then pieces of up to 4 MB, each sealed with AES-GCM and its own nonce. Each piece
/// is bound to its position, and the last is marked, so pieces can't be swapped, dropped or
/// cut off unnoticed.
public enum ChunkedSeal {
    static let magic = Data("CLV1".utf8)
    static let chunkSize = 4 << 20

    public enum Failure: Error { case notSealed, damaged }

    /// Whether `url` starts like a sealed file.
    public static func isSealed(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: magic.count)) == magic
    }

    public static func seal(_ input: URL, to output: URL, key: SymmetricKey) throws {
        let reader = try FileHandle(forReadingFrom: input)
        defer { try? reader.close() }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        try writer.write(contentsOf: magic)
        var index: UInt64 = 0
        var piece = try reader.read(upToCount: chunkSize) ?? Data()
        repeat {
            let next = try reader.read(upToCount: chunkSize) ?? Data()
            let box = try AES.GCM.seal(piece, using: key, authenticating: label(index, last: next.isEmpty))
            guard let combined = box.combined else { throw Failure.damaged }
            var length = UInt32(combined.count).bigEndian
            try writer.write(contentsOf: Data(bytes: &length, count: 4))
            try writer.write(contentsOf: combined)
            index += 1
            piece = next
        } while !piece.isEmpty
    }

    public static func open(_ input: URL, to output: URL, key: SymmetricKey) throws {
        let reader = try FileHandle(forReadingFrom: input)
        defer { try? reader.close() }
        guard try reader.read(upToCount: magic.count) == magic else { throw Failure.notSealed }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        var index: UInt64 = 0
        var sawLast = false
        while let header = try reader.read(upToCount: 4), header.count == 4 {
            guard !sawLast else { throw Failure.damaged }
            let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
            guard length >= 28, length <= chunkSize + 64, let combined = try reader.read(upToCount: length), combined.count == length else {
                throw Failure.damaged
            }
            let box = try AES.GCM.SealedBox(combined: combined)
            // A piece is either the last one or not; try the label it should have.
            if let plain = try? AES.GCM.open(box, using: key, authenticating: label(index, last: false)) {
                try writer.write(contentsOf: plain)
            } else {
                try writer.write(contentsOf: try AES.GCM.open(box, using: key, authenticating: label(index, last: true)))
                sawLast = true
            }
            index += 1
        }
        guard sawLast else { throw Failure.damaged }
    }

    static func label(_ index: UInt64, last: Bool) -> Data {
        var big = index.bigEndian
        return Data(bytes: &big, count: 8) + Data([last ? 1 : 0])
    }
}
