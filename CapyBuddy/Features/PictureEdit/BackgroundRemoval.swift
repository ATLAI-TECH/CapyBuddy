// Picture Editor disabled — feature is not mature yet.
#if false
import Foundation
import CoreImage
import Vision

/// Vision-backed background removal. Uses
/// `VNGenerateForegroundInstanceMaskRequest`, which Apple ships built into
/// the OS — no model download, runs on-device.
///
/// Returns the original image with the background pixels stripped to
/// transparent (alpha = 0). Suitable for export as PNG / HEIC. Throws if
/// no foreground subject was detected.
enum BackgroundRemoval {

    enum BGError: Error, LocalizedError {
        case noSubjectFound
        case maskGenerationFailed(String)

        var errorDescription: String? {
            switch self {
            case .noSubjectFound:
                return "No subject was detected in the image."
            case .maskGenerationFailed(let m):
                return m
            }
        }
    }

    /// Remove the background from `ciImage`. Runs Vision on a detached
    /// background-priority task — the request is purely CPU/Neural-Engine
    /// bound and shouldn't tie up the main actor.
    static func removeBackground(from ciImage: CIImage) async throws -> CIImage {
        let captured = CIImageCarrier(image: ciImage)
        return try await Task.detached(priority: .userInitiated) {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(ciImage: captured.image)
            do {
                try handler.perform([request])
            } catch {
                throw BGError.maskGenerationFailed(error.localizedDescription)
            }
            guard let result = request.results?.first else {
                throw BGError.noSubjectFound
            }
            do {
                let pixelBuffer = try result.generateMaskedImage(
                    ofInstances: result.allInstances,
                    from: handler,
                    croppedToInstancesExtent: false
                )
                return CIImage(cvPixelBuffer: pixelBuffer)
            } catch {
                throw BGError.maskGenerationFailed(error.localizedDescription)
            }
        }.value
    }
}

/// Sendable bridge for handing a CIImage into a detached task. CIImage is
/// not formally `Sendable`, but it is value-typed and reading is safe; this
/// wrapper silences the strict-concurrency complaint without unsafe flag.
private struct CIImageCarrier: @unchecked Sendable {
    let image: CIImage
}

#endif
