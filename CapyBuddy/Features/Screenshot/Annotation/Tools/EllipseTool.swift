import AppKit

@MainActor
final class EllipseTool: ToolHandler {

    static var tool: AnnotationTool { .ellipse }

    static func draw(_ annotation: Annotation, in context: CGContext) {
        guard case .ellipse(let rect, let style) = annotation.geometry else { return }
        context.saveGState()
        context.setStrokeColor(annotation.color.cgColor)
        context.setLineWidth(annotation.strokeWidth)
        if style == .dashed {
            let d = max(6, annotation.strokeWidth * 2.5)
            context.setLineDash(phase: 0, lengths: [d, d * 0.7])
        }
        context.strokeEllipse(in: rect)
        context.restoreGState()
    }

    var onCommit: ((Annotation) -> Void)?

    private var start: NSPoint?
    private var current: NSPoint?
    private var color: NSColor = .systemRed
    private var strokeWidth: CGFloat = 2
    private let style: ShapeStyle
    private let toolCase: AnnotationTool

    init(style: ShapeStyle = .solid, tool: AnnotationTool = .ellipse) {
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
        guard let rect = previewRect(), rect.width > 2, rect.height > 2 else { return nil }
        return Annotation(
            tool: toolCase,
            geometry: .ellipse(rect, style: style),
            color: color,
            strokeWidth: strokeWidth
        )
    }

    func drawPreview(in context: CGContext) {
        guard let rect = previewRect(), rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(strokeWidth)
        if style == .dashed {
            let d = max(6, strokeWidth * 2.5)
            context.setLineDash(phase: 0, lengths: [d, d * 0.7])
        }
        context.strokeEllipse(in: rect)
        context.restoreGState()
    }

    func cancel() { reset() }

    private func previewRect() -> NSRect? {
        guard let s = start, let c = current else { return nil }
        return ShapeGeometry.rect(from: s, to: c, constrainSquare: NSEvent.modifierFlags.contains(.shift))
    }

    private func reset() {
        start = nil
        current = nil
    }
}

/// Thin wrapper so the registry can construct the dashed variant by case.
@MainActor
final class EllipseDashedTool: ToolHandler {
    static var tool: AnnotationTool { .ellipseDashed }
    static func draw(_ annotation: Annotation, in context: CGContext) {
        EllipseTool.draw(annotation, in: context)
    }
    private let inner = EllipseTool(style: .dashed, tool: .ellipseDashed)
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
