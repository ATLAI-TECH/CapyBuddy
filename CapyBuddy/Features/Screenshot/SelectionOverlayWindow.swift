import AppKit

/// `NSPanel` (not `NSWindow`) with `.nonactivatingPanel` so the overlay
/// becomes key and receives mouse/keyboard events WITHOUT first activating
/// our app. Activation on capture caused a visible flash (previous app's
/// focus ring drops, menu bar swaps, dock icon highlights) — exactly the
/// thing the user expects to NOT happen when "the screen freezes".
final class SelectionOverlayWindow: NSPanel {

    let owningScreen: NSScreen
    let selectionView: SelectionView

    init(screen: NSScreen, onSelect: @escaping (NSRect) -> Void, onCancel: @escaping () -> Void) {
        self.owningScreen = screen
        self.selectionView = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Pin the panel to the target screen up-front. NSWindow's
        // designated init that takes `screen:` isn't accessible from a
        // subclass init in Swift, so we use `setFrame` here — but with
        // `display: false` AND `animationBehavior = .none` set first, so
        // the move doesn't animate.
        self.animationBehavior = .none
        self.setFrame(screen.frame, display: false)

        self.isRestorable = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver
        self.ignoresMouseEvents = false
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        self.hasShadow = false
        self.acceptsMouseMovedEvents = true
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
        // `.nonactivatingPanel` means we don't grab activation when shown;
        // pair it with `becomesKeyOnlyIfNeeded = false` so we DO become key
        // (needed for keyDown ESC/c/r) the moment the panel orders front.
        self.becomesKeyOnlyIfNeeded = false

        selectionView.onSelect = { [weak self] localRect in
            guard let self else { return }
            let globalRect = NSRect(
                x: self.frame.origin.x + localRect.origin.x,
                y: self.frame.origin.y + localRect.origin.y,
                width: localRect.width,
                height: localRect.height
            )
            onSelect(globalRect)
        }
        selectionView.onCancel = onCancel

        self.contentView = selectionView
        // Pin the selecting view as the keyboard target so the c/r color-
        // pick shortcuts (handled in `SelectionView.keyDown`) reliably
        // fire — `makeKeyAndOrderFront` doesn't always promote the
        // contentView to firstResponder for borderless screensaver-level
        // panels.
        self.initialFirstResponder = selectionView
    }

    override func becomeKey() {
        super.becomeKey()
        // Belt-and-braces: even if `initialFirstResponder` was honored, this
        // also re-makes the selecting view the firstResponder when the
        // window regains key (e.g. user clicked into another app and back).
        makeFirstResponder(selectionView)
    }

    /// Defensive override — Cocoa may call this from window restoration paths.
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        self.owningScreen = screen
        self.selectionView = SelectionView(frame: .zero)
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        self.isRestorable = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Full-screen overlay used in two phases:
///   1. `selecting` — user drags out a region. The view shows a frozen
///      screen snapshot covered by a 35%-black dim mask with a hole punched
///      where the selection rect is. All visuals are CALayers — the
///      `draw(_:)` path is unused on the hot mouseMoved/Dragged routes.
///   2. `annotating` — the canvas subview owns the selected region and
///      events; the dim mask follows the canvas frame so the user always
///      sees the selected area at full brightness.
final class SelectionView: NSView {

    enum Phase {
        case selecting
        case annotating(canvas: AnnotationCanvasView)
    }

    var onSelect: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    /// Fired on resize-handle mouseUp with the new canvas frame in this view's
    /// coords. Owner re-captures pixels for the new region.
    var onResize: ((_ localRect: NSRect) -> Void)?

    private(set) var phase: Phase = .selecting

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?

    /// Windows the user can snap-to, captured at the start of the capture
    /// session. Populated by the owner via `setSnappableWindows(_:)`.
    /// Coordinates are in AppKit global space.
    private var snappableWindows: [SnappableWindow] = []
    #if CAPYBUDDY_DIRECT
    /// Element-level hit tester. Returns nil whenever Accessibility is
    /// denied — falling back to the window-level snap is automatic.
    /// Pro-only: the MAS build strips this to avoid the AX-permission ask
    /// flagged under App Review guideline 2.4.5.
    private let elementHitTester = UIElementHitTester()
    #endif
    /// Snap rect under the cursor in view-local coords. May come from the
    /// AX element hit tester (preferred) or the window list (fallback).
    /// Cleared when the user starts a manual drag.
    private var hoveredWindowRect: NSRect?
    /// Set the moment the user actually drags (mouse moved past
    /// `dragSlop` after mouseDown). Suppresses hover snap so a real drag
    /// always wins over the cached hover candidate.
    private var didStartDragging: Bool = false
    private var dragSlop: CGFloat = 3

    private var resizeHandles: [ResizeHandle] = []
    private var resizeStartFrame: NSRect?
    private var cancelButton: CornerCancelButton?

    // MARK: - In-place translation state
    /// Snapshot of the canvas's base image *before* the user kicked off an
    /// in-place translation. Held so the "Show Original" toggle can swap
    /// back without re-running the pipeline.
    private var originalBaseImage: NSImage?
    /// Latest translated bitmap. Set once the pipeline completes.
    private var translatedBaseImage: NSImage?
    /// Which version is currently painted on the canvas.
    private(set) var showingTranslated: Bool = false
    private var translationToggleButton: TranslationToggleButton?

    private let magnifier = MagnifierView(frame: NSRect(
        x: 0, y: 0,
        width: MagnifierView.width,
        height: MagnifierView.height
    ))
    /// When true, mouse-driven reveal of the magnifier is suppressed —
    /// used while the cursor sits over a QR / barcode badge so the
    /// magnifier doesn't fight with the popover affordance.
    private var magnifierSuppressed: Bool = false
    private var trackingArea: NSTrackingArea?

    // MARK: - Layer-backed overlay visuals

    /// Frozen screen snapshot, set by `setScreenSnapshot(...)`. Drawn under
    /// the dim mask so the underlying screen content is "captured in time".
    private let backdropLayer = CALayer()
    /// 35%-black mask over `bounds`, with a hole at `selectionRect` /
    /// `canvas.frame` so the selected area shows the snapshot at full
    /// brightness.
    private let dimMaskLayer = CAShapeLayer()
    /// Accent-colored 1px border around the active rect.
    private let selectionStrokeLayer = CAShapeLayer()
    /// "WxH" pill above the selection during the selecting phase.
    private let sizeLabelLayer = CATextLayer()
    private let sizeLabelBgLayer = CALayer()
    /// "Drag to select · ESC to cancel" — the only signal the user is in
    /// screenshot mode; fades the moment a drag begins.
    private let hintTextLayer = CATextLayer()
    private let hintBgLayer = CALayer()
    private var didLayoutOverlayLayers = false

    /// Tracks whether we've pushed `.crosshair` onto the cursor stack, so
    /// every push pairs with exactly one pop — never strand the user with a
    /// stuck crosshair after the overlay tears down.
    private var crosshairPushed = false

    private var selectionRect: NSRect? {
        guard let s = startPoint, let c = currentPoint else { return nil }
        return NSRect(
            x: min(s.x, c.x),
            y: min(s.y, c.y),
            width: abs(s.x - c.x),
            height: abs(s.y - c.y)
        )
    }

    /// What the dim-mask hole + accent stroke should track right now.
    /// Drag-in-progress wins over hover; otherwise the hovered window
    /// (if any) is the implicit selection.
    private var activeRectForOverlay: NSRect? {
        if let manual = selectionRect, manual.width > 1 || manual.height > 1 {
            return manual
        }
        return hoveredWindowRect
    }

    /// Owner (ScreenshotManager) hands us the window list once at session
    /// start. We hold it for the lifetime of the capture session — windows
    /// that move/resize mid-session won't update, but that case is rare
    /// and the manual drag fallback still works.
    func setSnappableWindows(_ windows: [SnappableWindow]) {
        self.snappableWindows = windows
    }

    override var acceptsFirstResponder: Bool { true }

    /// Critical for the "modal freeze" guarantee: when our app isn't already
    /// active, the user's first click on the overlay should land in our
    /// selection logic, not be consumed by macOS to activate our window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        // Best-effort: `NSCursor.pop()` is safe to call any time, but only
        // pop if we actually pushed.
        if crosshairPushed {
            NSCursor.pop()
        }
    }

    /// Pixel-resolution snapshot of the screen this overlay covers. Used as
    /// both the magnifier's pixel source AND the overlay's frozen backdrop.
    func setScreenSnapshot(_ image: CGImage, screenSizeInPoints: NSSize) {
        magnifier.snapshot = image
        magnifier.screenWidthPoints = screenSizeInPoints.width
        magnifier.screenHeightPoints = screenSizeInPoints.height

        installOverlayLayersIfNeeded()
        // Force the layer change to commit BEFORE the panel orders front —
        // otherwise there can be a one-frame gap where the panel is visible
        // with an empty backdrop, then the snapshot snaps in. That gap is
        // what looked like the screen "shrinking and expanding".
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer.contents = image
        CATransaction.commit()
    }

    /// Extract the slice of the cached screen snapshot corresponding to
    /// `localRect` (this view's coords, AppKit Y-up). Used during selection-
    /// handle resize drags so the canvas image follows the new bounds in
    /// real time instead of being stretched by `baseImage.draw(in: bounds)`.
    func interimImage(forLocalRect localRect: NSRect) -> NSImage? {
        guard let snapshot = magnifier.snapshot,
              magnifier.screenWidthPoints > 0,
              magnifier.screenHeightPoints > 0,
              localRect.width > 0, localRect.height > 0 else { return nil }

        let scaleX = CGFloat(snapshot.width) / magnifier.screenWidthPoints
        let scaleY = CGFloat(snapshot.height) / magnifier.screenHeightPoints

        // Snapshot is top-down (CG); selectionView is bottom-up (AppKit).
        // Flip Y for the crop.
        let pxRect = CGRect(
            x: floor(localRect.minX * scaleX),
            y: floor((magnifier.screenHeightPoints - localRect.maxY) * scaleY),
            width: ceil(localRect.width * scaleX),
            height: ceil(localRect.height * scaleY)
        )

        // Clamp to image bounds — `cropping(to:)` returns nil for off-image
        // rects, which would freeze the live preview at the last good frame.
        let imgRect = CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height)
        let clamped = pxRect.intersection(imgRect)
        guard !clamped.isEmpty,
              let cropped = snapshot.cropping(to: clamped) else { return nil }
        return NSImage(cgImage: cropped, size: localRect.size)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installOverlayLayersIfNeeded()
            if magnifier.superview == nil {
                addSubview(magnifier)
                magnifier.isHidden = true   // shown when cursor enters
            }
            // Force the cursor to crosshair the instant the overlay appears,
            // even before the cursor enters the tracking area. Pop this in
            // `enterAnnotation` (canvas takes over) or on view removal.
            if !crosshairPushed {
                NSCursor.crosshair.push()
                crosshairPushed = true
            }
            // The capture path is async (ScreenCaptureKit), so by the time
            // the overlay panel orders front the cursor has been sitting
            // still inside its bounds for one or two runloop ticks. AppKit
            // only fires `mouseEntered`/`mouseMoved` when the cursor
            // *crosses* a tracking area boundary or moves — neither
            // happens here, so without this prime call the magnifier
            // stays hidden and `hoveredWindowRect` stays nil until the
            // user wiggles the mouse. Dispatching one tick later gives
            // the panel time to become key and the tracking area time
            // to install.
            DispatchQueue.main.async { [weak self] in
                self?.primeWithCurrentMouseLocation()
            }
        } else {
            popCrosshairIfNeeded()
        }
    }

    /// Show the magnifier and run the hover-snap pass using the cursor's
    /// current location. Used to compensate for mouseEntered/mouseMoved
    /// not firing when the overlay appears under a stationary cursor.
    private func primeWithCurrentMouseLocation() {
        guard let window = self.window else { return }
        // `NSEvent.mouseLocation` is real-time global AppKit coords (y-up,
        // origin at primary screen's bottom-left) — independent of the
        // event stream, so it works even if no events have flowed yet.
        let global = NSEvent.mouseLocation
        let local = NSPoint(
            x: global.x - window.frame.origin.x,
            y: global.y - window.frame.origin.y
        )
        guard bounds.contains(local) else { return }
        if !magnifierSuppressed {
            magnifier.isHidden = false
        }
        updateMagnifierPosition(cursor: local)
        updateHoverSnap(localPoint: local)
    }

    override func layout() {
        super.layout()
        guard didLayoutOverlayLayers else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer.frame = bounds
        dimMaskLayer.frame = bounds
        selectionStrokeLayer.frame = bounds
        layoutHintLayer()
        refreshOverlayLayers()
        CATransaction.commit()
    }

    private func popCrosshairIfNeeded() {
        if crosshairPushed {
            NSCursor.pop()
            crosshairPushed = false
        }
    }

    // MARK: - Overlay layer construction

    private func installOverlayLayersIfNeeded() {
        wantsLayer = true
        guard let host = layer, !didLayoutOverlayLayers else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0

        // Implicit animations on path/frame mutations would add ~250ms of
        // visible lag to selection updates — disable them globally for the
        // overlay layers.
        backdropLayer.frame = bounds
        backdropLayer.contentsGravity = .resize
        backdropLayer.contentsScale = scale
        backdropLayer.actions = noopActions
        host.addSublayer(backdropLayer)

        dimMaskLayer.frame = bounds
        dimMaskLayer.fillColor = NSColor.black.withAlphaComponent(0.35).cgColor
        dimMaskLayer.fillRule = .evenOdd
        dimMaskLayer.path = CGPath(rect: bounds, transform: nil)
        dimMaskLayer.actions = noopActions
        host.addSublayer(dimMaskLayer)

        selectionStrokeLayer.frame = bounds
        selectionStrokeLayer.strokeColor = NSColor.controlAccentColor.cgColor
        selectionStrokeLayer.fillColor = NSColor.clear.cgColor
        selectionStrokeLayer.lineWidth = 1
        selectionStrokeLayer.isHidden = true
        selectionStrokeLayer.actions = noopActions
        host.addSublayer(selectionStrokeLayer)

        sizeLabelBgLayer.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        sizeLabelBgLayer.cornerRadius = 3
        sizeLabelBgLayer.isHidden = true
        sizeLabelBgLayer.actions = noopActions
        host.addSublayer(sizeLabelBgLayer)

        sizeLabelLayer.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        sizeLabelLayer.fontSize = 11
        sizeLabelLayer.foregroundColor = NSColor.white.cgColor
        sizeLabelLayer.alignmentMode = .center
        sizeLabelLayer.contentsScale = scale
        sizeLabelLayer.isHidden = true
        sizeLabelLayer.actions = noopActions
        host.addSublayer(sizeLabelLayer)

        hintBgLayer.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        hintBgLayer.cornerRadius = 6
        hintBgLayer.actions = noopActions
        host.addSublayer(hintBgLayer)

        hintTextLayer.string = String(localized: "Click a window or drag  ·  ESC to cancel")
        hintTextLayer.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        hintTextLayer.fontSize = 13
        hintTextLayer.foregroundColor = NSColor.white.cgColor
        hintTextLayer.alignmentMode = .center
        hintTextLayer.contentsScale = scale
        hintTextLayer.actions = noopActions
        host.addSublayer(hintTextLayer)

        didLayoutOverlayLayers = true
        layoutHintLayer()
    }

    private let noopActions: [String: CAAction] = {
        let null = NSNull()
        return [
            "position": null, "bounds": null, "frame": null,
            "path": null, "hidden": null, "contents": null,
            "fillColor": null, "strokeColor": null,
        ]
    }()

    private func layoutHintLayer() {
        let text = hintTextLayer.string as? String ?? ""
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        ]
        let measured = (text as NSString).size(withAttributes: attrs)
        let padding: CGFloat = 14
        let h: CGFloat = 28
        let w = ceil(measured.width) + padding * 2
        let bg = NSRect(
            x: (bounds.width - w) / 2,
            y: bounds.minY + 60,
            width: w,
            height: h
        )
        hintBgLayer.frame = bg
        hintTextLayer.frame = NSRect(
            x: bg.minX,
            y: bg.minY + (h - measured.height) / 2,
            width: bg.width,
            height: measured.height
        )
    }

    /// Update the dim hole + accent stroke + WxH label to reflect the
    /// current `phase` and (when selecting) the in-progress selection.
    /// O(1) and allocation-free in the steady-state drag loop.
    private func refreshOverlayLayers() {
        let activeRect: NSRect?
        switch phase {
        case .selecting: activeRect = activeRectForOverlay
        case .annotating(let canvas): activeRect = canvas.frame
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let dimPath = CGMutablePath()
        dimPath.addRect(bounds)
        if let r = activeRect { dimPath.addRect(r) }
        dimMaskLayer.path = dimPath

        if let r = activeRect {
            selectionStrokeLayer.path = CGPath(rect: r, transform: nil)
            selectionStrokeLayer.isHidden = false
        } else {
            selectionStrokeLayer.isHidden = true
        }

        if case .selecting = phase, let r = activeRect {
            let label = "\(Int(r.width)) × \(Int(r.height))"
            sizeLabelLayer.string = label
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            ]
            let textSize = (label as NSString).size(withAttributes: attrs)
            let pad: CGFloat = 4
            let bg = NSRect(
                x: r.maxX - textSize.width - pad * 2,
                y: r.maxY + 4,
                width: textSize.width + pad * 2,
                height: textSize.height + pad
            )
            sizeLabelBgLayer.frame = bg
            sizeLabelLayer.frame = NSRect(
                x: bg.minX,
                y: bg.minY + (bg.height - textSize.height) / 2 - 1,
                width: bg.width,
                height: textSize.height + 2
            )
            sizeLabelBgLayer.isHidden = false
            sizeLabelLayer.isHidden = false
        } else {
            sizeLabelBgLayer.isHidden = true
            sizeLabelLayer.isHidden = true
        }

        CATransaction.commit()
    }

    private func setHintHidden(_ hidden: Bool) {
        if hintBgLayer.isHidden == hidden { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hintBgLayer.isHidden = hidden
        hintTextLayer.isHidden = hidden
        CATransaction.commit()
    }

    private func updateMagnifierPosition(cursor: NSPoint) {
        magnifier.cursorInScreenPoints = cursor

        // Anchor the magnifier so its top-left corner sits AT the cursor —
        // no empty band of space between the cursor crosshair (or its
        // accessibility outline) and the magnifier. The whole magnifier
        // surface is now content (zoom + hex + hint), so the user no
        // longer sees a "rounded frame" with a gap inside it either.
        let w = MagnifierView.width
        let h = MagnifierView.height
        var origin = NSPoint(x: cursor.x, y: cursor.y - h)
        if origin.x + w > bounds.maxX { origin.x = cursor.x - w }
        if origin.y < bounds.minY     { origin.y = cursor.y }
        magnifier.setFrameOrigin(origin)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if case .selecting = phase {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    // MARK: - In-place translation API (called by ScreenshotManager)

    /// Swap the canvas base image to the translated bitmap. Caches the
    /// pre-translation image so the toggle button can flip back without
    /// re-running the pipeline. Idempotent if called repeatedly with the
    /// same source: only the *first* call captures `originalBaseImage`.
    func applyTranslatedImage(_ cgImage: CGImage) {
        guard let canvas = annotationCanvas else { return }
        if originalBaseImage == nil {
            // Snapshot the current base image once. Subsequent translate
            // re-runs (re-translate after a language change) update only
            // `translatedBaseImage` — the original anchor never moves.
            originalBaseImage = canvas.baseImage
        }
        let ns = NSImage(cgImage: cgImage,
                         size: NSSize(width: cgImage.width, height: cgImage.height))
        translatedBaseImage = ns
        canvas.replaceBaseImage(ns)
        showingTranslated = true
        installTranslationToggleIfNeeded(around: canvas.frame)
    }

    /// Toggle between the cached original and translated bitmaps. No-op
    /// if the user hasn't run translation yet.
    func toggleTranslatedAndOriginal() {
        guard let canvas = annotationCanvas,
              let original = originalBaseImage,
              let translated = translatedBaseImage else { return }
        if showingTranslated {
            canvas.replaceBaseImage(original)
            showingTranslated = false
        } else {
            canvas.replaceBaseImage(translated)
            showingTranslated = true
        }
        translationToggleButton?.setShowingTranslated(showingTranslated)
    }

    private func installTranslationToggleIfNeeded(around rect: NSRect) {
        if let existing = translationToggleButton {
            existing.frame = translationToggleFrame(for: rect)
            existing.setShowingTranslated(showingTranslated)
            return
        }
        let button = TranslationToggleButton(frame: translationToggleFrame(for: rect))
        button.onClick = { [weak self] in self?.toggleTranslatedAndOriginal() }
        addSubview(button)
        translationToggleButton = button
    }

    private func translationToggleFrame(for rect: NSRect) -> NSRect {
        let width: CGFloat = 130
        let height: CGFloat = 24
        let gap: CGFloat = 6
        // Sit just below the top edge of the selection, anchored to the
        // top-left corner so it doesn't fight the cancel ✕ on the right.
        let aboveY = rect.maxY + gap
        if aboveY + height <= bounds.maxY - gap {
            return NSRect(x: rect.minX, y: aboveY, width: width, height: height)
        }
        // Fall back inside the selection's top-left corner.
        return NSRect(x: rect.minX + 6, y: rect.maxY - height - 6, width: width, height: height)
    }

    func enterAnnotation(rect: NSRect, canvas: AnnotationCanvasView) {
        canvas.frame = rect
        addSubview(canvas)
        installResizeHandles(around: rect)
        installCancelButton(around: rect)
        magnifier.isHidden = true
        setHintHidden(true)
        phase = .annotating(canvas: canvas)
        refreshOverlayLayers()
        // Canvas takes over the cursor (crosshair for drawing); release our
        // overlay-wide push so the canvas's own cursor rects can win.
        popCrosshairIfNeeded()
        window?.invalidateCursorRects(for: self)
        window?.makeFirstResponder(canvas)
    }

    var annotationCanvas: AnnotationCanvasView? {
        if case .annotating(let canvas) = phase { return canvas }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        // All overlay visuals are CALayers (snapshot, dim, stroke, size
        // label, hint). Nothing to paint here; the empty draw keeps the
        // hot mouseMoved/Dragged path off the CPU.
    }

    // MARK: - Mouse (selecting phase only — annotating goes to canvas / handles)

    override func mouseDown(with event: NSEvent) {
        guard case .selecting = phase else { return }
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        didStartDragging = false
        setHintHidden(true)
        // Don't clear hoveredWindowRect — if the user clicks without
        // dragging, the cached hover IS the snap target on mouseUp.
        refreshOverlayLayers()
    }

    override func mouseDragged(with event: NSEvent) {
        guard case .selecting = phase else { return }

        // Coalesce queued drags — keep only the most recent position. AppKit
        // delivers ~120 dragged events/sec on high-refresh trackpads; without
        // this the overlay update loop runs faster than the display.
        var p = convert(event.locationInWindow, from: nil)
        while let next = NSApp.nextEvent(
            matching: .leftMouseDragged,
            until: .distantPast,
            inMode: .eventTracking,
            dequeue: true
        ) {
            p = convert(next.locationInWindow, from: nil)
        }

        currentPoint = p
        // Promote to "real drag" once the cursor moves past dragSlop.
        // Until then the click is ambiguous — could still settle into a
        // window snap on mouseUp.
        if !didStartDragging, let s = startPoint {
            let dx = abs(p.x - s.x), dy = abs(p.y - s.y)
            if dx > dragSlop || dy > dragSlop {
                didStartDragging = true
                hoveredWindowRect = nil   // user has committed to manual rect
            }
        }
        updateMagnifierPosition(cursor: p)
        refreshOverlayLayers()
    }

    override func mouseMoved(with event: NSEvent) {
        guard case .selecting = phase else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !magnifierSuppressed {
            magnifier.isHidden = false
            updateMagnifierPosition(cursor: p)
        }
        updateHoverSnap(localPoint: p)
    }

    /// Recompute the snap rect under the cursor and refresh the overlay
    /// highlight. Two-stage strategy:
    ///
    ///   1. **AX element** — if Accessibility permission is granted, ask
    ///      the system-wide AX tester for the finest element under the
    ///      cursor (a button, text field, sub-view). This is the
    ///      Snipaste-style precision snap.
    ///   2. **Window** — fall back to the cached `CGWindowList` snapshot
    ///      to grab the whole owning window. Always available, no
    ///      permission needed.
    ///
    /// AX is preferred because it gives the user finer control: hover a
    /// button → snap to the button; hover the title bar → snap to the
    /// whole window.
    private func updateHoverSnap(localPoint: NSPoint) {
        if didStartDragging { return }
        guard let window = self.window else {
            hoveredWindowRect = nil
            refreshOverlayLayers()
            return
        }
        let appKitGlobal = NSPoint(
            x: window.frame.origin.x + localPoint.x,
            y: window.frame.origin.y + localPoint.y
        )
        let primaryHeight = (NSScreen.screens.first(where: { $0.frame.origin == .zero })
                             ?? NSScreen.main)?.frame.height ?? 0

        #if CAPYBUDDY_DIRECT
        // 1. Try AX element-level. Returns nil when permission is denied
        //    or the cursor is over our own process. Pro-only — see note
        //    on `elementHitTester` for MAS gating rationale.
        if let axRect = elementHitTester.elementRect(atAppKitGlobalPoint: appKitGlobal,
                                                     primaryHeight: primaryHeight) {
            hoveredWindowRect = clampToBounds(axRect, window: window)
            refreshOverlayLayers()
            return
        }
        #else
        _ = primaryHeight  // silence unused-variable in MAS build
        #endif
        // 2. Window-level fallback.
        if let hit = WindowHitTester.topMost(at: appKitGlobal, in: snappableWindows) {
            hoveredWindowRect = clampToBounds(hit.appKitGlobalRect, window: window)
        } else {
            hoveredWindowRect = nil
        }
        refreshOverlayLayers()
    }

    /// Convert an AppKit-global rect to overlay-local and clamp to the
    /// overlay's bounds (windows / elements that span monitors get cut
    /// off cleanly at the edges of THIS screen's overlay).
    private func clampToBounds(_ globalRect: NSRect, window: NSWindow) -> NSRect? {
        let local = NSRect(
            x: globalRect.origin.x - window.frame.origin.x,
            y: globalRect.origin.y - window.frame.origin.y,
            width: globalRect.width,
            height: globalRect.height
        )
        let clamped = local.intersection(bounds)
        return clamped.isEmpty ? nil : clamped
    }

    override func mouseEntered(with event: NSEvent) {
        guard case .selecting = phase else { return }
        if !magnifierSuppressed {
            magnifier.isHidden = false
        }
    }

    override func mouseExited(with event: NSEvent) {
        magnifier.isHidden = true
    }

    /// Called by overlay subviews (e.g. the QR badges) to suspend the
    /// loupe while the cursor is over them. Symmetric: `false` lets
    /// mouseMoved bring the magnifier back. While suppressed the
    /// magnifier stays hidden even if the cursor wiggles.
    func setMagnifierSuppressed(_ suppressed: Bool) {
        magnifierSuppressed = suppressed
        if suppressed {
            magnifier.isHidden = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard case .selecting = phase else { return }

        let manualRect = selectionRect
        let didDrag = didStartDragging
        startPoint = nil
        currentPoint = nil
        didStartDragging = false

        // Real drag → use manual rect.
        if didDrag, let r = manualRect, r.width > 2, r.height > 2 {
            onSelect?(r)
            return
        }
        // No drag, but the cursor was over a window when the user
        // clicked → snap to that window. This is the Snipaste-style
        // single-click capture path.
        if let snap = hoveredWindowRect, snap.width > 4, snap.height > 4 {
            hoveredWindowRect = nil
            onSelect?(snap)
            return
        }
        // Stray click somewhere with no candidate — stay in selecting.
        refreshOverlayLayers()
        setHintHidden(false)
    }

    override func keyDown(with event: NSEvent) {
        guard case .selecting = phase else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == 53 {  // ESC
            onCancel?()
            return
        }

        // Snipaste-style colour pick during the selecting phase. Magnifier
        // is already showing the cursor pixel + hex; these shortcuts write
        // the same value to the pasteboard.
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": copyCursorPixelHex()
        case "r": copyCursorPixelRGB()
        default:  super.keyDown(with: event)
        }
    }

    /// True only while the user is still dragging out a region — the window
    /// at which the c/r colour-pick shortcuts are meaningful.
    var isSelectingPhase: Bool {
        if case .selecting = phase { return true }
        return false
    }

    /// Internal (not private) so the capture session's local key-event
    /// monitor can drive these too. Window-level `keyDown` only fires on the
    /// single key overlay and is unreliable for a background non-activating
    /// panel, so the monitor is the dependable path — these methods are the
    /// shared sink for both.
    func copyCursorPixelHex() {
        guard let rgb = magnifier.sampleRGBAtCursor() else { return }
        let hex = String(format: "#%02X%02X%02X", rgb.r, rgb.g, rgb.b)
        writeStringToPasteboard(hex, confirmation: "✓ \(hex)")
    }

    func copyCursorPixelRGB() {
        guard let rgb = magnifier.sampleRGBAtCursor() else { return }
        let str = "rgb(\(rgb.r), \(rgb.g), \(rgb.b))"
        writeStringToPasteboard(str, confirmation: "✓ \(str)")
    }

    private func writeStringToPasteboard(_ s: String, confirmation: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        // Visible confirmation — the green banner over the magnifier's hex
        // strip is unmissable, so the user can tell the shortcut fired.
        magnifier.flashCopyConfirmation(confirmation)
    }

    // MARK: - Resize handles (annotating phase)

    private func installResizeHandles(around rect: NSRect) {
        resizeHandles.forEach { $0.removeFromSuperview() }
        resizeHandles.removeAll()

        for position in ResizeHandle.Position.allCases {
            let handle = ResizeHandle(position: position)
            handle.onDragBegan = { [weak self] in
                guard let self, let canvas = self.annotationCanvas else { return }
                self.resizeStartFrame = canvas.frame
                // Resizing changes the selection's pixel content, so any
                // cached translation no longer reflects the visible image.
                self.clearTranslationCache()
            }
            handle.onDragChanged = { [weak self] delta in
                guard let self,
                      let canvas = self.annotationCanvas,
                      let start = self.resizeStartFrame else { return }
                let newFrame = position.apply(delta: delta, to: start)
                canvas.frame = newFrame
                // Live-update the canvas's base image from the cached
                // screen snapshot so the screenshot doesn't visibly
                // stretch as the bounds change. The snapshot was taken at
                // the start of the capture session and covers the whole
                // screen, so any sub-rect can be cropped instantly.
                if let interim = self.interimImage(forLocalRect: newFrame) {
                    canvas.replaceBaseImage(interim)
                }
                self.repositionHandles(around: newFrame)
                self.repositionCancelButton(around: newFrame)
                self.repositionTranslationToggle(around: newFrame)
                self.refreshOverlayLayers()
            }
            handle.onDragEnded = { [weak self] in
                guard let self, let canvas = self.annotationCanvas else { return }
                self.resizeStartFrame = nil
                self.onResize?(canvas.frame)
            }
            addSubview(handle)
            resizeHandles.append(handle)
        }
        repositionHandles(around: rect)
    }

    func repositionHandles(around rect: NSRect) {
        for handle in resizeHandles {
            handle.frame = handle.position.frame(around: rect)
        }
    }

    func repositionTranslationToggle(around rect: NSRect) {
        translationToggleButton?.frame = translationToggleFrame(for: rect)
    }

    /// Drop the cached original/translated bitmaps and remove the toggle
    /// button. Called on resize (the underlying selection bounds changed
    /// and the cached frames no longer match) and on session dismissal.
    func clearTranslationCache() {
        originalBaseImage = nil
        translatedBaseImage = nil
        showingTranslated = false
        translationToggleButton?.removeFromSuperview()
        translationToggleButton = nil
    }

    func removeResizeHandles() {
        resizeHandles.forEach { $0.removeFromSuperview() }
        resizeHandles.removeAll()
    }

    // MARK: - Corner cancel button (annotating phase)

    private func installCancelButton(around rect: NSRect) {
        cancelButton?.removeFromSuperview()
        let button = CornerCancelButton(frame: cancelButtonFrame(for: rect))
        button.onClick = { [weak self] in self?.onCancel?() }
        addSubview(button)
        cancelButton = button
    }

    private func repositionCancelButton(around rect: NSRect) {
        cancelButton?.frame = cancelButtonFrame(for: rect)
    }

    /// Place the ✕ just above the selection's top-right corner. If the
    /// selection is too close to the top of the overlay to fit it there,
    /// dock it inside the top-right corner with enough inset that it
    /// doesn't overlap the .ne resize handle.
    private func cancelButtonFrame(for rect: NSRect) -> NSRect {
        let size: CGFloat = 26
        let gap: CGFloat = 6
        let aboveY = rect.maxY + gap
        if aboveY + size <= bounds.maxY - gap {
            return NSRect(x: rect.maxX - size, y: aboveY, width: size, height: size)
        }
        // Fallback: inside top-right, offset enough to clear the .ne handle.
        let inset: CGFloat = 8
        return NSRect(x: rect.maxX - size - inset, y: rect.maxY - size - inset,
                      width: size, height: size)
    }
}

// MARK: - Corner cancel button

/// Small ✕ button that lives at the top-right corner of the selection
/// rect during the annotating phase. Mirrors the ⎋ shortcut: clicking
/// dismisses the entire capture session.
private final class CornerCancelButton: NSView {

    var onClick: (() -> Void)?

    private var pressed = false
    private var hovering = false
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        applyVisualState()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsDefaultClipping: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        applyVisualState()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        applyVisualState()
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        applyVisualState()
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = pressed
        pressed = false
        applyVisualState()
        let local = convert(event.locationInWindow, from: nil)
        if wasPressed, bounds.contains(local) {
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Draw the ✕ glyph centered in the view. Vector-stroked so it
        // stays crisp at any backing scale.
        let inset: CGFloat = 8
        let r = bounds.insetBy(dx: inset, dy: inset)
        NSColor.white.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.8
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: r.minX, y: r.minY))
        path.line(to: NSPoint(x: r.maxX, y: r.maxY))
        path.move(to: NSPoint(x: r.minX, y: r.maxY))
        path.line(to: NSPoint(x: r.maxX, y: r.minY))
        path.stroke()
    }

    private func applyVisualState() {
        let bg: NSColor
        if pressed       { bg = NSColor.systemRed.withAlphaComponent(0.95) }
        else if hovering { bg = NSColor.systemRed.withAlphaComponent(0.80) }
        else             { bg = NSColor.black.withAlphaComponent(0.55) }
        layer?.backgroundColor = bg.cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        needsDisplay = true
    }
}

// MARK: - Resize handle

private final class ResizeHandle: NSView {

    enum Position: CaseIterable {
        case nw, n, ne, e, se, s, sw, w

        static let visualSize: CGFloat = 10

        func frame(around rect: NSRect) -> NSRect {
            let s = Self.visualSize
            let half = s / 2
            let p: NSPoint
            switch self {
            case .nw: p = NSPoint(x: rect.minX, y: rect.maxY)
            case .n:  p = NSPoint(x: rect.midX, y: rect.maxY)
            case .ne: p = NSPoint(x: rect.maxX, y: rect.maxY)
            case .e:  p = NSPoint(x: rect.maxX, y: rect.midY)
            case .se: p = NSPoint(x: rect.maxX, y: rect.minY)
            case .s:  p = NSPoint(x: rect.midX, y: rect.minY)
            case .sw: p = NSPoint(x: rect.minX, y: rect.minY)
            case .w:  p = NSPoint(x: rect.minX, y: rect.midY)
            }
            return NSRect(x: p.x - half, y: p.y - half, width: s, height: s)
        }

        /// AppKit lacks public diagonal resize cursors; fall back sensibly.
        var cursor: NSCursor {
            switch self {
            case .n, .s, .nw, .se, .ne, .sw: return .resizeUpDown
            case .e, .w:                     return .resizeLeftRight
            }
        }

        /// Apply a mouse delta (in window coords, AppKit Y-up) to a starting
        /// rect and return the new rect with the appropriate edges moved.
        func apply(delta: NSPoint, to start: NSRect) -> NSRect {
            var r = start
            switch self {
            case .nw:
                r.origin.x += delta.x
                r.size.width -= delta.x
                r.size.height += delta.y
            case .n:
                r.size.height += delta.y
            case .ne:
                r.size.width += delta.x
                r.size.height += delta.y
            case .e:
                r.size.width += delta.x
            case .se:
                r.origin.y += delta.y
                r.size.width += delta.x
                r.size.height -= delta.y
            case .s:
                r.origin.y += delta.y
                r.size.height -= delta.y
            case .sw:
                r.origin.x += delta.x
                r.size.width -= delta.x
                r.origin.y += delta.y
                r.size.height -= delta.y
            case .w:
                r.origin.x += delta.x
                r.size.width -= delta.x
            }
            // Clamp minimum so we don't invert.
            let minSize: CGFloat = 20
            if r.size.width < minSize {
                let dw = minSize - r.size.width
                r.size.width = minSize
                if self == .nw || self == .sw || self == .w {
                    r.origin.x -= dw
                }
            }
            if r.size.height < minSize {
                let dh = minSize - r.size.height
                r.size.height = minSize
                if self == .sw || self == .s || self == .se {
                    r.origin.y -= dh
                }
            }
            return r
        }
    }

    let position: Position
    var onDragBegan: (() -> Void)?
    var onDragChanged: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    private var dragStart: NSPoint?

    init(position: Position) {
        self.position = position
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        layer?.borderColor = NSColor.white.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 2
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: position.cursor)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }

        // Coalesce queued drags — match the SelectionView logic so resize
        // doesn't lag behind the cursor on high-refresh devices.
        var current = event.locationInWindow
        while let next = NSApp.nextEvent(
            matching: .leftMouseDragged,
            until: .distantPast,
            inMode: .eventTracking,
            dequeue: true
        ) {
            current = next.locationInWindow
        }
        onDragChanged?(NSPoint(x: current.x - start.x, y: current.y - start.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        onDragEnded?()
    }
}

// MARK: - Translation toggle button

/// Pill button shown above the selection rect after an in-place
/// translation has been applied. Clicking toggles between the original
/// and translated bitmaps. Always opaque/borderless so the user can spot
/// it even on busy screenshots, and small enough not to crowd the
/// selection's resize handles.
private final class TranslationToggleButton: NSView {

    var onClick: (() -> Void)?

    private let textLayer = CATextLayer()
    private let bgLayer = CALayer()
    private var hovering = false
    private var pressed = false
    private var trackingArea: NSTrackingArea?
    private var showingTranslated = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6

        bgLayer.cornerRadius = 6
        bgLayer.frame = bounds
        layer?.addSublayer(bgLayer)

        textLayer.frame = bounds
        textLayer.alignmentMode = .center
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.fontSize = 11
        textLayer.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer?.addSublayer(textLayer)

        applyVisualState()
        refreshLabel()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        bgLayer.frame = bounds
        // Vertically center the text layer, since CATextLayer aligns to
        // its frame's top-left for the baseline of the first line.
        let h = textLayer.fontSize * 1.4
        textLayer.frame = NSRect(
            x: 0,
            y: (bounds.height - h) / 2,
            width: bounds.width,
            height: h
        )
    }

    func setShowingTranslated(_ value: Bool) {
        showingTranslated = value
        refreshLabel()
    }

    private func refreshLabel() {
        textLayer.string = showingTranslated ? "Translated · Show Original" : "Original · Show Translated"
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; applyVisualState() }
    override func mouseExited(with event: NSEvent)  { hovering = false; applyVisualState() }
    override func mouseDown(with event: NSEvent)    { pressed = true; applyVisualState() }
    override func mouseUp(with event: NSEvent) {
        let wasPressed = pressed
        pressed = false
        applyVisualState()
        let local = convert(event.locationInWindow, from: nil)
        if wasPressed, bounds.contains(local) { onClick?() }
    }

    private func applyVisualState() {
        let bg: NSColor
        if pressed       { bg = NSColor.controlAccentColor.withAlphaComponent(0.95) }
        else if hovering { bg = NSColor.controlAccentColor.withAlphaComponent(0.85) }
        else             { bg = NSColor.black.withAlphaComponent(0.65) }
        bgLayer.backgroundColor = bg.cgColor
    }
}
