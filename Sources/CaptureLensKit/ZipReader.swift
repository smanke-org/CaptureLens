import Compression
import Foundation

/// Reads files out of a zip archive kept in memory (or mapped from disk): enough for the
/// documents other capture apps save, which are plain zips of JSON and PNG files.
public struct ZipReader {
    public struct Entry {
        public let name: String
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let localHeader: Int
    }

    public enum Failure: Error { case notZip, damaged, unsupported }

    public let entries: [String: Entry]
    private let data: Data

    public init(_ data: Data) throws {
        self.data = data
        // The end-of-central-directory record is in the last 64 KB (after an optional comment).
        let bytes = [UInt8](data.suffix(min(data.count, 65_557)))
        guard let end = (0...max(0, bytes.count - 22)).reversed().first(where: {
            bytes[$0] == 0x50 && bytes[$0 + 1] == 0x4B && bytes[$0 + 2] == 0x05 && bytes[$0 + 3] == 0x06
        }), bytes.count >= 22 else { throw Failure.notZip }
        let base = data.count - bytes.count + end
        let count = Int(data.u16(base + 10))
        var offset = Int(data.u32(base + 16))
        var entries: [String: Entry] = [:]
        for _ in 0..<count {
            guard offset + 46 <= data.count, data.u32(offset) == 0x0201_4B50 else { throw Failure.damaged }
            let nameLength = Int(data.u16(offset + 28)), extraLength = Int(data.u16(offset + 30)), commentLength = Int(data.u16(offset + 32))
            guard offset + 46 + nameLength <= data.count else { throw Failure.damaged }
            let nameData = data.subdata(in: data.startIndex + offset + 46..<data.startIndex + offset + 46 + nameLength)
            let name = String(decoding: nameData, as: UTF8.self)
            entries[name] = Entry(name: name, method: data.u16(offset + 10), compressedSize: Int(data.u32(offset + 20)),
                                  size: Int(data.u32(offset + 24)), localHeader: Int(data.u32(offset + 42)))
            offset += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    public var names: [String] { Array(entries.keys) }

    /// A file's contents, or nil if the archive doesn't have it.
    public func data(_ name: String) throws -> Data? {
        guard let entry = entries[name] else { return nil }
        let header = entry.localHeader
        guard header + 30 <= data.count, data.u32(header) == 0x0403_4B50 else { throw Failure.damaged }
        let start = header + 30 + Int(data.u16(header + 26)) + Int(data.u16(header + 28))
        guard start + entry.compressedSize <= data.count else { throw Failure.damaged }
        let stored = data.subdata(in: data.startIndex + start..<data.startIndex + start + entry.compressedSize)
        switch entry.method {
        case 0:
            return stored
        case 8:
            // Raw deflate, which is what Compression's ZLIB algorithm reads.
            guard entry.size > 0 else { return Data() }
            var out = Data(count: entry.size)
            let written = out.withUnsafeMutableBytes { dst in
                stored.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, entry.size,
                                              src.bindMemory(to: UInt8.self).baseAddress!, stored.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.size else { throw Failure.damaged }
            return out
        default:
            throw Failure.unsupported
        }
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16
    }
}
