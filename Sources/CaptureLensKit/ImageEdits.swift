import CoreGraphics
import Foundation

/// How a capture is adjusted on its way out: cropped, strips cut out, turned, resized,
/// given edges and a border, its background removed. Stored as instructions beside the
/// untouched picture, so each can be changed or undone any time. Geometry is in the
/// original picture's points, origin at the top left, like annotations.
public struct ImageEdits: Codable, Equatable, Sendable {
    /// The part to keep; nil keeps it all.
    public var crop: CGRect?
    /// Strips taken out of the middle, the rest joined up.
    public var cuts: [CutOut]
    /// Quarter turns clockwise, 0–3.
    public var rotation: Int
    /// The size it comes out at, as a share of its cropped size (1 = full size).
    public var outputScale: Double
    public var border: Border?
    public var edges: EdgeEffect?
    /// Keep only the subject (people, objects, a window), with a transparent background.
    public var removeBackground: Bool

    public init(crop: CGRect? = nil, cuts: [CutOut] = [], rotation: Int = 0, outputScale: Double = 1,
                border: Border? = nil, edges: EdgeEffect? = nil, removeBackground: Bool = false) {
        self.crop = crop
        self.cuts = cuts
        self.rotation = rotation
        self.outputScale = outputScale
        self.border = border
        self.edges = edges
        self.removeBackground = removeBackground
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        crop = try c.decodeIfPresent(CGRect.self, forKey: .crop)
        cuts = try c.decodeIfPresent([CutOut].self, forKey: .cuts) ?? []
        rotation = try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        outputScale = try c.decodeIfPresent(Double.self, forKey: .outputScale) ?? 1
        border = try c.decodeIfPresent(Border.self, forKey: .border)
        edges = try c.decodeIfPresent(EdgeEffect.self, forKey: .edges)
        removeBackground = try c.decodeIfPresent(Bool.self, forKey: .removeBackground) ?? false
    }

    public static let none = ImageEdits()
    public var isEmpty: Bool { self == .none }

    /// Turned a quarter turn left or right.
    public func rotated(clockwise: Bool) -> ImageEdits {
        var copy = self
        copy.rotation = ((rotation + (clockwise ? 1 : -1)) % 4 + 4) % 4
        return copy
    }

    /// The size, in points, of a picture `size` points large once cropped, cut, turned and
    /// resized (before edges and border).
    public func outputSize(for size: CGSize) -> CGSize {
        var rect = (crop ?? CGRect(origin: .zero, size: size)).intersection(CGRect(origin: .zero, size: size))
        if rect.isNull { rect = CGRect(origin: .zero, size: size) }
        var width = rect.width, height = rect.height
        for cut in cuts {
            let span = cut.span(within: rect)
            guard span > 0 else { continue }
            // A torn or wavy seam leaves a small gap between the two sides.
            let gap: CGFloat = cut.seam == .straight ? 0 : CutOut.seamGap
            if cut.axis == .horizontal { height -= span - gap } else { width -= span - gap }
        }
        if rotation % 2 == 1 { swap(&width, &height) }
        return CGSize(width: max(1, width * outputScale), height: max(1, height * outputScale))
    }
}

/// A strip taken out of a picture, and how the two sides are joined.
public struct CutOut: Codable, Equatable, Identifiable, Sendable {
    public enum Axis: String, Codable, Sendable {
        /// A band across the picture: rows from `from` to `to` go.
        case horizontal
        /// A band down the picture: columns from `from` to `to` go.
        case vertical
    }

    public enum Seam: String, Codable, CaseIterable, Sendable {
        case straight, torn, wave

        public var title: String {
            switch self {
            case .straight: "Straight"
            case .torn: "Torn"
            case .wave: "Wave"
            }
        }
    }

    /// The gap a torn or wavy seam leaves, in points.
    public static let seamGap: CGFloat = 8

    public var id: UUID
    public var axis: Axis
    public var from: Double
    public var to: Double
    public var seam: Seam

    public init(id: UUID = UUID(), axis: Axis, from: Double, to: Double, seam: Seam = .torn) {
        self.id = id
        self.axis = axis
        self.from = min(from, to)
        self.to = max(from, to)
        self.seam = seam
    }

    /// How much of `rect` (the cropped area) it removes, in points.
    public func span(within rect: CGRect) -> CGFloat {
        let (low, high) = axis == .horizontal ? (rect.minY, rect.maxY) : (rect.minX, rect.maxX)
        return max(0, min(to, high) - max(from, low))
    }
}

public struct Border: Codable, Equatable, Hashable, Sendable {
    public var width: Double
    public var color: RGBA
    public var cornerRadius: Double
    /// A drop shadow around the whole picture (on a transparent margin).
    public var shadow: Bool

    public init(width: Double = 4, color: RGBA = .black, cornerRadius: Double = 0, shadow: Bool = false) {
        self.width = width
        self.color = color
        self.cornerRadius = cornerRadius
        self.shadow = shadow
    }
}

public struct EdgeEffect: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case torn, wave, fade

        public var title: String {
            switch self {
            case .torn: "Torn Paper"
            case .wave: "Wavy"
            case .fade: "Fade Out"
            }
        }
    }

    public enum Side: String, Codable, CaseIterable, Sendable {
        case top, bottom, left, right
    }

    public var kind: Kind
    public var sides: Set<Side>

    public init(kind: Kind, sides: Set<Side> = [.bottom]) {
        self.kind = kind
        self.sides = sides
    }
}
