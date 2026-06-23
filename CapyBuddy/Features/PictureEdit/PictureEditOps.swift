// Picture Editor disabled — feature is not mature yet.
#if false
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Pure, stateless transformations on a `CIImage`. Each function returns a
/// new image; the caller (PictureEditModel) is responsible for pushing the
/// result onto the history stack.
///
/// All ops normalize the result back to an origin-anchored extent so that
/// chaining (e.g. rotate → crop → resize) stays consistent — CIImage's
/// extent.origin can drift with affine transforms otherwise, which makes
/// downstream cropping and rendering surprising.
enum PictureEditOps {

    // MARK: - Geometry

    /// Crop to `rect` (in image-space coordinates, top-left origin),
    /// re-anchoring the output extent at (0, 0).
    static func crop(_ image: CIImage, to rect: CGRect) -> CIImage {
        let intersected = rect.intersection(image.extent)
        guard !intersected.isNull, !intersected.isEmpty else { return image }
        let cropped = image.cropped(to: intersected)
        return cropped.transformed(by: CGAffineTransform(translationX: -intersected.minX, y: -intersected.minY))
    }

    /// Rotate by an arbitrary angle around the image center, then re-anchor
    /// the result so its extent starts at (0, 0).
    static func rotate(_ image: CIImage, byDegrees degrees: CGFloat) -> CIImage {
        let radians = degrees * .pi / 180
        let extent = image.extent
        let toOrigin = CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
        let rotate = CGAffineTransform(rotationAngle: radians)
        let back = CGAffineTransform(translationX: extent.midX, y: extent.midY)
        let combined = toOrigin.concatenating(rotate).concatenating(back)
        let rotated = image.transformed(by: combined)
        let normalize = CGAffineTransform(translationX: -rotated.extent.minX, y: -rotated.extent.minY)
        return rotated.transformed(by: normalize)
    }

    static func flipHorizontal(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let scale = CGAffineTransform(scaleX: -1, y: 1)
        let translate = CGAffineTransform(translationX: extent.width, y: 0)
        return image.transformed(by: scale.concatenating(translate))
    }

    static func flipVertical(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let scale = CGAffineTransform(scaleX: 1, y: -1)
        let translate = CGAffineTransform(translationX: 0, y: extent.height)
        return image.transformed(by: scale.concatenating(translate))
    }

    /// Resize uniformly. `scale` is a multiplier (0.5 = half size, 2.0 = 2x).
    /// Uses Lanczos for high quality at non-integer scales.
    static func resize(_ image: CIImage, scale: CGFloat) -> CIImage {
        guard scale > 0, scale != 1.0 else { return image }
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image
        filter.scale = Float(scale)
        filter.aspectRatio = 1.0
        return filter.outputImage ?? image
    }

    // MARK: - Filters

    enum Filter: String, CaseIterable, Identifiable {
        case grayscale
        case sepia
        case invert
        case blur
        case sharpen

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .grayscale: return "Grayscale"
            case .sepia:     return "Sepia"
            case .invert:    return "Invert"
            case .blur:      return "Blur"
            case .sharpen:   return "Sharpen"
            }
        }
    }

    static func apply(_ filter: Filter, to image: CIImage) -> CIImage {
        switch filter {
        case .grayscale:
            // True desaturation. `colorMonochrome` overlays a grey tint,
            // which produced the washed-out "search-engine grey" the v1
            // build shipped with — `colorControls` with saturation=0 maps
            // RGB onto luminance directly and yields proper black-and-white.
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.saturation = 0
            f.brightness = 0
            f.contrast = 1
            return f.outputImage ?? image
        case .sepia:
            let f = CIFilter.sepiaTone()
            f.inputImage = image
            f.intensity = 1.0
            return f.outputImage ?? image
        case .invert:
            let f = CIFilter.colorInvert()
            f.inputImage = image
            return f.outputImage ?? image
        case .blur:
            let f = CIFilter.gaussianBlur()
            f.inputImage = image
            f.radius = 8
            // Gaussian blur expands the extent — crop back so origin stays at (0,0).
            guard let out = f.outputImage else { return image }
            return out.cropped(to: image.extent)
        case .sharpen:
            let f = CIFilter.sharpenLuminance()
            f.inputImage = image
            f.sharpness = 0.6
            return f.outputImage ?? image
        }
    }

    /// Apply brightness / contrast / saturation in one pass.
    /// All three are 0-centered: 0 == identity.
    /// Brightness: -1...1, contrast: -1...1, saturation: -1...1.
    static func adjustColor(_ image: CIImage, brightness: CGFloat, contrast: CGFloat, saturation: CGFloat) -> CIImage {
        let f = CIFilter.colorControls()
        f.inputImage = image
        f.brightness = Float(brightness)
        // CIColorControls' contrast/saturation are 1-centered (1 == identity).
        f.contrast = Float(1.0 + contrast)
        f.saturation = Float(1.0 + saturation)
        return f.outputImage ?? image
    }

    // MARK: - Watermark

    enum WatermarkPosition: String, CaseIterable, Identifiable {
        case topLeft, topRight, bottomLeft, bottomRight, center
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .topLeft:     return "Top-left"
            case .topRight:    return "Top-right"
            case .bottomLeft:  return "Bottom-left"
            case .bottomRight: return "Bottom-right"
            case .center:      return "Center"
            }
        }
    }

    /// Composite a text watermark onto the image. CoreText renders into an
    /// NSImage which is bridged into a CIImage and `sourceOverCompositing`
    /// places it at the requested anchor. Font size auto-scales so the
    /// watermark stays readable on both small (web-thumb) and large
    /// (4K-photo) inputs.
    static func watermark(
        _ image: CIImage,
        text: String,
        position: WatermarkPosition,
        opacity: CGFloat,
        color: NSColor = .white
    ) -> CIImage {
        guard !text.isEmpty else { return image }

        let extent = image.extent
        // Heuristic: target watermark height ~5% of the shorter image side
        // (clamped to avoid hilariously huge / tiny text on extreme images).
        let baseSide = min(extent.width, extent.height)
        let fontSize = max(14, min(96, baseSide * 0.045))
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color.withAlphaComponent(opacity),
            .strokeColor: NSColor.black.withAlphaComponent(opacity * 0.6),
            .strokeWidth: -2.0, // negative = filled + stroked
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let textSize = attributed.size()

        // Render the text into a transparent NSImage, then bridge to CIImage.
        let padding: CGFloat = fontSize * 0.4
        let canvasSize = NSSize(width: ceil(textSize.width + padding * 2),
                                height: ceil(textSize.height + padding * 2))
        let nsImage = NSImage(size: canvasSize)
        nsImage.lockFocus()
        attributed.draw(at: NSPoint(x: padding, y: padding))
        nsImage.unlockFocus()

        guard let tiff = nsImage.tiffRepresentation,
              let textCI = CIImage(data: tiff) else { return image }

        // Anchor to the requested corner with a small inset.
        let inset = fontSize * 0.6
        let watermarkExtent = textCI.extent
        let translation: CGPoint = {
            switch position {
            case .topLeft:
                return CGPoint(x: inset, y: extent.height - watermarkExtent.height - inset)
            case .topRight:
                return CGPoint(x: extent.width - watermarkExtent.width - inset,
                               y: extent.height - watermarkExtent.height - inset)
            case .bottomLeft:
                return CGPoint(x: inset, y: inset)
            case .bottomRight:
                return CGPoint(x: extent.width - watermarkExtent.width - inset, y: inset)
            case .center:
                return CGPoint(x: (extent.width - watermarkExtent.width) / 2,
                               y: (extent.height - watermarkExtent.height) / 2)
            }
        }()
        let positioned = textCI.transformed(by: CGAffineTransform(translationX: translation.x, y: translation.y))

        let composite = CIFilter.sourceOverCompositing()
        composite.inputImage = positioned
        composite.backgroundImage = image
        return composite.outputImage ?? image
    }
}

#endif
