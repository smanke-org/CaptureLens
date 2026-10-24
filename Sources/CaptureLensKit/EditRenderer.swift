import CoreGraphics
import Foundation

/// Produces the finished picture: the capture with its background removed (if asked), its
/// annotations and pointer drawn in, then cropped, cut, turned, resized, given its edges and
/// its border. Used for the library's Result view, thumbnails, copying, dragging and saving.
public enum EditRenderer {
    /// `mask` is the subject's mask (white where it is), for background removal.
    public static func render(base: CGImage, scale: Double, edits: ImageEdits, annotations: [Annotation],
                              cursor: CursorLayer?, mask: CGImage? = nil) -> CGImage? {
        let scale = max(scale, 0.01)
        var image = base
        if edits.removeBackground, let mask, let cut = applyMask(image, mask: mask) { image = cut }
        if let marked = AnnotationRenderer.flatten(base: image, scale: scale, annotations: annotations, cursor: cursor) { image = marked }

        // Crop, in the original's points.
        var origin = CGPoint.zero
        if let crop = edits.crop {
            let pixels = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale)
                .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if !pixels.isEmpty, let cropped = image.cropping(to: pixels) {
                image = cropped
                origin = CGPoint(x: pixels.minX / scale, y: pixels.minY / scale)
            }
        }
        // Cut-outs, last first so earlier positions stay put.
        for cut in edits.cuts.sorted(by: { $0.from > $1.from }) {
            if let joined = removeStrip(image, cut: cut, origin: origin, scale: scale) { image = joined }
        }
        if edits.rotation % 4 != 0, let turned = rotate(image, quarterTurns: edits.rotation) { image = turned }
        let outScale = scale * edits.outputScale
        if abs(edits.outputScale - 1) > 0.001, let resized = resize(image, by: edits.outputScale) { image = resized }
        // Border first, so torn or wavy edges cut through it; the shadow last, so it follows
        // whatever shape the edges leave.
        if let border = edits.border, let framed = applyBorder(image, border, pixelsPerPoint: outScale) { image = framed }
        if let edges = edits.edges, let shaped = applyEdges(image, edges, pixelsPerPoint: outScale) { image = shaped }
        if edits.border?.shadow == true, let shadowed = applyShadow(image, pixelsPerPoint: outScale) { image = shadowed }
        return image
    }

    static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    // MARK: - Background

    /// Keeps only what the mask covers.
    public static func applyMask(_ image: CGImage, mask: CGImage) -> CGImage? {
        guard let ctx = context(width: image.width, height: image.height) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.clip(to: rect, mask: mask)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    // MARK: - Cut out

    /// Takes a strip out and joins the two sides, straight or with a torn or wavy seam (and a
    /// small gap, so it's clear something was taken out).
    static func removeStrip(_ image: CGImage, cut: CutOut, origin: CGPoint, scale: Double) -> CGImage? {
        let horizontal = cut.axis == .horizontal
        let length = horizontal ? image.height : image.width
        let base = horizontal ? origin.y : origin.x
        let a = Int(((cut.from - base) * scale).rounded()), b = Int(((cut.to - base) * scale).rounded())
        let start = min(max(a, 0), length), end = min(max(b, 0), length)
        guard end > start else { return nil }
        let gap = cut.seam == .straight ? 0 : Int((CutOut.seamGap * scale).rounded())
        let newLength = length - (end - start) + gap
        let width = horizontal ? image.width : newLength
        let height = horizontal ? newLength : image.height
        guard let ctx = context(width: width, height: height) else { return nil }
        // Work in a top-left space.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let amplitude = 5 * scale
        func draw(part: CGRect, at offset: CGFloat, jaggedEdge: CGFloat?, edgeIsEnd: Bool) {
            guard let piece = image.cropping(to: part), !part.isEmpty else { return }
            let dest = horizontal ? CGRect(x: 0, y: offset, width: part.width, height: part.height)
                                  : CGRect(x: offset, y: 0, width: part.width, height: part.height)
            ctx.saveGState()
            if cut.seam != .straight, jaggedEdge != nil {
                ctx.addPath(seamClip(dest, horizontal: horizontal, atEnd: edgeIsEnd, seam: cut.seam, amplitude: amplitude, scale: scale))
                ctx.clip()
            }
            AnnotationRenderer.drawImage(piece, in: dest, ctx: ctx)
            ctx.restoreGState()
        }
        let first = horizontal ? CGRect(x: 0, y: 0, width: full.width, height: CGFloat(start))
                               : CGRect(x: 0, y: 0, width: CGFloat(start), height: full.height)
        let second = horizontal ? CGRect(x: 0, y: CGFloat(end), width: full.width, height: CGFloat(length - end))
                                : CGRect(x: CGFloat(end), y: 0, width: CGFloat(length - end), height: full.height)
        draw(part: first, at: 0, jaggedEdge: CGFloat(start), edgeIsEnd: true)
        draw(part: second, at: CGFloat(start + gap), jaggedEdge: 0, edgeIsEnd: false)
        return ctx.makeImage()
    }

    /// `rect` with one edge (its end, or its start) made torn or wavy.
    static func seamClip(_ rect: CGRect, horizontal: Bool, atEnd: Bool, seam: CutOut.Seam, amplitude: Double, scale: Double) -> CGPath {
        let path = CGMutablePath()
        let length = horizontal ? rect.width : rect.height
        let steps = max(2, Int(length / (seam == .torn ? 12 * scale : 6 * scale)))
        var edge: [CGPoint] = []
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps) * length
            let offset: CGFloat = seam == .torn
                ? (i % 2 == 0 ? 0 : amplitude) * (0.6 + 0.4 * CGFloat((i * 7919) % 5) / 4)
                : amplitude / 2 * (1 + sin(t / (20 * scale) * .pi))
            let inset = atEnd ? -offset : offset
            if horizontal {
                edge.append(CGPoint(x: rect.minX + t, y: (atEnd ? rect.maxY : rect.minY) + inset))
            } else {
                edge.append(CGPoint(x: (atEnd ? rect.maxX : rect.minX) + inset, y: rect.minY + t))
            }
        }
        if horizontal {
            let far = atEnd ? rect.minY : rect.maxY
            path.move(to: CGPoint(x: rect.minX, y: far))
            path.addLines(between: [CGPoint(x: rect.minX, y: far)] + edge + [CGPoint(x: rect.maxX, y: far)])
        } else {
            let far = atEnd ? rect.minX : rect.maxX
            path.addLines(between: [CGPoint(x: far, y: rect.minY)] + edge + [CGPoint(x: far, y: rect.maxY)])
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Turning and sizing

    static func rotate(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let turns = (quarterTurns % 4 + 4) % 4
        let swap = turns % 2 == 1
        let width = swap ? image.height : image.width, height = swap ? image.width : image.height
        guard let ctx = context(width: width, height: height) else { return nil }
        ctx.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        // Clockwise on screen is a negative angle in the bitmap's y-up space.
        ctx.rotate(by: -CGFloat(turns) * .pi / 2)
        ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        return ctx.makeImage()
    }

    static func resize(_ image: CGImage, by factor: Double) -> CGImage? {
        let width = max(1, Int((Double(image.width) * factor).rounded())), height = max(1, Int((Double(image.height) * factor).rounded()))
        guard let ctx = context(width: width, height: height) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    // MARK: - Edges and border

    static func applyEdges(_ image: CGImage, _ edges: EdgeEffect, pixelsPerPoint s: Double) -> CGImage? {
        guard !edges.sides.isEmpty, let ctx = context(width: image.width, height: image.height) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if edges.kind == .fade {
            guard let mask = fadeMask(width: image.width, height: image.height, sides: edges.sides, distance: 40 * s) else { return nil }
            ctx.clip(to: rect, mask: mask)
        } else {
            // Work top-left, as the sides are named.
            ctx.saveGState()
            ctx.translateBy(x: 0, y: rect.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.addPath(edgePath(rect, sides: edges.sides, kind: edges.kind, scale: s))
            ctx.restoreGState()
            ctx.clip()
        }
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    /// The outline of `rect` with the chosen sides torn or wavy (top-left space).
    static func edgePath(_ rect: CGRect, sides: Set<EdgeEffect.Side>, kind: EdgeEffect.Kind, scale: Double) -> CGPath {
        let amplitude = 6 * scale
        func side(from a: CGPoint, to b: CGPoint, inward: CGVector, jagged: Bool) -> [CGPoint] {
            guard jagged else { return [a, b] }
            let length = hypot(b.x - a.x, b.y - a.y)
            let steps = max(2, Int(length / (kind == .torn ? 11 * scale : 5 * scale)))
            return (0...steps).map { i in
                let t = CGFloat(i) / CGFloat(steps)
                let depth: CGFloat = kind == .torn
                    ? amplitude * (i % 2 == 0 ? 0.2 : 1) * (0.55 + 0.45 * CGFloat((i * 104729) % 7) / 6)
                    : amplitude / 2 * (1 + sin(t * length / (22 * scale) * .pi))
                return CGPoint(x: a.x + (b.x - a.x) * t + inward.dx * depth, y: a.y + (b.y - a.y) * t + inward.dy * depth)
            }
        }
        let tl = CGPoint(x: rect.minX, y: rect.minY), tr = CGPoint(x: rect.maxX, y: rect.minY)
        let br = CGPoint(x: rect.maxX, y: rect.maxY), bl = CGPoint(x: rect.minX, y: rect.maxY)
        var points: [CGPoint] = []
        points += side(from: tl, to: tr, inward: CGVector(dx: 0, dy: 1), jagged: sides.contains(.top))
        points += side(from: tr, to: br, inward: CGVector(dx: -1, dy: 0), jagged: sides.contains(.right))
        points += side(from: br, to: bl, inward: CGVector(dx: 0, dy: -1), jagged: sides.contains(.bottom))
        points += side(from: bl, to: tl, inward: CGVector(dx: 1, dy: 0), jagged: sides.contains(.left))
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

    /// A grayscale mask: white, fading to black toward the chosen sides.
    static func fadeMask(width: Int, height: Int, sides: Set<EdgeEffect.Side>, distance: Double) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                  colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)] as CFArray, locations: [0, 1])!
        let w = CGFloat(width), h = CGFloat(height), d = CGFloat(min(distance, Double(min(width, height)) / 2))
        // The mask's space has y up: "top" is at y = h.
        ctx.setBlendMode(.multiply)
        for s in sides {
            let (start, end): (CGPoint, CGPoint) = switch s {
            case .top: (CGPoint(x: 0, y: h), CGPoint(x: 0, y: h - d))
            case .bottom: (CGPoint(x: 0, y: 0), CGPoint(x: 0, y: d))
            case .left: (CGPoint(x: 0, y: 0), CGPoint(x: d, y: 0))
            case .right: (CGPoint(x: w, y: 0), CGPoint(x: w - d, y: 0))
            }
            ctx.drawLinearGradient(gradient, start: start, end: end, options: [])
        }
        return ctx.makeImage()
    }

    /// Rounds the corners and draws the border line (no shadow; see `applyShadow`).
    static func applyBorder(_ image: CGImage, _ border: Border, pixelsPerPoint s: Double) -> CGImage? {
        guard let ctx = context(width: image.width, height: image.height) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let radius = min(CGFloat(border.cornerRadius * s), rect.width / 2, rect.height / 2)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        ctx.draw(image, in: rect)
        ctx.restoreGState()
        let line = CGFloat(border.width * s)
        if line > 0 {
            let inset = rect.insetBy(dx: line / 2, dy: line / 2)
            let innerRadius = max(0, radius - line / 2)
            ctx.addPath(CGPath(roundedRect: inset, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil))
            ctx.setStrokeColor(border.color.cgColor)
            ctx.setLineWidth(line)
            ctx.strokePath()
        }
        return ctx.makeImage()
    }

    /// A soft drop shadow around the picture's shape, on a transparent margin.
    static func applyShadow(_ image: CGImage, pixelsPerPoint s: Double) -> CGImage? {
        let margin = Int((18 * s).rounded())
        guard let ctx = context(width: image.width + margin * 2, height: image.height + margin * 2) else { return nil }
        ctx.setShadow(offset: CGSize(width: 0, height: -4 * s), blur: 14 * s, color: CGColor(gray: 0, alpha: 0.45))
        ctx.draw(image, in: CGRect(x: margin, y: margin, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}
