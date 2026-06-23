import AppKit
import ScreenCaptureKit

/// What the user picked from the Zoom-style mode chooser. The follow-up
/// target-selection (display, application, region rect) happens after the
/// mode is chosen.
enum RecordingMode: String, CaseIterable, Identifiable {
    case fullScreen
    case application
    case region

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fullScreen:  return "Full Screen"
        case .application: return "Application"
        case .region:      return "Portion of Screen"
        }
    }

    var shortLabel: String {
        switch self {
        case .fullScreen:  return "Screen"
        case .application: return "App"
        case .region:      return "Region"
        }
    }

    var description: String {
        switch self {
        case .fullScreen:  return "Capture an entire display."
        case .application: return "Capture every window of one app. Region locks at start."
        case .region:      return "Drag to select an area."
        }
    }

    var iconSystemName: String {
        switch self {
        case .fullScreen:  return "display"
        case .application: return "macwindow.on.rectangle"
        case .region:      return "selection.pin.in.out"
        }
    }
}

/// Concrete capture target produced by `RecordingTargetPicker`. Drives the
/// `SCContentFilter` + `SCStreamConfiguration.sourceRect` setup in the engine.
enum RecordingTarget {
    case display(SCDisplay)
    /// Capture all windows of one app, limited to `display` (SCContentFilter
    /// is per-display; cross-display app capture isn't a thing in SCK). The
    /// `boundingRect` is the union of the app's visible windows on
    /// `display`, in AppKit screen-local coordinates (lower-left origin,
    /// points) — same convention as `.region`. The engine uses this as
    /// `SCStreamConfiguration.sourceRect` to crop out the black backdrop
    /// SCK otherwise leaves around the app's pixels.
    case application(display: SCDisplay, application: SCRunningApplication, boundingRect: CGRect)
    /// `rect` is in AppKit screen-local coordinates (lower-left origin) and
    /// must lie within `display.frame`. The engine flips Y to CG top-left.
    case region(display: SCDisplay, rect: CGRect)

    var pixelSize: CGSize {
        switch self {
        case .display(let d):
            return CGSize(width: d.width, height: d.height)
        case .application(_, _, let rect):
            return rect.size
        case .region(_, let rect):
            return rect.size
        }
    }
}
