import CoreGraphics
import Foundation

/// One line of recognized text and where it sat in the image, in Vision's normalized
/// coordinates (0…1, origin at the bottom left).
public struct RecognizedLine: Equatable, Sendable {
    public var text: String
    public var box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }
}

/// Turns Vision's loose list of lines into text laid out the way it looked on screen.
///
/// Vision returns one observation per run of text, in no guaranteed order. Lines that
/// share a baseline become one row (a wide gap between them becomes a tab, so columns
/// survive a paste into a spreadsheet). Rows then either keep their line breaks, or are
/// reflowed into paragraphs: a row joins the one above unless there is a blank-line gap,
/// the row above ended early with closing punctuation, or the row starts a list item.
public enum TextAssembler {
    public static func assemble(_ lines: [RecognizedLine], keepLineBreaks: Bool) -> String {
        let rows = makeRows(lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
        guard !rows.isEmpty else { return "" }
        if keepLineBreaks { return rows.map(\.text).joined(separator: "\n") }

        let heights = rows.map(\.box.height).sorted()
        let typicalHeight = heights[heights.count / 2]
        let rightEdge = rows.map(\.box.maxX).max() ?? 1
        let leftEdge = rows.map(\.box.minX).min() ?? 0
        let width = max(rightEdge - leftEdge, 0.0001)

        var result = rows[0].text
        for (previous, row) in zip(rows, rows.dropFirst()) {
            let gap = previous.box.minY - row.box.maxY
            let endedEarly = (rightEdge - previous.box.maxX) / width > 0.2
            let previousText = previous.text.trimmingCharacters(in: .whitespaces)
            let breaksParagraph = gap > typicalHeight * 0.9
                || (endedEarly && previousText.last.map { ".!?:;\"”)".contains($0) } == true)
                || startsListItem(row.text)
                || previous.text.contains("\t") || row.text.contains("\t")
            if breaksParagraph {
                result += gap > typicalHeight * 0.9 ? "\n\n" : "\n"
                result += row.text
            } else {
                result = join(result, row.text)
            }
        }
        return result
    }

    /// Joins a reflowed line onto the text so far, mending a word hyphenated across the break.
    static func join(_ text: String, _ next: String) -> String {
        if text.hasSuffix("-"), let first = next.first, first.isLowercase,
           let beforeHyphen = text.dropLast().last, beforeHyphen.isLetter {
            return String(text.dropLast()) + next
        }
        return text + " " + next
    }

    static func startsListItem(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return false }
        if "•◦▪‣·–—*-".contains(first) { return true }
        // "1.", "12)", "a)" …
        let prefix = trimmed.prefix(4)
        if let end = prefix.firstIndex(where: { $0 == "." || $0 == ")" }), end != prefix.startIndex {
            let label = prefix[prefix.startIndex..<end]
            if label.allSatisfy(\.isNumber) || (label.count == 1 && label.first!.isLetter) {
                let after = trimmed.index(after: end)
                return after == trimmed.endIndex || trimmed[after] == " "
            }
        }
        return false
    }

    struct Row {
        var text: String
        var box: CGRect
    }

    /// Groups lines into rows top to bottom; within a row, left to right.
    static func makeRows(_ lines: [RecognizedLine]) -> [Row] {
        let sorted = lines.sorted { $0.box.midY > $1.box.midY }
        var groups: [[RecognizedLine]] = []
        for line in sorted {
            if let index = groups.lastIndex(where: { group in group.contains { sameRow($0.box, line.box) } }) {
                groups[index].append(line)
            } else {
                groups.append([line])
            }
        }
        return groups.map { group in
            let ordered = group.sorted { $0.box.minX < $1.box.minX }
            var text = ordered[0].text
            for (left, right) in zip(ordered, ordered.dropFirst()) {
                let gap = right.box.minX - left.box.maxX
                let height = min(left.box.height, right.box.height)
                text += gap > height * 2.5 ? "\t" : " "
                text += right.text
            }
            let box = ordered.dropFirst().reduce(ordered[0].box) { $0.union($1.box) }
            return Row(text: text, box: box)
        }
        .sorted { $0.box.midY > $1.box.midY }
    }

    /// Two boxes are on the same row when they overlap vertically by more than half the
    /// shorter one's height.
    static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap > min(a.height, b.height) * 0.5
    }
}
