// Picture Editor disabled — feature is not mature yet.
#if false
import AppKit
import CoreImage
import SwiftUI

/// Free-zoom canvas. Hosts an `NSImageView` inside an `NSScrollView` so
/// users get the full macOS pinch-to-zoom + pan experience that SwiftUI's
/// own `ScrollView` doesn't offer on the desktop.
///
/// Why we wrap NSScrollView ourselves instead of grabbing `advanced-scrollview`:
/// the editor needs *just* magnification + a single image — no infinite
/// canvas, no per-document zoom state. Pulling in a SwiftPM dependency for
/// 30 lines of NSScrollView config wasn't a good trade.
///
/// Coordination contract:
///   - SwiftUI owns the source of truth (`image`, `desiredZoom`).
///   - The Coordinator pushes the latest CIImage into the NSImageView and
///     applies any zoom command that arrived via `desiredZoom`.
///   - Magnification driven by the user (pinch / ⌘+ / ⌘-) is read back
///     into the `currentZoom` binding so the toolbar can show the % label.
struct ZoomableImageView: NSViewRepresentable {

    /// The image to display. CIImage is rendered to a CGImage via the
    /// shared context so the NSImageView shows native pixels.
    let image: CIImage
    let context: CIContext

    /// Read-back of the current scrollview magnification. Updated whenever
    /// the user zooms.
    @Binding var currentZoom: CGFloat

    /// One-shot zoom commands. SwiftUI sets the value, the coordinator
    /// applies it on the next `updateNSView`, then resets it to nil.
    @Binding var zoomCommand: ZoomCommand?

    enum ZoomCommand: Equatable {
        case fit
        case actualSize
        case zoomIn
        case zoomOut
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 16.0
        scrollView.magnification = 1.0
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(white: 0.93, alpha: 1.0)
        scrollView.autohidesScrollers = true
        scrollView.usesPredominantAxisScrolling = false

        let imageView = NSImageView()
        // .scaleNone: never resample — the scroll view's magnification IS
        // the zoom, so the underlying image stays at native pixel density
        // even at 800% zoom. The blurry "low-res" look the v1 build had
        // was scaleProportionallyUpOrDown bilinear-scaling everything.
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = true
        scrollView.documentView = imageView

        // Listen for live magnification from the user (pinch / ⌘+) and
        // mirror it back into the SwiftUI binding so the toolbar can show
        // a "120%" label without a polling loop.
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.didEndLiveMagnify(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView
        )

        // Also watch end-magnify (the smooth animation finished) so a
        // double-tap zoom or programmatic zoom updates the binding too.
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.willStartLiveMagnify(_:)),
            name: NSScrollView.willStartLiveMagnifyNotification,
            object: scrollView
        )

        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let imageView = scrollView.documentView as? NSImageView else { return }

        // Re-render the CIImage to a CGImage on every change. CIContext is
        // shared so the GPU stays warm — re-creating it would be the win
        // we didn't need on a single-image editor.
        let extent = image.extent
        if let cg = context.coordinator.makeCGImage(from: image,
                                                    using: self.context) {
            let ns = NSImage(cgImage: cg, size: NSSize(width: extent.width, height: extent.height))
            imageView.image = ns
            // Resize the documentView to match the image's pixel size.
            // The scroll view will then drive zoom on top of this.
            imageView.frame = NSRect(origin: .zero, size: NSSize(width: extent.width, height: extent.height))
        }

        // Honor any pending zoom command. We zero it out via the binding
        // so the same command doesn't fire repeatedly on subsequent
        // SwiftUI updates.
        if let cmd = zoomCommand {
            context.coordinator.applyZoomCommand(cmd)
            DispatchQueue.main.async { self.zoomCommand = nil }
        }

        // First-time setup: when the image is newly loaded (or replaced
        // with a different-sized one), default to fit-to-window so the
        // user always starts seeing the whole picture.
        if context.coordinator.lastImageExtent != extent {
            context.coordinator.lastImageExtent = extent
            DispatchQueue.main.async {
                context.coordinator.applyZoomCommand(.fit)
            }
        }
    }

    final class Coordinator: NSObject {
        var parent: ZoomableImageView
        weak var scrollView: NSScrollView?
        weak var imageView: NSImageView?
        var lastImageExtent: CGRect = .zero

        init(parent: ZoomableImageView) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func makeCGImage(from ciImage: CIImage, using context: CIContext) -> CGImage? {
            context.createCGImage(ciImage, from: ciImage.extent)
        }

        @objc func willStartLiveMagnify(_ note: Notification) {}

        @objc func didEndLiveMagnify(_ note: Notification) {
            guard let scrollView = note.object as? NSScrollView else { return }
            DispatchQueue.main.async {
                self.parent.currentZoom = scrollView.magnification
            }
        }

        func applyZoomCommand(_ cmd: ZoomCommand) {
            guard let scrollView = scrollView,
                  let imageView = imageView,
                  imageView.image != nil else { return }

            switch cmd {
            case .fit:
                fitToWindow(scrollView: scrollView, imageView: imageView)
            case .actualSize:
                scrollView.magnification = 1.0
                centerInScrollView(scrollView, imageSize: imageView.bounds.size)
                parent.currentZoom = 1.0
            case .zoomIn:
                let next = min(scrollView.magnification * 1.25, scrollView.maxMagnification)
                scrollView.animator().magnification = next
                parent.currentZoom = next
            case .zoomOut:
                let next = max(scrollView.magnification / 1.25, scrollView.minMagnification)
                scrollView.animator().magnification = next
                parent.currentZoom = next
            }
        }

        private func fitToWindow(scrollView: NSScrollView, imageView: NSImageView) {
            let imageSize = imageView.bounds.size
            let containerSize = scrollView.contentView.bounds.size
            guard imageSize.width > 0, imageSize.height > 0,
                  containerSize.width > 0, containerSize.height > 0 else { return }
            let scaleX = containerSize.width / imageSize.width
            let scaleY = containerSize.height / imageSize.height
            let fit = min(scaleX, scaleY)
            scrollView.magnification = fit
            centerInScrollView(scrollView, imageSize: imageSize)
            parent.currentZoom = fit
        }

        private func centerInScrollView(_ scrollView: NSScrollView, imageSize: CGSize) {
            let visibleSize = scrollView.contentView.bounds.size
            let originX = max(0, (imageSize.width  - visibleSize.width / scrollView.magnification) / 2)
            let originY = max(0, (imageSize.height - visibleSize.height / scrollView.magnification) / 2)
            scrollView.contentView.scroll(to: NSPoint(x: originX, y: originY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

#endif
