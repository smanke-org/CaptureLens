import CoreGraphics
import Foundation

/// A mark drawn over a capture: a box, an arrow, some text… Kept apart from the picture's
/// pixels, so it can be moved, resized, restyled or deleted any time. All geometry is in the
/// capture's points, origin at the top left.
public struct Annotation: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case rectangle, ellipse, line, arrow, text, callout, step, pen, highlighter, spotlight, magnify, stamp

        public var title: String {
            switch self {
            case .rectangle: "Box"
            case .ellipse: "Ellipse"
            case .line: "Line"
            case .arrow: "Arrow"
            case .text: "Text"
            case .callout: "Callout"
            case .step: "Step"
            case .pen: "Pen"
            case .highlighter: "Highlighter"
            case .spotlight: "Spotlight"
            case .magnify: "Magnify"
            case .stamp: "Stamp"
            }
        }

        public var symbol: String {
            switch self {
            case .rectangle: "rectangle"
            case .ellipse: "circle"
            case .line: "line.diagonal"
            case .arrow: "arrow.up.right"
            case .text: "textformat"
            case .callout: "text.bubble"
            case .step: "1.circle"
            case .pen: "pencil.tip"
            case .highlighter: "highlighter"
            case .spotlight: "light.max"
            case .magnify: "plus.magnifyingglass"
            case .stamp: "seal"
            }
        }

        /// Drawn from one point to another rather than as a box.
        public var isLinear: Bool { self == .line || self == .arrow }
        /// Drawn freehand.
        public var isFreehand: Bool { self == .pen || self == .highlighter }
        /// Placed with a click at a default size (dragging sizes them too).
        public var placesWithClick: Bool { self == .text || self == .callout || self == .step || self == .stamp }
        /// Holds text the user types.
        public var hasText: Bool { self == .text || self == .callout }
    }

    public var id: UUID
    public var kind: Kind
    /// The box it occupies (shapes, text, callout bubble, step, stamp, spotlight, magnify).
    public var rect: CGRect
    /// Start and end (lines, arrows).
    public var from: CGPoint
    public var to: CGPoint
    /// Where a callout's tail points.
    public var tail: CGPoint
    /// The stroke (pen, highlighter).
    public var points: [CGPoint]
    public var text: String
    /// An emoji, or a word such as "Approved", for stamps.
    public var stamp: String
    /// How much a magnifier enlarges.
    public var zoom: Double
    public var style: AnnotationStyle

    public init(id: UUID = UUID(), kind: Kind, rect: CGRect = .zero, from: CGPoint = .zero, to: CGPoint = .zero,
                tail: CGPoint = .zero, points: [CGPoint] = [], text: String = "", stamp: String = "", zoom: Double = 2,
                style: AnnotationStyle) {
        self.id = id
        self.kind = kind
        self.rect = rect
        self.from = from
        self.to = to
        self.tail = tail
        self.points = points
        self.text = text
        self.stamp = stamp
        self.zoom = zoom
        self.style = style
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        rect = try c.decodeIfPresent(CGRect.self, forKey: .rect) ?? .zero
        from = try c.decodeIfPresent(CGPoint.self, forKey: .from) ?? .zero
        to = try c.decodeIfPresent(CGPoint.self, forKey: .to) ?? .zero
        tail = try c.decodeIfPresent(CGPoint.self, forKey: .tail) ?? .zero
        points = try c.decodeIfPresent([CGPoint].self, forKey: .points) ?? []
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        stamp = try c.decodeIfPresent(String.self, forKey: .stamp) ?? ""
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom) ?? 2
        style = try c.decodeIfPresent(AnnotationStyle.self, forKey: .style) ?? .standard
    }

    /// The area it covers, for selection outlines and hit tests.
    public var bounds: CGRect {
        switch kind {
        case .line, .arrow:
            return CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y))
        case .pen, .highlighter:
            guard let first = points.first else { return .zero }
            return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        case .callout:
            return rect.union(CGRect(origin: tail, size: .zero))
        default:
            return rect
        }
    }

    /// Moves it by `dx`, `dy`.
    public mutating func offset(dx: CGFloat, dy: CGFloat) {
        rect = rect.offsetBy(dx: dx, dy: dy)
        from = CGPoint(x: from.x + dx, y: from.y + dy)
        to = CGPoint(x: to.x + dx, y: to.y + dy)
        tail = CGPoint(x: tail.x + dx, y: tail.y + dy)
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    /// Whether `point` touches it, within `tolerance` points.
    public func hit(_ point: CGPoint, tolerance: CGFloat = 6) -> Bool {
        let slack = tolerance + style.lineWidth / 2
        switch kind {
        case .line, .arrow:
            return Self.distance(point, segment: (from, to)) <= slack
        case .pen, .highlighter:
            let width = kind == .highlighter ? style.lineWidth * 3 : style.lineWidth
            return zip(points, points.dropFirst()).contains { Self.distance(point, segment: ($0, $1)) <= tolerance + width / 2 }
                || (points.count == 1 && hypot(points[0].x - point.x, points[0].y - point.y) <= slack)
        case .rectangle where !style.filled:
            let outer = rect.insetBy(dx: -slack, dy: -slack), inner = rect.insetBy(dx: slack, dy: slack)
            return outer.contains(point) && (inner.isNull || !inner.contains(point))
        case .ellipse where !style.filled:
            // Near the outline: compare the point's normalized radius with 1.
            guard rect.width > 0, rect.height > 0 else { return false }
            let nx = (point.x - rect.midX) / (rect.width / 2), ny = (point.y - rect.midY) / (rect.height / 2)
            let r = sqrt(nx * nx + ny * ny)
            let band = slack / max(min(rect.width, rect.height) / 2, 1)
            return abs(r - 1) <= band
        case .callout:
            return rect.insetBy(dx: -slack, dy: -slack).contains(point)
                || Self.distance(point, segment: (CGPoint(x: rect.midX, y: rect.midY), tail)) <= slack
        case .spotlight, .magnify:
            // The middle shows the picture; only the edge picks it up.
            let outer = rect.insetBy(dx: -slack, dy: -slack), inner = rect.insetBy(dx: slack * 2, dy: slack * 2)
            return outer.contains(point) && (inner.isNull || !inner.contains(point))
        default:
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    static func distance(_ p: CGPoint, segment: (CGPoint, CGPoint)) -> CGFloat {
        let (a, b) = segment
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// The number each step marker shows: steps count up in the order they were added.
    public static func stepNumbers(_ annotations: [Annotation]) -> [UUID: Int] {
        var numbers: [UUID: Int] = [:]
        var next = 1
        for a in annotations where a.kind == .step {
            numbers[a.id] = next
            next += 1
        }
        return numbers
    }

    /// A box from two corners, made square (or circular) when `constrain` is held.
    public static func rect(from a: CGPoint, to b: CGPoint, constrain: Bool) -> CGRect {
        var w = b.x - a.x, h = b.y - a.y
        if constrain {
            let side = max(abs(w), abs(h))
            w = w < 0 ? -side : side
            h = h < 0 ? -side : side
        }
        return CGRect(x: min(a.x, a.x + w), y: min(a.y, a.y + h), width: abs(w), height: abs(h))
    }

    /// The end of a line from `a` toward `b`, snapped to 45° steps when `constrain` is held.
    public static func lineEnd(from a: CGPoint, to b: CGPoint, constrain: Bool) -> CGPoint {
        guard constrain else { return b }
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: a.x + cos(angle) * length, y: a.y + sin(angle) * length)
    }
}

/// How an annotation looks.
public struct AnnotationStyle: Codable, Equatable, Hashable, Sendable {
    public var color: RGBA
    /// Stroke width in points (and the base for arrow heads and step sizes).
    public var lineWidth: Double
    /// Shapes are filled with a tint of the color.
    public var filled: Bool
    public var fontSize: Double
    public var bold: Bool
    /// A soft drop shadow, so marks stand out on busy pictures.
    public var shadow: Bool

    public init(color: RGBA, lineWidth: Double = 4, filled: Bool = false, fontSize: Double = 20, bold: Bool = true,
                shadow: Bool = true) {
        self.color = color
        self.lineWidth = lineWidth
        self.filled = filled
        self.fontSize = fontSize
        self.bold = bold
        self.shadow = shadow
    }

    public static let standard = AnnotationStyle(color: .red)

    /// The colors offered in the toolbar.
    public static let palette: [RGBA] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]

    /// Ready-made styles; the user can save their own beside them.
    public static let quickDefaults: [AnnotationStyle] = [
        AnnotationStyle(color: .red, lineWidth: 4),
        AnnotationStyle(color: .blue, lineWidth: 3),
        AnnotationStyle(color: .yellow, lineWidth: 6, shadow: false),
        AnnotationStyle(color: .black, lineWidth: 2, fontSize: 16, bold: false, shadow: false),
        AnnotationStyle(color: .white, lineWidth: 3, fontSize: 24),
    ]
}

/// A color as four 0–1 components, sRGB.
public struct RGBA: Codable, Equatable, Hashable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let red = RGBA(1.0, 0.23, 0.19)
    public static let orange = RGBA(1.0, 0.58, 0.0)
    public static let yellow = RGBA(1.0, 0.80, 0.0)
    public static let green = RGBA(0.20, 0.78, 0.35)
    public static let blue = RGBA(0.0, 0.48, 1.0)
    public static let purple = RGBA(0.69, 0.32, 0.87)
    public static let black = RGBA(0.1, 0.1, 0.1)
    public static let white = RGBA(1, 1, 1)

    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    public func withAlpha(_ alpha: Double) -> RGBA { RGBA(r, g, b, alpha) }

    /// Black or white, whichever reads better on this color.
    public var contrasting: RGBA {
        (0.299 * r + 0.587 * g + 0.114 * b) > 0.6 ? RGBA(0.1, 0.1, 0.1) : .white
    }
}
