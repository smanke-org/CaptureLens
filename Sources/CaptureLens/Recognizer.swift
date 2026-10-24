import AppKit
import CaptureLensKit
import Vision

/// Reading a capture with Apple's Vision framework, entirely on this Mac: its text (so the
/// library can search it) and what the picture shows (to help name it).
enum Recognizer {
    /// Every line of text in the image, with where it sits.
    static func lines(in image: CGImage) async throws -> [RecognizedLine] {
        let source = image.upscaledForReading()
        return try await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(cgImage: source, options: [:])
            try handler.perform([request])
            return (request.results ?? []).compactMap { observation in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                return RecognizedLine(text: text, box: observation.boundingBox)
            }
        }.value
    }

    /// The image's text, laid out as it looked.
    static func text(in image: CGImage) async throws -> String {
        TextAssembler.assemble(try await lines(in: image), keepLineBreaks: true)
    }

    /// What the picture shows, most likely first ("document", "chart", "screenshot"…).
    static func labels(in image: CGImage, limit: Int = 6) async -> [String] {
        let small = image.thumbnail(maxSide: 1024)
        return (try? await Task.detached(priority: .utility) {
            let request = VNClassifyImageRequest()
            try VNImageRequestHandler(cgImage: small, options: [:]).perform([request])
            return (request.results ?? [])
                .filter { $0.confidence > 0.25 }
                .sorted { $0.confidence > $1.confidence }
                .prefix(limit)
                .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        }.value) ?? []
    }
}
