import AppKit
import SwiftUI

/// Manages the lifetime of the click-to-decode "mask" buttons that get
/// painted over QR / barcode regions in a freshly captured screenshot.
///
/// The detection runs asynchronously after capture handoff; on success
/// each hit gets a translucent badge added as a sibling of the canvas
/// (so it lives in the SelectionView, NOT inside the canvas — staying
/// out of the canvas means the badge isn't rasterized into the saved
/// image when the user clicks Save / Copy / Pin).
@MainActor
final class BarcodeOverlayController {

    private weak var parent: NSView?
    private var badges: [BarcodeBadge] = []
    private var popover: NSPopover?
    /// Lets us cancel a stale detection if the selection resizes mid-flight.
    private var detectionGeneration: Int = 0

    init(parent: NSView) {
        self.parent = parent
    }

    /// Optional callback fired whenever any badge's hover state changes.
    /// Set by ScreenshotManager so the SelectionView can suspend its
    /// magnifier loupe while the cursor sits over a badge — otherwise
    /// the loupe and the badge both fight for the same pixels.
    var onAnyBadgeHoverChanged: ((Bool) -> Void)?

    /// When set, overrides the default in-place popover behaviour:
    /// clicking a badge calls this handler with the hit and the QR's
    /// rect (in `parent`'s coordinate space) instead. Used by the
    /// screen-phase flow so a click can dismiss the SelectionOverlay,
    /// crop the QR region into the clipboard, and present a free-
    /// floating result panel that outlives the overlay window.
    var onClickOverride: ((BarcodeService.Hit, NSRect) -> Void)?

    /// Run async detection over `cgImage` and, on success, paint badges
    /// at the corresponding positions inside `canvasFrame` (which is
    /// expressed in the parent view's unflipped coordinate space).
    func detectAndPresent(in cgImage: CGImage, canvasFrame: NSRect) {
        clear()
        detectionGeneration += 1
        let gen = detectionGeneration
        Task { @MainActor in
            let hits = (try? await BarcodeService.detect(in: cgImage)) ?? []
            // Bail if the user resized / cancelled while we were running.
            guard gen == self.detectionGeneration, !hits.isEmpty else { return }
            self.present(hits: hits, canvasFrame: canvasFrame)
        }
    }

    func clear() {
        detectionGeneration += 1   // invalidate any in-flight detection
        popover?.close()
        popover = nil
        badges.forEach { $0.removeFromSuperview() }
        badges.removeAll()
    }

    private func present(hits: [BarcodeService.Hit], canvasFrame: NSRect) {
        guard let parent else { return }
        for hit in hits {
            // Vision normalized → parent (unflipped) coords. Both
            // coordinate systems use bottom-left origin so this is a
            // direct mapping.
            let qrRect = NSRect(
                x: canvasFrame.minX + canvasFrame.width  * hit.normalizedBox.minX,
                y: canvasFrame.minY + canvasFrame.height * hit.normalizedBox.minY,
                width:  canvasFrame.width  * hit.normalizedBox.width,
                height: canvasFrame.height * hit.normalizedBox.height
            )
            // Sized at ~80% of the QR's smaller edge so the badge
            // visibly "marks" the code while leaving a thin border
            // showing through. Clamped on both ends so tiny QRs still
            // get a usable hit target and giant QRs don't produce a
            // 400pt monstrosity.
            let smallEdge = min(qrRect.width, qrRect.height)
            let badgeSize = max(28, min(120, smallEdge * 0.8))
            let badgeFrame = NSRect(
                x: qrRect.midX - badgeSize / 2,
                y: qrRect.midY - badgeSize / 2,
                width: badgeSize,
                height: badgeSize
            )
            let badge = BarcodeBadge(frame: badgeFrame)
            if let override = onClickOverride {
                badge.onClick = {
                    override(hit, qrRect)
                }
            } else {
                badge.onClick = { [weak self, weak badge] in
                    guard let self, let badge else { return }
                    self.showPopover(for: hit, anchoredTo: badge)
                }
            }
            badge.onHoverChanged = { [weak self] hovering in
                self?.onAnyBadgeHoverChanged?(hovering)
            }
            parent.addSubview(badge)
            badges.append(badge)
        }
    }

    private func showPopover(for hit: BarcodeService.Hit, anchoredTo view: NSView) {
        popover?.close()
        let pop = NSPopover()
        pop.behavior = .transient
        let host = NSHostingController(
            rootView: BarcodePopoverContent(payload: hit.payload, dismiss: { [weak pop] in
                pop?.close()
            })
        )
        pop.contentViewController = host
        pop.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        popover = pop
    }
}

// MARK: - Badge

/// Translucent rounded-rect button that covers a detected QR / barcode.
/// Plain NSView (not NSButton) so its hit-testing and visual state are
/// fully under our control — the surrounding SelectionView has its own
/// mouseDown / drag handling that we'd otherwise interfere with.
private final class BarcodeBadge: NSView {

    var onClick: (() -> Void)?
    /// Fired with `true` on hover-enter and `false` on hover-exit.
    /// Lets the SelectionView suppress its magnifier while we're hot.
    var onHoverChanged: ((Bool) -> Void)?

    private var hovering = false
    private var trackingArea: NSTrackingArea?
    private let icon = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Rounded rect — proportional to the badge's size — works for
        // both tight (28pt) and roomy (120pt) extremes without looking
        // like a pill or a coin.
        layer?.cornerRadius = min(16, frameRect.width * 0.18)
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.32
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        layer?.shadowRadius = 4
        // Icon roughly fills the badge with a comfortable margin.
        let iconSize = frameRect.width * 0.5
        icon.image = NSImage(systemSymbolName: "qrcode", accessibilityDescription: "QR code")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: iconSize, weight: .bold
        )
        icon.contentTintColor = .white
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.frame = NSRect(
            x: (frameRect.width  - iconSize) / 2,
            y: (frameRect.height - iconSize) / 2,
            width: iconSize, height: iconSize
        )
        addSubview(icon)
        applyVisualState()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Critical for non-activating-panel hosts (the SelectionOverlayWindow
    /// is a `.nonactivatingPanel`). Without this the FIRST click on a
    /// fresh badge gets eaten by AppKit to "promote" the click target
    /// rather than delivered as a `mouseDown`, forcing the user to
    /// click twice.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        applyVisualState()
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        applyVisualState()
        onHoverChanged?(false)
    }

    /// Eats the click — do NOT call super, otherwise the SelectionView
    /// underneath would try to start a fresh selection drag.
    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func applyVisualState() {
        let bg: NSColor = hovering
            ? NSColor.controlAccentColor
            : NSColor.controlAccentColor.withAlphaComponent(0.78)
        layer?.backgroundColor = bg.cgColor
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.white.withAlphaComponent(hovering ? 0.95 : 0.6).cgColor
    }
}

// MARK: - Free-floating result panel
//
// Used by the screen-phase flow: when the user clicks a QR mask, the
// SelectionOverlay is dismissed AND this small floating panel is shown
// near the QR's old screen position. It owns its own NSWindow and
// outlives the overlay, so dismissing the capture session doesn't take
// the result with it.

@MainActor
final class BarcodeResultPanel: NSPanel {

    init(payload: String) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 320),
            // No `.fullSizeContentView` — that pushes SwiftUI content
            // up behind the traffic lights, hiding the payload header.
            // Plain `.titled` keeps the titlebar in its own region and
            // the SwiftUI content fills only the area below it.
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.title = "QR Code"
        self.titleVisibility = .visible
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.becomesKeyOnlyIfNeeded = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = true

        let host = NSHostingController(
            rootView: BarcodePopoverContent(payload: payload, dismiss: { [weak self] in
                self?.close()
            })
        )
        self.contentViewController = host

        // Make the panel grow / shrink to whatever the SwiftUI body
        // actually wants to show — without this the payload `Text` can
        // get visually clipped on long URLs because the initial
        // contentRect was a static guess.
        host.view.layoutSubtreeIfNeeded()
        let fitting = host.view.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            self.setContentSize(NSSize(
                width: max(360, fitting.width),
                height: max(220, fitting.height)
            ))
        }
    }

    /// Defensive override — Cocoa may instantiate panels via this path
    /// during window restoration.
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        self.isRestorable = false
    }

    /// Place the panel adjacent to the QR rect that triggered it
    /// (`rect` is in AppKit-global coordinates). Below if there's room,
    /// above if not, screen-center as final fallback. Always clamped
    /// inside `screen.frame` with a small margin.
    func position(near rect: NSRect, on screen: NSScreen) {
        let panelSize = self.frame.size
        let gap: CGFloat = 12

        let belowY = rect.minY - panelSize.height - gap
        let aboveY = rect.maxY + gap

        var origin = NSPoint(x: rect.midX - panelSize.width / 2, y: belowY)
        let canFitBelow = belowY >= screen.frame.minY + gap
        let canFitAbove = aboveY + panelSize.height <= screen.frame.maxY - gap
        if !canFitBelow {
            if canFitAbove {
                origin.y = aboveY
            } else {
                origin.y = screen.frame.midY - panelSize.height / 2
            }
        }

        let minX = screen.frame.minX + gap
        let maxX = screen.frame.maxX - panelSize.width - gap
        origin.x = max(minX, min(maxX, origin.x))

        self.setFrameOrigin(origin)
    }
}

// MARK: - Popover content

fileprivate struct BarcodePopoverContent: View {

    let payload: String
    let dismiss: () -> Void

    private var openableURL: URL? { BarcodeService.openableURL(from: payload) }

    /// Distinguishes URL payloads from arbitrary text so the content
    /// area can render URLs as clickable links AND show the raw string
    /// — both views surface in the panel.
    private var isURL: Bool { openableURL != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: isURL ? "link.circle.fill" : "qrcode.viewfinder")
                    .foregroundStyle(isURL ? Color.accentColor : .secondary)
                Text(isURL ? "Link" : "QR / Barcode content")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                Spacer()
            }

            // Payload box — same place a URL preview would go in any
            // mailer-style UI. ScrollView so multi-line text + tall
            // QR contents (vCards, JSON, Wi-Fi configs) don't blow
            // the panel out vertically.
            ScrollView {
                Text(payload)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(minHeight: 80, idealHeight: 110, maxHeight: 200)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
            )

            HStack(spacing: 8) {
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(payload, forType: .string)
                    dismiss()
                } label: {
                    Label(isURL ? "Copy Link" : "Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("c", modifiers: [.command])

                if let url = openableURL {
                    Button {
                        NSWorkspace.shared.open(url)
                        dismiss()
                    } label: {
                        Label("Open in Browser", systemImage: "safari")
                    }
                    .keyboardShortcut(.return)
                }

                Spacer()

                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(minWidth: 360, idealWidth: 400)
    }
}
