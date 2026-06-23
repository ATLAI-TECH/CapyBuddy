import AppKit

@MainActor
final class ArrowTool: ToolHandler {

    static var tool: AnnotationTool { .arrow }

    static func draw(_ annotation: Annotation, in context: CGContext) {
        guard case .arrow(let start, let end, let style) = annotation.geometry else { return }
        drawArrow(from: start, to: end, style: style, color: annotation.color, strokeWidth: annotation.strokeWidth, in: context)
    }

    var onCommit: ((Annotation) -> Void)?

    private var start: NSPoint?
    private var current: NSPoint?
    private var color: NSColor = .systemRed
    private var strokeWidth: CGFloat = 2
    /// Visual variant baked in at construction by the registry.
    private let style: ArrowStyle
    /// Tool case to record on commit. We can't always derive it from `style`
    /// (e.g. callers might want `.line` and `.plain` distinguished even
    /// though both are headless) so we carry both.
    private let toolCase: AnnotationTool

    init(style: ArrowStyle = .solid, tool: AnnotationTool = .arrow) {
        self.style = style
        self.toolCase = tool
    }

    func begin(at point: NSPoint, color: NSColor, strokeWidth: CGFloat, canvas: AnnotationCanvasView) {
        self.start = point
        self.current = point
        self.color = color
        self.strokeWidth = strokeWidth
    }

    func update(to point: NSPoint) {
        current = point
    }

    func commit() -> Annotation? {
        defer { reset() }
        guard let s = start, let c = current else { return nil }
        let dx = c.x - s.x, dy = c.y - s.y
        guard sqrt(dx*dx + dy*dy) > 4 else { return nil }
        return Annotation(
            tool: toolCase,
            geometry: .arrow(start: s, end: c, style: style),
            color: color,
            strokeWidth: strokeWidth
        )
    }

    func drawPreview(in context: CGContext) {
        guard let s = start, let c = current else { return }
        Self.drawArrow(from: s, to: c, style: style, color: color, strokeWidth: strokeWidth, in: context)
    }

    func cancel() { reset() }

    private func reset() { start = nil; current = nil }

    /// Render an arrow according to `style`:
    /// - `solid`  : shaft pulled back to meet a filled triangular head
    /// - `line`   : shaft to tip + open chevron strokes
    /// - `dashed` : like `solid` but shaft uses a dashed pattern
    /// - `plain`  : just a straight line, no head at all
    fileprivate static func drawArrow(
        from start: NSPoint, to end: NSPoint,
        style: ArrowStyle,
        color: NSColor, strokeWidth: CGFloat,
        in context: CGContext
    ) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength: CGFloat = max(10, strokeWidth * 4)
        let headWidthAngle: CGFloat = .pi / 7

        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(strokeWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let p2 = NSPoint(
            x: end.x - headLength * cos(angle - headWidthAngle),
            y: end.y - headLength * sin(angle - headWidthAngle)
        )
        let p3 = NSPoint(
            x: end.x - headLength * cos(angle + headWidthAngle),
            y: end.y - headLength * sin(angle + headWidthAngle)
        )

        // Shaft.
        context.saveGState()
        if style == .dashed {
            let dashLen = max(6, strokeWidth * 2.5)
            context.setLineDash(phase: 0, lengths: [dashLen, dashLen * 0.7])
        }

        switch style {
        case .solid, .dashed:
            // Pull shaft back so it doesn't poke past the filled head.
            let shaftEnd = NSPoint(
                x: end.x - cos(angle) * headLength * 0.6,
                y: end.y - sin(angle) * headLength * 0.6
            )
            context.move(to: start)
            context.addLine(to: shaftEnd)
            context.strokePath()
        case .line, .plain:
            // Shaft runs all the way to the tip.
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
        }
        context.restoreGState()

        // Head — only solid + dashed get a filled triangle; line gets an
        // open chevron; plain gets nothing.
        switch style {
        case .solid, .dashed:
            context.move(to: end)
            context.addLine(to: p2)
            context.addLine(to: p3)
            context.closePath()
            context.fillPath()
        case .line:
            context.move(to: p2)
            context.addLine(to: end)
            context.addLine(to: p3)
            context.strokePath()
        case .plain:
            break
        }
    }
}

/// Thin wrappers so the registry can construct each variant by case rather
/// than passing an `ArrowStyle` parameter. Each one just forwards everything
/// to an `ArrowTool` instance configured for its variant.
@MainActor
final class ArrowLineTool: ToolHandler {
    static var tool: AnnotationTool { .arrowLine }
    static func draw(_ annotation: Annotation, in context: CGContext) {
        ArrowTool.draw(annotation, in: context)
    }
    private let inner = ArrowTool(style: .line, tool: .arrowLine)
    var onCommit: ((Annotation) -> Void)? {
        get { inner.onCommit } set { inner.onCommit = newValue }
    }
    func begin(at point: NSPoint, color: NSColor, strokeWidth: CGFloat, canvas: AnnotationCanvasView) {
        inner.begin(at: point, color: color, strokeWidth: strokeWidth, canvas: canvas)
    }
    func update(to point: NSPoint) { inner.update(to: point) }
    func commit() -> Annotation? { inner.commit() }
    func drawPreview(in context: CGContext) { inner.drawPreview(in: context) }
    func cancel() { inner.cancel() }
}

@MainActor
final class ArrowDashedTool: ToolHandler {
    static var tool: AnnotationTool { .arrowDashed }
    static func draw(_ annotation: Annotation, in context: CGContext) {
        ArrowTool.draw(annotation, in: context)
    }
    private let inner = ArrowTool(style: .dashed, tool: .arrowDashed)
    var onCommit: ((Annotation) -> Void)? {
        get { inner.onCommit } set { inner.onCommit = newValue }
    }
    func begin(at point: NSPoint, color: NSColor, strokeWidth: CGFloat, canvas: AnnotationCanvasView) {
        inner.begin(at: point, color: color, strokeWidth: strokeWidth, canvas: canvas)
    }
    func update(to point: NSPoint) { inner.update(to: point) }
    func commit() -> Annotation? { inner.commit() }
    func drawPreview(in context: CGContext) { inner.drawPreview(in: context) }
    func cancel() { inner.cancel() }
}

@MainActor
final class LineTool: ToolHandler {
    static var tool: AnnotationTool { .line }
    static func draw(_ annotation: Annotation, in context: CGContext) {
        ArrowTool.draw(annotation, in: context)
    }
    private let inner = ArrowTool(style: .plain, tool: .line)
    var onCommit: ((Annotation) -> Void)? {
        get { inner.onCommit } set { inner.onCommit = newValue }
    }
    func begin(at point: NSPoint, color: NSColor, strokeWidth: CGFloat, canvas: AnnotationCanvasView) {
        inner.begin(at: point, color: color, strokeWidth: strokeWidth, canvas: canvas)
    }
    func update(to point: NSPoint) { inner.update(to: point) }
    func commit() -> Annotation? { inner.commit() }
    func drawPreview(in context: CGContext) { inner.drawPreview(in: context) }
    func cancel() { inner.cancel() }
}
