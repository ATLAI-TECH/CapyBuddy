import AppKit
import CoreGraphics
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ScreenshotManager {

    private var overlayWindows: [SelectionOverlayWindow] = []
    private var pinnedWindows: [PinnedImageWindow] = []
    private var toolbar: AnnotationToolbarPanel?
    private var toolbarModel: AnnotationToolbarModel?
    private var configPanel: AnnotationConfigPanel?
    private var configModel: AnnotationConfigModel?
    private var activeOverlay: SelectionOverlayWindow?
    private var activeScreen: NSScreen?
    /// Result panel for OCR / Translate. Held weakly so it can be torn
    /// down on capture-session dismissal even if the user left it open.
    private var extractPanel: ExtractResultPanel?
    /// Owns the auto-detected QR / barcode "mask" buttons that get
    /// overlaid on top of the selection's canvas. Cleared on dismiss
    /// AND on resize (the captured image shifts, so old hits are stale).
    private var barcodeOverlay: BarcodeOverlayController?
    /// Per-screen badge controllers active during the SELECTING phase —
    /// they paint mask buttons on top of the dimmed full-screen overlay
    /// the moment the snapshots come back, so the user can scan a QR
    /// without ever drawing a selection rect. Replaced by
    /// `barcodeOverlay` once the user commits a selection.
    private var screenPhaseBarcodeOverlays: [BarcodeOverlayController] = []
    /// Local NSEvent monitor that catches ESC at the app level whenever
    /// a capture session is up. Belt-and-braces over the SelectionView /
    /// canvas keyDown handlers — those rely on first-responder routing,
    /// which a dismissed popover or stray SwiftUI focus can disrupt.
    /// With the monitor, ESC dismisses the session no matter where
    /// keyboard focus currently sits.
    private var escMonitor: Any?
    /// True from the moment captureRegion() is called until the Task's
    /// first await resumes and overlayWindows is populated. Prevents a
    /// second hotkey event from starting a second session in that window.
    private var isCapturing = false
    /// Free-floating popover shown after the user clicks a screen-phase
    /// QR badge. Lives outside the SelectionOverlayWindow so the QR
    /// result remains on screen after the capture session is dismissed.
    private var barcodeResultPanel: BarcodeResultPanel?

    func captureRegion() {
        guard overlayWindows.isEmpty, !isCapturing else { return }
        isCapturing = true

        if !PermissionChecker.isScreenRecordingGranted() {
            PermissionChecker.requestScreenRecording()
        }

        // Close any leftover QR result panel from a previous click —
        // starting a new capture always means the user is moving on.
        barcodeResultPanel?.close()
        barcodeResultPanel = nil

        installESCMonitor()

        // We deliberately do NOT call `NSApp.activate(ignoringOtherApps:)`
        // here — that triggers a visible app-switch flash (focus indicator
        // changes on the previously-active window, menu bar swap, etc.) at
        // the very moment the user expects the screen to "freeze".
        // Instead the overlay is an `NSPanel` with `.nonactivatingPanel`
        // so it becomes key without activating us; combined with
        // `acceptsFirstMouse = true` on the SelectionView, it captures
        // both mouse and keyboard from frame 0.

        let screens = NSScreen.screens

        // Snapshot ALL screens first (in parallel for multi-monitor) so the
        // capture is taken with the screen state untouched — context menus
        // and other transient UI are still visible. The snapshot doubles as
        // (a) the overlay's frozen backdrop and (b) the magnifier's pixel
        // source. SCK's `captureImage` is async; the overlays go up the
        // moment the snapshots return, mirroring the sync legacy timing
        // from a user-perception standpoint.
        Task { @MainActor in
            let snapshots = await Self.captureAllScreens(screens)
            isCapturing = false   // overlayWindows is about to be populated

            // Snapshot the on-screen window list ONCE per capture session,
            // BEFORE the overlay panels order front. Filtering by our
            // own PID also keeps any leftover pinned screenshots /
            // toolbars from showing up as snap candidates.
            let snappableWindows = WindowHitTester.snapshot()

            for (index, screen) in screens.enumerated() {
                let window = SelectionOverlayWindow(
                    screen: screen,
                    onSelect: { [weak self] globalRect in
                        self?.handleSelection(globalRect, screen: screen)
                    },
                    onCancel: { [weak self] in
                        self?.dismissCaptureSession()
                    }
                )
                if let snap = snapshots[index] {
                    window.selectionView.setScreenSnapshot(snap, screenSizeInPoints: screen.frame.size)
                }
                window.selectionView.setSnappableWindows(snappableWindows)
                overlayWindows.append(window)
                window.makeKeyAndOrderFront(nil)

                // Kick off QR detection against the freshly-taken snapshot
                // BEFORE the user does anything — badges materialize over
                // any QR the moment Vision finishes (~100-300ms typical).
                if let snap = snapshots[index] {
                    let selectionView = window.selectionView
                    let controller = BarcodeOverlayController(parent: selectionView)
                    controller.onAnyBadgeHoverChanged = { [weak selectionView] hovering in
                        selectionView?.setMagnifierSuppressed(hovering)
                    }
                    // Click on a screen-phase badge bypasses the embedded
                    // popover and triggers the "default screenshot" path:
                    // crop the QR region into the clipboard, dismiss the
                    // capture session entirely, and float the payload
                    // result on its own. No more dim/magnifier conflict.
                    let snapForClick: CGImage = snap
                    let windowForClick: SelectionOverlayWindow = window
                    let screenForClick: NSScreen = screen
                    controller.onClickOverride = { [weak self] hit, qrLocalRect in
                        guard let self else { return }
                        let qrGlobalRect = NSRect(
                            x: windowForClick.frame.origin.x + qrLocalRect.origin.x,
                            y: windowForClick.frame.origin.y + qrLocalRect.origin.y,
                            width: qrLocalRect.width,
                            height: qrLocalRect.height
                        )
                        self.handleScreenPhaseQRClick(
                            hit: hit,
                            qrGlobalRect: qrGlobalRect,
                            snapshot: snapForClick,
                            screen: screenForClick
                        )
                    }
                    let canvasFrame = NSRect(origin: .zero, size: screen.frame.size)
                    controller.detectAndPresent(in: snap, canvasFrame: canvasFrame)
                    screenPhaseBarcodeOverlays.append(controller)
                }
            }
        }
    }

    // MARK: - Selection → annotation handoff

    private func handleSelection(_ globalRect: NSRect, screen: NSScreen) {
        guard let overlay = overlayWindows.first(where: { $0.owningScreen === screen }) else {
            dismissCaptureSession()
            return
        }

        // Close overlays on other screens — user has committed to one.
        for w in overlayWindows where w !== overlay {
            w.orderOut(nil)
        }
        overlayWindows = [overlay]
        activeOverlay = overlay
        activeScreen = screen

        // The full-screen QR badges from the selecting phase are stale
        // now: their parent SelectionViews are about to flip into
        // annotating phase (which adds the canvas) and their hit boxes
        // were measured against the full screen, not the cropped region.
        // The canvas-phase auto-detect below paints fresh badges on top
        // of the captured image.
        clearScreenPhaseBarcodeOverlays()

        // Convert global → overlay-local coords (overlay frame is whole screen).
        let localRect = NSRect(
            x: globalRect.origin.x - overlay.frame.origin.x,
            y: globalRect.origin.y - overlay.frame.origin.y,
            width: globalRect.width,
            height: globalRect.height
        )

        // Crop from the snapshot taken BEFORE the overlay appeared. Re-
        // capturing here would lose any transient UI (right-click menus,
        // tooltips, autocomplete popups) that the system dismissed the
        // moment our overlay panel became key.
        guard let baseImage = overlay.selectionView.interimImage(forLocalRect: localRect) else {
            NSLog("[CapyBuddy] Screenshot: capture failed (Screen Recording permission required).")
            dismissCaptureSession()
            return
        }

        let canvas = AnnotationCanvasView(image: baseImage, frame: localRect)
        overlay.selectionView.enterAnnotation(rect: localRect, canvas: canvas)

        overlay.selectionView.onResize = { [weak self] newLocalRect in
            self?.handleResize(newLocalRect: newLocalRect)
        }

        presentToolbar(adjacentTo: globalRect, on: screen, canvas: canvas)
        autoDetectBarcodes(in: baseImage, canvasFrame: localRect, parent: overlay.selectionView)
    }

    /// Kick off async QR / barcode detection on the freshly captured
    /// region. The overlay controller paints translucent click-targets
    /// over each hit; clicking opens a popover with the payload + Copy
    /// / Open actions.
    private func autoDetectBarcodes(in baseImage: NSImage, canvasFrame: NSRect, parent: NSView) {
        guard let cgImage = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let controller = BarcodeOverlayController(parent: parent)
        barcodeOverlay = controller
        controller.detectAndPresent(in: cgImage, canvasFrame: canvasFrame)
    }

    private func clearScreenPhaseBarcodeOverlays() {
        screenPhaseBarcodeOverlays.forEach { $0.clear() }
        screenPhaseBarcodeOverlays.removeAll()
    }

    // MARK: - Screen-phase QR click → auto-screenshot + floating result

    private func handleScreenPhaseQRClick(
        hit: BarcodeService.Hit,
        qrGlobalRect: NSRect,
        snapshot: CGImage,
        screen: NSScreen
    ) {
        // Crop the QR region from the original snapshot and put it on
        // the pasteboard — that's the "default screenshot" the user
        // expects when they click the mask.
        if let cropped = Self.cropToNormalizedBox(image: snapshot, normalizedBox: hit.normalizedBox) {
            let nsImage = NSImage(cgImage: cropped, size: qrGlobalRect.size)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([nsImage])
        }
        // Tear the capture UI down BEFORE showing the floating panel,
        // so the dim/magnifier disappear immediately and the panel
        // appears on a clean screen.
        dismissCaptureSession()
        presentBarcodeResultPanel(payload: hit.payload, near: qrGlobalRect, on: screen)
    }

    /// Vision normalized box → CGImage pixel-space crop. Vision uses a
    /// bottom-left origin while `CGImage.cropping(to:)` expects
    /// top-left, so the y axis is flipped.
    private static func cropToNormalizedBox(image: CGImage, normalizedBox: CGRect) -> CGImage? {
        let pixelW = CGFloat(image.width)
        let pixelH = CGFloat(image.height)
        let cropRect = CGRect(
            x: normalizedBox.minX * pixelW,
            y: (1 - normalizedBox.maxY) * pixelH,
            width: normalizedBox.width * pixelW,
            height: normalizedBox.height * pixelH
        ).integral
        return image.cropping(to: cropRect)
    }

    private func presentBarcodeResultPanel(payload: String, near rect: NSRect, on screen: NSScreen) {
        barcodeResultPanel?.close()
        let panel = BarcodeResultPanel(payload: payload)
        panel.position(near: rect, on: screen)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        barcodeResultPanel = panel
    }

    // MARK: - Capture-session key catcher

    private func installESCMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.overlayWindows.isEmpty else { return event }
            // 53 = ESC. Consume only when a capture session is alive —
            // we don't want to swallow ESC for other parts of the app
            // if a stale monitor somehow survives.
            if event.keyCode == 53 {
                self.dismissCaptureSession()
                return nil
            }
            // Snipaste-style colour pick during the selecting phase. The
            // overlay's window-level `keyDown` only fires on whichever panel
            // is key (the last one created across multiple screens) and is
            // unreliable for a background non-activating panel, so we route
            // c/r here — the monitor receives the event regardless of which
            // overlay is key. Skip when a modifier is held so ⌘C etc. pass
            // through untouched.
            let mods = event.modifierFlags.intersection([.command, .control, .option])
            if mods.isEmpty, let ch = event.charactersIgnoringModifiers?.lowercased(),
               ch == "c" || ch == "r",
               let overlay = self.overlayUnderCursor(), overlay.selectionView.isSelectingPhase {
                if ch == "c" {
                    overlay.selectionView.copyCursorPixelHex()
                } else {
                    overlay.selectionView.copyCursorPixelRGB()
                }
                return nil
            }
            return event
        }
    }

    /// The overlay whose screen currently contains the mouse — the one whose
    /// magnifier is sampling the pixel the user is pointing at.
    private func overlayUnderCursor() -> SelectionOverlayWindow? {
        let mouse = NSEvent.mouseLocation
        return overlayWindows.first { $0.frame.contains(mouse) }
    }

    private func removeESCMonitor() {
        if let m = escMonitor {
            NSEvent.removeMonitor(m)
            escMonitor = nil
        }
    }

    private func handleResize(newLocalRect: NSRect) {
        guard let overlay = activeOverlay,
              let screen = activeScreen else { return }
        let newGlobalRect = NSRect(
            x: overlay.frame.origin.x + newLocalRect.origin.x,
            y: overlay.frame.origin.y + newLocalRect.origin.y,
            width: newLocalRect.width,
            height: newLocalRect.height
        )
        // The live drag already swapped the canvas image via `interimImage`;
        // nothing more to do for pixels — just reposition the toolbar.
        toolbar?.position(adjacentTo: newGlobalRect, on: screen)
        // The badges were positioned against the OLD canvas frame and
        // referenced the OLD image content; both are stale after resize.
        // Drop them — re-detection on resize is intentionally skipped to
        // avoid flicker during continuous dragging.
        barcodeOverlay?.clear()
    }

    private func presentToolbar(adjacentTo selectionRect: NSRect, on screen: NSScreen, canvas: AnnotationCanvasView) {
        let model = AnnotationToolbarModel()

        // Restore the user's last picks across capture sessions so the second
        // screenshot remembers their tool / colour / stroke from the first.
        let prefs = AnnotationPrefsStore.shared
        model.currentTool        = prefs.tool
        model.currentColor       = prefs.color
        model.currentStrokeWidth = prefs.strokeWidth
        model.textStyle          = prefs.textStyle

        // Restore last-used sub-tool per group so re-clicking a group icon
        // brings back the variant the user actually wants.
        var lastByGroup: [ToolGroup: AnnotationTool] = [:]
        for group in ToolGroup.allCases {
            lastByGroup[group] = prefs.lastTool(in: group)
        }
        // Make sure the currently active tool is reflected in its group's slot.
        lastByGroup[model.currentTool.group] = model.currentTool
        model.lastByGroup = lastByGroup

        canvas.currentTool        = model.currentTool
        canvas.currentColor       = model.currentColor
        canvas.currentStrokeWidth = model.currentStrokeWidth.rawValue
        canvas.currentTextStyle   = model.textStyle

        model.onToolChange = { [weak canvas] tool in
            canvas?.currentTool = tool
            AnnotationPrefsStore.shared.tool = tool
            AnnotationPrefsStore.shared.setLastTool(tool, in: tool.group)
        }
        model.onColorChange = { [weak canvas] color in
            canvas?.currentColor = color
            AnnotationPrefsStore.shared.color = color
        }
        model.onStrokeWidthChange = { [weak canvas] width in
            canvas?.currentStrokeWidth = width.rawValue
            AnnotationPrefsStore.shared.strokeWidth = width
        }
        model.onTextStyleChange = { [weak canvas] style in
            canvas?.currentTextStyle = style
            AnnotationPrefsStore.shared.textStyle = style
        }
        model.onUndo = { [weak canvas] in
            canvas?.undoLast()
        }
        model.onPin    = { [weak self] in self?.commit(.pin) }
        model.onCopy   = { [weak self] in self?.commit(.copy) }
        model.onSave   = { [weak self] in self?.commit(.save) }
        model.onOCR    = { [weak self] in self?.presentExtractPanel() }
        // In-place translation: render the canvas, push it as the source
        // bitmap on the toolbar model, kick the SwiftUI translationTask
        // by mutating `translationConfig`. The result lands back in
        // `onTranslatedImageReady` and is painted directly onto the
        // canvas — no separate panel.
        model.onTranslate = { [weak self, weak canvas] in
            guard let self,
                  let canvas,
                  let cg = canvas.renderToImage(),
                  let m = self.toolbarModel else { return }
            m.sourceCGImage = cg
            m.startInPlaceTranslation()
        }
        model.onTranslatedImageReady = { [weak self] cg in
            guard let self,
                  let overlay = self.activeOverlay else { return }
            overlay.selectionView.applyTranslatedImage(cg)
        }

        // Keyboard shortcuts dispatched from the canvas (it's the first responder
        // since the toolbar panel is non-activating).
        canvas.onPin    = { [weak self] in self?.commit(.pin) }
        canvas.onCopy   = { [weak self] in self?.commit(.copy) }
        canvas.onSave   = { [weak self] in self?.commit(.save) }
        canvas.onCancel = { [weak self] in self?.dismissCaptureSession() }

        let panel = AnnotationToolbarPanel(model: model)
        panel.position(adjacentTo: selectionRect, on: screen)
        panel.orderFront(nil)

        self.toolbar = panel
        self.toolbarModel = model

        // --- Per-annotation config popover ---
        let cfgModel = AnnotationConfigModel()
        let cfg = AnnotationConfigPanel(model: cfgModel)

        // Edits in the popover write back to the selected annotation AND
        // update the persisted defaults so the next draw inherits them.
        cfgModel.onColorChange = { [weak self, weak canvas] color in
            canvas?.updateSelectedAnnotation { $0.color = color }
            canvas?.currentColor = color
            self?.toolbarModel?.currentColor = color
            AnnotationPrefsStore.shared.color = color
        }
        cfgModel.onStrokeChange = { [weak self, weak canvas] width in
            canvas?.updateSelectedAnnotation { $0.strokeWidth = width.rawValue }
            canvas?.currentStrokeWidth = width.rawValue
            self?.toolbarModel?.currentStrokeWidth = width
            AnnotationPrefsStore.shared.strokeWidth = width
        }
        cfgModel.onTextStyleChange = { [weak self, weak canvas] style in
            canvas?.updateSelectedAnnotation { annot in
                if case .text(let origin, let str, _) = annot.geometry {
                    annot.geometry = .text(origin: origin, string: str, style: style)
                }
            }
            canvas?.currentTextStyle = style
            self?.toolbarModel?.textStyle = style
            AnnotationPrefsStore.shared.textStyle = style
        }

        canvas.onSelectionChange = { [weak self, weak canvas] annotation in
            self?.handleSelectionChange(annotation, canvas: canvas, screen: screen)
        }
        canvas.onSelectionGeometryChange = { [weak self] annotation in
            self?.repositionConfigPanel(for: annotation, screen: screen)
        }

        self.configPanel = cfg
        self.configModel = cfgModel
    }

    private func handleSelectionChange(_ annotation: Annotation?, canvas: AnnotationCanvasView?, screen: NSScreen) {
        guard let annotation, canvas != nil, let cfg = configPanel, let cfgModel = configModel else {
            configPanel?.orderOut(nil)
            return
        }
        cfgModel.loadFromAnnotation(annotation)
        repositionConfigPanel(for: annotation, screen: screen)
        if !cfg.isVisible { cfg.orderFront(nil) }
    }

    private func repositionConfigPanel(for annotation: Annotation, screen: NSScreen) {
        guard let cfg = configPanel,
              let overlay = activeOverlay,
              let canvas = overlay.selectionView.annotationCanvas else { return }

        // Convert annotation's canvas-local bbox → global AppKit coords.
        // Canvas is `isFlipped = true` (top-left origin) so we mirror y.
        let bb = annotation.boundingBoxImmutable
        let canvasFrame = canvas.frame
        let yInOverlay = canvasFrame.maxY - bb.maxY
        let globalRect = NSRect(
            x: overlay.frame.origin.x + canvasFrame.minX + bb.minX,
            y: overlay.frame.origin.y + yInOverlay,
            width: bb.width,
            height: bb.height
        )
        cfg.position(adjacentTo: globalRect, on: screen)
    }

    // MARK: - OCR / Translate
    //
    // OCR (text extraction) still uses a side panel — the user explicitly
    // wants to read / copy the recognized text, so a dedicated surface
    // makes sense. Translation is *in-place*: it lives in the toolbar's
    // SwiftUI host (`AnnotationToolbarView.translationTask(...)`) and
    // paints the rendered bitmap directly onto the canvas. There's no
    // separate translation panel anymore.

    /// Bring up the OCR text panel anchored to the current selection.
    /// Re-uses an existing panel if one's already up.
    private func presentExtractPanel() {
        guard let overlay = activeOverlay,
              let screen = activeScreen,
              let canvas = overlay.selectionView.annotationCanvas,
              let cgImage = canvas.renderToImage() else {
            return
        }

        let canvasFrame = canvas.frame
        let globalRect = NSRect(
            x: overlay.frame.origin.x + canvasFrame.minX,
            y: overlay.frame.origin.y + canvasFrame.minY,
            width: canvasFrame.width,
            height: canvasFrame.height
        )

        let viewModel = ExtractResultViewModel(
            runOCR: { try await OCRService.recognizedString(in: cgImage) }
        )
        let panel: ExtractResultPanel
        if let existing = extractPanel {
            panel = existing
            panel.contentViewController = NSHostingController(
                rootView: ExtractResultView(viewModel: viewModel)
            )
        } else {
            panel = ExtractResultPanel(viewModel: viewModel)
            extractPanel = panel
        }
        panel.position(adjacentTo: globalRect, on: screen)
        panel.orderFront(nil)
    }

    // MARK: - Commit

    private enum CommitAction { case pin, copy, save }

    private func commit(_ action: CommitAction) {
        guard let overlay = activeOverlay,
              let canvas = overlay.selectionView.annotationCanvas,
              let cgImage = canvas.renderToImage() else {
            dismissCaptureSession()
            return
        }

        let canvasFrame = canvas.frame
        let globalAnchor = NSPoint(
            x: overlay.frame.origin.x + canvasFrame.minX,
            y: overlay.frame.origin.y + canvasFrame.minY
        )
        let nsImage = NSImage(cgImage: cgImage, size: canvasFrame.size)

        // `cgImage` is backed by the canvas's cached bitmap rep
        // (`bitmapImageRepForCachingDisplay`), whose pixel storage dies with
        // the canvas. `pb.writeObjects([nsImage])` registers a LAZY pasteboard
        // entry — the bytes aren't read until something pastes. If we dismiss
        // first, the paste lands on garbage. Materialise PNG bytes upfront
        // (while the cached rep is still alive) and write the data directly.
        var copyPNG: Data? = nil
        if action == .copy {
            copyPNG = NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .png, properties: [:])
        }

        // Tear down the capture UI before doing anything else so a save panel
        // doesn't render on top of the dimmed overlay.
        dismissCaptureSession()

        switch action {
        case .pin:
            let pin = PinnedImageWindow(image: nsImage, anchor: globalAnchor)
            pinnedWindows.append(pin)
            pin.onClose = { [weak self, weak pin] in
                self?.pinnedWindows.removeAll { $0 === pin }
            }
            pin.orderFront(nil)

        case .copy:
            let pb = NSPasteboard.general
            pb.clearContents()
            if let copyPNG {
                // PNG covers virtually every paste target; we also publish
                // TIFF since some older AppKit apps key off `.tiff` only.
                pb.setData(copyPNG, forType: .png)
                pb.setData(copyPNG, forType: .tiff)
            } else {
                pb.writeObjects([nsImage])
            }

        case .save:
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = Self.defaultSaveFilename()
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard let tiff = nsImage.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: url)
        }
    }

    /// Default name for the Save dialog. Mirrors the macOS native screenshot
    /// pattern (timestamped) so saving multiple in a row doesn't ask the
    /// user to invent unique names. Format:
    ///   `CapyBuddyScreenshot 2026-05-05 at 11.30.45.png`
    private static func defaultSaveFilename() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "CapyBuddyScreenshot \(f.string(from: Date())).png"
    }

    private func dismissCaptureSession() {
        isCapturing = false
        for w in overlayWindows {
            w.orderOut(nil)
        }
        overlayWindows.removeAll()
        toolbar?.orderOut(nil)
        toolbar = nil
        toolbarModel = nil
        configPanel?.orderOut(nil)
        configPanel = nil
        configModel = nil
        extractPanel?.orderOut(nil)
        extractPanel = nil
        barcodeOverlay?.clear()
        barcodeOverlay = nil
        clearScreenPhaseBarcodeOverlays()
        removeESCMonitor()
        activeOverlay = nil
        activeScreen = nil
    }

    // MARK: - Capture (ScreenCaptureKit)
    //
    // Replaces the macOS 14-deprecated `CGWindowListCreateImage` calls.
    // SCK is fully async; all callers have been wrapped in `Task { @MainActor }`
    // so the main thread never blocks on capture.

    /// Capture every screen concurrently. Returns one `CGImage?` per
    /// input screen at native pixel resolution (or `nil` if that screen's
    /// capture failed — e.g. permission denied).
    @MainActor
    private static func captureAllScreens(_ screens: [NSScreen]) async -> [CGImage?] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        ) else {
            return Array(repeating: nil, count: screens.count)
        }
        return await withTaskGroup(of: (Int, CGImage?).self) { group in
            for (i, screen) in screens.enumerated() {
                let spec = ScreenCaptureSpec(screen: screen)
                group.addTask {
                    let img = await captureFullDisplay(spec: spec, content: content, excludingWindow: nil)
                    return (i, img)
                }
            }
            var out = [CGImage?](repeating: nil, count: screens.count)
            for await (i, img) in group {
                out[i] = img
            }
            return out
        }
    }

    /// Match the SCDisplay corresponding to `spec` and capture it,
    /// optionally telling SCK to omit a single window (our overlay).
    /// Output dimensions come from `SCContentFilter.pointPixelScale` —
    /// the SCK-canonical points→pixels factor — instead of
    /// `NSScreen.backingScaleFactor`, which lies on scaled display modes.
    nonisolated private static func captureFullDisplay(
        spec: ScreenCaptureSpec,
        content: SCShareableContent,
        excludingWindow overlayID: CGWindowID?
    ) async -> CGImage? {
        guard let scDisplay = content.displays.first(where: { $0.displayID == spec.displayID }) else {
            return nil
        }
        let excluded: [SCWindow]
        if let overlayID {
            excluded = content.windows.filter { $0.windowID == overlayID }
        } else {
            excluded = []
        }
        // Use the `excludingApplications:exceptingWindows:` filter form
        // instead of `excludingWindows:`. Both are documented to include the
        // desktop + dock, but on macOS Tahoe the latter strips window drop
        // shadows from the captured image (verified by dumping the raw
        // SCK output). The application-form goes through a different
        // compositing path that preserves WindowServer shadows.
        let filter = SCContentFilter(
            display: scDisplay,
            excludingApplications: [],
            exceptingWindows: excluded
        )
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        // Match the legacy `[.bestResolution]` flag — the captured frame
        // should be 1:1 with the configured output, no scaling.
        config.scalesToFit = false
        // SDR app, default 8-bit BGRA is what `CGWindowListCreateImage`
        // produced. Wide-gamut/HDR captures can be added later behind a
        // pref if anyone asks.
        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
        } catch {
            NSLog("[CapyBuddy] Screenshot: SCK capture failed: \(error)")
            return nil
        }
    }
}

/// Sendable snapshot of the NSScreen-derived values we need inside the
/// nonisolated capture path. NSScreen itself is not Sendable, so we
/// pre-compute everything on the main actor and pass this struct across.
private struct ScreenCaptureSpec: Sendable {
    let displayID: CGDirectDisplayID
    let frameOriginX: CGFloat
    let frameOriginY: CGFloat
    let frameWidth: CGFloat
    let frameHeight: CGFloat

    @MainActor
    init(screen: NSScreen) {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                  as? CGDirectDisplayID) ?? 0
        self.displayID = id
        self.frameOriginX = screen.frame.origin.x
        self.frameOriginY = screen.frame.origin.y
        self.frameWidth = screen.frame.width
        self.frameHeight = screen.frame.height
    }
}
