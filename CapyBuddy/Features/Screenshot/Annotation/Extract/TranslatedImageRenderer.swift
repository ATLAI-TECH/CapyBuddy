import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Renders an "in-place translation" version of the source image: the
/// original is preserved, then every OCR'd text fragment is masked with a
/// sampled background colour and overdrawn with its translation. Same
/// shape as the Google Lens / Apple Translate camera output.
///
/// Implementation notes:
///   - Background sampling uses a thin ring just *outside* the OCR box —
///     that's where the page colour usually sits, while the inside of the
///     box is the text we're trying to delete. Falls back to the box's own
///     average if the ring is out of bounds.
///   - Text is rendered with `CTLine`s so we can iterate font size
///     downwards until the line fits the box. CoreText respects the
///     attributed string's font / colour; no SwiftUI involvement.
///   - Fragments are sorted vertically before rendering so visual debug
///     output reads top-to-bottom; rendering order otherwise doesn't
///     matter (boxes don't overlap).
enum TranslatedImageRenderer {

    /// One replacement entry: a Vision-normalized box plus the translated
    /// string we want to paint into it.
    struct Replacement: Sendable {
        let normalizedBox: CGRect
        let translatedText: String
    }

    /// Build the translated CGImage. Returns nil if the source can't be
    /// re-encoded (e.g. malformed input).
    static func render(
        source: CGImage,
        replacements: [Replacement]
    ) -> CGImage? {
        let width = source.width
        let height = source.height
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Paint the original image as the backdrop. CGContext is
        // bottom-left-origin and so is the source CGImage, so no flip
        // needed here.
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Cache pixels for sampling — read once, sample many times.
        guard let pixels = PixelGrid(image: source) else { return ctx.makeImage() }

        for replacement in replacements where !replacement.translatedText.isEmpty {
            let n = replacement.normalizedBox
            let pixelBox = CGRect(
                x: n.minX * CGFloat(width),
                y: n.minY * CGFloat(height),
                width: n.width * CGFloat(width),
                height: n.height * CGFloat(height)
            ).integral

            // Sample the surrounding ring for the background colour. If
            // the ring is empty/out-of-bounds, fall back to the box's
            // average (worst case: the translation paints over text that
            // was the same colour as itself, which is acceptable).
            let bgColor = pixels.sampleRingColor(around: pixelBox)
                       ?? pixels.sampleAverageColor(in: pixelBox)
                       ?? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            ctx.setFillColor(bgColor)
            // Inset by -2 so anti-aliased text edges around the original
            // box don't bleed through after the fill.
            ctx.fill(pixelBox.insetBy(dx: -2, dy: -2))

            // Pick a foreground colour that contrasts the chosen
            // background — black text on light backgrounds, white text
            // on dark ones.
            let textColor = pixels.contrasting(against: bgColor)
            drawTextFitting(in: pixelBox,
                            text: replacement.translatedText,
                            color: textColor,
                            into: ctx)
        }

        return ctx.makeImage()
    }

    /// Fit the translated text into `box` by trying font sizes from a
    /// generous starting point downwards until both metrics fit. Centers
    /// the result vertically inside the box.
    private static func drawTextFitting(
        in box: CGRect,
        text: String,
        color: CGColor,
        into ctx: CGContext
    ) {
        // Heuristic seed: 75% of the box height in points. CTLine metrics
        // depend on the font but this lands close to "fits" most of the
        // time, so we walk down only a handful of steps.
        var fontSize = max(8, box.height * 0.75)
        let minSize: CGFloat = 6
        let maxIterations = 24

        let nsColor = NSColor(cgColor: color) ?? .black

        var attempt = 0
        while attempt < maxIterations {
            let font = CTFontCreateWithName("HelveticaNeue" as CFString, fontSize, nil)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: nsColor,
            ]
            let attributed = NSAttributedString(string: text, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attributed)

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let typoWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let typoHeight = ascent + descent

            if typoWidth <= box.width || fontSize <= minSize {
                // Render. CTLine origin is the baseline — center vertically
                // by lifting the baseline `descent` above the box bottom +
                // half the leftover.
                let leftover = max(0, box.height - typoHeight)
                let baselineY = box.minY + descent + leftover / 2
                ctx.saveGState()
                ctx.textPosition = CGPoint(x: box.minX, y: baselineY)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
                return
            }

            // Shrink in proportion to how much we overflowed; geometric
            // shrink converges fast even on long phrases.
            let shrink = max(0.7, box.width / typoWidth)
            fontSize *= shrink
            if fontSize <= minSize { fontSize = minSize }
            attempt += 1
        }
    }
}

/// Lightweight pixel reader. Pulls the source bitmap into a contiguous
/// RGBA buffer once so subsequent samples are direct array reads.
private struct PixelGrid {
    let width: Int
    let height: Int
    let buffer: [UInt8]
    let bytesPerRow: Int

    init?(image: CGImage) {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = bytes.withUnsafeMutableBytes({ raw -> CGContext? in
            CGContext(
                data: raw.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        self.width = w
        self.height = h
        self.buffer = bytes
        self.bytesPerRow = w * 4
    }

    /// Sample the median colour of a thin ring just outside `box`. Returns
    /// nil if the ring entirely falls off the image.
    func sampleRingColor(around box: CGRect) -> CGColor? {
        let ringThickness: CGFloat = 4
        let outer = box.insetBy(dx: -ringThickness, dy: -ringThickness)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        let inner = box.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !outer.isNull, !outer.isEmpty else { return nil }

        var rs: [Int] = [], gs: [Int] = [], bs: [Int] = []
        rs.reserveCapacity(2048); gs.reserveCapacity(2048); bs.reserveCapacity(2048)

        let xMin = Int(outer.minX), xMax = Int(outer.maxX) - 1
        let yMin = Int(outer.minY), yMax = Int(outer.maxY) - 1
        for y in stride(from: yMin, through: yMax, by: 1) {
            for x in stride(from: xMin, through: xMax, by: 1) {
                if !inner.isNull, inner.contains(CGPoint(x: x, y: y)) { continue }
                let yFlipped = height - 1 - y
                let idx = yFlipped * bytesPerRow + x * 4
                guard idx >= 0, idx + 2 < buffer.count else { continue }
                rs.append(Int(buffer[idx]))
                gs.append(Int(buffer[idx + 1]))
                bs.append(Int(buffer[idx + 2]))
            }
        }
        return median(rs: rs, gs: gs, bs: bs)
    }

    /// Fallback: average colour inside `box`.
    func sampleAverageColor(in box: CGRect) -> CGColor? {
        let clipped = box.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !clipped.isNull, !clipped.isEmpty else { return nil }

        var rSum = 0, gSum = 0, bSum = 0, count = 0
        let xMin = Int(clipped.minX), xMax = Int(clipped.maxX) - 1
        let yMin = Int(clipped.minY), yMax = Int(clipped.maxY) - 1
        for y in stride(from: yMin, through: yMax, by: 2) {
            for x in stride(from: xMin, through: xMax, by: 2) {
                let yFlipped = height - 1 - y
                let idx = yFlipped * bytesPerRow + x * 4
                guard idx >= 0, idx + 2 < buffer.count else { continue }
                rSum += Int(buffer[idx])
                gSum += Int(buffer[idx + 1])
                bSum += Int(buffer[idx + 2])
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return CGColor(
            srgbRed: CGFloat(rSum) / CGFloat(count) / 255,
            green:   CGFloat(gSum) / CGFloat(count) / 255,
            blue:    CGFloat(bSum) / CGFloat(count) / 255,
            alpha:   1
        )
    }

    /// Pick black or white text depending on which has more contrast
    /// against `against`. Uses relative luminance per WCAG.
    func contrasting(against bg: CGColor) -> CGColor {
        let comps = bg.components ?? [0, 0, 0, 1]
        let r = comps.count > 0 ? comps[0] : 0
        let g = comps.count > 1 ? comps[1] : 0
        let b = comps.count > 2 ? comps[2] : 0
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return lum > 0.5
            ? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    }

    private func median(rs: [Int], gs: [Int], bs: [Int]) -> CGColor? {
        guard !rs.isEmpty else { return nil }
        let sortedR = rs.sorted()
        let sortedG = gs.sorted()
        let sortedB = bs.sorted()
        let mid = sortedR.count / 2
        return CGColor(
            srgbRed: CGFloat(sortedR[mid]) / 255,
            green:   CGFloat(sortedG[mid]) / 255,
            blue:    CGFloat(sortedB[mid]) / 255,
            alpha:   1
        )
    }
}
