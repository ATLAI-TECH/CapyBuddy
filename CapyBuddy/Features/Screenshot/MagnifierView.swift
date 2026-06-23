import AppKit

/// Floating-cursor magnifier shown during the selection phase.
/// Layout (top-down):
///   - 130×130 pixel-zoom panel (a 13×13 sample of the screen at 10×)
///   - 22pt hex strip showing the centre-pixel `#RRGGBB`
///   - 20pt coords strip showing `X 1234  Y 567` (cursor in screen points)
///   - 18pt hint strip showing `C copy hex · R copy rgb`
/// Total: 130 wide × 190 tall — visually a rounded square stack with the
/// pixel-zoom area itself being a perfect 130×130 square; no empty band.
final class MagnifierView: NSView {

    private static let sampleSidePixels = 13
    private static let zoom: CGFloat = 10                                             // 1 source px → 10pt block
    private static let pixelSide: CGFloat = CGFloat(sampleSidePixels) * zoom          // 130
    static let hexStripHeight: CGFloat = 22
    static let coordStripHeight: CGFloat = 20
    static let hintStripHeight: CGFloat = 18

    static let width: CGFloat = pixelSide                                             // 130
    static let height: CGFloat = pixelSide + hexStripHeight + coordStripHeight + hintStripHeight  // 190

    /// Pixel-resolution snapshot of the entire screen (or backing scaled — we
    /// derive scale from `image.width / screenWidth`).
    var snapshot: CGImage?
    var screenWidthPoints: CGFloat = 0
    var screenHeightPoints: CGFloat = 0

    /// Cursor in this view's parent (SelectionView) coords — bottom-left origin.
    /// The didSet is the magnifier's hot path: it fires on every mouseMoved.
    /// We short-circuit when the cursor hasn't crossed an integer-pixel
    /// boundary in the snapshot, so sub-pixel mouse jitter doesn't trigger
    /// any redraws.
    var cursorInScreenPoints: NSPoint = .zero {
        didSet {
            let pixel = currentSamplePixel()
            if let p = pixel, let last = lastSampledPixel, p.x == last.x, p.y == last.y {
                return
            }
            lastSampledPixel = pixel
            // Invalidate the cached hex — recompute lazily inside draw().
            cachedHex = nil
            needsDisplay = true
        }
    }

    /// Set briefly to render a green "Copied X" banner over the hex label.
    /// Cleared automatically after `flashCopyConfirmation(_:)` fires.
    private var copyConfirmation: String?
    private var copyToken = UUID()

    // MARK: - Cached hot-path state

    /// Last (px, py) integer pair at which we sampled / drew. Used to skip
    /// redraws when the cursor only jittered within a single source pixel.
    private struct PixelCoord { let x: Int; let y: Int }
    private var lastSampledPixel: PixelCoord?
    /// Memoized `#RRGGBB` for the current cursor position. Re-formatted only
    /// when the sampled RGB actually changes.
    private var cachedHex: String?

    /// Reused 1×1 RGBA scratch space for `sampleRGB`. Allocating a fresh
    /// CGContext + 4-byte buffer per mouse event was the magnifier's
    /// dominant CPU cost.
    private static let sampleColorSpace = CGColorSpaceCreateDeviceRGB()
    private var sampleBytes: [UInt8] = [0, 0, 0, 0]

    /// Pre-built attributes for the three label strips. Constructing
    /// `[NSAttributedString.Key: Any]` per draw was a non-trivial allocation
    /// on the hot path.
    private static let hexAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
        .foregroundColor: NSColor.white,
    ]
    private static let coordAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92),
    ]
    private static let hintAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92),
    ]
    private static let hintAttributed = NSAttributedString(
        string: "C copy hex · R copy rgb",
        attributes: hintAttrs
    )

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    /// The magnifier sits AT the cursor while the user is selecting, so any
    /// view-based hit testing would route the very first mouseDown to this
    /// view instead of the parent SelectionView — silently dropping the
    /// drag (NSView's default mouseDown does nothing). The magnifier is
    /// presentation-only, so opt out of hit testing entirely and let clicks
    /// pass through to the SelectionView underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Flash a "Copied X" banner over the hex label. Auto-clears after a
    /// short delay.
    func flashCopyConfirmation(_ text: String) {
        let token = UUID()
        copyToken = token
        copyConfirmation = text
        needsDisplay = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, self.copyToken == token else { return }
            self.copyConfirmation = nil
            self.needsDisplay = true
        }
    }

    /// Convert the current cursor point into snapshot-pixel integer coords,
    /// or nil if no snapshot is loaded.
    private func currentSamplePixel() -> PixelCoord? {
        guard let snapshot,
              screenWidthPoints > 0, screenHeightPoints > 0 else { return nil }
        let scaleX = CGFloat(snapshot.width) / screenWidthPoints
        let scaleY = CGFloat(snapshot.height) / screenHeightPoints
        let pxX = Int(cursorInScreenPoints.x * scaleX)
        let pxY = Int((screenHeightPoints - cursorInScreenPoints.y) * scaleY)
        return PixelCoord(x: pxX, y: pxY)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let snapshot,
              screenWidthPoints > 0, screenHeightPoints > 0 else {
            NSColor.black.setFill()
            bounds.fill()
            return
        }

        let scaleX = CGFloat(snapshot.width) / screenWidthPoints
        let scaleY = CGFloat(snapshot.height) / screenHeightPoints

        // Convert cursor (AppKit, Y-up) → snapshot (CG, Y-down) pixel coords.
        let pxX = cursorInScreenPoints.x * scaleX
        let pxY = (screenHeightPoints - cursorInScreenPoints.y) * scaleY

        let side = CGFloat(Self.sampleSidePixels)
        let half = side / 2
        let cropRect = CGRect(
            x: floor(pxX - half),
            y: floor(pxY - half),
            width: side,
            height: side
        )

        guard let cropped = snapshot.cropping(to: cropRect) else {
            NSColor.black.setFill()
            bounds.fill()
            return
        }

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // ---- Pixel zoom: top of the view, occupies the full pixelSide ----
        ctx.saveGState()
        ctx.interpolationQuality = .none
        let zoomedRect = CGRect(
            x: 0,
            y: bounds.height - Self.pixelSide,
            width: Self.pixelSide,
            height: Self.pixelSide
        )
        ctx.draw(cropped, in: zoomedRect)

        // Crosshair on the centre pixel.
        let crossX = zoomedRect.minX + half * Self.zoom
        let crossY = zoomedRect.minY + half * Self.zoom
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: zoomedRect.minX, y: crossY))
        ctx.addLine(to: CGPoint(x: zoomedRect.maxX, y: crossY))
        ctx.move(to: CGPoint(x: crossX, y: zoomedRect.minY))
        ctx.addLine(to: CGPoint(x: crossX, y: zoomedRect.maxY))
        ctx.strokePath()

        // Red box on the centre pixel.
        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(
            x: crossX - Self.zoom / 2,
            y: crossY - Self.zoom / 2,
            width: Self.zoom,
            height: Self.zoom
        ))
        ctx.restoreGState()

        // ---- Hex strip (just below the zoom area) ----
        // Either the live `#RRGGBB`, or briefly a green "✓ #RRGGBB" toast.
        let hexY = Self.coordStripHeight + Self.hintStripHeight
        if let confirmation = copyConfirmation {
            drawStrip(text: confirmation,
                      y: hexY, height: Self.hexStripHeight,
                      background: NSColor.systemGreen.withAlphaComponent(0.92))
        } else {
            // Compute hex once per pixel-change; reuse otherwise.
            if cachedHex == nil {
                cachedHex = centerPixelHex(snapshot: snapshot, at: CGPoint(x: pxX, y: pxY))
            }
            if let hex = cachedHex {
                drawStrip(text: hex,
                          y: hexY, height: Self.hexStripHeight,
                          background: NSColor.black.withAlphaComponent(0.65))
            }
        }

        // ---- Coords strip (between hex and hint) ----
        // Cursor position in screen points, x and y. Refreshed on the same
        // pixel-change cadence as hex.
        drawCoordStrip()

        // ---- Hint strip (bottom) — keyboard shortcut help ----
        // Stays visible at all times so users discover the shortcut. Plain
        // English so a non-Chinese reader gets it too. Pre-built attributed
        // string is reused across frames to avoid per-event allocation.
        drawHintStrip()
    }

    private func drawCoordStrip() {
        NSColor.black.withAlphaComponent(0.55).setFill()
        let stripRect = NSRect(x: 0, y: Self.hintStripHeight,
                               width: bounds.width, height: Self.coordStripHeight)
        NSBezierPath(rect: stripRect).fill()

        let label = "X \(Int(cursorInScreenPoints.x))  Y \(Int(cursorInScreenPoints.y))"
        let attributed = NSAttributedString(string: label, attributes: Self.coordAttrs)
        let size = attributed.size()
        attributed.draw(at: NSPoint(
            x: (bounds.width - size.width) / 2,
            y: stripRect.minY + (stripRect.height - size.height) / 2
        ))
    }

    /// Render a centred single-line text label inside a coloured strip
    /// occupying the full width of the magnifier at `[y, y+height]`.
    /// Used for the live hex / copy-confirmation strips (font size 11).
    private func drawStrip(text: String,
                           y: CGFloat, height: CGFloat,
                           background: NSColor) {
        background.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: y, width: bounds.width, height: height)).fill()

        let attributed = NSAttributedString(string: text, attributes: Self.hexAttrs)
        let size = attributed.size()
        attributed.draw(at: NSPoint(
            x: (bounds.width - size.width) / 2,
            y: y + (height - size.height) / 2
        ))
    }

    /// Hint strip uses a precomputed attributed string — no per-frame alloc.
    private func drawHintStrip() {
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: bounds.width, height: Self.hintStripHeight)).fill()

        let size = Self.hintAttributed.size()
        Self.hintAttributed.draw(at: NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (Self.hintStripHeight - size.height) / 2
        ))
    }

    private func centerPixelHex(snapshot: CGImage, at pixel: CGPoint) -> String? {
        guard let rgb = sampleRGB(snapshot: snapshot, at: pixel) else { return nil }
        return String(format: "#%02X%02X%02X", rgb.r, rgb.g, rgb.b)
    }

    /// 8-bit RGB at a snapshot pixel using the instance's reusable scratch
    /// buffer + a freshly bound 1×1 CGContext. Allocating a CGContext is
    /// still relatively cheap; the previous version's main cost was the
    /// 4-byte heap allocation per call. Reusing `sampleBytes` removes it.
    private func sampleRGB(snapshot: CGImage, at pixel: CGPoint) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let one = snapshot.cropping(to: CGRect(
            x: floor(pixel.x), y: floor(pixel.y), width: 1, height: 1
        )) else { return nil }

        sampleBytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            // Zero the buffer so a failed CGContext leaves a deterministic
            // result (transparent black) rather than the previous frame.
            base.initializeMemory(as: UInt8.self, repeating: 0, count: 4)
            if let ctx = CGContext(
                data: base, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: Self.sampleColorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                ctx.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
        }
        return (sampleBytes[0], sampleBytes[1], sampleBytes[2])
    }

    /// Compute the RGB byte at `cursorInScreenPoints` for the snapshot the
    /// magnifier currently holds. Returns nil if no snapshot loaded yet.
    func sampleRGBAtCursor() -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let snapshot, screenWidthPoints > 0, screenHeightPoints > 0 else { return nil }
        let scaleX = CGFloat(snapshot.width) / screenWidthPoints
        let scaleY = CGFloat(snapshot.height) / screenHeightPoints
        let pxX = cursorInScreenPoints.x * scaleX
        let pxY = (screenHeightPoints - cursorInScreenPoints.y) * scaleY
        return sampleRGB(snapshot: snapshot, at: CGPoint(x: pxX, y: pxY))
    }
}
