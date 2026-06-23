import AppKit

/// State machine for one annotation tool. The canvas owns one handler at a
/// time and forwards mouse events to it. Each tool is responsible for:
///   - tracking its own in-progress gesture state
///   - drawing its preview while the gesture is active
///   - producing an `Annotation` on commit
///   - drawing committed annotations of its kind via `Self.draw`
@MainActor
protocol ToolHandler: AnyObject {

    /// Which tool this handler implements. The registry uses it to dispatch.
    static var tool: AnnotationTool { get }

    /// Render a committed annotation. The current graphics context already has
    /// the canvas's coordinate system set up.
    static func draw(_ annotation: Annotation, in context: CGContext)

    /// Some tools (text) commit out-of-band — they call this closure once the
    /// user completes their input rather than waiting for `commit()`.
    var onCommit: ((Annotation) -> Void)? { get set }

    /// Mouse-down. `canvas` is provided so tools that need to attach subviews
    /// (text input field) can hold a weak reference.
    func begin(at point: NSPoint,
               color: NSColor,
               strokeWidth: CGFloat,
               canvas: AnnotationCanvasView)

    /// Mouse-dragged.
    func update(to point: NSPoint)

    /// Mouse-up. Return the finished annotation, or nil if the gesture should
    /// be discarded (e.g. zero-area drag) or commits asynchronously (text).
    func commit() -> Annotation?

    /// Draw in-progress preview (e.g. a rectangle outline that follows the
    /// drag). Called every redraw while a gesture is active.
    func drawPreview(in context: CGContext)

    /// Cancel an in-progress gesture (ESC, tool change). Should remove any
    /// transient subviews and reset state.
    func cancel()
}

extension ToolHandler {
    /// Default no-op cancel for tools without transient state to clean up.
    func cancel() {}
}

/// Central registry mapping `AnnotationTool` cases to their handler types.
/// Adding a new tool means: add the enum case, set `isAvailable`, register
/// it here. The toolbar and canvas pick it up automatically.
@MainActor
enum ToolRegistry {

    /// Construct a fresh handler for the given tool.
    static func makeHandler(for tool: AnnotationTool) -> ToolHandler {
        switch tool {
        case .rectangle:        return RectangleTool()
        case .rectangleDashed:  return RectangleDashedTool()
        case .ellipse:          return EllipseTool()
        case .ellipseDashed:    return EllipseDashedTool()
        case .arrow:            return ArrowTool()
        case .arrowLine:        return ArrowLineTool()
        case .arrowDashed:      return ArrowDashedTool()
        case .line:             return LineTool()
        case .pen:              return PenTool()
        case .highlight:        return HighlightTool()
        case .text:             return TextTool()
        case .mosaic:           return MosaicTool()
        }
    }

    /// Dispatch drawing of a committed annotation to its tool's static method.
    static func draw(_ annotation: Annotation, in context: CGContext) {
        switch annotation.tool {
        case .rectangle, .rectangleDashed:
            RectangleTool.draw(annotation, in: context)
        case .ellipse, .ellipseDashed:
            EllipseTool.draw(annotation, in: context)
        case .arrow, .arrowLine, .arrowDashed, .line:
            ArrowTool.draw(annotation, in: context)
        case .pen:
            PenTool.draw(annotation, in: context)
        case .highlight:
            HighlightTool.draw(annotation, in: context)
        case .text:
            TextTool.draw(annotation, in: context)
        case .mosaic:
            MosaicTool.draw(annotation, in: context)
        }
    }
}
