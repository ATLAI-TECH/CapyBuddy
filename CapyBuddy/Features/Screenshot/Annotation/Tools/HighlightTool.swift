import AppKit

/// A pen variant: wider stroke, alpha 0.35, multiply blend mode — looks like
/// a translucent marker drawn over the screenshot.
@MainActor
final class HighlightTool: ToolHandler {

    static var tool: AnnotationTool { .highlight }

    static func draw(_ annotation: Annotation, in context: CGContext) {
        guard case .highlight(let points) = annotation.geometry else { return }
        Self.strokeHighlight(points: points, color: annotation.color, strokeWidth: annotation.strokeWidth, in: context)
    }

    var onCommit: ((Annotation) -> Void)?

    private var points: [NSPoint] = []
    private var color: NSColor = .systemYellow
    private var strokeWidth: CGFloat = 2

    func begin(at point: NSPoint, color: NSColor, strokeWidth: CGFloat, canvas: AnnotationCanvasView) {
        self.color = color
        self.strokeWidth = strokeWidth
        self.points = [point]
    }

    func update(to point: NSPoint) {
        if let last = points.last,
           abs(point.x - last.x) < 1.5, abs(point.y - last.y) < 1.5 { return }
        points.append(point)
    }

    func commit() -> Annotation? {
        defer { reset() }
        guard points.count > 1 else { return nil }
        return Annotation(tool: .highlight, geometry: .highlight(points: points), color: color, strokeWidth: strokeWidth)
    }

    func drawPreview(in context: CGContext) {
        guard points.count > 1 else { return }
        Self.strokeHighlight(points: points, color: color, strokeWidth: strokeWidth, in: context)
    }

    func cancel() { reset() }

    private func reset() { points.removeAll() }

    fileprivate static func strokeHighlight(
        points: [NSPoint], color: NSColor, strokeWidth: CGFloat, in context: CGContext
    ) {
        guard let first = points.first else { return }
        context.saveGState()
        context.setBlendMode(.multiply)
        let translucent = color.withAlphaComponent(0.35)
        context.setStrokeColor(translucent.cgColor)
        context.setLineWidth(strokeWidth * 3)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: first)
        for p in points.dropFirst() { context.addLine(to: p) }
        context.strokePath()
        context.restoreGState()
    }
}
