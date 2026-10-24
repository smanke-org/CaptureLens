import CoreGraphics
import CoreText
import Foundation

/// One capture in a guide.
public struct GuideEntry: Sendable {
    public var image: CGImage
    /// The picture's size in points (it's drawn no larger than this).
    public var pointSize: CGSize
    public var title: String
    public var text: String
    public var date: Date

    public init(image: CGImage, pointSize: CGSize, title: String, text: String = "", date: Date = Date()) {
        self.image = image
        self.pointSize = pointSize
        self.title = title
        self.text = text
        self.date = date
    }
}

public enum GuideTemplate: String, CaseIterable, Sendable {
    /// Numbered steps, each with its picture and notes.
    case steps
    /// Pictures two to a row with captions, for a quick reference sheet.
    case reference
    /// Down a line by time, each with when it was captured.
    case timeline

    public var title: String {
        switch self {
        case .steps: "Step-by-Step"
        case .reference: "Reference Sheet"
        case .timeline: "Timeline"
        }
    }
}

/// Lays captures out as a guide: as one tall picture, or as PDF pages where no step is split
/// across a page break.
public enum GuideRenderer {
    public struct Document: Sendable {
        public var template: GuideTemplate
        public var title: String
        public var subtitle: String
        public var entries: [GuideEntry]

        public init(template: GuideTemplate, title: String, subtitle: String = "", entries: [GuideEntry]) {
            self.template = template
            self.title = title
            self.subtitle = subtitle
            self.entries = entries
        }
    }

    static let ink = RGBA(0.11, 0.11, 0.12)
    static let gray = RGBA(0.45, 0.45, 0.48)
    static let accent = RGBA.blue

    /// A piece of the guide that stays in one piece, laid out for a content width.
    struct Block {
        var height: CGFloat
        /// Draws at the top-left origin of the block (top-left space).
        var draw: (CGContext) -> Void
    }

    // MARK: Output

    /// The whole guide as one picture, `width` points wide, at `scale` pixels per point.
    public static func image(_ document: Document, width: CGFloat = 900, scale: CGFloat = 2) -> CGImage? {
        let margin: CGFloat = 40
        let blocks = layout(document, contentWidth: width - margin * 2, maxImageHeight: 700)
        let spacing: CGFloat = 28
        let height = margin * 2 + blocks.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, blocks.count - 1))
        guard let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(ceil(height * scale)), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.translateBy(x: 0, y: CGFloat(ctx.height))
        ctx.scaleBy(x: scale, y: -scale)
        var y = margin
        for block in blocks {
            ctx.saveGState()
            ctx.translateBy(x: margin, y: y)
            block.draw(ctx)
            ctx.restoreGState()
            y += block.height + spacing
        }
        return ctx.makeImage()
    }

    /// The guide as a PDF, `page` points per page (US Letter by default).
    public static func pdf(_ document: Document, page: CGSize = CGSize(width: 612, height: 792)) -> Data? {
        let margin: CGFloat = 40, spacing: CGFloat = 22
        let usable = page.height - margin * 2
        let blocks = layout(document, contentWidth: page.width - margin * 2, maxImageHeight: usable - 80)
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: page)
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle as String: document.title] as CFDictionary)
        else { return nil }
        var y = margin
        var open = false
        func newPage() {
            if open { ctx.endPDFPage() }
            ctx.beginPDFPage(nil)
            ctx.translateBy(x: 0, y: page.height)
            ctx.scaleBy(x: 1, y: -1)
            open = true
            y = margin
        }
        newPage()
        for block in blocks {
            // Never split a step: start a new page when it won't fit (unless the page is empty).
            if y + block.height > page.height - margin && y > margin + 1 { newPage() }
            ctx.saveGState()
            ctx.translateBy(x: margin, y: y)
            block.draw(ctx)
            ctx.restoreGState()
            y += block.height + spacing
        }
        if open { ctx.endPDFPage() }
        ctx.closePDF()
        return data as Data
    }

    /// How many pages the PDF has (for previews and tests).
    public static func pageCount(_ pdf: Data) -> Int {
        guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider) else { return 0 }
        return document.numberOfPages
    }

    // MARK: Layout

    static func layout(_ document: Document, contentWidth width: CGFloat, maxImageHeight: CGFloat) -> [Block] {
        var blocks = [titleBlock(document, width: width)]
        switch document.template {
        case .steps:
            for (index, entry) in document.entries.enumerated() {
                blocks.append(stepBlock(entry, number: index + 1, width: width, maxImageHeight: maxImageHeight))
            }
        case .reference:
            let gap: CGFloat = 20
            let cell = (width - gap) / 2
            var index = 0
            while index < document.entries.count {
                let row = Array(document.entries[index..<min(index + 2, document.entries.count)])
                let cells = row.map { cellBlock($0, width: cell, maxImageHeight: min(maxImageHeight, 320)) }
                let height = cells.map(\.height).max() ?? 0
                blocks.append(Block(height: height) { ctx in
                    for (i, cell) in cells.enumerated() {
                        ctx.saveGState()
                        ctx.translateBy(x: CGFloat(i) * ((width + gap) / 2), y: 0)
                        cell.draw(ctx)
                        ctx.restoreGState()
                    }
                })
                index += 2
            }
        case .timeline:
            for entry in document.entries {
                blocks.append(timelineBlock(entry, width: width, maxImageHeight: maxImageHeight))
            }
        }
        return blocks
    }

    static func titleBlock(_ document: Document, width: CGFloat) -> Block {
        let title = textBox(document.title, size: 28, bold: true, color: ink, width: width)
        let subtitle = document.subtitle.isEmpty ? CGSize.zero : textBox(document.subtitle, size: 13, bold: false, color: gray, width: width)
        let height = title.height + (document.subtitle.isEmpty ? 0 : 6 + subtitle.height) + 8
        return Block(height: height) { ctx in
            draw(document.title, size: 28, bold: true, color: ink, in: CGRect(x: 0, y: 0, width: width, height: title.height), ctx: ctx)
            if !document.subtitle.isEmpty {
                draw(document.subtitle, size: 13, bold: false, color: gray,
                     in: CGRect(x: 0, y: title.height + 6, width: width, height: subtitle.height), ctx: ctx)
            }
            ctx.setFillColor(CGColor(gray: 0.85, alpha: 1))
            ctx.fill(CGRect(x: 0, y: height - 1, width: width, height: 1))
        }
    }

    static func stepBlock(_ entry: GuideEntry, number: Int, width: CGFloat, maxImageHeight: CGFloat) -> Block {
        let badge: CGFloat = 30
        let textX = badge + 12
        let titleSize = textBox(entry.title, size: 17, bold: true, color: ink, width: width - textX)
        let notes = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesSize = notes.isEmpty ? .zero : textBox(notes, size: 13, bold: false, color: ink, width: width - textX)
        let header = max(badge, titleSize.height + (notes.isEmpty ? 0 : 4 + notesSize.height))
        let picture = fit(entry.pointSize, width: width - textX, height: maxImageHeight)
        return Block(height: header + 12 + picture.height) { ctx in
            ctx.setFillColor(accent.cgColor)
            ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: badge, height: badge))
            AnnotationRenderer.drawCentered("\(number)", in: CGRect(x: 0, y: 0, width: badge, height: badge), size: 15, bold: true,
                                            color: .white, ctx: ctx)
            draw(entry.title, size: 17, bold: true, color: ink, in: CGRect(x: textX, y: 4, width: width - textX, height: titleSize.height), ctx: ctx)
            if !notes.isEmpty {
                draw(notes, size: 13, bold: false, color: ink,
                     in: CGRect(x: textX, y: 4 + titleSize.height + 4, width: width - textX, height: notesSize.height), ctx: ctx)
            }
            drawPicture(entry.image, in: CGRect(x: textX, y: header + 12, width: picture.width, height: picture.height), ctx: ctx)
        }
    }

    static func cellBlock(_ entry: GuideEntry, width: CGFloat, maxImageHeight: CGFloat) -> Block {
        let picture = fit(entry.pointSize, width: width, height: maxImageHeight)
        let titleSize = textBox(entry.title, size: 13, bold: true, color: ink, width: width)
        let notes = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesSize = notes.isEmpty ? .zero : textBox(notes, size: 11, bold: false, color: gray, width: width)
        return Block(height: picture.height + 8 + titleSize.height + (notes.isEmpty ? 0 : 2 + notesSize.height)) { ctx in
            drawPicture(entry.image, in: CGRect(x: 0, y: 0, width: picture.width, height: picture.height), ctx: ctx)
            draw(entry.title, size: 13, bold: true, color: ink, in: CGRect(x: 0, y: picture.height + 8, width: width, height: titleSize.height), ctx: ctx)
            if !notes.isEmpty {
                draw(notes, size: 11, bold: false, color: gray,
                     in: CGRect(x: 0, y: picture.height + 8 + titleSize.height + 2, width: width, height: notesSize.height), ctx: ctx)
            }
        }
    }

    static func timelineBlock(_ entry: GuideEntry, width: CGFloat, maxImageHeight: CGFloat) -> Block {
        let indent: CGFloat = 34
        let when = entry.date.formatted(date: .abbreviated, time: .shortened)
        let whenSize = textBox(when, size: 12, bold: false, color: gray, width: width - indent)
        let titleSize = textBox(entry.title, size: 16, bold: true, color: ink, width: width - indent)
        let notes = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesSize = notes.isEmpty ? .zero : textBox(notes, size: 13, bold: false, color: ink, width: width - indent)
        let textHeight = whenSize.height + 2 + titleSize.height + (notes.isEmpty ? 0 : 4 + notesSize.height)
        let picture = fit(entry.pointSize, width: width - indent, height: maxImageHeight)
        let height = textHeight + 10 + picture.height
        return Block(height: height) { ctx in
            // The line runs past the block, into the spacing, so the timeline reads as one.
            ctx.setFillColor(CGColor(gray: 0.82, alpha: 1))
            ctx.fill(CGRect(x: 10, y: 0, width: 2, height: height + 28))
            ctx.setFillColor(accent.cgColor)
            ctx.fillEllipse(in: CGRect(x: 4, y: 3, width: 14, height: 14))
            draw(when, size: 12, bold: false, color: gray, in: CGRect(x: indent, y: 0, width: width - indent, height: whenSize.height), ctx: ctx)
            draw(entry.title, size: 16, bold: true, color: ink,
                 in: CGRect(x: indent, y: whenSize.height + 2, width: width - indent, height: titleSize.height), ctx: ctx)
            if !notes.isEmpty {
                draw(notes, size: 13, bold: false, color: ink,
                     in: CGRect(x: indent, y: whenSize.height + 2 + titleSize.height + 4, width: width - indent, height: notesSize.height), ctx: ctx)
            }
            drawPicture(entry.image, in: CGRect(x: indent, y: textHeight + 10, width: picture.width, height: picture.height), ctx: ctx)
        }
    }

    // MARK: Pieces

    /// `size` shrunk (never enlarged) to fit `width` × `height`.
    static func fit(_ size: CGSize, width: CGFloat, height: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: width, height: min(height, width * 0.6)) }
        let factor = min(1, width / size.width, height / size.height)
        return CGSize(width: size.width * factor, height: size.height * factor)
    }

    static func drawPicture(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 6, color: CGColor(gray: 0, alpha: 0.25))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.restoreGState()
        ctx.interpolationQuality = .high
        AnnotationRenderer.drawImage(image, in: rect, ctx: ctx)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.12))
        ctx.setLineWidth(1)
        ctx.stroke(rect)
    }

    static func textBox(_ text: String, size: CGFloat, bold: Bool, color: RGBA, width: CGFloat) -> CGSize {
        AnnotationRenderer.textSize(text, style: AnnotationStyle(color: color, fontSize: size, bold: bold), width: width)
    }

    static func draw(_ text: String, size: CGFloat, bold: Bool, color: RGBA, in rect: CGRect, ctx: CGContext) {
        AnnotationRenderer.drawText(text, in: rect, color: color, style: AnnotationStyle(color: color, fontSize: size, bold: bold, shadow: false), ctx: ctx)
    }
}
