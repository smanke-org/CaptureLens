import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Draws annotations, the same way on screen and into a copied or saved picture, so what
/// you see is what you get.
public enum AnnotationRenderer {
    /// Draws `annotations` into `ctx`, whose space is the capture's points with the origin at
    /// the top left. `base` is the picture (for magnifiers), `canvas` its size in points.
    public static func draw(_ annotations: [Annotation], in ctx: CGContext, canvas: CGSize, base: CGImage?) {
        // Spotlights first, so every other mark stays bright on top of the dimming.
        let spots = annotations.filter { $0.kind == .spotlight }
        if !spots.isEmpty { drawSpotlights(spots, in: ctx, canvas: canvas) }
        let numbers = Annotation.stepNumbers(annotations)
        for annotation in annotations where annotation.kind != .spotlight {
            draw(annotation, number: numbers[annotation.id], in: ctx, canvas: canvas, base: base)
        }
    }

    /// The capture with its annotations and (if shown) its pointer drawn in, at full size.
    public static func flatten(base: CGImage, scale: Double, annotations: [Annotation], cursor: CursorLayer?) -> CGImage? {
        let showCursor = cursor?.visible == true
        guard !annotations.isEmpty || showCursor else { return base }
        guard let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        let scale = max(scale, 0.01)
        // Points, origin at the top left.
        ctx.translateBy(x: 0, y: CGFloat(base.height))
        ctx.scaleBy(x: scale, y: -scale)
        let canvas = CGSize(width: Double(base.width) / scale, height: Double(base.height) / scale)
        draw(annotations, in: ctx, canvas: canvas, base: base)
        if let cursor, cursor.visible, let pointer = image(from: cursor.png) {
            drawImage(pointer, in: cursor.frame, ctx: ctx)
        }
        return ctx.makeImage()
    }

    public static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - One annotation

    static func draw(_ a: Annotation, number: Int?, in ctx: CGContext, canvas: CGSize, base: CGImage?) {
        let style = a.style
        let color = style.color.cgColor
        let width = CGFloat(style.lineWidth)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if style.shadow && a.kind != .highlighter {
            ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 4, color: CGColor(gray: 0, alpha: 0.35))
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)

        switch a.kind {
        case .rectangle, .ellipse:
            let rect = a.rect.standardized
            let path = a.kind == .rectangle
                ? CGPath(roundedRect: rect, cornerWidth: min(width, rect.width / 2), cornerHeight: min(width, rect.height / 2), transform: nil)
                : CGPath(ellipseIn: rect, transform: nil)
            if style.filled {
                ctx.setFillColor(style.color.withAlpha(style.color.a * 0.25).cgColor)
                ctx.addPath(path)
                ctx.fillPath()
            }
            ctx.addPath(path)
            ctx.strokePath()

        case .line:
            ctx.move(to: a.from)
            ctx.addLine(to: a.to)
            ctx.strokePath()

        case .arrow:
            drawArrow(from: a.from, to: a.to, width: width, in: ctx)

        case .pen:
            strokePolyline(a.points, in: ctx)

        case .highlighter:
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(style.color.withAlpha(0.45).cgColor)
            ctx.setLineWidth(max(width * 3, 12))
            ctx.setLineCap(.square)
            strokePolyline(a.points, in: ctx)

        case .text:
            let rect = a.rect.standardized
            if style.filled {
                let box = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
                ctx.addPath(box)
                ctx.fillPath()
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
                drawText(a.text, in: rect.insetBy(dx: 8, dy: 6), color: style.color.contrasting, style: style, ctx: ctx)
            } else {
                drawText(a.text, in: rect, color: style.color, style: style, ctx: ctx)
            }

        case .callout:
            let rect = a.rect.standardized
            // Bubble and tail are filled one after the other inside one layer: filled as a
            // single path, where they overlap would cancel out, and each would cast its own shadow.
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
            ctx.fillPath()
            if !rect.insetBy(dx: -2, dy: -2).contains(a.tail) {
                // A wedge from the middle of the bubble to the point it's about.
                let center = CGPoint(x: rect.midX, y: rect.midY)
                let angle = atan2(a.tail.y - center.y, a.tail.x - center.x) + .pi / 2
                let half = min(rect.width, rect.height) * 0.18
                ctx.move(to: CGPoint(x: center.x + cos(angle) * half, y: center.y + sin(angle) * half))
                ctx.addLine(to: a.tail)
                ctx.addLine(to: CGPoint(x: center.x - cos(angle) * half, y: center.y - sin(angle) * half))
                ctx.closePath()
                ctx.fillPath()
            }
            ctx.endTransparencyLayer()
            drawText(a.text, in: rect.insetBy(dx: 10, dy: 8), color: style.color.contrasting, style: style, ctx: ctx)

        case .step:
            let rect = a.rect.standardized
            let side = min(rect.width, rect.height)
            let circle = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            ctx.fillEllipse(in: circle)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            drawCentered("\(number ?? 1)", in: circle, size: side * 0.55, bold: true, color: style.color.contrasting, ctx: ctx)

        case .stamp:
            let rect = a.rect.standardized
            if isEmoji(a.stamp) {
                drawCentered(a.stamp, in: rect, size: min(rect.width, rect.height) * 0.8, bold: false, color: style.color, ctx: ctx)
            } else {
                // A rubber stamp: the word in capitals in a frame, tipped a little.
                ctx.translateBy(x: rect.midX, y: rect.midY)
                ctx.rotate(by: -8 * .pi / 180)
                let frame = CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
                ctx.setLineWidth(max(3, rect.height * 0.08))
                ctx.addPath(CGPath(roundedRect: frame.insetBy(dx: 2, dy: 2), cornerWidth: 8, cornerHeight: 8, transform: nil))
                ctx.strokePath()
                drawCentered(a.stamp.uppercased(), in: frame, size: rect.height * 0.45, bold: true, color: style.color, ctx: ctx)
            }

        case .magnify:
            let rect = a.rect.standardized
            guard rect.width > 1, rect.height > 1 else { return }
            let circle = CGPath(ellipseIn: rect, transform: nil)
            if let base {
                ctx.saveGState()
                ctx.addPath(circle)
                ctx.clip()
                let zoom = CGFloat(max(a.zoom, 1))
                // The spot under the middle of the circle, enlarged to fill it.
                let center = CGPoint(x: rect.midX, y: rect.midY)
                let drawn = CGRect(x: center.x - center.x * zoom, y: center.y - center.y * zoom,
                                   width: canvas.width * zoom, height: canvas.height * zoom)
                ctx.interpolationQuality = .high
                drawImage(base, in: drawn, ctx: ctx)
                ctx.restoreGState()
            }
            ctx.addPath(circle)
            ctx.strokePath()

        case .spotlight:
            break
        }
    }

    /// Dims everything outside the spotlights.
    static func drawSpotlights(_ spots: [Annotation], in ctx: CGContext, canvas: CGSize) {
        ctx.saveGState()
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: canvas).insetBy(dx: -2, dy: -2))
        for spot in spots {
            let rect = spot.rect.standardized
            path.addPath(CGPath(roundedRect: rect, cornerWidth: min(12, rect.width / 2), cornerHeight: min(12, rect.height / 2), transform: nil))
        }
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    static func drawArrow(from: CGPoint, to: CGPoint, width: CGFloat, in ctx: CGContext) {
        let length = hypot(to.x - from.x, to.y - from.y)
        guard length > 0.5 else { return }
        let head = min(max(width * 3.5, 12), length * 0.6)
        let angle = atan2(to.y - from.y, to.x - from.x)
        // The shaft stops inside the head, so its round cap doesn't poke out past the tip.
        let shaftEnd = CGPoint(x: to.x - cos(angle) * head * 0.6, y: to.y - sin(angle) * head * 0.6)
        ctx.move(to: from)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()
        let spread: CGFloat = .pi / 7
        ctx.move(to: to)
        ctx.addLine(to: CGPoint(x: to.x - cos(angle - spread) * head, y: to.y - sin(angle - spread) * head))
        ctx.addLine(to: CGPoint(x: to.x - cos(angle + spread) * head, y: to.y - sin(angle + spread) * head))
        ctx.closePath()
        ctx.fillPath()
    }

    static func strokePolyline(_ points: [CGPoint], in ctx: CGContext) {
        guard let first = points.first else { return }
        if points.count == 1 {
            ctx.move(to: first)
            ctx.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
        } else {
            ctx.addLines(between: points)
        }
        ctx.strokePath()
    }

    /// Draws a picture right side up in a top-left-origin context.
    static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    // MARK: - Text

    static func font(size: CGFloat, bold: Bool) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        return base
    }

    static func attributed(_ text: String, size: CGFloat, bold: Bool, color: RGBA, centered: Bool = false) -> NSAttributedString {
        var alignment: CTTextAlignment = centered ? .center : .left
        let settings = [CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                                value: withUnsafePointer(to: &alignment) { UnsafeRawPointer($0) })]
        let paragraph = CTParagraphStyleCreate(settings, settings.count)
        return NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size: size, bold: bold),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ])
    }

    /// Text wrapped inside `rect` (top-left origin), from its top.
    static func drawText(_ text: String, in rect: CGRect, color: RGBA, style: AnnotationStyle, ctx: CGContext) {
        guard !text.isEmpty, rect.width > 1, rect.height > 1 else { return }
        let string = attributed(text, size: CGFloat(style.fontSize), bold: style.bold, color: color)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        ctx.saveGState()
        // CoreText draws with y up: flip around the box.
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    static func drawCentered(_ text: String, in rect: CGRect, size: CGFloat, bold: Bool, color: RGBA, ctx: CGContext) {
        guard !text.isEmpty else { return }
        let line = CTLineCreateWithAttributedString(attributed(text, size: size, bold: bold, color: color))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// The size text needs at `style`, wrapped to `width` (for fitting a text box to its words).
    public static func textSize(_ text: String, style: AnnotationStyle, width: CGFloat) -> CGSize {
        let string = attributed(text.isEmpty ? " " : text, size: CGFloat(style.fontSize), bold: style.bold, color: style.color)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                                                                CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        return CGSize(width: ceil(size.width) + 2, height: ceil(size.height) + 2)
    }

    static func isEmoji(_ text: String) -> Bool {
        text.count == 1 && (text.unicodeScalars.first?.properties.isEmojiPresentation == true
            || text.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0x238C })
    }
}
