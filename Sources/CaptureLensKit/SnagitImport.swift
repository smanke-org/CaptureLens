import CoreGraphics
import CryptoKit
import Foundation

/// Reading a Snagit capture (`.snagx`): a zip holding the picture, Snagit's own drawing of it
/// with its markup (thumbnail.png, full size), the markup itself, and where and when it was
/// captured. Markup with a CaptureLens counterpart becomes editable marks; anything else
/// means the capture comes in as Snagit drew it.
public enum SnagitImport {
    public struct Capture {
        /// No picture inside: a placeholder Snagit left (its "Online-only" entries).
        public var isEmpty: Bool
        public var created: Date?
        public var source: CaptureItem.Source
        public var tags: [String]
        public var favorite: Bool
        public var recognizedText: String
        /// Points per pixel of the picture: 2 for a Retina capture.
        public var scale: Double
        /// The original picture (PNG), and Snagit's drawing of it with its markup.
        public var picture: Data?
        public var drawn: Data?
        /// Size of Snagit's canvas, in points.
        public var canvas: CGSize
        /// The picture sits at the canvas's top left at its own size (it doesn't when the
        /// canvas was enlarged around it).
        public var pictureFillsCanvas: Bool
        public var annotations: [Annotation]
        /// Markup with no CaptureLens counterpart ("Image", "Shape (rotated)"…).
        public var unsupported: [String]

        /// Whether the markup came across whole, so the picture can come in with editable marks.
        public var convertible: Bool { pictureFillsCanvas && unsupported.isEmpty && picture != nil }

        /// Identifies the picture, so the same capture in two folders comes in once.
        public var fingerprint: String? {
            guard let data = picture ?? drawn else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Text from RTF (the app reads it with AppKit): the words, their size, color and weight.
    public typealias RichText = (text: String, fontSize: Double?, color: RGBA?, bold: Bool)

    public static func read(_ archive: Data, rtf: (Data) -> RichText?) throws -> Capture {
        let zip = try ZipReader(archive)
        func json(_ name: String) throws -> [String: Any] {
            guard let data = try zip.data(name), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return object
        }
        let index = try json("index.json")
        let meta = try json("metadata.json")
        let pageName = (index["Pages"] as? [String])?.first ?? ""
        let page = try json(pageName)

        var source = CaptureItem.Source()
        source.appName = (meta["AppName"] as? String).nonEmpty
        source.windowTitle = (meta["WindowName"] as? String).nonEmpty
        source.url = (meta["WebURL"] as? String).nonEmpty
        var tags = (meta["Tags"] as? [String]) ?? []
        let favorite = tags.contains("Snagit Favorites")
        tags.removeAll { $0 == "Snagit Favorites" || $0 == "Online-only" }

        let dpi = (page["DPI"] as? Double) ?? 72
        let scale = max(1, dpi / 72)
        let canvas = CGSize(width: number(page["CaptureCanvasWidth"]), height: number(page["CaptureCanvasHeight"]))
        let pictureName = page["CaptureBackgroundImage"] as? String
        let picture = try pictureName.flatMap { try zip.data($0) }
        let drawn = try zip.data("thumbnail.png")
        let location = point(page["CaptureBackgroundLocation"])
        let backgroundSize = size(page["BackgroundSize"])
        let fills = location == .zero && abs(backgroundSize.width - canvas.width) < 1.5 && abs(backgroundSize.height - canvas.height) < 1.5

        var annotations: [Annotation] = []
        var unsupported: [String] = []
        for object in (page["CaptureObjects"] as? [[String: Any]]) ?? [] {
            if (object["IsHidden"] as? Bool) == true { continue }
            switch convert(object, rtf: rtf) {
            case .mark(let mark): annotations.append(mark)
            case .skip: break
            case .unsupported(let what): unsupported.append(what)
            }
        }

        return Capture(isEmpty: picture == nil && drawn == nil, created: date(meta["CaptureDate"] as? String), source: source,
                       tags: tags, favorite: favorite, recognizedText: (meta["OcrText"] as? String) ?? "", scale: scale,
                       picture: picture, drawn: drawn, canvas: canvas, pictureFillsCanvas: fills,
                       annotations: annotations, unsupported: unsupported)
    }

    enum Converted {
        case mark(Annotation)
        case skip
        case unsupported(String)
    }

    static func convert(_ o: [String: Any], rtf: (Data) -> RichText?) -> Converted {
        let mode = o["ToolMode"] as? String ?? "?"
        let shape = o["ToolShape"] as? String
        if number(o["RotationAngle"]) != 0 { return .unsupported("\(mode) (rotated)") }
        let start = point(o["StartPoint"]), end = point(o["EndPoint"])
        let rect = Annotation.rect(from: start, to: end, constrain: false)
        let opacity = (o["Opacity"] as? Double).map { $0 / 100 } ?? 1
        let stroke = color(o["ForegroundColor"])?.faded(opacity)
        let fill = color(o["BackgroundColor"])?.faded(opacity)
        let width = number(o["StrokeWidth"])
        let shadow = (o["DropShadowEnabled"] as? Bool) == true
        func style(_ color: RGBA, filled: Bool = false) -> AnnotationStyle {
            AnnotationStyle(color: color, lineWidth: max(width, 1), filled: filled, shadow: shadow)
        }

        switch mode {
        case "Shape":
            guard shape == "Rectangle" || shape == "RoundedRectangle" || shape == "Ellipse" else { return .unsupported("Shape \(shape ?? "")") }
            let hasStroke = (stroke?.a ?? 0) > 0.01 && width > 0, hasFill = (fill?.a ?? 0) > 0.01
            if hasStroke && !hasFill {
                return .mark(Annotation(kind: shape == "Ellipse" ? .ellipse : .rectangle, rect: rect, style: style(stroke!)))
            }
            if hasFill && !hasStroke && shape != "Ellipse" {
                // A solid box of one color: what a black-out box is, in any color.
                return .mark(Annotation(kind: .redact, rect: rect, style: AnnotationStyle(color: fill!, lineWidth: 0, shadow: shadow)))
            }
            return hasStroke || hasFill ? .unsupported("Shape with outline and fill") : .skip
        case "Arrow":
            guard (o["BezierCurve"] as? Bool) != true, let stroke else { return .unsupported("Curved arrow") }
            let heads = ["ArrowStart", "ArrowEnd"].map { isHead(o[$0] as? String) }
            switch (heads[0], heads[1]) {
            case (false, false): return .mark(Annotation(kind: .line, from: start, to: end, style: style(stroke)))
            case (false, true): return .mark(Annotation(kind: .arrow, from: start, to: end, style: style(stroke)))
            case (true, false): return .mark(Annotation(kind: .arrow, from: end, to: start, style: style(stroke)))
            case (true, true): return .unsupported("Double-headed arrow")
            }
        case "Text", "Callout":
            let rich = (o["RTFEncodedText"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap(rtf)
            let text = rich?.text ?? (o["PlainText"] as? String) ?? ""
            guard !text.isEmpty else { return .skip }
            let size = rich?.fontSize ?? number(o["FontSize"])
            if mode == "Callout" {
                guard let fill, let tail = (o["CalloutTails"] as? [String])?.first else { return .unsupported("Callout") }
                var style = AnnotationStyle(color: fill, lineWidth: 2, filled: true, fontSize: size > 0 ? size : 20,
                                            bold: rich?.bold ?? false, shadow: shadow)
                style.color = fill
                return .mark(Annotation(kind: .callout, rect: rect, tail: point(tail), text: text, style: style))
            }
            let textColor = rich?.color ?? color(o["TextSelectionColor"]) ?? .black
            return .mark(Annotation(kind: .text, rect: rect, text: text,
                                    style: AnnotationStyle(color: textColor, lineWidth: 2, filled: false, fontSize: size > 0 ? size : 20,
                                                           bold: rich?.bold ?? false, shadow: shadow)))
        case "Step":
            guard (o["StepSequenceType"] as? String ?? "Number") == "Number", let fill else { return .unsupported("Lettered step") }
            return .mark(Annotation(kind: .step, rect: rect, style: AnnotationStyle(color: fill, lineWidth: 2, fontSize: rect.height / 1.6, shadow: shadow)))
        case "Highlight":
            guard let stroke else { return .skip }
            let y = rect.midY
            var mark = Annotation(kind: .highlighter, points: [CGPoint(x: rect.minX, y: y), CGPoint(x: rect.maxX, y: y)],
                                  style: AnnotationStyle(color: stroke, lineWidth: max(4, rect.height / 3), shadow: false))
            mark.rect = rect
            return .mark(mark)
        case "Pen":
            guard let stroke else { return .skip }
            let points = ((o["PointsArray"] as? [String]) ?? []).map(point)
            return points.isEmpty ? .skip : .mark(Annotation(kind: .pen, points: points, style: style(stroke)))
        case "Magnify":
            guard shape == "Ellipse", point(o["MagnifyOffset"]) == .zero else { return .unsupported("Magnifier") }
            return .mark(Annotation(kind: .magnify, rect: rect, zoom: max(1, number(o["MagnifyScale"]) / 100),
                                    style: style(stroke ?? .white)))
        case "Blur":
            let pixelate = (o["BlurType"] as? String)?.localizedCaseInsensitiveContains("pixel") == true
            return .mark(Annotation(kind: pixelate ? .pixelate : .blur, rect: rect, style: AnnotationStyle(color: .black, lineWidth: 0, shadow: false)))
        case "Select":
            return .skip
        default:
            return .unsupported(mode)
        }
    }

    static func isHead(_ style: String?) -> Bool {
        guard let style else { return false }
        return !["Flat", "None", "Round", "Square", ""].contains(style)
    }

    // MARK: Values

    static func number(_ value: Any?) -> Double {
        switch value {
        case let v as Double: v
        case let v as Int: Double(v)
        case let v as String: Double(v) ?? 0
        default: 0
        }
    }

    static func point(_ value: Any?) -> CGPoint {
        let parts = (value as? String)?.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? []
        return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : .zero
    }

    static func size(_ value: Any?) -> CGSize {
        let p = point(value)
        return CGSize(width: p.x, height: p.y)
    }

    /// "#AARRGGBB".
    static func color(_ value: Any?) -> RGBA? {
        guard var hex = value as? String, hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard hex.count == 8, let v = UInt32(hex, radix: 16) else { return nil }
        func c(_ shift: UInt32) -> Double { Double((v >> shift) & 0xFF) / 255 }
        return RGBA(c(16), c(8), c(0), c(24))
    }

    /// "2022-12-14 21:12:34", in UTC.
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)
    }
}

/// How alike two pictures look, for checking converted markup against the original app's own
/// drawing of it.
public enum ImageCompare {
    /// The largest difference (0–255) between matching 8 × 8 blocks of the two pictures, each
    /// shrunk to `width` across in grays. Small for the same picture drawn slightly
    /// differently; large where something is missing or misplaced.
    public static func difference(_ a: CGImage, _ b: CGImage, width: Int = 160) -> Double {
        let w = width, h = max(8, Int((Double(width) * Double(a.height) / Double(max(a.width, 1))).rounded()))
        guard let pa = gray(a, w, h), let pb = gray(b, w, h) else { return 255 }
        var worst = 0.0
        for by in stride(from: 0, to: h, by: 8) {
            for bx in stride(from: 0, to: w, by: 8) {
                var total = 0.0, count = 0.0
                for y in by..<min(by + 8, h) {
                    for x in bx..<min(bx + 8, w) {
                        total += abs(Double(pa[y * w + x]) - Double(pb[y * w + x]))
                        count += 1
                    }
                }
                worst = max(worst, total / max(count, 1))
            }
        }
        return worst
    }

    static func gray(_ image: CGImage, _ w: Int, _ h: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            // Transparent parts count as white in both.
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? pixels : nil
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return self
    }
}

private extension RGBA {
    func faded(_ opacity: Double) -> RGBA { withAlpha(a * min(max(opacity, 0), 1)) }
}
