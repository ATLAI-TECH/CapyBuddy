import Foundation
import Vision
import CoreGraphics

/// Vision-backed OCR service. Lives behind an enum because there is no
/// per-instance state — each call spins up a request handler, runs once,
/// and returns. Recognition runs on a detached background priority task
/// so the toolbar's main-actor click handler doesn't block.
enum OCRService {

    enum OCRError: Error, LocalizedError {
        case noTextFound
        case visionFailure(String)

        var errorDescription: String? {
            switch self {
            case .noTextFound:           return "No text found in this region."
            case .visionFailure(let m):  return m
            }
        }
    }

    /// Run OCR on `cgImage` and return the extracted lines, top-to-bottom.
    /// `recognitionLanguages` defaults to a hand-picked set covering the
    /// most common cases on a Chinese-English-Japanese trilingual machine.
    /// macOS will pick the best one per region automatically.
    static func recognizeText(
        in cgImage: CGImage,
        languages: [String] = ["zh-Hans", "zh-Hant", "en-US", "ja-JP"]
    ) async throws -> [String] {
        let captured = LanguageCaptured(languages: languages)
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = captured.languages
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                throw OCRError.visionFailure(error.localizedDescription)
            }

            let observations = (request.results ?? [])
            // Sort by vertical position so the lines come out reading-order.
            // Vision returns Cartesian normalized coords (origin bottom-left),
            // so a higher minY means a higher line on screen.
            let sorted = observations.sorted { lhs, rhs in
                lhs.boundingBox.minY > rhs.boundingBox.minY
            }
            let lines = sorted.compactMap { $0.topCandidates(1).first?.string }
            return lines
        }.value
    }

    /// Convenience: run OCR and join the lines with newlines for the
    /// clipboard / panel display.
    static func recognizedString(in cgImage: CGImage) async throws -> String {
        let lines = try await recognizeText(in: cgImage)
        guard !lines.isEmpty else { throw OCRError.noTextFound }
        return lines.joined(separator: "\n")
    }

    /// One OCR fragment with its bounding box. Coordinates are Vision's
    /// native normalized form: [0,1] in both dimensions, origin
    /// bottom-left. Renderers that paint into a top-left-origin context
    /// (like CGContext defaults) must flip the y axis.
    struct OCRBox: Sendable {
        public let text: String
        public let normalizedBox: CGRect
    }

    /// OCR variant that preserves bounding boxes — used by the
    /// translate-on-image pipeline to know where to paint the translation.
    static func recognizeBoxes(
        in cgImage: CGImage,
        languages: [String] = ["zh-Hans", "zh-Hant", "en-US", "ja-JP"]
    ) async throws -> [OCRBox] {
        let captured = LanguageCaptured(languages: languages)
        let imgCarrier = CGImageCarrier(image: cgImage)
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = captured.languages
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: imgCarrier.image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                throw OCRError.visionFailure(error.localizedDescription)
            }
            let observations = (request.results ?? [])
            return observations.compactMap { obs -> OCRBox? in
                guard let str = obs.topCandidates(1).first?.string else { return nil }
                return OCRBox(text: str, normalizedBox: obs.boundingBox)
            }
        }.value
    }
}

/// `CGImage` is reference-typed but immutable in practice; the
/// `@unchecked Sendable` wrapper lets us cross actor boundaries without
/// silencing the compiler globally.
struct CGImageCarrier: @unchecked Sendable {
    let image: CGImage
}

/// Sendable wrapper so we can pass the languages array into a detached task
/// without bumping into Sendable warnings on plain `[String]` captures in
/// strict-concurrency builds.
private struct LanguageCaptured: Sendable {
    let languages: [String]
}
