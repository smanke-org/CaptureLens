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

/// When scrolling for the user has to stop. The scroll events go where the pointer is, so
/// each one puts the pointer back over the area: if it has moved since, the user wants it,
/// and scrolling stops rather than pull it back. It also stops once the picture hasn't grown
/// for a few steps (the end of the page), even if something on it keeps moving.
public struct AutoScrollGuard: Sendable {
    public enum Stop: Equatable, Sendable {
        case pointerMoved
        case noProgress
    }

    /// How far, in points, the pointer can be from where scrolling left it.
    public var tolerance: CGFloat
    /// Steps in a row without the picture growing before it counts as the end.
    public var stallLimit: Int
    private var tallest = 0
    private var stalled = 0

    public init(tolerance: CGFloat = 4, stallLimit: Int = 6) {
        self.tolerance = tolerance
        self.stallLimit = stallLimit
    }

    /// Before each scroll step: `pointer` is where the pointer is, `expected` where scrolling
    /// put it, and `height` the picture's height so far.
    public mutating func check(pointer: CGPoint, expected: CGPoint, height: Int) -> Stop? {
        if hypot(pointer.x - expected.x, pointer.y - expected.y) > tolerance { return .pointerMoved }
        if height > tallest {
            tallest = height
            stalled = 0
        } else {
            stalled += 1
            if stalled >= stallLimit { return .noProgress }
        }
        return nil
    }
}

/// How far to scroll for the user after each frame. Steps start at under a third of the
/// area, so frames overlap plenty. When a frame can't be matched (the page went further
/// than asked, or a sticky bar left little to match), it scrolls back by the step it just
/// took, so the page returns to the last frame that fit, and goes on in half-size steps.
public struct AutoScrollPace: Sendable {
    /// The step, as a share of the area's height.
    public private(set) var fraction: Double
    public let smallest: Double
    /// The last scroll sent, in points: negative is down the page.
    private var last: Int32 = 0

    public init(fraction: Double = 0.3, smallest: Double = 0.08) {
        self.fraction = fraction
        self.smallest = smallest
    }

    /// The scroll to send after a frame with `result`, for an area `height` points tall:
    /// negative scrolls down the page, positive back up.
    public mutating func next(after result: ScrollStitcher.Result, height: Double) -> Int32 {
        if result == .lost, last < 0 {
            fraction = max(smallest, fraction / 2)
            last = -last
            return last
        }
        last = -Int32(max(20, (height * fraction).rounded()))
        return last
    }
}
