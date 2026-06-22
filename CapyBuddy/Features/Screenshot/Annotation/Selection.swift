import AppKit

/// Identifies one of the grab points shown on a selected annotation.
/// `start`/`end` are arrow-only; the 8 box handles apply to rect/ellipse/text.
enum SelectionHandle: Hashable {
    case topLeft, top, topRight
    case left, right
    case bottomLeft, bottom, bottomRight
    case start, end

    var resizeCursor: NSCursor {
        switch self {
        case .top, .bottom:                         return .resizeUpDown
        case .left, .right:                         return .resizeLeftRight
        case .topLeft, .bottomRight,
             .topRight, .bottomLeft:                return .crosshair  // diagonal cursor isn't standard on macOS
        case .start, .end:                          return .openHand
        }
    }
}

extension Annotation {

    /// Tight bounding box used for hit-testing and drawing the selection
    /// chrome. Padded slightly so thin strokes still register clicks.
    /// Lazily memoized — text annotations in particular need to measure
    /// the rendered string, which is far too expensive to redo on every
    /// drag-event redraw.
    var boundingBox: NSRect {
        mutating get {
            if let cached = _cachedBoundingBox { return cached }
            let computed = computeBoundingBox()
            _cachedBoundingBox = computed
            return computed
        }
    }

    /// Read-only fallback for callers that hold an immutable Annotation
    /// (e.g. inside an `if let annot = annotations.first(...)` binding).
    /// Skips the cache slot — used in cold paths like resetCursorRects /
    /// selection chrome — but the hot draw / hit-test paths go through the
    /// mutating accessor on the array element directly.
    var boundingBoxImmutable: NSRect {
        if let cached = _cachedBoundingBox { return cached }
        return computeBoundingBox()
    }

    private func computeBoundingBox() -> NSRect {
        let pad = max(2, strokeWidth)
        switch geometry {
        case .rectangle(let r, _), .ellipse(let r, _):
            return r.insetBy(dx: -strokeWidth/2, dy: -strokeWidth/2)
        case .arrow(let s, let e, _):
            return NSRect(
                x: min(s.x, e.x), y: min(s.y, e.y),
                width: abs(e.x - s.x), height: abs(e.y - s.y)
            ).insetBy(dx: -pad, dy: -pad)
        case .pen(let pts), .highlight(let pts):
            return Self.boundingBox(of: pts).insetBy(dx: -pad, dy: -pad)
        case .mosaic(let pts, _):
            // Brush radius — not blockSize — defines the affected area.
            // Old code used bs/2 which under-reported the box and broke
            // hit-testing of mosaic annotations near their edges.
            let radius = strokeWidth * 6
            return Self.boundingBox(of: pts).insetBy(dx: -radius, dy: -radius)
        case .text(let origin, let str, let style):
            let size = TextTool.fontSize(for: strokeWidth)
            let attrs = TextTool.attributes(size: size, color: color, style: style)
            let measured = (str as NSString).size(withAttributes: attrs)
            return NSRect(
                x: origin.x,
                y: origin.y,
                width: max(8, measured.width),
                height: max(size, measured.height)
            )
        }
    }

    /// Whether `point` lies on (or close to) this annotation's body.
    func hitTest(_ point: NSPoint) -> Bool {
        boundingBoxImmutable.insetBy(dx: -2, dy: -2).contains(point)
    }

    /// Handles to render and hit-test for this annotation's selection chrome.
    func handlePositions() -> [(SelectionHandle, NSPoint)] {
        switch geometry {
        case .arrow(let s, let e, _):
            return [(.start, s), (.end, e)]
        case .rectangle, .ellipse, .text:
            return Self.handles8(of: boundingBoxImmutable)
        case .pen, .highlight, .mosaic:
            return []  // movable but not resizable
        }
    }

    /// Returns a copy translated by `delta`.
    func translated(by delta: CGSize) -> Annotation {
        var copy = self
        copy.geometry = Self.translate(geometry, by: delta)
        return copy
    }

    /// Returns a copy resized so that `handle` lies at `point`. `originalBox`
    /// is the bbox at the start of the drag — it pins the opposite anchor so
    /// the drag is symmetric and doesn't drift if the user crosses through
    /// zero.
    func resized(handle: SelectionHandle, originalBox: NSRect, to point: NSPoint) -> Annotation {
        switch geometry {
        case .arrow(let s, let e, let style):
            switch handle {
            case .start:
                var copy = self; copy.geometry = .arrow(start: point, end: e, style: style); return copy
            case .end:
                var copy = self; copy.geometry = .arrow(start: s, end: point, style: style); return copy
            default:
                return self
            }

        case .rectangle(_, let style):
            let newBox = Self.resizeRect(originalBox, handle: handle, to: point)
            var copy = self; copy.geometry = .rectangle(newBox, style: style); return copy

        case .ellipse(_, let style):
            let newBox = Self.resizeRect(originalBox, handle: handle, to: point)
            var copy = self; copy.geometry = .ellipse(newBox, style: style); return copy

        case .text(_, let str, let style):
            // Drag a corner → scale the font (strokeWidth) by the bbox change.
            // Origin moves so the dragged corner lands at `point`.
            let newBox = Self.resizeRect(originalBox, handle: handle, to: point)
            let oldDiag = max(1, hypot(originalBox.width, originalBox.height))
            let newDiag = hypot(newBox.width, newBox.height)
            let scale = max(0.3, min(5.0, newDiag / oldDiag))
            var copy = self
            copy.strokeWidth = max(1, min(60, strokeWidth * scale))
            copy.geometry = .text(origin: NSPoint(x: newBox.minX, y: newBox.minY), string: str, style: style)
            return copy

        case .pen, .highlight, .mosaic:
            return self
        }
    }

    // MARK: - Static helpers

    static func boundingBox(of points: [NSPoint]) -> NSRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func translate(_ g: AnnotationGeometry, by d: CGSize) -> AnnotationGeometry {
        switch g {
        case .rectangle(let r, let style):
            return .rectangle(r.offsetBy(dx: d.width, dy: d.height), style: style)
        case .ellipse(let r, let style):
            return .ellipse(r.offsetBy(dx: d.width, dy: d.height), style: style)
        case .arrow(let s, let e, let style):
            return .arrow(
                start: NSPoint(x: s.x + d.width, y: s.y + d.height),
                end:   NSPoint(x: e.x + d.width, y: e.y + d.height),
                style: style
            )
        case .pen(let pts):
            return .pen(points: pts.map { NSPoint(x: $0.x + d.width, y: $0.y + d.height) })
        case .highlight(let pts):
            return .highlight(points: pts.map { NSPoint(x: $0.x + d.width, y: $0.y + d.height) })
        case .mosaic(let pts, let bs):
            return .mosaic(points: pts.map { NSPoint(x: $0.x + d.width, y: $0.y + d.height) }, blockSize: bs)
        case .text(let origin, let str, let style):
            return .text(
                origin: NSPoint(x: origin.x + d.width, y: origin.y + d.height),
                string: str, style: style
            )
        }
    }

    /// `originalBox` is the pre-drag box; `handle` is the dragged corner/edge;
    /// `p` is the new mouse point. The opposite corner/edge is anchored.
    private static func resizeRect(_ originalBox: NSRect, handle: SelectionHandle, to p: NSPoint) -> NSRect {
        var minX = originalBox.minX, maxX = originalBox.maxX
        var minY = originalBox.minY, maxY = originalBox.maxY

        switch handle {
        case .topLeft:     minX = p.x; minY = p.y
        case .top:         minY = p.y
        case .topRight:    maxX = p.x; minY = p.y
        case .right:       maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom:      maxY = p.y
        case .bottomLeft:  minX = p.x; maxY = p.y
        case .left:        minX = p.x
        case .start, .end: break
        }

        // Normalize so width/height are non-negative even if the user crossed
        // through the anchor.
        return NSRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width:  max(1, abs(maxX - minX)),
            height: max(1, abs(maxY - minY))
        )
    }

    private static func handles8(of r: NSRect) -> [(SelectionHandle, NSPoint)] {
        return [
            (.topLeft,     NSPoint(x: r.minX, y: r.minY)),
            (.top,         NSPoint(x: r.midX, y: r.minY)),
            (.topRight,    NSPoint(x: r.maxX, y: r.minY)),
            (.left,        NSPoint(x: r.minX, y: r.midY)),
            (.right,       NSPoint(x: r.maxX, y: r.midY)),
            (.bottomLeft,  NSPoint(x: r.minX, y: r.maxY)),
            (.bottom,      NSPoint(x: r.midX, y: r.maxY)),
            (.bottomRight, NSPoint(x: r.maxX, y: r.maxY)),
        ]
    }
}
