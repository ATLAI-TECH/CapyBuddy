import AppKit

@MainActor
final class RectangleTool: ToolHandler {

    static var tool: AnnotationTool { .rectangle }

    static func draw(_ annotation: Annotation, in context: CGContext) {
        guard case .rectangle(let rect, let style) = annotation.geometry else { return }
        context.saveGState()
        context.setStrokeColor(annotation.color.cgColor)
        context.setLineWidth(annotation.strokeWidth)
        if style == .dashed {
            let d = max(6, annotation.strokeWidth * 2.5)
            context.setLineDash(phase: 0, lengths: [d, d * 0.7])
        }
        context.stroke(rect)
        context.restoreGState()
    }

    var onCommit: ((Annotation) -> Void)?

    private var start: NSPoint?
    private var current: NSPoint?
    private var color: NSColor = .systemRed
    private var strokeWidth: CGFloat = 2
    private let style: ShapeStyle
    private let toolCase: AnnotationTool

    init(style: ShapeStyle = .solid, tool: AnnotationTool = .rectangle) {
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
            geometry: .rectangle(rect, style: style),
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
        context.stroke(rect)
        context.restoreGState()
    }

    func cancel() {
        reset()
    }

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
final class RectangleDashedTool: ToolHandler {
    static var tool: AnnotationTool { .rectangleDashed }
    static func draw(_ annotation: Annotation, in context: CGContext) {
        RectangleTool.draw(annotation, in: context)
    }
    private let inner = RectangleTool(style: .dashed, tool: .rectangleDashed)
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

/// Shared rect math for rectangle / ellipse. Holding Shift constrains the
/// drag to a square (largest of the two axes).
enum ShapeGeometry {
    static func rect(from s: NSPoint, to c: NSPoint, constrainSquare: Bool) -> NSRect {
        let dx = c.x - s.x
        let dy = c.y - s.y
        if constrainSquare {
            let side = max(abs(dx), abs(dy))
            let signX: CGFloat = dx < 0 ? -1 : 1
            let signY: CGFloat = dy < 0 ? -1 : 1
            return NSRect(
                x: min(s.x, s.x + side * signX),
                y: min(s.y, s.y + side * signY),
                width: side,
                height: side
            )
        }
        return NSRect(
            x: min(s.x, c.x),
            y: min(s.y, c.y),
            width: abs(dx),
            height: abs(dy)
        )
    }
}
