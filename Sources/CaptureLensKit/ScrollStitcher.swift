import CoreGraphics
import Foundation

/// Joins pictures of an area taken while it scrolls into one tall picture.
///
/// Each new frame is compared with the last one: rows that stay put at the top and bottom
/// (a toolbar, a sticky header, a status bar) are kept once, and the rows in between are
/// matched to find how far the content moved, so only what's new is added. Frames that
/// didn't move add nothing; a frame that can't be matched (the page jumped) is skipped, and
/// matching carries on from the last frame that fit, so scrolling back a little recovers.
public final class ScrollStitcher {
    /// Width of the signature each row is reduced to for matching.
    static let signatureWidth = 96

    public private(set) var frames = 0
    /// Rows of content added so far, below the fixed header.
    public private(set) var contentHeight = 0
    /// The tallest it may get, in pixels (very long pages stop here).
    public let maxHeight: Int

    private var width = 0
    private var height = 0
    private var previous: Frame?
    /// Fixed rows at the top and bottom, as seen so far (the smallest ever seen).
    private var header = 0
    private var footer = 0
    /// The picture so far: the first frame's header, then each frame's new content.
    private var pieces: [(image: CGImage, rows: Range<Int>)] = []
    private var lastFrame: CGImage?

    public init(maxHeight: Int = 40_000) {
        self.maxHeight = maxHeight
    }

    struct Frame {
        let image: CGImage
        /// One grayscale signature per row.
        let rows: [[UInt8]]
    }

    public enum Result: Equatable {
        case first
        /// The content moved by this many rows; that much was added.
        case moved(Int)
        /// Nothing moved.
        case unchanged
        /// Couldn't tell how it moved (skipped).
        case lost
        /// It's as tall as allowed.
        case full
    }

    /// Adds the next frame. Frames must all be the same size.
    @discardableResult
    public func add(_ image: CGImage) -> Result {
        guard let rows = Self.signatures(of: image) else { return .lost }
        let frame = Frame(image: image, rows: rows)
        defer { frames += 1 }
        guard let previous else {
            width = image.width
            height = image.height
            header = height
            footer = height
            self.previous = frame
            lastFrame = image
            return .first
        }
        guard image.width == width, image.height == height else { return .lost }
        if contentHeight + height >= maxHeight { return .full }

        // Fixed rows: identical at the same place in both frames.
        var top = 0
        while top < height && Self.same(previous.rows[top], frame.rows[top]) { top += 1 }
        if top == height { return .unchanged }
        var bottom = 0
        while bottom < height - top && Self.same(previous.rows[height - 1 - bottom], frame.rows[height - 1 - bottom]) { bottom += 1 }
        // A header can only shrink as more is seen (a row that once moved isn't fixed).
        let fixedTop = min(header, top), fixedBottom = min(footer, bottom)

        guard let shift = Self.shift(from: previous.rows, to: frame.rows, top: fixedTop, bottom: fixedBottom) else {
            // Keep comparing with the last frame that fit, so scrolling back to it recovers.
            return .lost
        }
        if pieces.isEmpty {
            // The first frame, up to its footer, starts the picture.
            pieces.append((previous.image, 0..<(height - fixedBottom)))
            contentHeight = height - fixedBottom
        }
        header = fixedTop
        footer = fixedBottom
        // The new rows: the last `shift` rows above the footer.
        let start = height - fixedBottom - shift, end = height - fixedBottom
        pieces.append((image, start..<end))
        contentHeight += shift
        self.previous = frame
        lastFrame = image
        return .moved(shift)
    }

    /// The tall picture so far: everything that scrolled past, with the footer of the last
    /// frame at the bottom.
    public func image() -> CGImage? {
        guard let lastFrame else { return nil }
        guard !pieces.isEmpty else { return lastFrame }
        let total = contentHeight + footer
        guard let ctx = CGContext(data: nil, width: width, height: total, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Fill top-down: CoreGraphics's origin is at the bottom left.
        var y = 0
        for piece in pieces {
            let rows = piece.rows
            guard !rows.isEmpty, let slice = piece.image.cropping(to: CGRect(x: 0, y: rows.lowerBound, width: width, height: rows.count)) else { continue }
            ctx.draw(slice, in: CGRect(x: 0, y: total - y - rows.count, width: width, height: rows.count))
            y += rows.count
        }
        if footer > 0, let slice = lastFrame.cropping(to: CGRect(x: 0, y: height - footer, width: width, height: footer)) {
            ctx.draw(slice, in: CGRect(x: 0, y: 0, width: width, height: footer))
        }
        return ctx.makeImage()
    }

    // MARK: Matching

    /// Each row reduced to `signatureWidth` gray values, for quick comparison.
    static func signatures(of image: CGImage) -> [[UInt8]]? {
        let w = signatureWidth, h = image.height
        guard h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        // Memory rows run from the top.
        return (0..<h).map { row in Array(UnsafeBufferPointer(start: data + row * w, count: w)) }
    }

    static func same(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        difference(a, b) <= 2
    }

    /// The mean difference between two rows' signatures.
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var total = 0
        for i in a.indices { total += abs(Int(a[i]) - Int(b[i])) }
        return total / max(a.count, 1)
    }

    /// How many rows the content between the fixed header and footer moved up, or nil if
    /// no shift matches well. Plain rows (all one color) don't count: they match anything.
    static func shift(from old: [[UInt8]], to new: [[UInt8]], top: Int, bottom: Int) -> Int? {
        let height = old.count
        let span = height - top - bottom
        guard span > 8 else { return nil }
        func plain(_ row: [UInt8]) -> Bool { (row.max() ?? 0) - (row.min() ?? 0) < 6 }
        var best: (shift: Int, score: Double)?
        // At least a fifth of the area must still overlap to trust a match.
        for shift in 1...max(1, span - span / 5) {
            var total = 0, counted = 0
            var row = top
            // Sample rows (every 2nd) to keep this quick on tall frames.
            while row + shift < height - bottom {
                let a = old[row + shift], b = new[row]
                if !plain(a) || !plain(b) {
                    total += difference(a, b)
                    counted += 1
                }
                row += 2
            }
            guard counted >= 4 else { continue }
            let score = Double(total) / Double(counted)
            if score < (best?.score ?? .infinity) { best = (shift, score) }
            if score == 0 { break }
        }
        guard let best, best.score <= 3 else { return nil }
        return best.shift
    }
}
