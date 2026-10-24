import CaptureLensKit
import Foundation
import FoundationModels

/// Names captures from what's in them, with Apple Intelligence's on-device model, the way
/// Finder suggests names for files. Nothing leaves the Mac.
enum AutoNamer {
    /// Whether the on-device model can be used, and if not, why, for Settings.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "This Mac can't run Apple Intelligence, so captures are named after their app and window."
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings to name captures from what's in them. Until then they're named after their app and window."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still getting ready. Until it is, captures are named after their app and window."
        case .unavailable: return "Apple Intelligence isn't available, so captures are named after their app and window."
        }
    }

    static var isAvailable: Bool { unavailableReason == nil }

    private static let instructions = """
        You name screenshots, the way a person would name a file. Reply with only the name: \
        2 to 6 words in Title Case, describing what the screenshot shows (its subject, such as \
        "Quarterly Revenue Chart" or "Xcode Build Error"). Never say it's a screenshot, never \
        add a file extension, quotes or punctuation at the end.
        """

    /// A name for a capture, or nil if the model isn't available or declined.
    static func suggest(text: String, labels: [String], source: CaptureItem.Source) async -> String? {
        guard isAvailable else { return nil }
        var facts: [String] = []
        if let app = source.appName { facts.append("App: \(app)") }
        if let title = source.windowTitle { facts.append("Window title: \(title)") }
        if let page = source.pageTitle { facts.append("Web page title: \(page)") }
        if let site = source.website { facts.append("Website: \(site)") }
        if !labels.isEmpty { facts.append("The picture looks like: \(labels.joined(separator: ", "))") }
        let visible = text.split(whereSeparator: \.isNewline).prefix(60).joined(separator: "\n")
        if !visible.isEmpty { facts.append("Text visible in it:\n\(String(visible.prefix(1_500)))") }
        guard !facts.isEmpty else { return nil }
        let prompt = "Name this screenshot.\n\n" + facts.joined(separator: "\n")
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2))
            return CaptureNaming.clean(response.content)
        } catch {
            NSLog("CaptureLens: naming declined: \(error.localizedDescription)")
            return nil
        }
    }
}
