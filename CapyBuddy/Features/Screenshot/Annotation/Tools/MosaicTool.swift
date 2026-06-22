import AppKit

/// Drag along the screenshot to pixelate the area under the brush. Each
/// stroke point covers blocks of `blockSize` points; per-block colour is
/// sampled from the canvas's base image.
@MainActor
final class MosaicTool: ToolHandler {

    static var tool: AnnotationTool { .mosaic }
    static let defaultBlockSize: CGFloat = 12

    /// Fallback path: draw flat-grey blocks. Live preview and committed
    /// rendering both go through `MosaicRasterCache` (which calls
    /// `drawMosaic` directly with a base CGImage); this static draw is only
    /// reached when the canvas has no base image to sample from, so the
    /// annotation isn't invisible.
    static func draw(_ annotation: Annotation, in context: CGContext) {
        guard case .mosaic(let points, let blockSize) = annotation.geometry else { return }
        context.setFillColor(NSColor.gray.cgColor)
        for p in points {
            let bx = floor(p.x / blockSize) * blockSize
            let by = floor(p.y / blockSize) * blockSize
            context.fill(NSRect(x: bx, y: by, width: blockSize, height: blockSize))
        }
    }

    var onCommit: ((Annotation) -> Void)?

    private var points: [NSPoint] = []
    private var color: NSColor = .systemGray   // unused but required by protocol
    private var strokeWidth: CGFloat = 4
    private weak var canvas: AnnotationCanvasView?

    func begin(at point: NSPoint, color: NSColor, strokeWidth: CGFloat, canvas: AnnotationCanvasView) {
        self.color = color
        self.strokeWidth = strokeWidth
        self.canvas = canvas
        self.points = [point]
    }

    func update(to point: NSPoint) {
        if let last = points.last,
           abs(point.x - last.x) < 2, abs(point.y - last.y) < 2 { return }
        points.append(point)
    }

    func commit() -> Annotation? {
        defer { reset() }
        guard points.count > 0 else { return nil }
        return Annotation(
            tool: .mosaic,
            geometry: .mosaic(points: points, blockSize: Self.defaultBlockSize),
            color: color,
            strokeWidth: strokeWidth
        )
    }

    func drawPreview(in context: CGContext) {
        guard let canvas, !points.isEmpty,
              let baseCG = canvas.baseCGImage else { return }
        Self.drawMosaic(
            points: points,
            blockSize: Self.defaultBlockSize,
            baseCG: baseCG,
            baseSizePoints: canvas.baseImage.size,
            brushRadius: strokeWidth * 6,
            in: context
        )
    }

    func cancel() { reset() }

    private func reset() { points.removeAll() }

    /// For each stroke point, fill all blocks within `brushRadius` with the
    /// sampled centre colour of that block. Deduplicated by block index so
    /// overlapping points don't waste fills.
    static func drawMosaic(
        points: [NSPoint], blockSize: CGFloat, baseCG: CGImage, baseSizePoints: NSSize,
        brushRadius: CGFloat, in context: CGContext
    ) {
        let imgW = CGFloat(baseCG.width)
        let imgH = CGFloat(baseCG.height)
        // baseSizePoints is in points; cg dimensions are in pixels.
        let scaleX = imgW / baseSizePoints.width
        let scaleY = imgH / baseSizePoints.height

        var visited = Set<Int>()
        let cols = Int(ceil(baseSizePoints.width / blockSize)) + 1
        let radiusBlocks = Int(ceil(brushRadius / blockSize))

        // Reused per-block 4-byte sampling buffer — avoids allocating a
        // fresh `[UInt8]` for every block (a mosaic stroke can hit several
        // thousand blocks; per-block allocation was the dominant cost).
        var sampleBytes: [UInt8] = [0, 0, 0, 0]
        let cs = CGColorSpaceCreateDeviceRGB()

        for p in points {
            let cx = Int(floor(p.x / blockSize))
            let cy = Int(floor(p.y / blockSize))
            for dy in -radiusBlocks...radiusBlocks {
                for dx in -radiusBlocks...radiusBlocks {
                    let bx = cx + dx, by = cy + dy
                    let blockX = CGFloat(bx) * blockSize
                    let blockY = CGFloat(by) * blockSize
                    let centerX = blockX + blockSize/2
                    let centerY = blockY + blockSize/2
                    let dxp = centerX - p.x, dyp = centerY - p.y
                    if dxp*dxp + dyp*dyp > brushRadius*brushRadius { continue }

                    let key = by * cols + bx
                    if !visited.insert(key).inserted { continue }

                    // Sample the centre pixel of this block from the base image.
                    let pxX = Int(centerX * scaleX)
                    // CGImage is top-down; canvas is flipped (Y down) so y-axis
                    // matches directly.
                    let pxY = Int(centerY * scaleY)
                    if pxX < 0 || pxX >= baseCG.width || pxY < 0 || pxY >= baseCG.height { continue }

                    if let cropped = baseCG.cropping(to: CGRect(x: pxX, y: pxY, width: 1, height: 1)),
                       let rgb = sampleColor(cropped, into: &sampleBytes, colorSpace: cs) {
                        context.setFillColor(rgb)
                        context.fill(CGRect(x: blockX, y: blockY, width: blockSize, height: blockSize))
                    }
                }
            }
        }
    }

    /// Sample a single pixel of `image` into the caller's `bytes` buffer
    /// using a 1×1 CGContext bound to that buffer. Allocating `bytes` and
    /// the CGContext per-call (the pre-refactor version) was the inner
    /// loop's hot allocation site.
    private static func sampleColor(_ image: CGImage, into bytes: inout [UInt8], colorSpace cs: CGColorSpace) -> CGColor? {
        bytes[0] = 0; bytes[1] = 0; bytes[2] = 0; bytes[3] = 0
        return bytes.withUnsafeMutableBytes { raw -> CGColor? in
            guard let base = raw.baseAddress else { return nil }
            guard let ctx = CGContext(
                data: base, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let bytePtr = base.assumingMemoryBound(to: UInt8.self)
            return CGColor(
                red: CGFloat(bytePtr[0]) / 255,
                green: CGFloat(bytePtr[1]) / 255,
                blue: CGFloat(bytePtr[2]) / 255,
                alpha: 1
            )
        }
    }
}

/// Per-canvas raster cache for committed mosaic annotations. Each entry
/// holds the CGImage of one mosaic at native pixel resolution; redrawing
/// the canvas (e.g. while dragging some other annotation) is then a single
/// `context.draw(image, in: bbox)` per cached mosaic instead of running
/// the full per-block sample/fill loop.
///
/// Invalidation is generation-based — `Annotation.generation` bumps on
/// every geometry / strokeWidth / color mutation, so any user edit to a
/// mosaic transparently re-rasterizes on next draw.
@MainActor
final class MosaicRasterCache {

    private struct Entry {
        let generation: Int
        let pixelScale: CGFloat
        let image: CGImage
        let originInCanvas: NSPoint
        let sizeInPoints: NSSize
    }

    private var entries: [UUID: Entry] = [:]

    func remove(id: UUID) { entries.removeValue(forKey: id) }

    func clearAll() { entries.removeAll() }

    /// Drop entries for annotation IDs no longer present.
    func gc(liveIDs: Set<UUID>) {
        for id in entries.keys where !liveIDs.contains(id) {
            entries.removeValue(forKey: id)
        }
    }

    /// Return a CGImage of `annotation` rendered against `baseCG`, plus
    /// the canvas-space rect it should be drawn at. Computes (and caches)
    /// on first call; subsequent calls with the same generation hit cache.
    func image(for annotation: Annotation, baseCG: CGImage, baseSizePoints: NSSize, pixelScale: CGFloat) -> (CGImage, NSRect)? {
        if let entry = entries[annotation.id],
           entry.generation == annotation.generation,
           entry.pixelScale == pixelScale {
            let rect = NSRect(origin: entry.originInCanvas, size: entry.sizeInPoints)
            return (entry.image, rect)
        }
        guard case .mosaic(let points, let blockSize) = annotation.geometry else { return nil }
        let bbox = annotation.boundingBoxImmutable
        let pxW = Int(ceil(bbox.width * pixelScale))
        let pxH = Int(ceil(bbox.height * pixelScale))
        guard pxW > 0, pxH > 0 else { return nil }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let off = CGContext(
            data: nil, width: pxW, height: pxH, bitsPerComponent: 8,
            bytesPerRow: pxW * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Render the mosaic in canvas coordinates, then scale the whole
        // context to pixelScale so the output bitmap matches retina.
        off.scaleBy(x: pixelScale, y: pixelScale)
        off.translateBy(x: -bbox.minX, y: -bbox.minY)

        MosaicTool.drawMosaic(
            points: points,
            blockSize: blockSize,
            baseCG: baseCG,
            baseSizePoints: baseSizePoints,
            brushRadius: annotation.strokeWidth * 6,
            in: off
        )

        guard let image = off.makeImage() else { return nil }
        entries[annotation.id] = Entry(
            generation: annotation.generation,
            pixelScale: pixelScale,
            image: image,
            originInCanvas: bbox.origin,
            sizeInPoints: bbox.size
        )
        return (image, bbox)
    }
}
