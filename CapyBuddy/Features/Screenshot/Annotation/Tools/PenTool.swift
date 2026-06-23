import AppKit

@MainActor
final class PenTool: ToolHandler {

    static var tool: AnnotationTool { .pen }

    static func draw(_ annotation: Annotation, in context: CGContext) {
        guard case .pen(let points) = annotation.geometry else { return }
        Self.strokePath(points: points, color: annotation.color, strokeWidth: annotation.strokeWidth, in: context)
    }

    var onCommit: ((Annotation) -> Void)?

    fileprivate var points: [NSPoint] = []
    fileprivate var color: NSColor = .systemRed
    fileprivate var strokeWidth: CGFloat = 2

    func begin(at point: NSPoint, color: NSColor, strokeWidth: CGFloat, canvas: AnnotationCanvasView) {
        self.color = color
        self.strokeWidth = strokeWidth
        self.points = [point]
    }

    func update(to point: NSPoint) {
        // Drop near-duplicate points to keep the path light.
        if let last = points.last,
           abs(point.x - last.x) < 1.5, abs(point.y - last.y) < 1.5 { return }
        points.append(point)
    }

    func commit() -> Annotation? {
        defer { reset() }
        guard points.count > 1 else { return nil }
        return Annotation(tool: .pen, geometry: .pen(points: points), color: color, strokeWidth: strokeWidth)
    }

    func drawPreview(in context: CGContext) {
        guard points.count > 1 else { return }
        Self.strokePath(points: points, color: color, strokeWidth: strokeWidth, in: context)
    }

    func cancel() { reset() }

    fileprivate func reset() { points.removeAll() }

    fileprivate static func strokePath(
        points: [NSPoint], color: NSColor, strokeWidth: CGFloat, in context: CGContext
    ) {
        guard let first = points.first else { return }
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(strokeWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: first)
        for p in points.dropFirst() { context.addLine(to: p) }
        context.strokePath()
    }
}
