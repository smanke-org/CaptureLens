import AppKit
import CaptureLensKit
import CoreImage
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

    /// Where sensitive text sits in the picture (emails, card numbers…), as boxes in 0–1
    /// coordinates with the origin at the top left, for Smart Redact.
    static func sensitiveBoxes(in image: CGImage, kinds: Set<SensitiveText.Kind> = Set(SensitiveText.Kind.allCases)) async -> [CGRect] {
        let source = image.upscaledForReading()
        return (try? await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: source, options: [:]).perform([request])
            var boxes: [CGRect] = []
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                for match in SensitiveText.find(in: candidate.string, kinds: kinds) {
                    guard let box = try? candidate.boundingBox(for: match.range)?.boundingBox else { continue }
                    // Vision's origin is at the bottom left.
                    boxes.append(CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
                }
            }
            return boxes
        }.value) ?? []
    }

    /// A mask of the picture's subject (white where it is), for removing the background.
    static func subjectMask(for image: CGImage) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            guard let result = request.results?.first else { return nil }
            let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
            let mask = CIImage(cvPixelBuffer: buffer)
            return CIContext().createCGImage(mask, from: mask.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        } catch {
            NSLog("CaptureLens: couldn't find the subject: \(error.localizedDescription)")
            return nil
        }
    }
}
