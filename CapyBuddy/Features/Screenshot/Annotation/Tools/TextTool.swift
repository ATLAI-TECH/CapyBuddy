import AppKit

/// Click anywhere → in-place editable NSTextField. Enter (or focus loss)
/// commits the text as an annotation; ESC discards.
@MainActor
final class TextTool: ToolHandler {

    static var tool: AnnotationTool { .text }

    nonisolated static func draw(_ annotation: Annotation, in context: CGContext) {
        guard case .text(let origin, let string, let style) = annotation.geometry else { return }

        let size = fontSize(for: annotation.strokeWidth)
        let attributed = NSAttributedString(string: string, attributes: attributes(size: size, color: annotation.color, style: style))

        // The canvas is `isFlipped = true`, which means the CGContext arrives
        // with a y-axis-down transform. AppKit text APIs need to know about
        // that flip — passing `flipped: false` was making text render
        // upside-down. Match the actual context state.
        NSGraphicsContext.saveGraphicsState()
        let nsCtx = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = nsCtx
        attributed.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
    }

    var onCommit: ((Annotation) -> Void)?

    private weak var canvas: AnnotationCanvasView?
    private var activeField: TextEntryField?
    private var fieldOrigin: NSPoint = .zero
    private var color: NSColor = .systemRed
    private var strokeWidth: CGFloat = 2
    private var style: TextStyle = .plain

    func begin(at point: NSPoint, color: NSColor, strokeWidth: CGFloat, canvas: AnnotationCanvasView) {
        // Replace any in-flight field — single text input at a time.
        activeField?.removeFromSuperview()

        self.canvas = canvas
        self.color = color
        self.strokeWidth = strokeWidth
        self.style = canvas.currentTextStyle
        self.fieldOrigin = point

        let size = Self.fontSize(for: strokeWidth)
        let field = TextEntryField(frame: NSRect(x: point.x, y: point.y - size * 1.4, width: 220, height: size * 1.6))
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.black.withAlphaComponent(0.15)
        field.focusRingType = .none
        field.font = Self.nsFont(size: size, style: style)
        field.textColor = color
        // Live underline in the field while typing.
        if style.underline {
            field.attributedStringValue = NSAttributedString(
                string: "",
                attributes: Self.attributes(size: size, color: color, style: style)
            )
        }
        field.placeholderString = "Type text…"
        field.onCommit  = { [weak self] in self?.commitField() }
        field.onCancel  = { [weak self] in self?.cancelField() }

        canvas.addSubview(field)
        canvas.window?.makeFirstResponder(field)
        activeField = field
    }

    func update(to point: NSPoint) {
        // Text doesn't update on drag.
    }

    func drawPreview(in context: CGContext) {
        // The active text field is a real subview — nothing to draw here.
    }

    func commit() -> Annotation? {
        // Text commits asynchronously via the field's delegate; mouseUp is a
        // no-op here.
        return nil
    }

    func cancel() {
        activeField?.removeFromSuperview()
        activeField = nil
    }

    nonisolated static func fontSize(for strokeWidth: CGFloat) -> CGFloat {
        // Continuous mapping so drag-resize on a text annotation can scale
        // smoothly all the way to ~120pt instead of being clamped to the
        // S/M/L (14/20/30) step function the toolbar swatches still emit.
        // Stroke 2 → 10pt, 4 → 20pt, 7 → 35pt, 24 → 120pt.
        return max(10, min(120, strokeWidth * 5))
    }

    nonisolated static func nsFont(size: CGFloat, style: TextStyle) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if style.bold   { traits.insert(.bold) }
        if style.italic { traits.insert(.italic) }
        let base = NSFont.systemFont(ofSize: size, weight: style.bold ? .bold : .semibold)
        if traits.isEmpty { return base }
        let desc = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: desc, size: size) ?? base
    }

    nonisolated static func attributes(size: CGFloat, color: NSColor, style: TextStyle) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: nsFont(size: size, style: style),
            .foregroundColor: color,
        ]
        if style.underline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
    }

    private func commitField() {
        guard let field = activeField else { return }
        let text = field.stringValue
        field.removeFromSuperview()
        activeField = nil
        guard !text.isEmpty else { return }
        let annotation = Annotation(
            tool: .text,
            geometry: .text(origin: fieldOrigin, string: text, style: style),
            color: color,
            strokeWidth: strokeWidth
        )
        onCommit?(annotation)
    }

    private func cancelField() {
        activeField?.removeFromSuperview()
        activeField = nil
    }
}

/// NSTextField that fires `onCommit` on Enter and `onCancel` on Escape.
private final class TextEntryField: NSTextField, NSTextFieldDelegate {

    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.delegate = self
        self.cell?.usesSingleLineMode = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            onCommit?()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }

    /// If the user clicks elsewhere, treat that as commit (matches Snipaste).
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        // Avoid double-commit if commitField already removed us.
        if superview != nil {
            onCommit?()
        }
    }
}
