import CoreGraphics
import Foundation
import simd

/// A picture's pixels (or part of them) as 8-bit RGBA, for the smart tools to look at.
struct Pixels {
    let width: Int
    let height: Int
    var data: [UInt8]

    /// `image` drawn at `width` × `height`, or just the part of it at `crop` (in its pixels,
    /// origin at the top left) at that part's own size.
    init?(_ image: CGImage, crop: CGRect? = nil, width: Int? = nil, height: Int? = nil) {
        let part = crop ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let w = width ?? Int(part.width), h = height ?? Int(part.height)
        guard w > 0, h > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            // Place the whole picture so that `part` lands on the context (whose rows run from the top in memory).
            let sx = CGFloat(w) / part.width, sy = CGFloat(h) / part.height
            ctx.draw(image, in: CGRect(x: -part.minX * sx, y: -(CGFloat(image.height) - part.maxY) * sy,
                                       width: CGFloat(image.width) * sx, height: CGFloat(image.height) * sy))
            return true
        }
        guard drawn else { return nil }
        self.width = w
        self.height = h
        self.data = data
    }

    func pixel(_ x: Int, _ y: Int) -> SIMD4<Float> {
        let i = (y * width + x) * 4
        return SIMD4(Float(data[i]), Float(data[i + 1]), Float(data[i + 2]), Float(data[i + 3]))
    }

    func makeImage() -> CGImage? {
        var copy = data
        return copy.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}

/// Paints over part of a picture with what's around it, as if what was there had never been:
/// the colors just outside each edge are blended across, so plain backgrounds and gentle
/// gradients carry on smoothly.
public enum PatchFill {
    /// How far outside the area, in pixels, the surrounding colors are read.
    static let ring = 3

    /// The patch for `rect` (in the picture's points; the picture is `canvas` points large),
    /// with the area it covers, snapped to whole pixels.
    public static func patch(base: CGImage, rect: CGRect, canvas: CGSize) -> (image: CGImage, rect: CGRect)? {
        let scale = CGFloat(base.width) / max(canvas.width, 1)
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .standardized.integral.intersection(bounds)
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1 else { return nil }
        let drawn = CGRect(x: pixels.minX / scale, y: pixels.minY / scale, width: pixels.width / scale, height: pixels.height / scale)
        let key = Cache.Key(pixels)
        if let cached = cache.get(base, key) { return (cached, drawn) }
        guard let image = fill(base, pixels: pixels) else { return nil }
        cache.put(base, key, image)
        return (image, drawn)
    }

    static func fill(_ base: CGImage, pixels area: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let outer = area.insetBy(dx: -CGFloat(ring), dy: -CGFloat(ring)).intersection(bounds)
        guard let around = Pixels(base, crop: outer) else { return nil }
        let x0 = Int(area.minX - outer.minX), y0 = Int(area.minY - outer.minY)
        let w = Int(area.width), h = Int(area.height)

        // The colors just outside each side (nil where the area meets the picture's edge).
        func side(count: Int, _ sample: (Int, Int) -> (Int, Int)) -> [SIMD4<Float>]? {
            var values: [SIMD4<Float>] = []
            values.reserveCapacity(count)
            for i in 0..<count {
                var samples: [SIMD4<Float>] = []
                for k in 1...ring {
                    let (x, y) = sample(i, k)
                    guard x >= 0, y >= 0, x < around.width, y < around.height else { continue }
                    samples.append(around.pixel(x, y))
                }
                guard !samples.isEmpty else { return nil }
                values.append(median(samples))
            }
            return smooth(values)
        }
        let left = side(count: h) { i, k in (x0 - k, y0 + i) }
        let right = side(count: h) { i, k in (x0 + w - 1 + k, y0 + i) }
        let top = side(count: w) { i, k in (x0 + i, y0 - k) }
        let bottom = side(count: w) { i, k in (x0 + i, y0 + h - 1 + k) }

        guard var out = Pixels(empty: w, h) else { return nil }
        let l = left ?? right, r = right ?? left, t = top ?? bottom, b = bottom ?? top
        let fallback = SIMD4<Float>(128, 128, 128, 255)
        for y in 0..<h {
            let v = (Float(y) + 0.5) / Float(h)
            for x in 0..<w {
                let u = (Float(x) + 0.5) / Float(w)
                var value: SIMD4<Float>
                switch (l, t) {
                case let (l?, t?):
                    // A Coons patch: blend across both ways, less the corners counted twice.
                    let r = r!, b = b!
                    let across = (1 - u) * l[y] + u * r[y]
                    let down = (1 - v) * t[x] + v * b[x]
                    let c00 = (t[0] + l[0]) / 2, c10 = (t[w - 1] + r[0]) / 2
                    let c01 = (b[0] + l[h - 1]) / 2, c11 = (b[w - 1] + r[h - 1]) / 2
                    let corners = (1 - u) * (1 - v) * c00 + u * (1 - v) * c10 + (1 - u) * v * c01 + u * v * c11
                    value = across + down - corners
                case let (l?, nil):
                    value = (1 - u) * l[y] + u * r![y]
                case let (nil, t?):
                    value = (1 - v) * t[x] + v * b![x]
                case (nil, nil):
                    value = fallback
                }
                value = simd_clamp(value, SIMD4(repeating: 0), SIMD4(repeating: 255))
                // Keep it valid premultiplied color.
                let a = value[3]
                value = SIMD4(min(value[0], a), min(value[1], a), min(value[2], a), a)
                out.set(x, y, value)
            }
        }
        return out.makeImage()
    }

    static func median(_ values: [SIMD4<Float>]) -> SIMD4<Float> {
        guard values.count > 2 else { return values.reduce(.zero, +) / Float(max(values.count, 1)) }
        var result = SIMD4<Float>()
        for c in 0..<4 {
            let sorted = values.map { $0[c] }.sorted()
            result[c] = sorted[sorted.count / 2]
        }
        return result
    }

    /// A running median along a side, so a stray dark pixel just outside doesn't streak across.
    static func smooth(_ values: [SIMD4<Float>], radius: Int = 2) -> [SIMD4<Float>] {
        guard values.count > radius * 2 else { return values }
        return values.indices.map { i in
            median(Array(values[max(0, i - radius)...min(values.count - 1, i + radius)]))
        }
    }

    // Patches are drawn on every redraw while marks are dragged, so they're kept for the
    // picture last drawn.
    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var base: CGImage?
        private var patches: [Key: CGImage] = [:]

        struct Key: Hashable {
            let x, y, width, height: Int
            init(_ r: CGRect) { (x, y, width, height) = (Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)) }
        }

        func get(_ base: CGImage, _ rect: Key) -> CGImage? {
            lock.lock()
            defer { lock.unlock() }
            return self.base === base ? patches[rect] : nil
        }

        func put(_ base: CGImage, _ rect: Key, _ image: CGImage) {
            lock.lock()
            defer { lock.unlock() }
            if self.base !== base || patches.count > 400 {
                self.base = base
                patches = [:]
            }
            patches[rect] = image
        }
    }
}

extension Pixels {
    init?(empty width: Int, _ height: Int) {
        guard width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
        data = [UInt8](repeating: 0, count: width * height * 4)
    }

    mutating func set(_ x: Int, _ y: Int, _ value: SIMD4<Float>) {
        let i = (y * width + x) * 4
        data[i] = UInt8(value[0].rounded())
        data[i + 1] = UInt8(value[1].rounded())
        data[i + 2] = UInt8(value[2].rounded())
        data[i + 3] = UInt8(value[3].rounded())
    }
}

/// Finds the separate things in a screenshot (lines of text, buttons, icons, pictures) by
/// where its colors change sharply, for Smart Move and Simplify.
public enum ObjectFinder {
    /// The boxes around them, in the picture's points (origin at the top left), each with a
    /// little room around it.
    public static func objects(in base: CGImage, canvas: CGSize) -> [CGRect] {
        guard canvas.width >= 1, canvas.height >= 1 else { return [] }
        // About one pixel per point (at most 2400 across), so the gaps below are in points.
        let factor = min(1, 2400 / max(canvas.width, canvas.height))
        let w = max(1, Int(canvas.width * factor)), h = max(1, Int(canvas.height * factor))
        guard let pixels = Pixels(base, width: w, height: h) else { return [] }

        // Where the color jumps, against the pixel to the right or below.
        var edge = [Bool](repeating: false, count: w * h)
        let threshold: Float = 40
        for y in 0..<h {
            for x in 0..<w {
                let p = pixels.pixel(x, y)
                var jump: Float = 0
                if x + 1 < w { jump = max(jump, maxDifference(p, pixels.pixel(x + 1, y))) }
                if y + 1 < h { jump = max(jump, maxDifference(p, pixels.pixel(x, y + 1))) }
                edge[y * w + x] = jump > threshold
            }
        }
        // Spread sideways enough to join letters into words and words into lines, and up and
        // down a little, so lines of text stay apart.
        let rx = 3, ry = 1
        let grown = dilate(dilate(edge, w, h, radius: rx, horizontal: true), w, h, radius: ry, horizontal: false)

        var boxes: [CGRect] = []
        var seen = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        for start in 0..<(w * h) where grown[start] && !seen[start] {
            seen[start] = true
            stack.append(start)
            // The box around the edges themselves, not the spread.
            var minX = w, minY = h, maxX = -1, maxY = -1
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                if edge[i] {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
                func visit(_ n: Int) {
                    if grown[n] && !seen[n] { seen[n] = true; stack.append(n) }
                }
                if x > 0 { visit(i - 1) }
                if x + 1 < w { visit(i + 1) }
                if y > 0 { visit(i - w) }
                if y + 1 < h { visit(i + w) }
            }
            guard maxX >= 0 else { continue }
            // An edge at x is the step between x and x + 1.
            boxes.append(CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX + 2), height: CGFloat(maxY - minY + 2)))
        }

        let area = CGFloat(w * h)
        return boxes.compactMap { box -> CGRect? in
            // Specks, dividing lines and whole panels or windows aren't things to move.
            if box.width < 3 && box.height < 3 { return nil }
            let thin = min(box.width, box.height), long = max(box.width, box.height)
            if thin <= 4 && long >= thin * 10 { return nil }
            if box.width * box.height > area * 0.35 { return nil }
            let points = CGRect(x: box.minX / factor, y: box.minY / factor, width: box.width / factor, height: box.height / factor)
            return points.insetBy(dx: -2, dy: -2).intersection(CGRect(origin: .zero, size: canvas))
        }
        .sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    static func maxDifference(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
        let d = simd_abs(a - b)
        return max(d[0], d[1], d[2], d[3])
    }

    static func dilate(_ mask: [Bool], _ w: Int, _ h: Int, radius: Int, horizontal: Bool) -> [Bool] {
        guard radius > 0 else { return mask }
        var out = [Bool](repeating: false, count: mask.count)
        let (lines, length) = horizontal ? (h, w) : (w, h)
        for line in 0..<lines {
            func index(_ i: Int) -> Int { horizontal ? line * w + i : i * w + line }
            // How many set cells lie within `radius` of each position, kept as a running count.
            var count = 0
            for i in 0..<min(radius, length) where mask[index(i)] { count += 1 }
            for i in 0..<length {
                if i + radius < length, mask[index(i + radius)] { count += 1 }
                if i - radius - 1 >= 0, mask[index(i - radius - 1)] { count -= 1 }
                out[index(i)] = count > 0
            }
        }
        return out
    }

    /// The color just around `rect` (in points): the background it sits on.
    public static func backgroundColor(around rect: CGRect, in base: CGImage, canvas: CGSize) -> RGBA {
        let scale = CGFloat(base.width) / max(canvas.width, 1)
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let inner = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .integral.intersection(bounds)
        let outer = inner.insetBy(dx: -2, dy: -2).intersection(bounds)
        guard !inner.isNull, let pixels = Pixels(base, crop: outer) else { return .white }
        let local = inner.offsetBy(dx: -outer.minX, dy: -outer.minY)
        var ring: [SIMD4<Float>] = []
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where !local.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                ring.append(pixels.pixel(x, y))
            }
        }
        guard !ring.isEmpty else { return .white }
        return rgba(PatchFill.median(ring))
    }

    /// The main color inside `rect` that isn't `background`: the ink of text, the fill of a
    /// button, the body of an icon.
    public static func mainColor(in rect: CGRect, of base: CGImage, canvas: CGSize, background: RGBA) -> RGBA {
        let scale = CGFloat(base.width) / max(canvas.width, 1)
        let pixelsRect = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard !pixelsRect.isNull, let pixels = Pixels(base, crop: pixelsRect) else { return background }
        let bg = SIMD4<Float>(Float(background.r * 255), Float(background.g * 255), Float(background.b * 255), 255)
        // Colors in 16 steps a channel; the busiest bucket wins, and its colors are averaged.
        var buckets: [Int: (count: Int, sum: SIMD4<Float>)] = [:]
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let p = pixels.pixel(x, y)
                guard p[3] > 128, maxDifference(p, bg) > 60 else { continue }
                let key = (Int(p[0]) / 16) << 8 | (Int(p[1]) / 16) << 4 | Int(p[2]) / 16
                let old = buckets[key] ?? (0, .zero)
                buckets[key] = (old.count + 1, old.sum + p)
            }
        }
        guard let best = buckets.values.max(by: { $0.count < $1.count }) else { return background }
        return rgba(best.sum / Float(best.count))
    }

    /// Whether a part is a solid box, round (its corners are background), or a frame whose
    /// middle is the background (or close to it).
    public static func shape(of rect: CGRect, in base: CGImage, canvas: CGSize, background: RGBA) -> Annotation.SimpleShape {
        let scale = CGFloat(base.width) / max(canvas.width, 1)
        let pixelsRect = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard !pixelsRect.isNull, let pixels = Pixels(base, crop: pixelsRect), pixels.width > 4, pixels.height > 4 else { return .box }
        let bg = SIMD4<Float>(Float(background.r * 255), Float(background.g * 255), Float(background.b * 255), 255)
        // The middle: a quarter in from each side.
        var middle: [SIMD4<Float>] = []
        for y in (pixels.height / 4)..<max(pixels.height / 4 + 1, pixels.height * 3 / 4) {
            for x in (pixels.width / 4)..<max(pixels.width / 4 + 1, pixels.width * 3 / 4) { middle.append(pixels.pixel(x, y)) }
        }
        if maxDifference(PatchFill.median(middle), bg) < 30 { return .outline }
        // Points 15% of the way in from each corner: outside a circle or pill, inside a box
        // with gently rounded corners.
        let inset = Int(CGFloat(min(pixels.width, pixels.height)) * 0.15)
        let corners = [(inset, inset), (pixels.width - 1 - inset, inset), (inset, pixels.height - 1 - inset),
                       (pixels.width - 1 - inset, pixels.height - 1 - inset)]
            .filter { $0.0 >= 0 && $0.1 >= 0 && $0.0 < pixels.width && $0.1 < pixels.height }
        let bare = corners.filter { maxDifference(pixels.pixel($0.0, $0.1), bg) < 30 }.count
        return corners.count == 4 && bare >= 3 ? .round : .box
    }

    /// How much of `rect` is covered by marks unlike `background` (0–1): bold text covers more.
    public static func coverage(in rect: CGRect, of base: CGImage, canvas: CGSize, background: RGBA) -> Double {
        let scale = CGFloat(base.width) / max(canvas.width, 1)
        let pixelsRect = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard !pixelsRect.isNull, let pixels = Pixels(base, crop: pixelsRect) else { return 0 }
        let bg = SIMD4<Float>(Float(background.r * 255), Float(background.g * 255), Float(background.b * 255), 255)
        var inked = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where maxDifference(pixels.pixel(x, y), bg) > 100 { inked += 1 }
        }
        return Double(inked) / Double(max(pixels.width * pixels.height, 1))
    }

    static func rgba(_ p: SIMD4<Float>) -> RGBA {
        let a = max(p[3], 1)
        return RGBA(Double(min(p[0] / a, 1)), Double(min(p[1] / a, 1)), Double(min(p[2] / a, 1)))
    }
}

/// Retyping text found in the picture: the style that matches it as closely as it can.
public enum TextMatch {
    /// The text size for a line of recognized text `height` points tall.
    public static func fontSize(forLineHeight height: CGFloat) -> Double {
        (Double(height) / 1.2 * 2).rounded() / 2
    }

    /// An Edit Text mark for the line `text` at `box` (points), styled to match the picture.
    public static func mark(text: String, box: CGRect, in base: CGImage, canvas: CGSize) -> Annotation {
        let source = box.insetBy(dx: -2, dy: -2).intersection(CGRect(origin: .zero, size: canvas))
        let background = ObjectFinder.backgroundColor(around: source, in: base, canvas: canvas)
        let ink = ObjectFinder.mainColor(in: box, of: base, canvas: canvas, background: background)
        let bold = ObjectFinder.coverage(in: box, of: base, canvas: canvas, background: background) > 0.2
        let style = AnnotationStyle(color: ink, lineWidth: 2, filled: false, fontSize: fontSize(forLineHeight: box.height),
                                    bold: bold, shadow: false)
        return Annotation(kind: .editText, rect: box, text: text, source: source, style: style)
    }
}

/// Redraws a screenshot as plain shapes: each line of text a bar, each button, icon or
/// picture a box in its main color. Good for showing the layout of a screen without its
/// details, or keeping attention on one part.
public enum Simplifier {
    public enum Colors: String, CaseIterable, Sendable {
        /// Each part keeps its own main color.
        case original
        /// Everything in grays.
        case grays
    }

    /// The Simplify marks for the picture. `textLines` are the boxes (in points) of its
    /// recognized lines of text.
    public static func marks(in base: CGImage, canvas: CGSize, textLines: [CGRect], colors: Colors) -> [Annotation] {
        let lines = textLines.map { $0.insetBy(dx: -2, dy: -2).intersection(CGRect(origin: .zero, size: canvas)) }.filter { !$0.isNull }
        var boxes: [Annotation] = []
        for object in ObjectFinder.objects(in: base, canvas: canvas) {
            // Parts that are mostly text are drawn as bars instead.
            let covered = lines.reduce(0) { total, line in
                let overlap = line.intersection(object)
                return total + (overlap.isNull ? 0 : overlap.width * overlap.height)
            }
            if covered >= object.width * object.height * 0.5 { continue }
            let background = ObjectFinder.backgroundColor(around: object, in: base, canvas: canvas)
            let color = ObjectFinder.mainColor(in: object, of: base, canvas: canvas, background: background)
            let shape = ObjectFinder.shape(of: object, in: base, canvas: canvas, background: background)
            boxes.append(mark(object, shape: shape, color: tone(color, colors, text: false)))
        }
        let bars = lines.map { line -> Annotation in
            let background = ObjectFinder.backgroundColor(around: line, in: base, canvas: canvas)
            let ink = ObjectFinder.mainColor(in: line, of: base, canvas: canvas, background: background)
            return mark(line, shape: .textBar, color: tone(ink, colors, text: true))
        }
        // Boxes first, so the bars of text on buttons sit on top of them.
        return boxes + bars
    }

    static func mark(_ rect: CGRect, shape: Annotation.SimpleShape, color: RGBA) -> Annotation {
        Annotation(kind: .simplify, rect: rect, source: rect, shape: shape,
                   style: AnnotationStyle(color: color, lineWidth: 0, filled: true, shadow: false))
    }

    static func tone(_ color: RGBA, _ colors: Colors, text: Bool) -> RGBA {
        guard colors == .grays else {
            // Text as bars reads better a little softer than the ink.
            return text ? mix(color, .init(0.5, 0.5, 0.5), 0.25) : color
        }
        let lightness = 0.299 * color.r + 0.587 * color.g + 0.114 * color.b
        let gray = text ? 0.5 + (lightness - 0.5) * 0.4 : 0.35 + lightness * 0.55
        return RGBA(gray, gray, gray)
    }

    static func mix(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
        RGBA(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a)
    }
}
