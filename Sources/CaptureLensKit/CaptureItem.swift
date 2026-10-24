import CoreGraphics
import Foundation

/// One capture in the library: its name, tags, notes and where it came from. The picture
/// itself is stored beside it (see `LibraryDatabase`), and layers drawn over the picture
/// stay separate from its pixels.
public struct CaptureItem: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case region, window, screen, imported
        /// A screen recording; its picture is the poster frame.
        case video

        public var title: String {
            switch self {
            case .region: "Area"
            case .window: "Window"
            case .screen: "Full Screen"
            case .imported: "Imported"
            case .video: "Video"
            }
        }

        public var symbol: String {
            switch self {
            case .region: "rectangle.dashed"
            case .window: "macwindow"
            case .screen: "display"
            case .imported: "square.and.arrow.down"
            case .video: "video"
            }
        }
    }

    public var id: UUID
    /// When the capture was taken.
    public var created: Date
    /// When anything about it last changed on any Mac, for syncing.
    public var modified: Date
    public var kind: Kind
    public var name: String
    /// Whether the name came from on-device naming (or the fallback), rather than the user.
    public var nameIsAutomatic: Bool
    public var tags: [String]
    /// The user's own notes ("More Info").
    public var notes: String
    /// Text read from the picture, for searching.
    public var recognizedText: String
    public var favorite: Bool
    public var source: Source
    /// Size of the picture in pixels, and how many pixels per point it was captured at.
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Double
    /// The mouse pointer, kept as its own layer so it can be shown, hidden, moved or resized.
    public var cursor: CursorLayer?
    /// Boxes, arrows, text and the rest, drawn over the picture but never into it.
    public var annotations: [Annotation]
    /// Crop, cut-outs, rotation, size, edges, border, background: applied on the way out.
    public var edits: ImageEdits
    /// For a recording: its length, sound, and trims and cuts.
    public var video: VideoInfo?
    /// The hashed device ID of the Mac that took it.
    public var origin: String?

    public struct Source: Codable, Equatable, Sendable {
        public var appName: String?
        public var bundleID: String?
        public var windowTitle: String?
        /// The web page shown in the front browser window, when there was one.
        public var url: String?
        public var pageTitle: String?
        public var displayName: String?

        public init(appName: String? = nil, bundleID: String? = nil, windowTitle: String? = nil, url: String? = nil,
                    pageTitle: String? = nil, displayName: String? = nil) {
            self.appName = appName
            self.bundleID = bundleID
            self.windowTitle = windowTitle
            self.url = url
            self.pageTitle = pageTitle
            self.displayName = displayName
        }

        /// The site's host without "www.", for filtering by website.
        public var website: String? {
            guard let url, let host = URL(string: url)?.host(), !host.isEmpty else { return nil }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
    }

    public init(id: UUID = UUID(), created: Date = Date(), modified: Date? = nil, kind: Kind, name: String,
                nameIsAutomatic: Bool = true, tags: [String] = [], notes: String = "", recognizedText: String = "",
                favorite: Bool = false, source: Source = Source(), pixelWidth: Int, pixelHeight: Int, scale: Double = 2,
                cursor: CursorLayer? = nil, annotations: [Annotation] = [], edits: ImageEdits = .none, video: VideoInfo? = nil,
                origin: String? = nil) {
        self.id = id
        self.created = created
        self.modified = modified ?? created
        self.kind = kind
        self.name = name
        self.nameIsAutomatic = nameIsAutomatic
        self.tags = tags
        self.notes = notes
        self.recognizedText = recognizedText
        self.favorite = favorite
        self.source = source
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.cursor = cursor
        self.annotations = annotations
        self.edits = edits
        self.video = video
        self.origin = origin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        created = try c.decode(Date.self, forKey: .created)
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? created
        // An unknown kind (from a newer version) reads as an area rather than failing the item.
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)).flatMap { $0.flatMap(Kind.init) } ?? .region
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        nameIsAutomatic = try c.decodeIfPresent(Bool.self, forKey: .nameIsAutomatic) ?? true
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        recognizedText = try c.decodeIfPresent(String.self, forKey: .recognizedText) ?? ""
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? Source()
        pixelWidth = try c.decodeIfPresent(Int.self, forKey: .pixelWidth) ?? 0
        pixelHeight = try c.decodeIfPresent(Int.self, forKey: .pixelHeight) ?? 0
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 2
        cursor = try c.decodeIfPresent(CursorLayer.self, forKey: .cursor)
        // A mark this version doesn't know (made by a newer one) is skipped, not the whole capture.
        annotations = (try c.decodeIfPresent([Lossy<Annotation>].self, forKey: .annotations) ?? []).compactMap(\.value)
        edits = try c.decodeIfPresent(ImageEdits.self, forKey: .edits) ?? .none
        video = try? c.decodeIfPresent(VideoInfo.self, forKey: .video)
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
    }

    /// The size in points, as it looked on screen.
    public var pointSize: CGSize {
        CGSize(width: Double(pixelWidth) / max(scale, 1), height: Double(pixelHeight) / max(scale, 1))
    }
}

/// The mouse pointer at the moment of capture, drawn over the picture rather than into it.
public struct CursorLayer: Codable, Equatable, Sendable {
    /// The pointer's picture (PNG), as macOS drew it.
    public var png: Data
    /// Its size in points at 100%.
    public var width: Double
    public var height: Double
    /// Where its top-left corner sits, in the capture's points (origin at the top left).
    public var x: Double
    public var y: Double
    public var visible: Bool
    /// 1 = as it was on screen.
    public var size: Double

    public init(png: Data, width: Double, height: Double, x: Double, y: Double, visible: Bool = true, size: Double = 1) {
        self.png = png
        self.width = width
        self.height = height
        self.x = x
        self.y = y
        self.visible = visible
        self.size = size
    }

    /// The pointer's frame in the capture's points, origin at the top left.
    public var frame: CGRect { CGRect(x: x, y: y, width: width * size, height: height * size) }
}

/// Decodes to nil instead of failing, so one bad element doesn't sink a whole array.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
