import Foundation
import Vision
import CoreGraphics

/// Vision-backed barcode / QR detector. Sister of `OCRService` — same
/// detached-task pattern, same `CGImageCarrier` trick for crossing actor
/// boundaries. Detects every supported symbology (QR, EAN, Code128, …)
/// and returns the decoded payloads in document reading order.
enum BarcodeService {

    enum BarcodeError: Error, LocalizedError {
        case noCodeFound
        case visionFailure(String)

        var errorDescription: String? {
            switch self {
            case .noCodeFound:           return "No barcode or QR code found."
            case .visionFailure(let m):  return m
            }
        }
    }

    struct Hit: Sendable, Equatable {
        let payload: String
        let symbology: String
        /// Vision normalized bounding box: [0,1] in both axes, origin
        /// bottom-left. Stays as-is for AppKit-positioned overlays
        /// (which also use bottom-left). Top-left consumers must flip y.
        let normalizedBox: CGRect
    }

    /// Run barcode detection on `cgImage`. Hits are sorted top-to-bottom
    /// then left-to-right so the "first" hit matches what a human eye
    /// would call the primary code.
    static func detect(in cgImage: CGImage) async throws -> [Hit] {
        let imgCarrier = CGImageCarrier(image: cgImage)
        return try await Task.detached(priority: .userInitiated) {
            let request = VNDetectBarcodesRequest()
            let handler = VNImageRequestHandler(cgImage: imgCarrier.image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                throw BarcodeError.visionFailure(error.localizedDescription)
            }
            let observations = (request.results ?? [])
            let sorted = observations.sorted { lhs, rhs in
                if abs(lhs.boundingBox.minY - rhs.boundingBox.minY) > 0.02 {
                    return lhs.boundingBox.minY > rhs.boundingBox.minY
                }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            return sorted.compactMap { obs -> Hit? in
                guard let payload = obs.payloadStringValue, !payload.isEmpty else { return nil }
                return Hit(
                    payload: payload,
                    symbology: obs.symbology.rawValue,
                    normalizedBox: obs.boundingBox
                )
            }
        }.value
    }

    /// Convenience: return the first hit or throw `.noCodeFound`.
    static func firstPayload(in cgImage: CGImage) async throws -> Hit {
        let hits = try await detect(in: cgImage)
        guard let first = hits.first else { throw BarcodeError.noCodeFound }
        return first
    }

    /// True iff the payload parses as a clickable URL (`http(s)://…`).
    /// Plain strings ("hello") and arbitrary text encodings round-trip
    /// through URL but produce nothing actionable, so we gate on scheme.
    static func openableURL(from payload: String) -> URL? {
        guard let url = URL(string: payload),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
}
