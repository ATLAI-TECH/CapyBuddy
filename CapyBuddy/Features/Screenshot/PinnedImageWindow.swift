import AppKit

/// Shared geometry for the pinned-image window. The window is grown by
/// `padding` on every side so the resize handles, which straddle the image
/// edge, are not clipped by the window bounds. All resize/zoom math works on
/// the image rect (`window.frame` inset by `padding`), never the raw frame.
private enum PinMetrics {
    static let padding: CGFloat = 6
}

final class PinnedImageWindow: NSWindow, NSWindowDelegate {

    /// Fired from `windowWillClose`. ScreenshotManager uses it to drop its
    /// strong reference — with `isReleasedWhenClosed = false`, a closed pin
    /// (and its image) would otherwise live until the app quits.
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    init(image: NSImage, anchor: NSPoint) {
        let size = image.size
        let pad = PinMetrics.padding
        // Window is the image plus a `pad` margin all round so straddling
        // handles aren't clipped; offset the origin so the image still lands
        // at `anchor`.
        let frame = NSRect(
            x: anchor.x - pad,
            y: anchor.y - pad,
            width: max(40, size.width) + pad * 2,
            height: max(40, size.height) + pad * 2
        )

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        self.isRestorable = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]
        self.isMovableByWindowBackground = true
        self.isReleasedWhenClosed = false
        self.delegate = self   // for windowWillClose → onClose
        // No `aspectRatio`: resize/zoom are fully custom and proportional, and
        // a fixed padded ratio would drift from the image ratio as it scales.

        let view = PinnedImageView(image: image, window: self)
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.autoresizingMask = [.width, .height]
        self.contentView = view
    }

    /// Defensive override — see SelectionOverlayWindow.
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        self.isRestorable = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class PinnedImageView: NSView {

    let imageView: NSImageView
    weak var hostWindow: NSWindow?
    private let originalSize: NSSize

    private let handleOverlay = ResizeHandleOverlay()

    private enum Handle {
        case topLeft, top, topRight
        case left, right
        case bottomLeft, bottom, bottomRight
    }
    /// Handle being dragged, or nil when a drag moves the window instead.
    private var activeHandle: Handle?
    /// The image rect (screen coords) at the moment the drag began. Edges not
    /// driven by the active handle stay pinned to this rect.
    private var resizeStartImageRect: NSRect = .zero
    private let resizeMargin: CGFloat = 14

    init(image: NSImage, window: NSWindow) {
        self.imageView = NSImageView()
        self.imageView.image = image
        // Fill the frame on both axes so free (non-proportional) resize
        // actually stretches the image instead of letterboxing it.
        self.imageView.imageScaling = .scaleAxesIndependently
        self.imageView.imageAlignment = .alignCenter
        // Rounded clipping lives on the image layer, not this view — this view
        // must NOT mask, or the handles straddling the image edge get cut off.
        self.imageView.wantsLayer = true
        self.imageView.layer?.cornerRadius = 4
        self.imageView.layer?.masksToBounds = true
        self.imageView.layer?.borderWidth = 1
        self.imageView.layer?.borderColor = NSColor.separatorColor.cgColor
        self.hostWindow = window
        self.originalSize = NSSize(width: max(40, image.size.width),
                                   height: max(40, image.size.height))
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(imageView)
        handleOverlay.isHidden = true
        addSubview(handleOverlay)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Never propagate a non-finite or degenerate bounds to the subviews —
        // AppKit logs "Invalid view geometry" runtime issues otherwise. This
        // can happen transiently while the window is being torn down.
        let b = bounds
        guard b.width.isFinite, b.height.isFinite, b.width > 0, b.height > 0 else { return }
        let pad = min(PinMetrics.padding, min(b.width, b.height) / 2)
        imageView.frame = b.insetBy(dx: pad, dy: pad)
        handleOverlay.frame = b
    }

    /// Route every mouse event to this view so dragging/zooming work
    /// anywhere on the pin instead of being swallowed by the image subview.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    /// Deliver the very first click to this view even when the window
    /// isn't key — otherwise a freshly deactivated pin needs one click to
    /// wake up before it can be dragged.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// We move and resize the window ourselves; letting the system's
    /// background-move run as well would fight the custom handlers.
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: - Hover affordance

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        handleOverlay.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        if activeHandle == nil {
            handleOverlay.isHidden = true
        }
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch handle(at: point) {
        case .topLeft:     NSCursor.frameResize(position: .topLeft, directions: .all).set()
        case .topRight:    NSCursor.frameResize(position: .topRight, directions: .all).set()
        case .bottomLeft:  NSCursor.frameResize(position: .bottomLeft, directions: .all).set()
        case .bottomRight: NSCursor.frameResize(position: .bottomRight, directions: .all).set()
        case .top:         NSCursor.frameResize(position: .top, directions: .all).set()
        case .bottom:      NSCursor.frameResize(position: .bottom, directions: .all).set()
        case .left:        NSCursor.frameResize(position: .left, directions: .all).set()
        case .right:       NSCursor.frameResize(position: .right, directions: .all).set()
        case nil:          NSCursor.arrow.set()
        }
    }

    private func handle(at point: NSPoint) -> Handle? {
        let r = bounds.insetBy(dx: PinMetrics.padding, dy: PinMetrics.padding)
        let m = resizeMargin
        let nearLeft = abs(point.x - r.minX) <= m
        let nearRight = abs(point.x - r.maxX) <= m
        let nearBottom = abs(point.y - r.minY) <= m
        let nearTop = abs(point.y - r.maxY) <= m
        switch (nearLeft, nearRight, nearBottom, nearTop) {
        case (true, _, _, true):  return .topLeft
        case (_, true, _, true):  return .topRight
        case (true, _, true, _):  return .bottomLeft
        case (_, true, true, _):  return .bottomRight
        case (true, _, _, _):     return .left
        case (_, true, _, _):     return .right
        case (_, _, true, _):     return .bottom
        case (_, _, _, true):     return .top
        default:                  return nil
        }
    }

    // MARK: - Drag to move / corner resize

    override func mouseDragged(with event: NSEvent) {
        guard let window = hostWindow else { return }
        if let handle = activeHandle {
            resize(to: window.convertPoint(toScreen: event.locationInWindow),
                   handle: handle,
                   proportional: event.modifierFlags.contains(.shift),
                   window: window)
        } else {
            let origin = NSPoint(x: window.frame.origin.x + event.deltaX,
                                 y: window.frame.origin.y - event.deltaY)
            window.setFrameOrigin(origin)
        }
    }

    override func mouseUp(with event: NSEvent) {
        activeHandle = nil
        super.mouseUp(with: event)
    }

    /// Resize the image rect by dragging `handle` to `mouse` (screen coords).
    /// Default is a free, axis-independent stretch — only the edges the handle
    /// owns move, the rest stay pinned to `resizeStartImageRect`. Holding Shift
    /// constrains to the image's original aspect ratio.
    private func resize(to mouse: NSPoint, handle: Handle, proportional: Bool, window: NSWindow) {
        guard mouse.x.isFinite, mouse.y.isFinite else { return }
        let start = resizeStartImageRect
        let minS: CGFloat = 60
        let maxW = originalSize.width * 5
        let maxH = originalSize.height * 5

        let movesLeft   = handle == .left  || handle == .topLeft    || handle == .bottomLeft
        let movesRight  = handle == .right || handle == .topRight   || handle == .bottomRight
        let movesBottom = handle == .bottom || handle == .bottomLeft || handle == .bottomRight
        let movesTop    = handle == .top    || handle == .topLeft    || handle == .topRight

        // Move only the dragged edges; clamp against the pinned opposite edge.
        var left = start.minX, right = start.maxX
        var bottom = start.minY, top = start.maxY
        if movesLeft   { left   = min(max(mouse.x, right - maxW), right - minS) }
        if movesRight  { right  = max(min(mouse.x, left + maxW), left + minS) }
        if movesBottom { bottom = min(max(mouse.y, top - maxH), top - minS) }
        if movesTop    { top    = max(min(mouse.y, bottom + maxH), bottom + minS) }

        var w = right - left
        var h = top - bottom

        if proportional {
            let ratio = originalSize.height / originalSize.width   // height per width
            if (movesLeft || movesRight) && !(movesTop || movesBottom) {
                // Horizontal edge: height follows width, stay centred vertically.
                h = w * ratio
                let cy = (top + bottom) / 2
                bottom = cy - h / 2; top = cy + h / 2
            } else if (movesTop || movesBottom) && !(movesLeft || movesRight) {
                // Vertical edge: width follows height, stay centred horizontally.
                w = h / ratio
                let cx = (left + right) / 2
                left = cx - w / 2; right = cx + w / 2
            } else {
                // Corner: grow to the larger of the two axes, pin the fixed corner.
                if w * ratio >= h { h = w * ratio } else { w = h / ratio }
                if movesLeft { left = right - w } else { right = left + w }
                if movesBottom { bottom = top - h } else { top = bottom + h }
            }
        }

        let imageRect = NSRect(x: left, y: bottom, width: right - left, height: top - bottom)
        let pad = PinMetrics.padding
        setWindowFrame(imageRect.insetBy(dx: -pad, dy: -pad), on: window)
    }

    /// Apply a frame only if every component is finite — a last line of
    /// defence against the "Invalid view geometry" runtime issues.
    private func setWindowFrame(_ frame: NSRect, on window: NSWindow) {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { return }
        window.setFrame(frame, display: true)
    }

    // MARK: - Zoom

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * 3
        guard delta != 0 else { return }
        zoom(by: 1 + delta * 0.004)
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification)
    }

    private func zoom(by factor: CGFloat) {
        guard let window = hostWindow, factor.isFinite, factor > 0 else { return }
        let pad = PinMetrics.padding
        let image = window.frame.insetBy(dx: pad, dy: pad)
        guard image.width > 0, image.height > 0 else { return }
        let minW: CGFloat = 60
        let maxW = originalSize.width * 5
        var newW = image.width * factor
        newW = max(minW, min(newW, maxW))
        let scale = newW / image.width
        let newH = image.height * scale
        let newImage = NSRect(x: image.midX - newW / 2,
                              y: image.midY - newH / 2,
                              width: newW,
                              height: newH)
        setWindowFrame(newImage.insetBy(dx: -pad, dy: -pad), on: window)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:  // ESC
            hostWindow?.close()
        case 8 where event.modifierFlags.contains(.command):  // Cmd+C
            copyImageToPasteboard()
        default:
            super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            hostWindow?.close()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let handle = handle(at: point), let window = hostWindow {
            activeHandle = handle
            resizeStartImageRect = window.frame.insetBy(dx: PinMetrics.padding, dy: PinMetrics.padding)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(.init(title: String(localized: "Copy"),
                           action: #selector(copyAction),
                           keyEquivalent: "c"))
        menu.addItem(.init(title: String(localized: "Save Image…"),
                           action: #selector(saveAction),
                           keyEquivalent: "s"))
        menu.addItem(.init(title: String(localized: "Reset Size"),
                           action: #selector(resetSizeAction),
                           keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(.init(title: String(localized: "Close"),
                           action: #selector(closeAction),
                           keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func copyAction() { copyImageToPasteboard() }

    @objc private func saveAction() {
        guard let image = imageView.image else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Screenshot.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    @objc private func resetSizeAction() {
        guard let window = hostWindow else { return }
        let frame = window.frame
        let pad = PinMetrics.padding
        let image = NSRect(x: frame.midX - originalSize.width / 2,
                           y: frame.midY - originalSize.height / 2,
                           width: originalSize.width,
                           height: originalSize.height)
        setWindowFrame(image.insetBy(dx: -pad, dy: -pad), on: window)
    }

    @objc private func closeAction() {
        hostWindow?.close()
    }

    private func copyImageToPasteboard() {
        guard let image = imageView.image else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }
}

/// Hover-only chrome for a pinned screenshot: a dashed accent border plus
/// eight dark-blue resize handles (four corners and four edge midpoints) that
/// straddle the image edge, mirroring the capture overlay's selection box.
/// Never receives events — the parent view handles the actual drag.
private final class ResizeHandleOverlay: NSView {

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Dark-blue resize handle fill, straddling the image edge.
    private let handleFill = NSColor(srgbRed: 0.05, green: 0.20, blue: 0.55, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        // Everything is drawn on the image rect — the window is `padding`
        // larger all round, so handles centred on the image edge stay visible.
        let r = bounds.insetBy(dx: PinMetrics.padding, dy: PinMetrics.padding)

        // Dashed bounding box hugging the image edge.
        let border = NSBezierPath(rect: r)
        border.lineWidth = 1
        border.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        border.stroke()

        // Eight handles — dark-blue square with a white border, centred on the
        // image edge (half inside the image, half in the surrounding margin).
        let s: CGFloat = 8
        let handles = [
            NSPoint(x: r.minX, y: r.minY),
            NSPoint(x: r.maxX, y: r.minY),
            NSPoint(x: r.minX, y: r.maxY),
            NSPoint(x: r.maxX, y: r.maxY),
            NSPoint(x: r.midX, y: r.minY),
            NSPoint(x: r.midX, y: r.maxY),
            NSPoint(x: r.minX, y: r.midY),
            NSPoint(x: r.maxX, y: r.midY),
        ]
        for center in handles {
            let rect = NSRect(x: center.x - s / 2, y: center.y - s / 2,
                              width: s, height: s)
            let handle = NSBezierPath(rect: rect)
            handleFill.setFill()
            handle.fill()
            handle.lineWidth = 1
            NSColor.white.setStroke()
            handle.stroke()
        }
    }
}
