import Foundation

/// Finds what's worth hiding before sharing a capture: email addresses, phone numbers,
/// payment card numbers, ID numbers, IP addresses, street addresses and secrets such as API
/// keys. Used by Smart Redact on each line of text read from the picture.
public enum SensitiveText {
    public enum Kind: String, CaseIterable, Sendable {
        case email, phone, card, idNumber, ipAddress, address, secret

        public var title: String {
            switch self {
            case .email: "Email addresses"
            case .phone: "Phone numbers"
            case .card: "Card numbers"
            case .idNumber: "ID numbers"
            case .ipAddress: "IP addresses"
            case .address: "Street addresses"
            case .secret: "Keys and tokens"
            }
        }
    }

    public struct Match: Equatable, Sendable {
        public var kind: Kind
        public var range: Range<String.Index>
    }

    private static let patterns: [(Kind, NSRegularExpression)] = [
        (.email, try! NSRegularExpression(pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: .caseInsensitive)),
        (.card, try! NSRegularExpression(pattern: #"\b(?:\d[ \-]?){12,18}\d\b"#)),
        (.idNumber, try! NSRegularExpression(pattern: #"\b\d{3}-\d{2}-\d{4}\b"#)),
        (.ipAddress, try! NSRegularExpression(pattern: #"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b"#)),
        // Long runs of letters and digits that look random: API keys, tokens, passwords.
        (.secret, try! NSRegularExpression(pattern: #"\b(?:sk|pk|ghp|gho|xox[abp]|AKIA|AIza)[A-Za-z0-9_\-]{12,}\b|\b(?=[A-Za-z0-9_\-]*\d)(?=[A-Za-z0-9_\-]*[A-Za-z])[A-Za-z0-9_\-]{28,}\b"#)),
    ]

    /// Every sensitive stretch of `text`, without overlaps, in order.
    public static func find(in text: String, kinds: Set<Kind> = Set(Kind.allCases)) -> [Match] {
        var found: [Match] = []
        let whole = NSRange(text.startIndex..., in: text)
        for (kind, regex) in patterns where kinds.contains(kind) {
            for result in regex.matches(in: text, range: whole) {
                guard let range = Range(result.range, in: text) else { continue }
                if kind == .card && !luhn(String(text[range])) { continue }
                found.append(Match(kind: kind, range: range))
            }
        }
        var types: NSTextCheckingResult.CheckingType = []
        if kinds.contains(.phone) { types.insert(.phoneNumber) }
        if kinds.contains(.address) { types.insert(.address) }
        if !types.isEmpty, let detector = try? NSDataDetector(types: types.rawValue) {
            for result in detector.matches(in: text, range: whole) {
                guard let range = Range(result.range, in: text) else { continue }
                let kind: Kind = result.resultType == .address ? .address : .phone
                // A long digit run that passed as a card number isn't also a phone number.
                found.append(Match(kind: kind, range: range))
            }
        }
        // Earliest first; a match inside one already taken is dropped.
        found.sort { $0.range.lowerBound < $1.range.lowerBound || ($0.range.lowerBound == $1.range.lowerBound && $0.range.upperBound > $1.range.upperBound) }
        var kept: [Match] = []
        for match in found {
            if let last = kept.last, match.range.lowerBound < last.range.upperBound { continue }
            kept.append(match)
        }
        return kept
    }

    /// The payment-card checksum, so ordinary long numbers aren't hidden as cards.
    static func luhn(_ text: String) -> Bool {
        let digits = text.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (i, digit) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }
}
