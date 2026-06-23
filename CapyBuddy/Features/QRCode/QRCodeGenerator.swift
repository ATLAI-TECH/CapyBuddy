import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Options

enum QRDotShape: String, CaseIterable, Identifiable {
    case square
    case roundedSquare
    case circle

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .square:        return String(localized: "Square")
        case .roundedSquare: return String(localized: "Rounded")
        case .circle:        return String(localized: "Circle")
        }
    }
}

enum QREyeShape: String, CaseIterable, Identifiable {
    case square
    case roundedSquare
    case circle

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .square:        return String(localized: "Square")
        case .roundedSquare: return String(localized: "Rounded")
        case .circle:        return String(localized: "Circle")
        }
    }
}

enum QRErrorCorrection: String, CaseIterable, Identifiable {
    case low      = "L"  // ~7%
    case medium   = "M"  // ~15%
    case quartile = "Q"  // ~25%
    case high     = "H"  // ~30%

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .low:      return "L · 7%"
        case .medium:   return "M · 15%"
        case .quartile: return "Q · 25%"
        case .high:     return "H · 30%"
        }
    }
}

struct QRCodeOptions {
    var text: String = ""
    var pixelSize: CGFloat = 512
    var foreground: NSColor = .black
    var background: NSColor = .white
    var dotShape: QRDotShape = .square
    var eyeShape: QREyeShape = .square
    var errorCorrection: QRErrorCorrection = .high
    var quietZoneModules: Int = 2
    var logo: NSImage? = nil
    /// Logo width as a fraction of the QR side. Hard-capped at 0.30 in the
    /// drawer so we don't punch through more error-correction headroom than
    /// the chosen level can recover.
    var logoScale: CGFloat = 0.20
}

// MARK: - Generator

enum QRCodeGenerator {

    /// Build an NSImage for the given options. Returns nil if the message
    /// can't be encoded (e.g. text too long for the chosen error level).
    static func render(options: QRCodeOptions) -> NSImage? {
        // When a logo is present, force H-level (~30%) error correction
        // regardless of what the user picked. A centered logo punches a hole
        // in the codeword grid; lower EC levels can't reconstruct that hole
        // and the result won't scan.
        let effectiveEC: QRErrorCorrection = options.logo != nil ? .high : options.errorCorrection
        guard let matrix = makeMatrix(text: options.text, ec: effectiveEC)
        else { return nil }

        let trimmed = trim(matrix)
        guard !trimmed.isEmpty else { return nil }

        let n  = trimmed.count
        let qz = max(0, options.quietZoneModules)
        let totalModules = n + qz * 2
        let side = max(64, options.pixelSize)
        // Force module pixel size to an integer so dots align on the pixel
        // grid — sub-pixel module sizes smear circles/rounded squares and
        // make scanning unreliable, so we round down then recompute side.
        let modulePx = max(1, floor(side / CGFloat(totalModules)))
        let actualSide = modulePx * CGFloat(totalModules)

        let pixelW = Int(actualSide)
        let pixelH = Int(actualSide)
        guard let context = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Background
        context.setFillColor(options.background.usingColorSpace(.deviceRGB)!.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))

        // Module drawing — origin at top-left for our matrix, but CGContext
        // has origin bottom-left. Flip the row index when computing the y.
        let fg = options.foreground.usingColorSpace(.deviceRGB)!.cgColor
        context.setFillColor(fg)

        let finderRegions = finderRegions(side: n)
        for row in 0..<n {
            for col in 0..<n {
                guard trimmed[row][col] else { continue }
                if isInFinderRegion(row: row, col: col, regions: finderRegions) {
                    continue  // drawn separately below
                }
                let cellRect = moduleRect(
                    row: row, col: col,
                    modulePx: modulePx,
                    quietZone: qz,
                    totalModules: totalModules
                )
                drawDot(in: cellRect, shape: options.dotShape, context: context)
            }
        }

        // Finder patterns (the three big "eye" squares in corners). We
        // render each as a 7-module outer ring + 3-module inner dot so they
        // stay scannable even when data dots are circles.
        for region in finderRegions {
            drawFinder(
                topLeftRow: region.row,
                topLeftCol: region.col,
                modulePx: modulePx,
                quietZone: qz,
                totalModules: totalModules,
                fg: fg,
                bg: options.background.usingColorSpace(.deviceRGB)!.cgColor,
                shape: options.eyeShape,
                context: context
            )
        }

        // Logo (last so it sits on top). Hard-capped at 22% — H-level EC
        // recovers ~30% but the safe centered hole is closer to 22% before
        // bleed onto alignment patterns starts hurting decode reliability.
        if let logo = options.logo,
           let cgLogo = logo.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let cap: CGFloat = 0.22
            let scale = min(cap, max(0.05, options.logoScale))
            let logoBoxSide = actualSide * scale

            // Fit the logo into a square of `logoBoxSide` while preserving
            // aspect ratio — non-square logos would otherwise stretch.
            let lw = CGFloat(cgLogo.width)
            let lh = CGFloat(cgLogo.height)
            let ratio = lw / lh
            var drawW = logoBoxSide
            var drawH = logoBoxSide
            if ratio > 1 { drawH = logoBoxSide / ratio }
            else if ratio < 1 { drawW = logoBoxSide * ratio }
            let logoRect = CGRect(
                x: (actualSide - drawW) / 2,
                y: (actualSide - drawH) / 2,
                width: drawW,
                height: drawH
            )

            // Halo follows the logo's actual rect (not a giant square) so it
            // doesn't look like a big white patch on the QR. 1 module of
            // padding keeps the logo edges from bleeding into dots.
            let pad: CGFloat = modulePx
            let bgRect = logoRect.insetBy(dx: -pad, dy: -pad)
            context.setFillColor(options.background.usingColorSpace(.deviceRGB)!.cgColor)
            let bgPath = CGPath(
                roundedRect: bgRect,
                cornerWidth: modulePx,
                cornerHeight: modulePx,
                transform: nil
            )
            context.addPath(bgPath)
            context.fillPath()

            context.draw(cgLogo, in: logoRect)
        }

        guard let cgFinal = context.makeImage() else { return nil }
        let nsImage = NSImage(cgImage: cgFinal, size: NSSize(width: actualSide, height: actualSide))
        return nsImage
    }

    // MARK: - Matrix

    private static func makeMatrix(text: String, ec: QRErrorCorrection) -> [[Bool]]? {
        let payload = Data(text.utf8)
        guard !payload.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = payload
        filter.correctionLevel = ec.rawValue
        guard let ciImage = filter.outputImage else { return nil }
        let extent = ciImage.extent
        let w = Int(extent.width)
        let h = Int(extent.height)
        guard w > 0, h > 0 else { return nil }

        let ciContext = CIContext(options: nil)
        guard let cg = ciContext.createCGImage(ciImage, from: extent) else { return nil }

        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &bytes,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Build matrix with row 0 at top — CGContext draws bottom-up, so we
        // read pixel rows in reverse to put origin at top-left for our use.
        var matrix = [[Bool]](repeating: [Bool](repeating: false, count: w), count: h)
        for y in 0..<h {
            let srcRow = h - 1 - y
            for x in 0..<w {
                let i = (srcRow * w + x) * 4
                matrix[y][x] = bytes[i] < 128
            }
        }
        return matrix
    }

    /// CoreImage may include some quiet-zone padding in the QR output. Trim
    /// off any fully-empty rows/cols on the border so we control padding
    /// ourselves via `quietZoneModules`.
    private static func trim(_ matrix: [[Bool]]) -> [[Bool]] {
        guard !matrix.isEmpty else { return matrix }
        var top = 0, bottom = matrix.count - 1
        var left = 0, right = matrix[0].count - 1

        func rowEmpty(_ r: Int) -> Bool { matrix[r].allSatisfy { !$0 } }
        func colEmpty(_ c: Int) -> Bool { matrix.allSatisfy { !$0[c] } }

        while top < bottom, rowEmpty(top) { top += 1 }
        while bottom > top, rowEmpty(bottom) { bottom -= 1 }
        while left < right, colEmpty(left) { left += 1 }
        while right > left, colEmpty(right) { right -= 1 }

        return matrix[top...bottom].map { row in Array(row[left...right]) }
    }

    // MARK: - Drawing helpers

    private struct FinderRegion { let row: Int; let col: Int }  // top-left of 7×7

    private static func finderRegions(side n: Int) -> [FinderRegion] {
        guard n >= 7 else { return [] }
        return [
            FinderRegion(row: 0, col: 0),
            FinderRegion(row: 0, col: n - 7),
            FinderRegion(row: n - 7, col: 0),
        ]
    }

    private static func isInFinderRegion(row: Int, col: Int, regions: [FinderRegion]) -> Bool {
        for r in regions {
            if row >= r.row, row < r.row + 7, col >= r.col, col < r.col + 7 {
                return true
            }
        }
        return false
    }

    private static func moduleRect(
        row: Int,
        col: Int,
        modulePx: CGFloat,
        quietZone: Int,
        totalModules: Int
    ) -> CGRect {
        let x = CGFloat(col + quietZone) * modulePx
        // Flip row to CG y-up coords.
        let yTop = CGFloat(row + quietZone) * modulePx
        let yBottom = CGFloat(totalModules) * modulePx - yTop - modulePx
        return CGRect(x: x, y: yBottom, width: modulePx, height: modulePx)
    }

    private static func drawDot(in rect: CGRect, shape: QRDotShape, context: CGContext) {
        switch shape {
        case .square:
            context.fill(rect)
        case .roundedSquare:
            let r = rect.width * 0.30
            let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
            context.addPath(path)
            context.fillPath()
        case .circle:
            context.fillEllipse(in: rect)
        }
    }

    /// Render the 7×7 finder pattern as an outer frame + inner dot. The
    /// frame uses the chosen eye shape; the inner dot mirrors the frame
    /// shape so the eye reads as a single cohesive mark.
    private static func drawFinder(
        topLeftRow: Int,
        topLeftCol: Int,
        modulePx: CGFloat,
        quietZone: Int,
        totalModules: Int,
        fg: CGColor,
        bg: CGColor,
        shape: QREyeShape,
        context: CGContext
    ) {
        let topLeft = moduleRect(
            row: topLeftRow,
            col: topLeftCol,
            modulePx: modulePx,
            quietZone: quietZone,
            totalModules: totalModules
        )
        // moduleRect for top-left module is at the top — to get the 7×7
        // bounding rect in CG (y-up) coords, take the bottom-right module
        // and union with the top-left.
        let bottomRight = moduleRect(
            row: topLeftRow + 6,
            col: topLeftCol + 6,
            modulePx: modulePx,
            quietZone: quietZone,
            totalModules: totalModules
        )
        let outer = topLeft.union(bottomRight)
        // 7×7 outer (filled), 5×5 inner (background), 3×3 inner (filled).
        let inner = outer.insetBy(dx: modulePx, dy: modulePx)              // 5×5
        let core  = outer.insetBy(dx: modulePx * 2, dy: modulePx * 2)      // 3×3

        context.setFillColor(fg)
        addEyePath(rect: outer, shape: shape, in: context)
        context.fillPath()

        context.setFillColor(bg)
        addEyePath(rect: inner, shape: shape, in: context)
        context.fillPath()

        context.setFillColor(fg)
        addEyePath(rect: core, shape: shape, in: context)
        context.fillPath()
    }

    private static func addEyePath(rect: CGRect, shape: QREyeShape, in context: CGContext) {
        switch shape {
        case .square:
            context.addRect(rect)
        case .roundedSquare:
            let r = rect.width * 0.22
            context.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
        case .circle:
            context.addEllipse(in: rect)
        }
    }
}
