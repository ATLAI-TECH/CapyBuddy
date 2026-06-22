import AppKit

/// NSView that:
///   1. Draws a captured base image (the user's selection rect contents).
///   2. Replays a list of `Annotation`s on top of it via the per-tool drawers.
///   3. Forwards mouse events to the active `ToolHandler` OR — for already-
///      committed annotations — to the selection / move / resize machinery.
///   4. Renders itself to a CGImage at native pixel resolution for export.
final class AnnotationCanvasView: NSView {

    private(set) var baseImage: NSImage
    /// Underlying CGImage of `baseImage`. Cached so MosaicTool / cache lookups
    /// don't re-derive it (which would lock NSImage internals) every draw.
    private(set) var baseCGImage: CGImage?
    private(set) var annotations: [Annotation] = []

    /// Per-canvas mosaic raster cache. Committed mosaics get rasterized
    /// once and blit on subsequent frames (huge win once a mosaic exists
    /// and the user keeps interacting with the canvas).
    private let mosaicCache = MosaicRasterCache()

    /// Swap in a freshly captured image (e.g., after the user resized the
    /// selection rect). Existing annotations are preserved at their canvas
    /// coordinates and may be clipped if the new bounds are smaller.
    func replaceBaseImage(_ image: NSImage) {
        self.baseImage = image
        self.baseCGImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        // Mosaics rendered against the previous base image are now stale.
        mosaicCache.clearAll()
        needsDisplay = true
    }

    var currentColor: NSColor = .systemRed {
        didSet { needsDisplay = true }
    }
    var currentStrokeWidth: CGFloat = 4 {
        didSet { needsDisplay = true }
    }
    /// Style applied to the next text annotation begun on this canvas.
    /// Read by `TextTool.begin(...)` so the toolbar's B/I/U toggles flow
    /// through without an extra closure indirection.
    var currentTextStyle: TextStyle = .plain

    private var currentHandler: ToolHandler = RectangleTool() {
        didSet {
            oldValue.cancel()
            wireHandler(currentHandler)
        }
    }

    var currentTool: AnnotationTool {
        get { type(of: currentHandler).tool }
        set {
            guard newValue != currentTool else { return }
            currentHandler = ToolRegistry.makeHandler(for: newValue)
            // Switching tools always clears the current selection — the user
            // has signalled they want to draw something new.
            deselect()
        }
    }

    /// Callbacks invoked from keyboard shortcuts inside the canvas. The
    /// toolbar panel wires its buttons to the same closures.
    var onCancel: (() -> Void)?
    var onPin: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?

    /// Fires whenever the selection changes (after select, deselect, undo,
    /// delete, or new-annotation auto-select). The argument is the newly
    /// selected annotation, or nil if nothing is selected. Used by the
    /// `AnnotationConfigPanel` to show/hide and reposition itself.
    var onSelectionChange: ((Annotation?) -> Void)?

    /// Fires whenever a selected annotation's geometry changes (drag-move
    /// or drag-resize commits, or config-popover edits). Lets the popover
    /// reposition itself to track the moving annotation.
    var onSelectionGeometryChange: ((Annotation) -> Void)?

    /// Top-left origin matches typical screenshot/annotation UX.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(image: NSImage, frame: NSRect) {
        self.baseImage = image
        self.baseCGImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        super.init(frame: frame)
        wantsLayer = true
        // No border on the canvas itself — `SelectionView.selectionStrokeLayer`
        // already paints a 1px accent-color frame around `canvas.frame`. The
        // old border was redundant on screen AND was getting captured into
        // `cacheDisplay`'s output, leaving an unwanted blue rectangle in the
        // saved/copied image.
        wireHandler(currentHandler)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func wireHandler(_ handler: ToolHandler) {
        handler.onCommit = { [weak self] annotation in
            guard let self else { return }
            self.annotations.append(annotation)
            // Auto-select freshly committed annotations so the user can move
            // / resize them right away (Snipaste behavior).
            self.selectedID = annotation.id
            self.needsDisplay = true
        }
    }

    // MARK: - Selection state

    private(set) var selectedID: UUID? {
        didSet {
            guard oldValue != selectedID else { return }
            let annot = selectedID.flatMap { id in annotations.first(where: { $0.id == id }) }
            onSelectionChange?(annot)
            // Handle cursor rects only exist while something is selected;
            // re-build them so hovering a handle shows the resize cursor.
            window?.invalidateCursorRects(for: self)
        }
    }

    /// Look up the currently selected annotation, if any.
    var selectedAnnotation: Annotation? {
        guard let id = selectedID else { return nil }
        return annotations.first(where: { $0.id == id })
    }

    /// Mutate the currently selected annotation in place. Used by the
    /// `AnnotationConfigPanel` to push color / stroke / text-style edits
    /// back into the canvas.
    func updateSelectedAnnotation(_ transform: (inout Annotation) -> Void) {
        guard let id = selectedID,
              let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        transform(&annotations[idx])
        needsDisplay = true
        onSelectionGeometryChange?(annotations[idx])
    }

    /// Active drag (move or resize) on the selected annotation. `nil` when
    /// nothing is being dragged.
    private struct ActiveDrag {
        let id: UUID
        let kind: Kind
        let downPoint: NSPoint
        /// Snapshot of the annotation at mouseDown — used as the anchor for
        /// resize so dragging through zero stays well-defined.
        let original: Annotation

        enum Kind {
            case move
            case resize(SelectionHandle, originalBox: NSRect)
        }
    }
    private var activeDrag: ActiveDrag?

    /// True while the user is creating a new annotation via the current tool.
    /// Disjoint from `activeDrag`.
    private var isCreating: Bool = false

    /// Hit-test radius around handle centers, in points.
    private static let handleHitRadius: CGFloat = 8
    private static let handleVisualSize: CGFloat = 8

    func deselect() {
        if selectedID != nil {
            selectedID = nil
            needsDisplay = true
        }
    }

    /// Remove the currently selected annotation, if any.
    func deleteSelection() {
        guard let id = selectedID else { return }
        annotations.removeAll { $0.id == id }
        mosaicCache.remove(id: id)
        selectedID = nil
        needsDisplay = true
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)

        // Layer per-handle cursors on top of the crosshair so hovering a
        // selected annotation's handle previews the gesture (resize / drag
        // endpoint). macOS doesn't ship a public diagonal-resize cursor,
        // so corners reuse `.crosshair` rather than fake one.
        guard let annot = selectedAnnotation else { return }
        let r: CGFloat = Self.handleHitRadius
        for (handle, p) in annot.handlePositions() {
            let rect = NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            addCursorRect(rect, cursor: handle.resizeCursor)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        baseImage.draw(in: bounds)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let pixelScale = window?.backingScaleFactor ?? 2.0
        let baseSize = baseImage.size

        for annotation in annotations {
            // Mosaics: blit the cached raster instead of running the
            // per-block sample/fill loop on every redraw. First draw
            // populates the cache; subsequent draws are a single
            // `context.draw(image, in:)`.
            if annotation.tool == .mosaic, let baseCG = baseCGImage,
               let (cached, rect) = mosaicCache.image(
                    for: annotation,
                    baseCG: baseCG,
                    baseSizePoints: baseSize,
                    pixelScale: pixelScale
               ) {
                ctx.draw(cached, in: rect)
                continue
            }
            ToolRegistry.draw(annotation, in: ctx)
        }
        currentHandler.drawPreview(in: ctx)

        if let id = selectedID, let annot = annotations.first(where: { $0.id == id }) {
            drawSelectionChrome(for: annot, in: ctx)
        }
    }

    private func drawSelectionChrome(for annotation: Annotation, in ctx: CGContext) {
        let bbox = annotation.boundingBoxImmutable

        ctx.saveGState()
        // Dashed bounding box.
        ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(bbox)
        ctx.setLineDash(phase: 0, lengths: [])

        // Handles — filled white square with accent border.
        let s = Self.handleVisualSize
        for (_, p) in annotation.handlePositions() {
            let r = NSRect(x: p.x - s/2, y: p.y - s/2, width: s, height: s)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(r)
        }
        ctx.restoreGState()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        // Double-click on empty canvas (no annotation hit) = copy, Snipaste-style.
        if event.clickCount == 2 {
            let hitAnnotation = annotations.reversed().first(where: { $0.hitTest(p) })
            let hitHandle: Bool = {
                guard let id = selectedID,
                      let annot = annotations.first(where: { $0.id == id }) else { return false }
                return handleAt(point: p, on: annot) != nil
            }()
            if hitAnnotation == nil && !hitHandle {
                currentHandler.cancel()
                isCreating = false
                onCopy?()
                return
            }
        }

        // 1) If something is already selected, prefer its handles & body
        //    over starting a new annotation. This lets users keep editing.
        if let id = selectedID, let annot = annotations.first(where: { $0.id == id }) {
            if let handle = handleAt(point: p, on: annot) {
                activeDrag = ActiveDrag(
                    id: id,
                    kind: .resize(handle, originalBox: annot.boundingBoxImmutable),
                    downPoint: p,
                    original: annot
                )
                return
            }
            if annot.hitTest(p) {
                activeDrag = ActiveDrag(id: id, kind: .move, downPoint: p, original: annot)
                return
            }
        }

        // 2) Click landed on some other annotation? Select it (top-most first
        //    since the array is z-ordered bottom→top).
        if let hit = annotations.reversed().first(where: { $0.hitTest(p) }) {
            selectedID = hit.id
            activeDrag = ActiveDrag(id: hit.id, kind: .move, downPoint: p, original: hit)
            needsDisplay = true
            return
        }

        // 3) Empty space — drop selection, start creating with current tool.
        if selectedID != nil {
            selectedID = nil
            needsDisplay = true
        }
        isCreating = true
        currentHandler.begin(at: p, color: currentColor, strokeWidth: currentStrokeWidth, canvas: self)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        // Coalesce queued drags — keep only the most recent point so the
        // canvas update loop never runs faster than the display.
        var p = convert(event.locationInWindow, from: nil)
        while let next = NSApp.nextEvent(
            matching: .leftMouseDragged,
            until: .distantPast,
            inMode: .eventTracking,
            dequeue: true
        ) {
            p = convert(next.locationInWindow, from: nil)
        }

        if let drag = activeDrag, let idx = annotations.firstIndex(where: { $0.id == drag.id }) {
            let dx = p.x - drag.downPoint.x
            let dy = p.y - drag.downPoint.y
            switch drag.kind {
            case .move:
                annotations[idx] = drag.original.translated(by: CGSize(width: dx, height: dy))
            case .resize(let handle, let originalBox):
                annotations[idx] = drag.original.resized(handle: handle, originalBox: originalBox, to: p)
            }
            needsDisplay = true
            return
        }

        if isCreating {
            currentHandler.update(to: p)
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let drag = activeDrag {
            activeDrag = nil
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            // Notify so the config popover can re-anchor to the new bbox.
            if let annot = annotations.first(where: { $0.id == drag.id }) {
                onSelectionGeometryChange?(annot)
            }
            return
        }

        if isCreating {
            isCreating = false
            if let annotation = currentHandler.commit() {
                annotations.append(annotation)
                selectedID = annotation.id
            }
            needsDisplay = true
        }
    }

    private func handleAt(point p: NSPoint, on annotation: Annotation) -> SelectionHandle? {
        let r = Self.handleHitRadius
        for (handle, hp) in annotation.handlePositions() {
            let dx = abs(p.x - hp.x), dy = abs(p.y - hp.y)
            if dx <= r && dy <= r { return handle }
        }
        return nil
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53:                   // ESC — first deselect, otherwise dismiss.
            if selectedID != nil {
                deselect()
            } else {
                onCancel?()
            }
        case 36, 76:               // Return, Enter
            onPin?()
        case 51, 117:              // Backspace / forward Delete
            if selectedID != nil {
                deleteSelection()
            } else {
                super.keyDown(with: event)
            }
        case 6 where cmd:          // ⌘Z
            undoLast()
        case 8 where cmd:          // ⌘C
            onCopy?()
        case 1 where cmd:          // ⌘S
            onSave?()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Edit ops

    func undoLast() {
        guard !annotations.isEmpty else { return }
        let removed = annotations.removeLast()
        if selectedID == removed.id { selectedID = nil }
        mosaicCache.remove(id: removed.id)
        needsDisplay = true
    }

    // MARK: - Export

    /// Renders base image + all committed annotations (no in-progress preview,
    /// no selection chrome) into a CGImage at the screen's native pixel
    /// resolution.
    func renderToImage() -> CGImage? {
        // Suppress preview + selection chrome so they don't make it into the
        // exported image.
        let saved = currentHandler
        let savedSelection = selectedID
        let placeholder = NoopHandler()
        currentHandler = placeholder
        selectedID = nil
        defer {
            currentHandler = saved
            selectedID = savedSelection
        }

        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        rep.size = bounds.size
        cacheDisplay(in: bounds, to: rep)
        return rep.cgImage
    }
}

/// Stand-in handler used during export so `drawPreview` is a no-op.
@MainActor
private final class NoopHandler: ToolHandler {
    static var tool: AnnotationTool { .rectangle }
    static func draw(_ annotation: Annotation, in context: CGContext) {}
    var onCommit: ((Annotation) -> Void)?
    func begin(at point: NSPoint, color: NSColor, strokeWidth: CGFloat, canvas: AnnotationCanvasView) {}
    func update(to point: NSPoint) {}
    func commit() -> Annotation? { nil }
    func drawPreview(in context: CGContext) {}
}
